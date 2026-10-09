@tool
extends Node3D
## Streams baked road corridor chunks around the viewer, built one at a time on a worker with distance LOD.

const Job = preload("res://src/world/region/road_chunk_job.gd")
const RoadShader = preload("res://src/world/region/road_material.gdshader")
const Furniture = preload("res://src/world/region/road_furniture.gd")
const RegionFiles = preload("res://src/world/region/region_files.gd")

@export var preview_in_editor := true
@export_file("*.json") var manifest_path := "res://assets/world/region/data/roads/manifest.json"
@export var view_distance := 6500.0
@export var collision_distance := 1500.0
@export var max_chunks := 40
@export var max_colliders := 10

var manifest: Dictionary = {}
var _chunks: Dictionary = {}
var _wanted: Dictionary = {}
var _queue: Array[int] = []
var _failed: Dictionary = {}
var _viewer := Vector3.ZERO
var _override_viewer := false
var _timer := 0.0
var _task := -1
var _task_id := -1
var _task_lod := 0
var _result: Dictionary = {}
var _material: ShaderMaterial
var _max_upload_ms := 0.0
## RegionFiles, which fetches chunks this build does not carry.
var _files: Node = null


func _ready() -> void:
	if Engine.is_editor_hint() and not preview_in_editor:
		return
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null:
		push_error("Road prototype is not baked. Run tools/bake/regionforge/build_roads.py")
		return
	var value: Variant = JSON.parse_string(file.get_as_text())
	if not value is Dictionary or value.get("format_version", 0) != 1 or value.get("row_stride", 0) != 10:
		push_error("Invalid road manifest")
		return
	manifest = value
	_material = ShaderMaterial.new()
	_material.shader = RoadShader
	_material.set_shader_parameter("road_length", float(manifest.length))
	Furniture.prepare()
	if not Engine.is_editor_hint():
		_files = RegionFiles.instance(get_tree())


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)


## Streams around world_position instead of the camera, starting now.
func set_viewer(world_position: Vector3) -> void:
	_viewer = to_local(world_position)
	_override_viewer = true
	_reconcile()


func follow_camera() -> void:
	_override_viewer = false
	_timer = 0


func _process(delta: float) -> void:
	if Engine.is_editor_hint() and not preview_in_editor:
		return
	if manifest.is_empty():
		return
	if not _override_viewer:
		_follow_camera_position()
	_timer -= delta
	if _timer <= 0:
		_timer = 0.2
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
		_viewer = to_local(camera.global_position)


## Drops the result if the chunk is no longer wanted at that LOD.
func _finish_task() -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if _result.has("error"):
		_failed[_task_id] = true
		push_error(_result.error)
	elif _wanted.has(_task_id) and int(_wanted[_task_id].lod) == _task_lod:
		_install(_task_id, _task_lod, _result)
	_result = {}


## On the ground plane, to the chunk's bounds.
func _distance(id: int) -> float:
	var b: Array = manifest.chunks[id].bounds
	return Vector2(maxf(maxf(b[0] - _viewer.x, _viewer.x - b[2]), 0),
		maxf(maxf(b[1] - _viewer.z, _viewer.z - b[3]), 0)).length()


## Keeps the nearest max_chunks within view_distance, queues those needing a build, frees the rest.
func _reconcile() -> void:
	if manifest.is_empty():
		return
	var candidates := _candidates()
	var ids: Array = candidates.keys()
	ids.sort_custom(func(a, b): return candidates[a] < candidates[b])
	_wanted.clear()
	_queue.clear()
	var colliders := 0
	for index in mini(ids.size(), max_chunks):
		var id: int = ids[index]
		var distance: float = candidates[id]
		var physical := not Engine.is_editor_hint() and distance <= collision_distance and colliders < max_colliders
		colliders += int(physical)
		var lod := 0 if distance <= collision_distance else 1 if distance < 3500 else 2
		_wanted[id] = {"lod": lod, "collision": physical}
		if _failed.has(id):
			continue
		if not _chunks.has(id) or _chunks[id].lod != lod or (physical and _chunks[id].body == null):
			_queue.append(id)
	for id in _chunks.keys():
		if not _wanted.has(id):
			_chunks[id].node.queue_free()
			_chunks.erase(id)
		elif not _wanted[id].collision and _chunks[id].body != null:
			_chunks[id].body.queue_free()
			_chunks[id].body = null


## {chunk id: distance} within view_distance, via the manifest's 1024 m spatial index.
func _candidates() -> Dictionary:
	var candidates: Dictionary = {}
	var center := Vector2i(floori(_viewer.x / 1024), floori(_viewer.z / 1024))
	var radius := ceili(view_distance / 1024)
	for z in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			_add_cell_candidates("%d_%d" % [x, z], candidates)
	return candidates


func _add_cell_candidates(cell: String, candidates: Dictionary) -> void:
	for id in manifest.spatial_index.get(cell, []):
		var distance := _distance(int(id))
		if distance <= view_distance:
			candidates[int(id)] = distance


func _start_next() -> void:
	while not _queue.is_empty():
		var id: int = _queue.pop_front()
		if not _wanted.has(id) or _failed.has(id):
			continue
		if _chunks.has(id) and _chunks[id].lod == _wanted[id].lod and (not _wanted[id].collision or _chunks[id].body != null):
			continue
		var path := _chunk_path(id)
		if path == "":
			continue
		_task_id = id
		_task_lod = int(_wanted[id].lod)
		var count: int = manifest.chunks[id].rows
		var lod := _task_lod
		var length: float = manifest.length
		_task = WorkerThreadPool.add_task(func(): _result = Job.build(path, count, lod, length))
		break


## "" while RegionFiles still has to fetch it (requested here) or after it failed to.
func _chunk_path(id: int) -> String:
	var path := manifest_path.get_base_dir().path_join(str(manifest.chunks[id].file))
	if _files == null:
		return path
	var located: Dictionary = _files.locate(path)
	if not located.is_empty():
		return located.path
	if _files.has_failed(path):
		_failed[id] = true
	else:
		_files.request(path, 0, 0, _distance(id) / 1024.0)
	return ""


## Replaces an older mesh; furniture at lod 0 and 1.
func _install(id: int, lod: int, result: Dictionary) -> void:
	var began := Time.get_ticks_usec()
	if _chunks.has(id):
		_chunks[id].node.queue_free()
	var node := MeshInstance3D.new()
	node.name = "Road_%d" % id
	var p: Array = manifest.chunks[id].origin
	node.position = Vector3(p[0], p[1], p[2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, result.arrays)
	node.mesh = mesh
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if lod == 0 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	if lod < 2:
		Furniture.install(node, result.get("signs", []))
	var body: StaticBody3D = null
	if _wanted[id].collision:
		body = _add_collider(node, result.collision)
	_chunks[id] = {"node": node, "body": body, "lod": lod, "triangles": result.triangles}
	_max_upload_ms = maxf(_max_upload_ms, (Time.get_ticks_usec() - began) / 1000.0)


func _add_collider(node: Node3D, faces: PackedVector3Array) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var surface := ConcavePolygonShape3D.new()
	surface.set_faces(faces)
	surface.backface_collision = true
	shape.shape = surface
	body.add_child(shape)
	node.add_child(body)
	return body


## False until the manifest is loaded.
func collision_ready(world_position: Vector3) -> bool:
	var p := to_local(world_position)
	var key := "%d_%d" % [floori(p.x / 1024), floori(p.z / 1024)]
	for value in manifest.get("spatial_index", {}).get(key, []):
		var id := int(value)
		if not _chunks.has(id) or _chunks[id].body == null:
			return false
	return not manifest.is_empty()


func get_streaming_stats() -> Dictionary:
	var physical := 0
	var triangles := 0
	for chunk: Dictionary in _chunks.values():
		physical += int(chunk.body != null)
		triangles += int(chunk.triangles)
	return {"chunks": _chunks.size(), "colliders": physical, "triangles": triangles,
		"busy": _task >= 0 or not _queue.is_empty(), "failed": _failed.size(), "max_upload_ms": _max_upload_ms}
