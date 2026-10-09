extends Node3D
## Snow cover: the weather owner simulates depth and tracks; every display paints them into patches.

const State = preload("res://src/world/environment/snow_state.gd")
const Patch = preload("res://src/world/environment/snow_patch.gd")

@export_range(1, 8) var patch_radius := 5
@export var rays_per_tick := 384

var state = State.new()
var weather: Node
var render_enabled := true
var _patches := {}
var _queue: Array = []
var _centre := Vector2i(100000, 100000)
var _view := Vector3.ZERO
var _layout_timer := 0.0
var _contact_timer := 0.0
var _terrain_timer := 0.0
var _contacts := {}
var _paint_epoch := ""
var _sea_level := -10000.0
var _cast_top := 256.0
var _cast_bottom := -512.0
var _send_timer := 1.0
var _config := {}
var _headless := false
var _full_next := true


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_headless = DisplayServer.get_name() == "headless"
	render_enabled = not _headless
	var packs := get_node_or_null("/root/PCKManager")
	if packs != null and packs.has_signal("placeholders_materialized"):
		packs.placeholders_materialized.connect(func(_count): refresh_surfaces())


## Stores the snow config, applied to the state while this peer owns it.
func configure(config: Dictionary) -> void:
	_config = config.duplicate(true)
	if owns_state():
		state.configure(_config)


func owns_state() -> bool:
	return weather != null and weather._owns_weather()


## Advances the owned state, the distant terrain's snow and, with a display, the nearby patches.
func advance(delta: float, snowing: bool) -> void:
	if owns_state():
		_advance_state(delta, snowing)
	_send_timer += delta
	_terrain_timer += delta
	if _terrain_timer >= 1.0:
		_terrain_timer = 0.0
		_update_distant_terrain()
	if not render_enabled:
		return
	visible = state.depth > 0.0005
	if not visible:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	_view = camera.global_position
	_layout_timer -= delta
	if _layout_timer <= 0.0:
		_layout_timer = 0.5
		_update_layout()
	_update_materials()
	_paint_tracks()


## With regional weather the track clock follows the home region and depth is the deepest region's.
func _advance_state(delta: float, snowing: bool) -> void:
	# Also applies a command that arrived before this peer became the owner.
	state.configure(_config)
	if _regional():
		var anchor: Dictionary = weather.regional.states[Identity.value("home_region")]
		state.advance(delta, anchor.type == "snow")
		state.depth = 0.0
		for region in weather.regional.states.values():
			state.depth = maxf(state.depth, float(region.snow_depth))
	else:
		state.advance(delta, snowing)


func _regional() -> bool:
	return weather != null and weather.get("regional_weather") == true and str(weather.get("override_type")) == ""


func _depth_at(point: Vector3) -> float:
	return float(weather.conditions_at(point).snow_depth) if _regional() else state.depth


## The next state packet to send (at most every 0.5 s unless forced), or {}.
func snapshot(force := false) -> Dictionary:
	if not force and _send_timer < 0.5:
		return {}
	_send_timer = 0.0
	var packet: Dictionary = state.packet(force or _full_next)
	state._sent = state.last
	_full_next = false
	return packet


func request_full_snapshot() -> void:
	_full_next = true
	_send_timer = 1.0


func apply_snapshot(packet: Dictionary, initial := false) -> bool:
	if owns_state() and not initial:
		return false
	return state.apply_packet(packet)


## Samples contacts every 0.1 s when owning; traces patch samples within rays_per_tick and 3 ms.
func _physics_process(delta: float) -> void:
	if state.depth <= 0.001:
		_contacts.clear()
		return
	if owns_state():
		_contact_timer -= delta
		if _contact_timer <= 0.0:
			_contact_timer = 0.1
			_sample_contacts()
	if not render_enabled or _queue.is_empty():
		return
	var began := Time.get_ticks_usec()
	for i in rays_per_tick:
		if _queue.is_empty():
			break
		var patch = _queue[0]
		var p: Vector2 = patch.next_position()
		var hit := static_hit(Vector3(p.x, _cast_top, p.y), Vector3(p.x, _cast_bottom, p.y))
		patch.sample(hit, _sea_level)
		if patch.complete():
			_queue.pop_front()
		if Time.get_ticks_usec() - began > 3000:
			break


## First StaticBody3D hit, skipping up to 12 other bodies (cars and people are not ground); {} if none.
func static_hit(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var space := get_world_3d().direct_space_state
	for attempt in 12:
		var hit := space.intersect_ray(query)
		if hit.is_empty() or hit.collider is StaticBody3D:
			return hit
		var excluded := query.exclude
		excluded.append(hit.rid)
		query.exclude = excluded
	return {}


## Re-centres the grid once the view clearly leaves the centre patch; nearest patches queue first.
func _update_layout() -> void:
	var world := get_tree().current_scene
	var sea = world.find_child("CitySea", true, false) if world != null else null
	if sea is Node3D:
		_sea_level = sea.global_position.y
	_cast_top = _view.y + 256.0
	_cast_bottom = _view.y - 512.0
	var centre := Vector2i(floori(_view.x / Patch.SIZE), floori(_view.z / Patch.SIZE))
	if centre == _centre:
		return
	var offset := Vector2(_view.x, _view.z) - (Vector2(_centre) + Vector2.ONE * 0.5) * Patch.SIZE
	if maxf(absf(offset.x), absf(offset.y)) < Patch.SIZE * 0.65:
		# Hysteresis, so swaying at a patch boundary is not travel.
		return
	_centre = centre
	var wanted := {}
	for z in range(-patch_radius, patch_radius + 1):
		for x in range(-patch_radius, patch_radius + 1):
			var key := centre + Vector2i(x, z)
			var distance := maxi(absi(x), absi(z))
			wanted[key] = true
			_want_patch(key, 128 if distance <= 1 else 16)
	for key in _patches.keys():
		if not wanted.has(key):
			var patch = _patches[key]
			_queue.erase(patch)
			patch.dispose()
			_patches.erase(key)
	_queue.sort_custom(func(a, b): return (Vector2(a.key) - Vector2(_centre)).length_squared() < (Vector2(b.key) - Vector2(_centre)).length_squared())


## Creates the patch at key, or rebuilds it at a new resolution.
func _want_patch(key: Vector2i, cells: int) -> void:
	if _patches.has(key) and _patches[key].cells != cells:
		var patch = _patches[key]
		patch.rebuild(cells)
		if not _queue.has(patch):
			_queue.append(patch)
	if not _patches.has(key):
		var patch = Patch.new()
		patch.setup(key, cells, self)
		_patches[key] = patch
		_queue.append(patch)


## Resamples every patch, after packs arrive or the collision changes.
func refresh_surfaces() -> void:
	for patch in _patches.values():
		patch.rebuild(patch.cells)
		if not _queue.has(patch):
			_queue.append(patch)


func _update_materials() -> void:
	var centre := Vector2(_view.x, _view.z)
	for patch in _patches.values():
		var material: ShaderMaterial = patch.material
		material.set_shader_parameter("snow_depth", _depth_at(Vector3((patch.key.x + 0.5) * Patch.SIZE, 0, (patch.key.y + 0.5) * Patch.SIZE)))
		material.set_shader_parameter("snowfall", state.snowfall)
		material.set_shader_parameter("snow_time", state.elapsed)
		material.set_shader_parameter("first_track", float(state.first))
		material.set_shader_parameter("view_center", centre)
		material.set_shader_parameter("view_radius", maxf(6.0, (patch_radius - 0.25) * Patch.SIZE))


## Paints new track records into every patch; a new epoch clears them.
func _paint_tracks() -> void:
	if _paint_epoch != state.epoch:
		_paint_epoch = state.epoch
		for patch in _patches.values():
			patch.clear_tracks()
	for patch in _patches.values():
		if patch.painted < state.last:
			for i in range(maxi(0, patch.painted + 1 - state.first), state.records.size()):
				patch.paint(state.records[i], state.first + i, state.snowfall, state.elapsed, state.first)
		patch.upload()


## Updates the sea level and the snow on the distant CityTerrain.
func _update_distant_terrain() -> void:
	var world := get_tree().current_scene
	var sea = world.find_child("CitySea", true, false) if world != null else null
	if sea is Node3D:
		_sea_level = sea.global_position.y
	if not render_enabled:
		return
	var terrain = world.find_child("CityTerrain", true, false) if world != null else null
	if terrain != null and terrain.get("material") is ShaderMaterial:
		terrain.material.set_shader_parameter("snow_depth", _depth_at(terrain.global_position))
		if _regional():
			weather.set_regional_shader(terrain.material, "snow_depth")
		else:
			terrain.material.set_shader_parameter("regional_enabled", false)


func _sample_contacts() -> void:
	var world := get_tree().current_scene
	if world == null:
		return
	var actors := {}
	var manager = world.find_child("AmbientManager", true, false)
	if manager != null:
		_add_actors(actors, manager.peds(), false)
		_add_actors(actors, manager.residents(), false)
		var traffic = manager.get("traffic")
		_add_actors(actors, traffic.cars if traffic != null else null, true)
	var vehicles = world.find_child("VehicleManager", true, false)
	if vehicles != null and vehicles.get("_vehicles") is Dictionary:
		_add_actors(actors, vehicles._vehicles, true)
	var network = get_node_or_null("/root/NetworkController")
	if network != null:
		_add_actors(actors, network.get_indexed("players:remote_players"), false)
		var local = network.get_indexed("players:local_player")
		if is_instance_valid(local):
			actors[local.get_instance_id()] = [local, false]
	for id in actors:
		var body: Node3D = actors[id][0]
		if actors[id][1]:
			_vehicle_contacts(body, id)
		else:
			_walker_contacts(body, id)
	for id in _contacts.keys():
		if not actors.has(id):
			_contacts.erase(id)


## Adds the valid bodies of a Dictionary to actors as [body, is_vehicle].
func _add_actors(actors: Dictionary, bodies: Variant, vehicle: bool) -> void:
	if not bodies is Dictionary:
		return
	for body in bodies.values():
		if is_instance_valid(body):
			actors[body.get_instance_id()] = [body, vehicle]


## One footprint per stride since the last sample; jumps (teleports, rides) leave none.
func _walker_contacts(body: Node3D, id: int) -> void:
	var position := body.global_position
	var scale_m := maxf(0.05, body.global_basis.get_scale().y)
	var previous: Dictionary = _contacts.get(id, {})
	_contacts[id] = {"position": position, "distance": previous.get("distance", 0.0), "side": previous.get("side", 1.0)}
	if previous.is_empty() or body.get("sitting") == true:
		return
	var travel := position - Vector3(previous.position)
	travel.y = 0.0
	var distance := travel.length()
	if distance < 0.005 or distance > 3.0:
		return
	var stride := clampf(scale_m * 1.8, 0.22, 0.8)
	var walked := float(previous.distance) + distance
	if walked < stride:
		_contacts[id].distance = walked
		return
	var forward := travel.normalized()
	var right := Vector3(forward.z, 0, -forward.x)
	var side := float(previous.side)
	var remaining := stride - float(previous.distance)
	while remaining <= distance:
		var centre: Vector3 = Vector3(previous.position).lerp(position, remaining / distance)
		var foot := centre + right * side * scale_m * 0.45
		var hit := static_hit(foot + Vector3.UP * 0.1, foot - Vector3.UP * scale_m * 3.8)
		if not hit.is_empty() and hit.normal.y > 0.55 and position.y - hit.position.y < scale_m * 3.8:
			_stamp_exposed(hit.position, atan2(forward.x, forward.z), clampf(scale_m * 0.65, 0.08, 0.22), clampf(scale_m * 1.25, 0.14, 0.38), false)
		side *= -1.0
		remaining += stride
	_contacts[id].distance = fmod(walked, stride)
	_contacts[id].side = side


func _vehicle_contacts(body: Node3D, id: int) -> void:
	var scale_m := maxf(0.05, body.global_basis.get_scale().x)
	var points := _wheel_points(body)
	var previous: Dictionary = _contacts.get(id, {})
	_contacts[id] = {"wheels": points}
	if previous.is_empty():
		return
	var old: Array = previous.get("wheels", [])
	# The axle choice changed with steering; do not join unrelated wheels.
	if old.size() != points.size():
		return
	for i in mini(points.size(), old.size()):
		var movement := points[i] - Vector3(old[i])
		movement.y = 0.0
		var distance := movement.length()
		if distance < 0.025 or distance > 6.0:
			continue
		var samples := maxi(1, ceili(distance / 1.5))
		for sample in samples:
			var p: Vector3 = Vector3(old[i]).lerp(points[i], (sample + 0.5) / samples)
			var hit := static_hit(p + Vector3.UP * scale_m, p - Vector3.UP * scale_m * 2.5)
			if not hit.is_empty() and hit.normal.y > 0.55:
				_stamp_exposed(hit.position, atan2(movement.x, movement.z), clampf(scale_m * 1.15, 0.12, 0.5), distance / samples + 0.12, true)


## One axle driving straight (the other follows its grooves), all while steering, or two fixed points.
func _wheel_points(body: Node3D) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var vm = body.get("_vm")
	if vm != null and is_instance_valid(vm):
		for wheel in vm.wheel_positions_local():
			points.append(vm.to_global(wheel))
		if points.size() >= 4 and absf(float(body.get("_steer"))) < 0.08:
			points.sort_custom(func(a, b):
				var pa: Vector3 = body.to_local(a)
				var pb: Vector3 = body.to_local(b)
				return pa.z > pb.z if absf(pa.z - pb.z) > 0.01 else pa.x < pb.x)
			points.resize(2)
	if points.is_empty():
		for x in [-2.8, 2.8]:
			for z in [5.2]:
				points.append(body.to_global(Vector3(x, 1.0, z)))
	return points


## Skips positions without snow, at sea level, or sheltered from above.
func _stamp_exposed(position: Vector3, yaw: float, width: float, length: float, tire: bool) -> void:
	if _depth_at(position) <= 0.001 or position.y <= _sea_level + 0.02:
		return
	var shelter := static_hit(position + Vector3.UP * 0.06, position + Vector3.UP * 256.0)
	if shelter.is_empty():
		state.stamp(position, yaw, width, length, tire)
