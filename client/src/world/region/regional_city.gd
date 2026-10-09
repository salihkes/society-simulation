@tool
extends Node3D
## A city in the country, placed from its placement JSON; its model loads on approach and frees on leaving.

const WorldGeo := preload("res://src/world/region/world_geo.gd")

@export_file("*.json") var placement_path := ""
@export var preview_in_editor := true
## Region whose packs this city needs; empty means the region the placement stands in.
@export var region_id := ""
## Pack prefetch starts at this multiple of load_distance.
@export var prefetch_factor := 3.0

var placement: Dictionary = {}
var _city: Node3D
var _loading := false
var _failed := false
var _timer := 0.0
var _override_viewer := false
var _viewer := Vector3.ZERO


func _ready() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(placement_path))
	if not parsed is Dictionary:
		push_error("Missing city placement: run regionforge --stamps-only")
		set_process(false)
		return
	placement = parsed
	var p: Array = placement.position
	position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	rotation.y = float(placement.rotation_y)
	# The model keeps its authored size.
	scale = Vector3.ONE
	if region_id == "":
		region_id = str(WorldGeo.region_at(Vector2(position.x, position.z)).get("id", ""))


func set_viewer(world_position: Vector3) -> void:
	_override_viewer = true
	_viewer = world_position
	_timer = 0


func follow_camera() -> void:
	_override_viewer = false
	_timer = 0


func _content_here(path: String) -> bool:
	var packs = get_node_or_null("/root/PCKManager")
	if packs != null and packs.has_method("region_required_ready") and not packs.region_required_ready(region_id):
		return false
	return ResourceLoader.exists(path)


## Starts the region's downloads in PCKManager.
func _approach(distance: float) -> void:
	if distance > float(placement.load_distance) * prefetch_factor:
		return
	var packs = get_node_or_null("/root/PCKManager")
	if packs != null and packs.has_method("enter_region") and not packs.has_entered_region(region_id):
		print("[RegionalCity] approaching %s: entering region '%s'" % [name, region_id])
		packs.enter_region(region_id)


static func _is_world_process() -> bool:
	if Engine.is_editor_hint():
		return false
	return OS.get_cmdline_user_args().has("--world") or OS.get_environment("GAME_WORLD") == "1"


func is_city_loaded() -> bool:
	return is_instance_valid(_city)


func _process(delta: float) -> void:
	if placement.is_empty() or _failed:
		return
	if Engine.is_editor_hint() and not preview_in_editor:
		return
	_timer -= delta
	if _timer > 0:
		return
	_timer = 0.2
	if not _update_viewer():
		return
	var local := to_local(_viewer)
	var distance := Vector2(local.x, local.z).length()
	var path: String = placement.model_scene
	if not Engine.is_editor_hint():
		_approach(distance)
	if _loading:
		_poll_load(path, distance)
	elif is_city_loaded():
		if distance > float(placement.unload_distance):
			_city.queue_free()
			_city = null
	elif distance < float(placement.load_distance):
		if not _content_here(path):
			return
		var error := ResourceLoader.load_threaded_request(path, "PackedScene", true, ResourceLoader.CACHE_MODE_IGNORE)
		_loading = error == OK
		if not _loading:
			_failed = true
			push_error("Cannot start regional city load: " + error_string(error))


## The city itself in the world process, else the set_viewer() override, else the camera; false without one.
func _update_viewer() -> bool:
	if _is_world_process():
		_viewer = global_position
	if _override_viewer or _is_world_process():
		return true
	var camera: Camera3D
	if Engine.is_editor_hint():
		camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	else:
		camera = get_viewport().get_camera_3d()
	if camera == null:
		return false
	_viewer = camera.global_position
	return true


## A failed load stops further attempts.
func _poll_load(path: String, distance: float) -> void:
	var status := ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		var packed := ResourceLoader.load_threaded_get(path) as PackedScene
		_loading = false
		if packed != null and distance < float(placement.unload_distance):
			_add_city(packed)
	elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		_loading = false
		_failed = true
		push_error("Cannot load regional city: " + path)


func _add_city(packed: PackedScene) -> void:
	_city = packed.instantiate() as Node3D
	_city.name = "CityModel"
	add_child(_city)
	# Optional buildings arrive as placeholders until their packs are in.
	var packs = get_node_or_null("/root/PCKManager")
	if packs != null and packs.has_method("materialize_placeholders"):
		packs.materialize_placeholders()
