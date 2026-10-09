extends Node
## Sets the WorldEnvironment (day, sunset, night, space or a blend) from the camera's planet altitude.

@export var world_environment: WorldEnvironment
## Empty finds every StaticBody3D named "Planet*" beside this node; the "planets" group adds more.
@export var planets: Array[Node3D] = []
## The sun; its -Z points at the planet.
@export var sun_node: Node3D

## Atmosphere thickness as a fraction of the planet radius.
@export var atmosphere_height_ratio: float = 0.15

## Half-width of the atmosphere-edge blend band, as a fraction of the planet radius.
@export var transition_band_ratio: float = 0.03

@export var space_environment: Environment
@export var day_environment: Environment
@export var sunset_environment: Environment
@export var night_environment: Environment

@export var dof_far_distance_foot: float = 32.0
@export var dof_far_transition_foot: float = 22.0

@export var dof_far_distance_ship: float = 500.0
@export var dof_far_transition_ship: float = 200.0

enum Zone { SURFACE, TRANSITION, SPACE }

var _current_zone: int = -1
## Our own environment for the blend, so shared resources are never changed.
var _blend_env: Environment
## { node, center, radius } per tracked planet, refreshed every frame.
var _planet_cache: Array = []
var _cam_attrs: CameraAttributesPractical
## -1 unknown, 0 normal, 1 ship.
var _last_cam_was_ship: int = -1
## Seconds until the next "planets" group sweep.
var _group_rescan := 0.0


func _ready() -> void:
	if world_environment == null:
		push_warning("[ZoneEnvSwitcher] No WorldEnvironment assigned.")
		return
	if space_environment == null:
		space_environment = world_environment.environment

	if day_environment == null:
		day_environment = load("res://assets/world/environment/day_environment.tres")
	if sunset_environment == null:
		sunset_environment = load("res://assets/world/environment/sunriseset_environment.tres")
	if night_environment == null:
		night_environment = load("res://assets/world/environment/night_environment.tres")

	day_environment = _planet_safe(day_environment)
	sunset_environment = _planet_safe(sunset_environment)
	night_environment = _planet_safe(night_environment)

	_blend_env = Environment.new()

	# Depth of field stays off in the scene so the editor view is sharp.
	_cam_attrs = world_environment.camera_attributes as CameraAttributesPractical
	if _cam_attrs != null:
		_cam_attrs.dof_blur_far_enabled = true
		_cam_attrs.dof_blur_near_enabled = true

	if planets.is_empty():
		_auto_find_planets()
	for p in planets:
		if p == null:
			continue
		var info := _collect_planet_info(p)
		if info.radius <= 0.0:
			push_warning("[ZoneEnvSwitcher] Could not auto-detect radius for %s" % p.name)
			continue
		_planet_cache.append({ "node": p, "center": info.center, "radius": info.radius })
		print("[ZoneEnvSwitcher] %s  center=%s  radius=%.2f" % [p.name, info.center, info.radius])


func _auto_find_planets() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for c in parent.get_children():
		if c is StaticBody3D and (c.name as String).begins_with("Planet"):
			planets.append(c)


## get_surface_radius(), else the largest sphere collider, else SphereMesh; radius 0 if none.
func _collect_planet_info(p: Node3D) -> Dictionary:
	if p.has_method("get_surface_radius"):
		var s: float = p.global_transform.basis.get_scale().x
		return { "center": p.global_position, "radius": float(p.get_surface_radius()) * s }
	var found := _largest_sphere(p, false)
	if found.radius > 0.0:
		return found
	return _largest_sphere(p, true)


## { center, radius } of the largest sphere under p, skipping Area3D subtrees.
func _largest_sphere(p: Node3D, meshes: bool) -> Dictionary:
	var best_radius: float = 0.0
	var best_center: Vector3 = p.global_position
	var stack: Array = [p]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Area3D and n != p:
			continue
		for c in n.get_children():
			stack.push_back(c)
		var r := _sphere_radius(n, meshes)
		if r > best_radius:
			best_radius = r
			best_center = (n as Node3D).global_position
	return { "center": best_center, "radius": best_radius }


## The scaled radius of n's sphere shape (or SphereMesh), or 0.
func _sphere_radius(n: Node, meshes: bool) -> float:
	if not meshes and n is CollisionShape3D and n.shape is SphereShape3D:
		var s: float = (n as Node3D).global_transform.basis.get_scale().x
		return (n.shape as SphereShape3D).radius * s
	if meshes and n is MeshInstance3D and (n as MeshInstance3D).mesh is SphereMesh:
		var m := (n as MeshInstance3D).mesh as SphereMesh
		var s: float = (n as Node3D).global_transform.basis.get_scale().x
		return m.radius * s
	return 0.0


## A copy without SDFGI, SSIL and SSAO, which misbehave around a planet.
func _planet_safe(src: Environment) -> Environment:
	if src == null:
		return null
	var dup: Environment = src.duplicate(true)
	dup.sdfgi_enabled = false
	dup.ssil_enabled = false
	dup.ssao_enabled = false
	return dup


## Also re-sweeps the "planets" group every second.
func _process(delta: float) -> void:
	if world_environment == null:
		return
	_group_rescan -= delta
	if _group_rescan <= 0.0:
		_group_rescan = 1.0
		_scan_planet_group()
	if _planet_cache.is_empty():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return

	_update_dof_for_camera(cam)

	var nearest := _nearest_planet(cam)
	if nearest.is_empty():
		return
	var best_info: Dictionary = nearest.info
	var best_altitude: float = nearest.altitude
	var best_to_cam: Vector3 = nearest.to_cam

	var radius: float = best_info.radius
	var atmosphere_height: float = radius * atmosphere_height_ratio
	var transition_band: float = radius * transition_band_ratio

	if best_altitude <= atmosphere_height - transition_band:
		_apply_surface(best_to_cam)
	elif best_altitude >= atmosphere_height + transition_band:
		_apply_space()
	else:
		var t: float = (best_altitude - (atmosphere_height - transition_band)) / (2.0 * transition_band)
		_apply_transition(best_to_cam, clamp(t, 0.0, 1.0))


## {info, altitude, to_cam} of the planet the camera is lowest over; {} when none is valid.
func _nearest_planet(cam: Camera3D) -> Dictionary:
	var best_info: Dictionary = {}
	var best_altitude: float = INF
	var best_to_cam: Vector3 = Vector3.ZERO
	for info in _planet_cache:
		var p: Node3D = info.node
		if p == null or not is_instance_valid(p):
			continue
		var live := _collect_planet_info(p)
		info.center = live.center
		info.radius = live.radius
		var to_cam: Vector3 = cam.global_position - info.center
		var altitude: float = to_cam.length() - info.radius
		if altitude < best_altitude:
			best_altitude = altitude
			best_info = info
			best_to_cam = to_cam
	if best_info.is_empty():
		return {}
	return {"info": best_info, "altitude": best_altitude, "to_cam": best_to_cam}


## Drops freed planets and tracks new "planets" group members (streamed planets come and go).
func _scan_planet_group() -> void:
	for i in range(_planet_cache.size() - 1, -1, -1):
		var n: Node3D = _planet_cache[i].node
		if n == null or not is_instance_valid(n) or not n.is_inside_tree():
			_planet_cache.remove_at(i)
	for p in get_tree().get_nodes_in_group("planets"):
		if not (p is Node3D):
			continue
		var known := false
		for info in _planet_cache:
			if info.node == p:
				known = true
				break
		if known:
			continue
		var found := _collect_planet_info(p)
		if found.radius > 0.0:
			_planet_cache.append({ "node": p, "center": found.center, "radius": found.radius })
			print("[ZoneEnvSwitcher] tracking %s  radius=%.2f" % [p.name, found.radius])


## Long-range profile only for the external "ShipCamera"; a boarded player's camera stays normal.
func _update_dof_for_camera(cam: Camera3D) -> void:
	if _cam_attrs == null:
		return
	var is_ship := cam.name == "ShipCamera"

	var want := 1 if is_ship else 0
	if want == _last_cam_was_ship:
		return
	_last_cam_was_ship = want
	if is_ship:
		_cam_attrs.dof_blur_far_distance = dof_far_distance_ship
		_cam_attrs.dof_blur_far_transition = dof_far_transition_ship
	else:
		_cam_attrs.dof_blur_far_distance = dof_far_distance_foot
		_cam_attrs.dof_blur_far_transition = dof_far_transition_foot


## Direction towards the sun: the sun node faces the planet, so its +Z.
func _sun_direction() -> Vector3:
	if sun_node == null:
		return Vector3.UP
	return sun_node.global_transform.basis.z.normalized()


## Day, sunset or night by the sun's height over the camera's local horizon.
func _pick_surface_env(to_cam: Vector3) -> Environment:
	var up: Vector3 = to_cam.normalized()
	var d: float = up.dot(_sun_direction())
	if d > 0.15:
		return day_environment
	elif d > -0.15:
		return sunset_environment
	else:
		return night_environment


func _apply_surface(to_cam: Vector3) -> void:
	var env: Environment = _pick_surface_env(to_cam)
	if _current_zone != Zone.SURFACE or world_environment.environment != env:
		world_environment.environment = env
		_current_zone = Zone.SURFACE


func _apply_space() -> void:
	if _current_zone != Zone.SPACE:
		world_environment.environment = space_environment
		_current_zone = Zone.SPACE


## Surface (t = 0) to space (t = 1): the space sky with ambient and fog eased from the surface.
func _apply_transition(to_cam: Vector3, t: float) -> void:
	var surface_env: Environment = _pick_surface_env(to_cam)
	if surface_env == null or space_environment == null:
		return

	_blend_env.background_mode = space_environment.background_mode
	_blend_env.sky = space_environment.sky
	_blend_env.ambient_light_source = space_environment.ambient_light_source
	_blend_env.ambient_light_color = space_environment.ambient_light_color.lerp(
		surface_env.ambient_light_color, 1.0 - t
	)
	_blend_env.ambient_light_energy = lerp(
		surface_env.ambient_light_energy, space_environment.ambient_light_energy, t
	)
	_blend_env.fog_enabled = surface_env.fog_enabled
	_blend_env.fog_density = lerp(surface_env.fog_density, 0.0, t)

	world_environment.environment = _blend_env
	_current_zone = Zone.TRANSITION
