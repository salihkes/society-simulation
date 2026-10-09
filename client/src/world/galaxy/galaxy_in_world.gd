@tool
class_name GalaxyInWorld
extends Node3D
## Places GalaxyMap geometry so the home planet's galaxy position is this node's origin, and streams planet scenes by distance.

## World units per galaxy unit.
@export var galaxy_scale := 500.0
@export var spawn_home_planet := false
## Local units; unload is larger so a ship at the boundary does not thrash.
@export var load_distance := 4000.0
@export var unload_distance := 6000.0
## Seconds between streaming distance checks.
@export var check_interval := 0.5
## Sun node in the hosting scene, used to wash the stars out in daylight.
@export var sun_name := "Sun_Move_Me_Around"
## Local units from the planet centre over which the day sky stops hiding the stars.
@export var atmosphere_top_start := 400.0
@export var atmosphere_top_end := 900.0
## Galaxy units beyond which a planet shows as a glint instead of a disc.
@export var disc_range := 7.0
## Editor only: shows every planet's scene at its galaxy position.
@export var editor_preview_scenes := true:
	set(v):
		editor_preview_scenes = v
		if Engine.is_editor_hint() and is_inside_tree():
			_spawn_editor_previews()

var map: GalaxyMap
## rid -> instanced planet scene
var _streamed := {}
## rid -> scene path being loaded on a thread
var _loading := {}
var _check_accum := 0.0
var _sun: Node3D


func _ready() -> void:
	map = GalaxyMap.new()
	var skip: Array = [] if spawn_home_planet else [GalaxyPlanets.HOME_RID]
	add_child(map)
	map.build_world(GalaxyPlanets.PLANETS, GalaxyPlanets.colors(), skip)
	var home := map.placement(GalaxyPlanets.PLANETS.get(GalaxyPlanets.HOME_RID, {}))
	map.scale = Vector3.ONE * galaxy_scale
	map.position = -home * galaxy_scale
	if Engine.is_editor_hint():
		_spawn_editor_previews.call_deferred()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_update_daylight_fade()
	_check_accum += delta
	if _check_accum < check_interval:
		return
	_check_accum = 0.0
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# Distances in local units, whatever the scene's scale.
	var unit := maxf(global_transform.basis.get_scale().x, 0.0001)
	for rid in map.planets:
		var path := str(GalaxyPlanets.PLANETS.get(rid, {}).get("scene", ""))
		if path == "":
			continue
		var d: float = map.planets[rid]["node"].global_position.distance_to(cam.global_position) / unit
		if _streamed.has(rid):
			if d > unload_distance:
				_unload(rid)
		elif _loading.has(rid):
			_finish_load(rid, d)
		elif d < load_distance and ResourceLoader.exists(path):
			ResourceLoader.load_threaded_request(path)
			_loading[rid] = path


func planet_local_position(rid: String) -> Vector3:
	return map.position + map.planets[rid]["pos"] * galaxy_scale


## Editor only: the instances are unowned, so never saved.
func _spawn_editor_previews() -> void:
	for child in get_children():
		if child.has_meta("planet_preview"):
			child.queue_free()
	if map == null or not editor_preview_scenes:
		return
	for rid in GalaxyPlanets.PLANETS:
		if rid == GalaxyPlanets.HOME_RID and not spawn_home_planet:
			continue
		var path := str(GalaxyPlanets.PLANETS[rid].get("scene", ""))
		if path == "" or not ResourceLoader.exists(path) or not map.planets.has(rid):
			continue
		var packed: PackedScene = load(path)
		if packed == null:
			continue
		var inst := packed.instantiate()
		inst.set_meta("planet_preview", true)
		if inst is Node3D:
			inst.position = planet_local_position(rid)
		add_child(inst)
		map.planets[rid]["node"].visible = false


func _has_scene(rid: String) -> bool:
	return GalaxyPlanets.PLANETS.get(rid, {}).has("scene")


## Daylight washes out stars and glints; near planets show as discs, far ones as glints.
func _update_daylight_fade() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or map == null:
		return
	var unit := maxf(global_transform.basis.get_scale().x, 0.0001)
	var fade := _sky_fade(cam, unit)
	for layer in map.sky_layers:
		layer.transparency = fade
		layer.visible = fade < 0.995
	for rid in map.planets:
		_fade_planet(rid, cam, unit, fade)


## How much daylight hides the sky: 0 at night or in space, 1 at noon.
func _sky_fade(cam: Camera3D, unit: float) -> float:
	if _sun == null:
		var scene_root := get_tree().current_scene
		_sun = scene_root.find_child(sun_name, true, false) if scene_root else null
	var to_cam := cam.global_position - global_position
	var up := to_cam.normalized()
	var daylight := 0.0
	if _sun:
		var sun_dir := (_sun.global_position - cam.global_position).normalized()
		daylight = smoothstep(-0.12, 0.18, up.dot(sun_dir))
	var altitude := to_cam.length() / unit
	var in_space: float = smoothstep(atmosphere_top_start, atmosphere_top_end, altitude)
	return clampf(daylight * (1.0 - in_space), 0.0, 1.0)


## A near disc only goes pale in daylight; the glint stays bright at any distance.
func _fade_planet(rid: String, cam: Camera3D, unit: float, fade: float) -> void:
	var p: Dictionary = map.planets[rid]
	var d_gu: float = p["node"].global_position.distance_to(cam.global_position) / (unit * galaxy_scale)
	var far_fade: float = smoothstep(disc_range * 0.7, disc_range, d_gu)
	var day_fade: float = fade * lerpf(0.45, 1.0, smoothstep(disc_range * 0.35, disc_range, d_gu))
	var sphere: GeometryInstance3D = p["mesh"]
	sphere.transparency = clampf(maxf(far_fade, day_fade), 0.0, 1.0)
	sphere.visible = sphere.transparency < 0.995
	var glint: float = smoothstep(disc_range * 0.45, disc_range * 0.8, d_gu)
	var beacon: GeometryInstance3D = p["beacon"]
	beacon.get_surface_override_material(0).albedo_color.a = glint * 0.95
	beacon.transparency = fade
	beacon.visible = fade < 0.995 and glint > 0.005
	var ring: GeometryInstance3D = p["ring"]
	if ring:
		ring.transparency = fade
		ring.get_surface_override_material(0).albedo_color.a = glint * (0.65 if _has_scene(rid) else 0.28)
		ring.visible = beacon.visible


## Skips the instance if the camera went beyond unload_distance meanwhile.
func _finish_load(rid: String, d: float) -> void:
	var path: String = _loading[rid]
	match ResourceLoader.load_threaded_get_status(path):
		ResourceLoader.THREAD_LOAD_LOADED:
			_loading.erase(rid)
			if d > unload_distance:
				return
			_instance_planet(rid, ResourceLoader.load_threaded_get(path))
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_warning("GalaxyInWorld: failed to load planet scene: " + path)
			_loading.erase(rid)


func _instance_planet(rid: String, scene: PackedScene) -> void:
	if scene == null or _streamed.has(rid):
		return
	var inst := scene.instantiate()
	if inst is Node3D:
		inst.position = planet_local_position(rid)
	add_child(inst)
	_streamed[rid] = inst
	map.planets[rid]["node"].visible = false


## Synchronous, so travel cannot arrive before the planet exists. Not in the editor.
func ensure_streamed(rid: String) -> void:
	if Engine.is_editor_hint() or _streamed.has(rid):
		return
	var path := str(GalaxyPlanets.PLANETS.get(rid, {}).get("scene", ""))
	if path == "" or not ResourceLoader.exists(path):
		return
	_loading.erase(rid)
	_instance_planet(rid, load(path))


func _unload(rid: String) -> void:
	var inst: Node = _streamed[rid]
	_streamed.erase(rid)
	if is_instance_valid(inst):
		inst.queue_free()
	map.planets[rid]["node"].visible = true
