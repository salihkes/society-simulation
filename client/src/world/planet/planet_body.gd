extends StaticBody3D
class_name Planet
## A simple spherical planet body with mesh, collision and atmosphere; acts as a GravitySource.

@export var planet_name: String = "Unnamed Planet"
@export var gravity_strength: float = 9.8
## Distance from the centre beyond which there is no gravity.
@export var gravity_radius: float = 200.0
@export var surface_radius: float = 128.0
@export var atmosphere_color: Color = Color.CYAN
@export var planet_material: Material

var mesh_instance: MeshInstance3D
var collision_shape: CollisionShape3D
var atmosphere_effect: MeshInstance3D


func _ready():
	setup_planet_mesh()
	setup_collision()
	setup_atmosphere()


## Creates the MeshInstance3D child if missing.
func setup_planet_mesh():
	if has_node("MeshInstance3D"):
		mesh_instance = $MeshInstance3D
	else:
		mesh_instance = MeshInstance3D.new()
		add_child(mesh_instance)
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = surface_radius
	sphere_mesh.height = surface_radius * 2
	mesh_instance.mesh = sphere_mesh
	if planet_material:
		mesh_instance.material_override = planet_material


## Creates the CollisionShape3D child if missing; surface_radius then follows the shape.
func setup_collision():
	if has_node("CollisionShape3D"):
		collision_shape = $CollisionShape3D
	else:
		collision_shape = CollisionShape3D.new()
		add_child(collision_shape)
	if not collision_shape.shape:
		var sphere_shape = SphereShape3D.new()
		sphere_shape.radius = surface_radius
		collision_shape.shape = sphere_shape
	_update_surface_radius_from_shape()


func _update_surface_radius_from_shape():
	if not collision_shape or not collision_shape.shape:
		return
	var shape = collision_shape.shape
	if shape is SphereShape3D:
		surface_radius = (shape as SphereShape3D).radius
	elif shape is CapsuleShape3D:
		surface_radius = (shape as CapsuleShape3D).radius
	elif shape is CylinderShape3D:
		surface_radius = (shape as CylinderShape3D).top_radius
	elif shape is BoxShape3D:
		var size = (shape as BoxShape3D).size
		surface_radius = max(size.x, max(size.y, size.z)) * 0.5
	elif shape is ConvexPolygonShape3D or shape is ConcavePolygonShape3D:
		var estimated_radius = _estimate_radius_from_complex_shape()
		if estimated_radius > 0:
			surface_radius = estimated_radius
	print("Planet surface radius updated to: ", surface_radius, " for shape type: ", shape.get_class())


## Half the largest extent of the shape's debug mesh, else of the planet mesh, else surface_radius.
func _estimate_radius_from_complex_shape() -> float:
	if collision_shape and collision_shape.shape:
		var shape = collision_shape.shape
		if shape.has_method("get_debug_mesh"):
			var debug_mesh = shape.get_debug_mesh()
			if debug_mesh:
				return _half_extent(debug_mesh.get_aabb())
	if mesh_instance and mesh_instance.mesh:
		return _half_extent(mesh_instance.mesh.get_aabb())
	return surface_radius


func _half_extent(aabb: AABB) -> float:
	var size = aabb.size
	return max(size.x, max(size.y, size.z)) * 0.5


func setup_atmosphere():
	atmosphere_effect = MeshInstance3D.new()
	atmosphere_effect.name = "Atmosphere"
	add_child(atmosphere_effect)
	var atmosphere_mesh = SphereMesh.new()
	atmosphere_mesh.radius = surface_radius * 1.1
	atmosphere_mesh.height = surface_radius * 2.2
	atmosphere_effect.mesh = atmosphere_mesh
	var atmosphere_material = StandardMaterial3D.new()
	atmosphere_material.albedo_color = atmosphere_color
	atmosphere_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	atmosphere_material.albedo_color.a = 0.3
	atmosphere_material.emission_enabled = true
	atmosphere_material.emission = atmosphere_color * 0.5
	atmosphere_material.no_depth_test = true
	atmosphere_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	atmosphere_effect.material_override = atmosphere_material


## Zero beyond gravity_radius; scaled by linear falloffs from the centre and from the surface.
func get_gravity_force(target_position: Vector3) -> Vector3:
	var distance_to_planet = global_position.distance_to(target_position)
	if distance_to_planet > gravity_radius:
		return Vector3.ZERO
	var gravity_direction = (global_position - target_position).normalized()
	var gravity_falloff = 1.0 - (distance_to_planet / gravity_radius)
	gravity_falloff = max(gravity_falloff, 0.0)
	var surface_distance = max(distance_to_planet - surface_radius, 0.0)
	var surface_falloff = 1.0 - (surface_distance / (gravity_radius - surface_radius))
	surface_falloff = max(surface_falloff, 0.0)
	var final_strength = gravity_strength * gravity_falloff * surface_falloff
	return gravity_direction * final_strength


## True within 5 units above the surface (or anywhere inside).
func is_on_surface(target_position: Vector3) -> bool:
	var distance = global_position.distance_to(target_position)
	return distance <= (surface_radius + 5.0)


func get_surface_normal(target_position: Vector3) -> Vector3:
	return (target_position - global_position).normalized()
