extends Node
## Walkable graph from the Path3D curves under the parent, in parent (workspace) space; NPCs ask it for routes.

## Sample spacing along each curve, in local units.
@export var sample_interval := 10.0
## Samples of different paths closer than this are connected.
@export var connection_threshold := 15.0

var _points: PackedVector3Array = PackedVector3Array()
var _edges: Dictionary = {}           # point_idx -> PackedInt32Array of neighbors
var _point_meta: Array[Dictionary] = []  # per point: {"path": path_idx, "offset": float}

var _workspace: Node3D = null
var _built := false


func _ready():
	_workspace = get_parent()
	# Wait a frame so every Path3D is ready.
	await get_tree().process_frame
	rebuild()


func rebuild():
	_points = PackedVector3Array()
	_edges.clear()
	_point_meta.clear()

	var paths: Array[Path3D] = []
	_collect_paths(get_parent(), paths)

	if paths.is_empty():
		print("[NpcPathNetwork] No Path3D nodes found — path navigation disabled")
		_built = false
		return

	for path_idx in paths.size():
		_sample_path(paths[path_idx], path_idx)
	_connect_across_paths()

	_built = true
	print("[NpcPathNetwork] Built graph: %d points, %d paths" % [_points.size(), paths.size()])


func _sample_path(path: Path3D, path_idx: int) -> void:
	var curve: Curve3D = path.curve
	if curve == null or curve.point_count < 2:
		return

	var length := curve.get_baked_length()
	if length < 0.01:
		return

	var num_samples := maxi(2, int(length / sample_interval) + 1)
	for i in num_samples:
		var offset: float = float(i) / float(num_samples - 1) * length
		var ws_pos: Vector3 = _to_workspace(path, curve.sample_baked(offset))

		var idx := _points.size()
		_points.append(ws_pos)
		_point_meta.append({"path": path_idx, "offset": offset})
		_edges[idx] = PackedInt32Array()
		if i > 0:
			_connect(idx, idx - 1)


func _connect_across_paths() -> void:
	for i in _points.size():
		var pi: int = _point_meta[i]["path"]
		for j in range(i + 1, _points.size()):
			if _point_meta[j]["path"] == pi:
				continue
			if _edges[i].has(j):
				continue
			if _points[i].distance_to(_points[j]) <= connection_threshold:
				_connect(i, j)


## Skips NPC and player bodies.
func _collect_paths(node: Node, out: Array[Path3D]):
	for child in node.get_children():
		if child is Path3D:
			out.append(child)
		elif not (child is CharacterBody3D):
			_collect_paths(child, out)


func _to_workspace(path: Path3D, local_pos: Vector3) -> Vector3:
	if _workspace == null:
		return local_pos
	return _workspace.to_local(path.to_global(local_pos))


func _connect(a: int, b: int):
	if not _edges[a].has(b):
		_edges[a].append(b)
	if not _edges[b].has(a):
		_edges[b].append(a)


func has_paths() -> bool:
	return _built and _points.size() > 0


## -1 when the graph is empty.
func nearest_point_index(pos: Vector3) -> int:
	var best := -1
	var best_d := INF
	for i in _points.size():
		var d := pos.distance_to(_points[i])
		if d < best_d:
			best_d = d
			best = i
	return best


func nearest_point_position(pos: Vector3) -> Vector3:
	var idx := nearest_point_index(pos)
	if idx >= 0:
		return _points[idx]
	return pos


## Fewest-hop route ending with `to`; just [to] when there is no route.
func find_route(from: Vector3, to: Vector3) -> Array[Vector3]:
	if not _built or _points.size() == 0:
		return [to]

	var start := nearest_point_index(from)
	var goal := nearest_point_index(to)
	if start < 0 or goal < 0:
		return [to]
	if start == goal:
		return [_points[goal], to]

	var parent := _bfs_parents(start, goal)
	if not parent.has(goal):
		return [to]

	var route: Array[Vector3] = []
	var idx := goal
	while idx != -1:
		route.insert(0, _points[idx])
		idx = parent.get(idx, -1)

	# The destination itself may lie off the graph.
	route.append(to)
	return route


## Parent map (start -> -1); `goal` is in it only when reachable.
func _bfs_parents(start: int, goal: int) -> Dictionary:
	var parent: Dictionary = {start: -1}
	var queue: Array[int] = [start]
	while queue.size() > 0:
		var cur: int = queue.pop_front()
		if cur == goal:
			break
		for nb in _edges.get(cur, PackedInt32Array()):
			if not parent.has(nb):
				parent[nb] = cur
				queue.append(nb)
	return parent


## Falls back to the nearest point, or `pos` when the graph is empty.
func random_point_near(pos: Vector3, radius: float) -> Vector3:
	if not _built or _points.size() == 0:
		return pos

	var candidates: PackedInt32Array = PackedInt32Array()
	for i in _points.size():
		if pos.distance_to(_points[i]) <= radius:
			candidates.append(i)

	if candidates.is_empty():
		return nearest_point_position(pos)

	return _points[candidates[randi() % candidates.size()]]
