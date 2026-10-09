@tool
extends Node3D
## Streams country terrain tiles around the observer with distance LOD and near colliders, in the Builds frame.

const TileJob = preload("res://src/world/region/terrain_tile_job.gd")
const RegionFiles = preload("res://src/world/region/region_files.gd")

@export_dir var data_dir := "res://assets/world/region/data"
@export var material: Material
@export_range(3, 16) var view_radius := 8
@export_range(1, 4) var collision_radius := 2
@export var build_collision := true
@export var preview_in_editor := true
@export var refresh_seconds := 0.2

var meta: Dictionary = {}
var _tiles: Dictionary = {}
var _wanted: Dictionary = {}
var _queue: Array[Vector2i] = []
var _failed: Dictionary = {}
var _size := 1024.0
var _quads := 64
var _bounds := Rect2i()
var _observer := Vector3.ZERO
var _override_observer := false
var _timer := 0.0
var _task := -1
var _task_key := Vector2i.ZERO
var _task_lod := 0
var _result: Dictionary = {}
var _loaded := false
var _uploads := 0
var _max_upload_usec := 0
var _max_worker_usec := 0
## RegionFiles, which fetches tiles this build does not carry.
var _files: Node = null
## Tile key -> true while its file downloads.
var _fetching: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint() and not preview_in_editor:
		return
	_load_manifest()
	if not Engine.is_editor_hint():
		_files = RegionFiles.instance(get_tree())
	if material != null:
		material = material.duplicate()
	_reconcile()


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Streaming stays off unless meta.json is valid.
func _load_manifest() -> void:
	var file := FileAccess.open(data_dir.path_join("meta.json"), FileAccess.READ)
	if file == null:
		push_error("Country terrain is not baked. Run tools/bake/regionforge/build_region.py")
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or parsed.get("format_version", 0) != 2:
		push_error("Invalid country terrain manifest")
		return
	meta = parsed
	_size = float(meta.get("tile_size", 0))
	_quads = int(meta.get("quads", 0))
	var b: Array = meta.get("tile_bounds", [])
	if _size <= 0 or _quads < 8 or (_quads & (_quads - 1)) != 0 or b.size() != 4:
		push_error("Invalid country tile dimensions")
		return
	_bounds = Rect2i(int(b[0]), int(b[1]), int(b[2]) - int(b[0]), int(b[3]) - int(b[1]))
	_loaded = _bounds.has_area()


func _process(delta: float) -> void:
	if not _loaded:
		return
	if not _override_observer:
		_follow_camera_position()
	_timer -= delta
	if _timer <= 0:
		_timer = refresh_seconds
		_reconcile()
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		_finish_task()
	if _task < 0:
		_start_next()


func _follow_camera_position() -> void:
	var camera: Camera3D
	if Engine.is_editor_hint():
		camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	else:
		camera = get_viewport().get_camera_3d()
	if camera != null:
		_observer = to_local(camera.global_position)


## Drops the result if the tile is no longer wanted at that LOD.
func _finish_task() -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if _result.has("error"):
		_failed[_task_key] = true
		push_error(_result.error)
	elif _wanted.has(_task_key) and int(_wanted[_task_key].lod) == _task_lod:
		_install(_task_key, _task_lod, _result)
	_result = {}


func tile_at(local_pos: Vector3) -> Vector2i:
	return Vector2i(floori(local_pos.x / _size), floori(local_pos.z / _size))


## For tests and travel tools. Ordinary play follows the active camera.
func set_viewer(world_position: Vector3) -> void:
	_observer = to_local(world_position)
	_override_observer = true
	_reconcile()


func follow_camera() -> void:
	_override_observer = false
	_timer = 0


## A tile keeps its old LOD until the replacement is ready, so nothing gaps.
func _reconcile() -> void:
	if not _loaded:
		return
	var centre := tile_at(_observer)
	var radius := clampi(view_radius, 3, 16)
	var physical_radius := clampi(collision_radius, 1, radius - 1)
	_wanted.clear()
	_queue.clear()
	for z in range(centre.y - radius, centre.y + radius + 1):
		for x in range(centre.x - radius, centre.x + radius + 1):
			_want_tile(Vector2i(x, z), centre, physical_radius)
	for key: Vector2i in _tiles.keys():
		if not _wanted.has(key):
			_tiles[key].node.queue_free()
			_tiles.erase(key)
		elif not _wanted[key].collision and _tiles[key].body != null:
			_tiles[key].body.queue_free()
			_tiles[key].body = null
	_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector2(a - centre).length_squared() < Vector2(b - centre).length_squared())


func _want_tile(key: Vector2i, centre: Vector2i, physical_radius: int) -> void:
	if not _bounds.has_point(key):
		return
	var ring := maxi(absi(key.x - centre.x), absi(key.y - centre.y))
	var lod := 0 if ring <= physical_radius else (1 if ring <= 3 else (2 if ring <= 5 else 3))
	var collision := build_collision and not Engine.is_editor_hint() and ring <= physical_radius
	_wanted[key] = {"lod": lod, "collision": collision}
	if _failed.has(key):
		return
	if not _tiles.has(key) or int(_tiles[key].lod) != lod:
		_queue.append(key)
	elif collision and _tiles[key].body == null:
		_queue.append(key)


func _start_next() -> void:
	while not _queue.is_empty():
		var key: Vector2i = _queue.pop_front()
		if not _wanted.has(key) or _failed.has(key):
			continue
		var target: Dictionary = _wanted[key]
		if _tiles.has(key) and int(_tiles[key].lod) == int(target.lod) and (not target.collision or _tiles[key].body != null):
			continue
		var source := _tile_source(key)
		if source.is_empty():
			continue
		var path: String = source.path
		var offset: int = source.offset
		_task_key = key
		_task_lod = int(target.lod)
		# Only this worker writes _result; the main thread reads it after joining.
		_task = WorkerThreadPool.add_task(func(): _result = TileJob.build(path, _quads, _size, _task_lod, offset))
		break


## {path, offset}: a page-file slot or an override file; {} while fetching (requested here) or after failure.
func _tile_source(key: Vector2i) -> Dictionary:
	var page_side := int(meta.page_side)
	var page := Vector2i(floori(float(key.x) / page_side), floori(float(key.y) / page_side))
	var offset := (posmod(key.y, page_side) * page_side + posmod(key.x, page_side)) * (_quads + 3) * (_quads + 3) * 4
	var path := data_dir.path_join(str(meta.tiles_dir)).path_join("%d_%d.bin" % [page.x, page.y])
	var override_path: String = meta.get("tile_overrides", {}).get("%d_%d" % [key.x, key.y], "")
	var length := (_quads + 3) * (_quads + 3) * 4
	if not override_path.is_empty():
		path = data_dir.path_join(override_path)
		offset = 0
		length = 0
	if _files == null:
		return {"path": path, "offset": offset}
	var located: Dictionary = _files.locate(path, offset, length)
	if located.is_empty():
		if _files.has_failed(path, offset, length):
			_failed[key] = true
			_fetching.erase(key)
		else:
			_fetching[key] = true
			_files.request(path, offset, length, Vector2(key - tile_at(_observer)).length())
		return {}
	_fetching.erase(key)
	return {"path": located.path, "offset": int(located.offset)}


## Reuses the tile's node and collider.
func _install(key: Vector2i, lod: int, result: Dictionary) -> void:
	var began := Time.get_ticks_usec()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, result.arrays)
	var node: MeshInstance3D
	var body: StaticBody3D = null
	if _tiles.has(key):
		node = _tiles[key].node
		body = _tiles[key].body
	else:
		node = MeshInstance3D.new()
		node.name = "Tile_%d_%d" % [key.x, key.y]
		node.position = Vector3(key.x * _size, 0, key.y * _size)
		node.material_override = material
		add_child(node)
		node.set_instance_shader_parameter("tile_origin", Vector2(key) * _size)
	node.mesh = mesh
	# Far terrain does not add shadow-map draw calls.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if lod == 0 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _wanted[key].collision and body == null:
		body = _add_collider(node, result.heights)
	_tiles[key] = {"node": node, "lod": lod, "body": body, "heights": result.heights, "triangles": result.triangles}
	_uploads += 1
	_max_upload_usec = maxi(_max_upload_usec, Time.get_ticks_usec() - began)
	_max_worker_usec = maxi(_max_worker_usec, int(result.worker_usec))


func _add_collider(node: MeshInstance3D, heights: PackedFloat32Array) -> StaticBody3D:
	var shape := HeightMapShape3D.new()
	shape.map_width = _quads + 1
	shape.map_depth = _quads + 1
	shape.map_data = heights
	var body := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = Vector3(_size * 0.5, 0, _size * 0.5)
	collider.scale = Vector3(_size / _quads, 1, _size / _quads)
	body.add_child(collider)
	node.add_child(body)
	return body


## Await prepare_position before moving an actor into an unloaded area.
func collision_ready(world_position: Vector3, radius := 1) -> bool:
	if not _loaded or not build_collision:
		return false
	var centre := tile_at(to_local(world_position))
	for z in range(centre.y - radius, centre.y + radius + 1):
		for x in range(centre.x - radius, centre.x + radius + 1):
			var key := Vector2i(x, z)
			if not _bounds.has_point(key) or not _tiles.has(key) or _tiles[key].body == null:
				return false
	return true


## Streams around world_position until collision is ready or the timeout passes, then follows the camera.
func prepare_position(world_position: Vector3, timeout_seconds := 15.0) -> bool:
	if not _loaded or not _bounds.has_point(tile_at(to_local(world_position))):
		return false
	set_viewer(world_position)
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000)
	while not collision_ready(world_position):
		if Time.get_ticks_msec() >= deadline:
			follow_camera()
			return false
		await get_tree().process_frame
	# Bodies must enter the physics world before the caller moves its actor.
	await get_tree().physics_frame
	follow_camera()
	return true


## Resident full-resolution data only; NAN means not loaded.
func height_at(x: float, z: float) -> float:
	var key := tile_at(Vector3(x, 0, z))
	if not _tiles.has(key):
		return NAN
	var h: PackedFloat32Array = _tiles[key].heights
	var p := (Vector2(x, z) - Vector2(key) * _size) * (_quads / _size)
	var ix := clampi(floori(p.x), 0, _quads - 1)
	var iz := clampi(floori(p.y), 0, _quads - 1)
	var i := iz * (_quads + 1) + ix
	return lerpf(lerpf(h[i], h[i + 1], p.x - ix), lerpf(h[i + _quads + 1], h[i + _quads + 2], p.x - ix), p.y - iz)


func get_streaming_stats() -> Dictionary:
	var bodies := 0
	var triangles := 0
	var height_bytes := 0
	for tile: Dictionary in _tiles.values():
		bodies += 1 if tile.body != null else 0
		triangles += int(tile.triangles)
		height_bytes += tile.heights.size() * 4
	return {"tiles": _tiles.size(), "wanted": _wanted.size(), "queued": _queue.size(), "colliders": bodies,
		"triangles": triangles, "height_bytes": height_bytes, "uploads": _uploads, "failed": _failed.size(),
		"max_upload_ms": _max_upload_usec / 1000.0, "max_worker_ms": _max_worker_usec / 1000.0,
		"fetching": _fetching.size(),
		"busy": _task >= 0 or not _queue.is_empty()}
