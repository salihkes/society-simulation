extends StaticBody3D
## Base for a planet scene: a gravity source in the "planets" group, at real scale.

## Name of the sun node in the hosting scene.
@export var sun_name := "Sun_Move_Me_Around"
## Ground radius; replaced by a PlanetTerrain child's data radius if present.
@export var surface_radius := 320.0
## Surface gravity, m/s².
@export var gravity_strength := 9.8
## No pull beyond this distance; raised to 5x the radius with terrain data.
@export var gravity_range := 3000.0

var _terrain: PlanetTerrain


func _enter_tree() -> void:
	add_to_group("planets")


## Points Atmosphere and VolumetricClouds at the hosting scene's sun, which their scene cannot reference.
func _ready() -> void:
	for child in get_children():
		if child is PlanetTerrain:
			_terrain = child
			if _terrain.data:
				surface_radius = _terrain.data.radius
				gravity_range = maxf(gravity_range, surface_radius * 5.0)
			break
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var sun := scene_root.find_child(sun_name, true, false)
	if sun == null:
		return
	var atmosphere := get_node_or_null("Atmosphere")
	if atmosphere:
		atmosphere.sun_object = sun.get_node_or_null("SunMesh")
		atmosphere.set_physics_process(atmosphere.sun_object != null)
	var clouds := get_node_or_null("VolumetricClouds")
	if clouds:
		clouds.sun_object = sun
		clouds.set_physics_process(true)


## Pull toward the centre at constant strength within gravity_range.
func get_gravity_force(target_position: Vector3) -> Vector3:
	var to_center := global_position - target_position
	var d := to_center.length()
	if d > gravity_range or d < 0.001:
		return Vector3.ZERO
	return to_center / d * gravity_strength


func get_surface_normal(target_position: Vector3) -> Vector3:
	return (target_position - global_position).normalized()


func is_on_surface(target_position: Vector3, margin := 3.0) -> bool:
	return global_position.distance_to(target_position) <= surface_height_at(target_position) + margin


func get_gravity_priority() -> int:
	return 0   # ships have higher priority, so their deck wins


## Distance from the centre to the ground under a world position.
func surface_height_at(target_position: Vector3) -> float:
	if _terrain and is_instance_valid(_terrain):
		var dir := (to_local(target_position)).normalized()
		if dir.length_squared() > 0.5:
			return surface_radius + _terrain.height_at_dir(dir)
	return surface_radius


func get_surface_radius() -> float:
	return surface_radius


## Planet-local transform standing something on the ground in direction dir, up along dir.
func place_on_surface(dir: Vector3, yaw := 0.0, h_off := 0.0, scale := 1.0) -> Transform3D:
	dir = dir.normalized()
	var h := surface_height_at(to_global(dir * surface_radius))
	var east: Vector3 = CubeSphere.tangent_frame(dir)[0]
	var fwd := east.rotated(dir, yaw)
	fwd = (fwd - dir * fwd.dot(dir)).normalized()
	var basis := Basis(dir.cross(fwd).normalized(), dir, fwd)
	if scale != 1.0:
		basis = basis.scaled(Vector3.ONE * scale)
	return Transform3D(basis, dir * (h + h_off))
