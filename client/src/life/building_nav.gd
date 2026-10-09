class_name BuildingNav
extends Node
## Walking inside the school from its collision geometry alone: storeys, stairs, bridges, classroom doors and the lift.

const NavScript := preload("res://src/life/interior_nav.gd")
const CELL := 1.0
const STEP := 3.0  # a tread, an entrance sill
const HEADROOM := 6.0
const LAYER_GAP := 8.0  # units between sampling heights (1.6 m)
const FIRST_LAYER_ABOVE := 9.0  # above the lowest floor
const LIFT_ENTER := 6.0  # cost to board at all
const LIFT_PER_UNIT := 0.4  # ...and per unit of rise, so one floor is climbed on foot
const HEURISTIC := 2.0  # weighted A*: slightly longer paths, far fewer cells looked at
const REACH := 2.5  # a route ends within this of what was asked
const DEDUPE := 0.3  # heights this close from two layers are the same surface
const ENTRY_MARKERS := ["EntrySchool", "EntrySchool2"]
const BUDGET_MS := 6.0  # sampling work per rendered frame, ms
const DOOR_REACH := 8  # cells either side of a classroom's Door marker its step may span
const DOOR_COST := 4.0
const ASTAR_CAP := 12000  # cells a direct search may look at before the lift trees answer

var ready_ok := false
var _manager = null
var _world: Node3D = null
var _lift = null
var _floors: Array = []  # the lift's stops
var _layers: Array = []  # one interior nav per sampling height
var _heights: Array = []
var _cols := 0
var _rows := 0
var _per := 0
var _column: Array = []  # per cell: PackedByteArray of layers with routable floor there
var _comp := PackedInt32Array()  # per node: component id (0 = not floor)
var _landing_nodes: Array = []  # per lift stop: node id or -1
var _door_edges: Dictionary = {}  # node -> [[node, cost, "door"], ...]: a door shut in the collision
# Walking distance from every landing to every floor cell, so lift routes are read off, not searched.
var _dense := PackedInt32Array()  # node id -> dense index (floor nodes only), -1 otherwise
var _dense_n := 0
var _dist: Array = []  # per landing, over dense indices (INF unreachable)
var _parent: Array = []  # per landing: node id of the next step toward the landing
var _pkind: Array = []  # per landing: that step's edge kind (0 walk, 2 door)
var _bounds := AABB()
var _seam := Vector3.INF
var _entrance := Vector3.INF
var _entries: Array = []
# A* scratch, sized once: generation stamps instead of clearing.
var _g := PackedFloat32Array()
var _g_gen := PackedInt32Array()
var _closed_gen := PackedInt32Array()
var _came := PackedInt32Array()
var _by_lift := PackedByteArray()
var _gen := 0
var _goal_c := 0
var _goal_r := 0
var _goal_h := 0.0
var worst_slice_ms := 0  # the longest stretch of work between two yields while building
var build_ms := 0  # ms
var cache: NavCache = null
var _landings: Array = []  # the lift's approach points, per stop


func setup(manager, world: Node3D) -> void:
	_manager = manager
	_world = world
	cache = NavCache.new(self, world)
	_build.call_deferred()


func _build() -> void:
	for i in 6:
		await get_tree().physics_frame
	_lift = _find_lift()
	if _lift == null or not ("FLOORS" in _lift):
		print("[BuildingNav] no school lift found: the school is not sampled")
		return
	_floors = Array(_lift.FLOORS)
	_find_entries()
	var seeds: Array = []
	var pts: Array = []
	_collect_room_points(seeds, pts)
	var landings := _collect_landings(seeds, pts)
	seeds.append_array(_entries)
	pts.append_array(_entries)
	if pts.is_empty():
		print("[BuildingNav] nothing to sample around")
		return
	_bounds = AABB(pts[0], Vector3.ZERO)
	for p in pts:
		_bounds = _bounds.expand(p)
	_bounds = _bounds.grow(30.0)
	var exclude := _moving_bodies()
	_landings = landings
	var t0 := Time.get_ticks_msec()
	var lowest: float = float(_floors[0])
	var top: float = float(_floors[-1]) + 12.0
	_heights = _sampling_heights(lowest, top)
	_layers = []
	var footprint := AABB(Vector3(_bounds.position.x, lowest - 3.0, _bounds.position.z),
		Vector3(_bounds.size.x, 3.0, _bounds.size.z))
	var key: String = await cache.key(_floors, _heights, _entries, seeds, landings, footprint, lowest, top, exclude)
	if OS.get_environment("GAME_NAV_FINGERPRINT_ONLY") == "1":
		print("[BuildingNav] fingerprint %s (%s)" % [key, NavCache.file_name(key)])
		return
	var use_cache := OS.get_environment("GAME_NAV_NOCACHE") != "1"
	if use_cache and _restore(cache.read(key, landings.size())):
		_finish(t0, "floors read from " + cache.path)
		return
	if use_cache:
		print("[BuildingNav] no cached floors for this building (%s): sampling" % NavCache.file_name(key))
	await _sample_layers(seeds, footprint, exclude)
	await _connect_floors(landings)
	_finish(t0, "sampled")
	cache.write(key, _graph())


## A home's plain lift is in the same group but has no landings.
func _find_lift():
	for e in get_tree().get_nodes_in_group("elevators"):
		if e.has_node("Landing0/Approach"):
			return e
	return null


func _find_entries() -> void:
	for name in ENTRY_MARKERS:
		var m = _world.find_child(name, true, false)
		if m is Node3D:
			_entries.append(_world.to_local(m.global_position))


func _collect_room_points(seeds: Array, pts: Array) -> void:
	for sch in _manager.places.schools:
		if sch == null or not is_instance_valid(sch):
			continue
		for p in [sch._door, sch._lectern]:
			if p != Vector3.INF:
				seeds.append(p)
				pts.append(p)
		if sch.match_.has_yard():
			pts.append(sch.match_.yard)


## INF where a stop has none.
func _collect_landings(seeds: Array, pts: Array) -> Array:
	var landings: Array = []
	for i in _floors.size():
		var a: Node3D = _lift.get_node_or_null("Landing%d/Approach" % i)
		var lp: Vector3 = _world.to_local(a.global_position) if a != null else Vector3.INF
		landings.append(lp)
		if lp != Vector3.INF:
			seeds.append(lp)
			pts.append(lp)
	return landings


## Kept out of the rays so only the building is sampled.
func _moving_bodies() -> Array:
	var exclude: Array = []
	for body in _world.find_children("*", "PhysicsBody3D", true, false):
		if body is AnimatableBody3D or not (body is StaticBody3D):
			exclude.append(body.get_rid())
	return exclude


func _sampling_heights(lowest: float, top: float) -> Array:
	var heights: Array = []
	var h: float = lowest + FIRST_LAYER_ABOVE
	while h < top + LAYER_GAP:
		heights.append(h)
		h += LAYER_GAP
	return heights


func _sample_layers(seeds: Array, footprint: AABB, exclude: Array) -> void:
	for k in _heights.size():
		var space := _world.get_world_3d().direct_space_state
		var layer_seeds: Array = []
		for sp in seeds:
			if sp.y < float(_heights[k]) - 1.0:
				layer_seeds.append(sp)
		var g = NavScript.new()
		g.cell_size = CELL
		g.headroom = HEADROOM
		# Erosion is done across layers, so a stair split between two layers keeps its middle.
		g.erode_cells = 0
		await g.build_chunked(get_tree(), BUDGET_MS, space, _world, footprint, exclude,
			float(_heights[k]), STEP, layer_seeds)
		worst_slice_ms = maxi(worst_slice_ms, g.worst_slice_ms)
		_layers.append(g)
	_cols = _layers[0].cols
	_rows = _layers[0].rows
	_per = _cols * _rows


func _connect_floors(landings: Array) -> void:
	await _dedupe()
	await _erode_across_layers()
	await _columns()
	_landing_nodes = []
	for lp in landings:
		_landing_nodes.append(_node_of(lp) if lp != Vector3.INF else -1)
	await _label_components()
	# Classroom doors the collision keeps shut: a step across each.
	var doors_bridged := 0
	for sch in _manager.places.schools:
		if sch == null or not is_instance_valid(sch) or sch._door == Vector3.INF:
			continue
		if _bridge_door(sch._door):
			doors_bridged += 1
	if doors_bridged > 0:
		await _label_components()
	await _build_landing_trees()


func _finish(t0: int, how: String) -> void:
	var n := _layers.size() * _per
	_g.resize(n)
	_g_gen.resize(n)
	_closed_gen.resize(n)
	_came.resize(n)
	_by_lift.resize(n)
	_seam = _pick_seam()
	_entrance = _seam
	ready_ok = _layers.any(func(l): return l.built)
	build_ms = Time.get_ticks_msec() - t0
	_log_build(how)


func _pick_seam() -> Vector3:
	for e in _entries:
		if _manager.nav != null and _manager.nav.is_walkable(Vector2(e.x, e.z)):
			return e
	if not _entries.is_empty():
		return _entries[0]
	return Vector3.INF


func _log_build(how: String) -> void:
	var floor_total := 0
	for l in _layers:
		floor_total += l.floor_cells
	var landings_ok := 0
	for id in _landing_nodes:
		if id >= 0:
			landings_ok += 1
	print(("[BuildingNav] %s: %d layers (%.0f..%.0f), %dx%d cells, %d floor cells, %d lift landings on the floor, "
		+ "%d ms (longest work slice %d ms); seam %s") %
		[how, _layers.size(), float(_heights[0]), float(_heights[-1]), _cols, _rows, floor_total, landings_ok,
		build_ms, worst_slice_ms, str(_seam.snapped(Vector3(1, 1, 1))) if _seam != Vector3.INF else "none"])
	if landings_ok < _floors.size():
		for i in _landing_nodes.size():
			if _landing_nodes[i] < 0:
				print("[BuildingNav]   lift landing %d at %s is not on any sampled floor" %
					[i, str(_landings[i].round())])


## Await it. Returns the start of the current slice.
func _yield_slice(frame_start: int) -> int:
	if Time.get_ticks_msec() - frame_start <= BUDGET_MS:
		return frame_start
	worst_slice_ms = maxi(worst_slice_ms, Time.get_ticks_msec() - frame_start)
	await get_tree().process_frame
	return Time.get_ticks_msec()


## False for an empty graph (nothing cached that fits).
func _restore(graph: Dictionary) -> bool:
	if graph.is_empty():
		return false
	_heights = graph.heights
	_cols = graph.cols
	_rows = graph.rows
	_per = _cols * _rows
	_layers = graph.layers
	_column = graph.column
	_comp = graph.comp
	_landing_nodes = graph.landing_nodes
	_door_edges = graph.door_edges
	_dense = graph.dense
	_dense_n = graph.dense_n
	_dist = graph.dist
	_parent = graph.parent
	_pkind = graph.pkind
	_bounds = graph.bounds
	worst_slice_ms = 0
	return true


func _graph() -> Dictionary:
	return {"heights": _heights, "cols": _cols, "rows": _rows, "layers": _layers, "column": _column,
		"comp": _comp, "landing_nodes": _landing_nodes, "door_edges": _door_edges, "dense": _dense,
		"dense_n": _dense_n, "dist": _dist, "parent": _parent, "pkind": _pkind, "bounds": _bounds}


func _dedupe() -> void:
	var frame_start := Time.get_ticks_msec()
	for k in range(1, _layers.size()):
		var g = _layers[k]
		if not g.built:
			continue
		for i in _per:
			if i % 4096 == 0:
				frame_start = await _yield_slice(frame_start)
			if g._cells[i] != 0 and _seen_below(k, i, g._heights[i]):
				g._cells[i] = 0


func _seen_below(k: int, i: int, hk: float) -> bool:
	for j in k:
		var gj = _layers[j]
		if gj.built and gj._cells[i] != 0 and absf(gj._heights[i] - hk) <= DEDUPE:
			return true
	return false


## A cell is routable when all eight neighbours have floor within a step in some layer.
func _erode_across_layers() -> void:
	var frame_start := Time.get_ticks_msec()
	var floor_cols: Array = []
	floor_cols.resize(_per)
	for i in _per:
		floor_cols[i] = _layers_at(i, false)
		if i % 8192 == 0:
			frame_start = await _yield_slice(frame_start)
	for k in _layers.size():
		var g = _layers[k]
		if not g.built:
			continue
		g.floor_cells = 0
		for i in _per:
			if i % 8192 == 0:
				frame_start = await _yield_slice(frame_start)
			if g._cells[i] == 0:
				continue
			g.floor_cells += 1
			g._cells[i] = 2 if _clear_around(i, g._heights[i], floor_cols) else 1


func _clear_around(i: int, h: float, floor_cols: Array) -> bool:
	var c := i % _cols
	var r := i / _cols
	for dr in range(-1, 2):
		for dc in range(-1, 2):
			if dr == 0 and dc == 0:
				continue
			var nc := c + dc
			var nr := r + dr
			if nc < 0 or nr < 0 or nc >= _cols or nr >= _rows:
				return false
			var ni := nr * _cols + nc
			if not _within_step(floor_cols[ni], ni, h):
				return false
	return true


func _columns() -> void:
	_column = []
	_column.resize(_per)
	var frame_start := Time.get_ticks_msec()
	for i in _per:
		_column[i] = _layers_at(i, true)
		if i % 4096 == 0:
			frame_start = await _yield_slice(frame_start)


func _layers_at(i: int, routable_only: bool) -> PackedByteArray:
	var col := PackedByteArray()
	for k in _layers.size():
		var g = _layers[k]
		if not g.built:
			continue
		if (g._cells[i] == 2) if routable_only else (g._cells[i] != 0):
			col.append(k)
	return col


func _within_step(layers: PackedByteArray, i: int, h: float) -> bool:
	for k in layers:
		if absf(_height(k, i) - h) <= STEP:
			return true
	return false


func _height(k: int, i: int) -> float:
	return _layers[k]._heights[i]


## Nearest height within 6 units, looking out four cells for a marker standing at a wall; else -1.
func _node_of(p: Vector3) -> int:
	if _layers.is_empty():
		return -1
	var cr: Vector2i = _layers[0].cell_of(p)
	if cr.x < 0 or cr.y < 0 or cr.x >= _cols or cr.y >= _rows:
		return -1
	for radius in range(0, 5):
		var best := _nearest_on_ring(cr, radius, p.y)
		if best >= 0:
			return best
	return -1


## Within 6 units, else -1.
func _nearest_on_ring(cr: Vector2i, radius: int, y: float) -> int:
	var best := -1
	var best_d := 6.0
	for dr in range(-radius, radius + 1):
		for dc in range(-radius, radius + 1):
			if maxi(absi(dr), absi(dc)) != radius:
				continue
			var c := cr.x + dc
			var r := cr.y + dr
			if c < 0 or r < 0 or c >= _cols or r >= _rows:
				continue
			var i := r * _cols + c
			for k in _column[i]:
				var d := absf(_height(k, i) - y)
				if d < best_d:
					best_d = d
					best = k * _per + i
	return best


## So an unreachable goal is answered at once.
func _label_components() -> void:
	var n := _layers.size() * _per
	_comp = PackedInt32Array()
	_comp.resize(n)
	var next_id := 1
	var stack := PackedInt32Array()
	var frame_start := Time.get_ticks_msec()
	var visited := 0
	for start in n:
		if start % 8192 == 0:
			frame_start = await _yield_slice(frame_start)
		if _comp[start] != 0 or not _is_node(start):
			continue
		_comp[start] = next_id
		stack.clear()
		stack.append(start)
		while not stack.is_empty():
			var cur := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			_label_neighbours(cur, next_id, stack)
			visited += 1
			if visited % 256 == 0:
				frame_start = await _yield_slice(frame_start)
		next_id += 1


func _label_neighbours(cur: int, id: int, stack: PackedInt32Array) -> void:
	for nb in _neighbours(cur, true):
		var nid: int = nb[0]
		if _comp[nid] == 0:
			_comp[nid] = id
			stack.append(nid)


## False when there is no floor of another component within DOOR_REACH cells and a step.
func _bridge_door(door: Vector3) -> bool:
	var a := _node_of(door)
	if a < 0:
		return false
	var ai := a % _per
	var ac := ai % _cols
	var ar := ai / _cols
	var ah := _height(a / _per, ai)
	var best := -1
	var best_d := INF
	for dr in range(-DOOR_REACH, DOOR_REACH + 1):
		for dc in range(-DOOR_REACH, DOOR_REACH + 1):
			var c := ac + dc
			var r := ar + dr
			if c < 0 or r < 0 or c >= _cols or r >= _rows:
				continue
			var id := _other_floor_at(r * _cols + c, _comp[a], ah)
			var d := float(dc * dc + dr * dr)
			if id >= 0 and d < best_d:
				best_d = d
				best = id
	if best < 0:
		return false
	for pair in [[a, best], [best, a]]:
		var edges: Array = _door_edges.get(pair[0], [])
		edges.append([pair[1], DOOR_COST, "door"])
		_door_edges[pair[0]] = edges
	print("[BuildingNav] door at %s is shut in the collision: stepping through to %s (%.1f cells)" %
		[str(door.round()), str(node_pos(best).round()), sqrt(best_d)])
	return true


## Else -1.
func _other_floor_at(i: int, comp: int, h: float) -> int:
	for k in _column[i]:
		var id: int = int(k) * _per + i
		if _comp[id] != comp and absf(_height(int(k), i) - h) <= STEP:
			return id
	return -1


## Dijkstra per landing, lift excluded, spread over frames.
func _build_landing_trees() -> void:
	var n := _layers.size() * _per
	_dense = PackedInt32Array()
	_dense.resize(n)
	_dense.fill(-1)
	_dense_n = 0
	for id in n:
		if _is_node(id):
			_dense[id] = _dense_n
			_dense_n += 1
	_dist = []
	_parent = []
	_pkind = []
	var frame_start := Time.get_ticks_msec()
	for s in _landing_nodes.size():
		var root: int = _landing_nodes[s]
		var tree: Array = [PackedFloat32Array(), PackedInt32Array(), PackedByteArray(), frame_start]
		if root >= 0:
			tree = await _landing_tree(root, frame_start)
		frame_start = tree[3]
		_dist.append(tree[0])
		_parent.append(tree[1])
		_pkind.append(tree[2])


## Await it. Returns [dist, parent, kind, frame_start].
func _landing_tree(root: int, frame_start: int) -> Array:
	var dist := PackedFloat32Array()
	var parent := PackedInt32Array()
	var kind := PackedByteArray()
	dist.resize(_dense_n)
	dist.fill(INF)
	parent.resize(_dense_n)
	parent.fill(-1)
	kind.resize(_dense_n)
	var heap := Heap.new()
	dist[_dense[root]] = 0.0
	heap.push(0.0, root)
	var pops := 0
	while not heap.empty():
		var cur := heap.pop()
		var cd := dist[_dense[cur]]
		pops += 1
		if pops % 512 == 0:
			frame_start = await _yield_slice(frame_start)
		_relax_tree(cur, cd, dist, parent, kind, heap)
	return [dist, parent, kind, frame_start]


func _relax_tree(cur: int, cd: float, dist: PackedFloat32Array, parent: PackedInt32Array, kind: PackedByteArray,
		heap: Heap) -> void:
	for nb in _neighbours(cur, false):
		var nid: int = nb[0]
		var nd: int = _dense[nid]
		var alt: float = cd + float(nb[1])
		if alt < dist[nd]:
			dist[nd] = alt
			parent[nd] = cur
			kind[nd] = 2 if (nb.size() > 2 and str(nb[2]) == "door") else 0
			heap.push(alt, nid)


## [node ids, kinds]; kinds[m] is the edge between ids[m] and ids[m + 1].
func _walk_to_landing(id: int, s: int) -> Array:
	var ids := PackedInt32Array()
	var kinds := PackedByteArray()
	var cur := id
	var guard := _dense_n + 1
	while cur >= 0 and guard > 0:
		guard -= 1
		ids.append(cur)
		var d: int = _dense[cur]
		var next: int = _parent[s][d]
		kinds.append(_pkind[s][d] if next >= 0 else 0)
		if cur == _landing_nodes[s]:
			break
		cur = next
	return [ids, kinds]


func _is_node(id: int) -> bool:
	var k := id / _per
	var i := id % _per
	return k < _layers.size() and _layers[k].built and _layers[k]._cells[i] == 2


## [node id, cost(, "door"|"lift")] per step: eight neighbours within a step, doors, and lift edges if asked.
func _neighbours(id: int, with_lift: bool) -> Array:
	var out: Array = []
	var k := id / _per
	var i := id % _per
	var c := i % _cols
	var r := i / _cols
	var h := _height(k, i)
	for dr in range(-1, 2):
		for dc in range(-1, 2):
			if dr == 0 and dc == 0:
				continue
			_append_steps(c, r, dc, dr, h, out)
	if _door_edges.has(id):
		out.append_array(_door_edges[id])
	if with_lift and _lift != null:
		var s := _landing_nodes.find(id)
		if s >= 0:
			out.append_array(_lift_edges(s))
	return out


## Appends [node id, cost] to `out`.
func _append_steps(c: int, r: int, dc: int, dr: int, h: float, out: Array) -> void:
	var nc := c + dc
	var nr := r + dr
	if nc < 0 or nr < 0 or nc >= _cols or nr >= _rows:
		return
	var ni := nr * _cols + nc
	var diagonal := dr != 0 and dc != 0
	if diagonal and (not _floor_near(r * _cols + nc, h) or not _floor_near(nr * _cols + c, h)):
		return
	for nk in _column[ni]:
		var dh := absf(_height(nk, ni) - h)
		if dh > STEP:
			continue
		out.append([nk * _per + ni, (1.41421 if diagonal else 1.0) + dh * 2.0])


func _lift_edges(s: int) -> Array:
	var out: Array = []
	for os in _landing_nodes.size():
		if os == s or _landing_nodes[os] < 0:
			continue
		var rise: float = absf(float(_floors[os]) - float(_floors[s]))
		out.append([_landing_nodes[os], LIFT_ENTER + LIFT_PER_UNIT * rise, "lift"])
	return out


func _floor_near(i: int, h: float) -> bool:
	return _within_step(_column[i], i, h)


func covers(p: Vector3) -> bool:
	if not ready_ok or not _bounds.has_point(Vector3(p.x, _bounds.position.y + 1.0, p.z)):
		return false
	return _node_of(p) >= 0


## With the entrance cut there is no outside piece: anywhere the floor covers is the building's.
func inside(p: Vector3) -> bool:
	return covers(p)


func seam() -> Vector3:
	return _seam


func entrance() -> Vector3:
	return _entrance


func bounds() -> AABB:
	return _bounds


func node_pos(id: int) -> Vector3:
	var k := id / _per
	var i := id % _per
	return _layers[k].cell_pos(i % _cols, i / _cols)


class Heap:
	var keys := PackedFloat32Array()
	var vals := PackedInt32Array()

	func push(k: float, v: int) -> void:
		keys.append(k)
		vals.append(v)
		var i := keys.size() - 1
		while i > 0:
			var parent := (i - 1) >> 1
			if keys[parent] <= keys[i]:
				break
			_swap(parent, i)
			i = parent

	func pop() -> int:
		var top := vals[0]
		var last := keys.size() - 1
		keys[0] = keys[last]
		vals[0] = vals[last]
		keys.resize(last)
		vals.resize(last)
		var i := 0
		while true:
			var l := 2 * i + 1
			var r := l + 1
			var m := i
			if l < last and keys[l] < keys[m]:
				m = l
			if r < last and keys[r] < keys[m]:
				m = r
			if m == i:
				break
			_swap(m, i)
			i = m
		return top

	func empty() -> bool:
		return keys.is_empty()

	func _swap(a: int, b: int) -> void:
		var tk := keys[a]
		keys[a] = keys[b]
		keys[b] = tk
		var tv := vals[a]
		vals[a] = vals[b]
		vals[b] = tv


func _hcost(id: int, _goal: int) -> float:
	var i := id % _per
	var dx := absi(i % _cols - _goal_c)
	var dz := absi(i / _cols - _goal_r)
	var flat := float(maxi(dx, dz)) + 0.41421 * float(mini(dx, dz))
	return HEURISTIC * (flat + absf(_height(id / _per, i) - _goal_h))


## {"points", "lifts": {i: place}, "jumps": {i: true}, "reached"} plus "why", "expanded", "via_lift" for the log.
func route(from: Vector3, to: Vector3) -> Dictionary:
	var out := {"points": PackedVector3Array(), "lifts": {}, "jumps": {}, "reached": false}
	if not ready_ok:
		out["why"] = "not ready"
		return out
	var start := _node_of(from)
	var goal := _node_of(to)
	if start < 0 or goal < 0:
		out["why"] = "no floor under the %s" % ("start" if start < 0 else "goal")
		return out
	if _comp[start] != _comp[goal]:
		out["why"] = "not connected (components %d and %d)" % [_comp[start], _comp[goal]]
		return out
	if start == goal:
		out.points = PackedVector3Array([node_pos(start)])
		out.reached = true
		return out
	var rise := absf(_height(start / _per, start % _per) - _height(goal / _per, goal % _per))
	var storeys_apart: bool = rise > STEP * 3.0
	var direct := {} if storeys_apart else _astar(start, goal, ASTAR_CAP)
	out["expanded"] = direct.get("expanded", 0)
	if direct.has("path"):
		return _emit(direct.path, direct.kinds, to, out)
	var pair := _best_lift_pair(_dense[start], _dense[goal])
	if pair.is_empty():
		if storeys_apart:
			# No lift joins them: stairs alone, with a wider search.
			direct = _astar(start, goal, ASTAR_CAP * 12)
			out["expanded"] = direct.get("expanded", 0)
			if direct.has("path"):
				return _emit(direct.path, direct.kinds, to, out)
		out["why"] = "no direct walk within %d cells and no lift between them" % ASTAR_CAP
		return out
	var legs := _lift_walk(start, goal, pair[0], pair[1])
	out["via_lift"] = "%d->%d" % [pair[0], pair[1]]
	return _emit(legs[0], legs[1], to, out)


## [] when no pair of landings reaches both.
func _best_lift_pair(ds: int, dg: int) -> Array:
	var best_cost := INF
	var best: Array = []
	for i in _landing_nodes.size():
		if _landing_nodes[i] < 0 or _dist[i].is_empty():
			continue
		var d1: float = _dist[i][ds]
		if d1 == INF:
			continue
		for j in _landing_nodes.size():
			if j == i or _landing_nodes[j] < 0 or _dist[j].is_empty():
				continue
			var d2: float = _dist[j][dg]
			if d2 == INF:
				continue
			var cost: float = d1 + LIFT_ENTER + LIFT_PER_UNIT * absf(float(_floors[j]) - float(_floors[i])) + d2
			if cost < best_cost:
				best_cost = cost
				best = [i, j]
	return best


## [node ids, kinds], read off the landing trees.
func _lift_walk(start: int, goal: int, i: int, j: int) -> Array:
	var leg1: Array = _walk_to_landing(start, i)
	var leg2: Array = _walk_to_landing(goal, j)
	var ids: PackedInt32Array = leg1[0]
	var kinds: PackedByteArray = leg1[1]
	# leg2 runs goal -> landing j; it is appended reversed.
	var ids2: PackedInt32Array = leg2[0]
	var kinds2: PackedByteArray = leg2[1]
	for m in range(ids2.size() - 1, -1, -1):
		ids.append(ids2[m])
		if m == ids2.size() - 1:
			kinds.append(1)  # arrived here by lift
		else:
			kinds.append(kinds2[m + 1])
	return [ids, kinds]


## {"path", "kinds", "expanded"} on success, {"expanded"} when capped or not found.
func _astar(start: int, goal: int, cap: int) -> Dictionary:
	_gen += 1
	_goal_c = (goal % _per) % _cols
	_goal_r = (goal % _per) / _cols
	_goal_h = _height(goal / _per, goal % _per)
	var heap := Heap.new()
	_g[start] = 0.0
	_g_gen[start] = _gen
	_came[start] = -1
	_by_lift[start] = 0
	heap.push(_hcost(start, goal), start)
	var found := false
	var pops := 0
	while not heap.empty() and pops < cap:
		var cur := heap.pop()
		if _closed_gen[cur] == _gen:
			continue
		_closed_gen[cur] = _gen
		pops += 1
		if cur == goal:
			found = true
			break
		_expand_walk(cur, goal, heap)
		_expand_special(cur, goal, heap)
	if not found:
		return {"expanded": pops}
	return _trace(goal, pops)


func _expand_walk(cur: int, goal: int, heap: Heap) -> void:
	var gc := _g[cur]
	var ck := cur / _per
	var ci := cur % _per
	var cc := ci % _cols
	var cr := ci / _cols
	var ch: float = _layers[ck]._heights[ci]
	for dr in range(-1, 2):
		var nr := cr + dr
		if nr < 0 or nr >= _rows:
			continue
		for dc in range(-1, 2):
			if dr == 0 and dc == 0:
				continue
			var nc := cc + dc
			if nc < 0 or nc >= _cols:
				continue
			var diagonal := dr != 0 and dc != 0
			if diagonal and (not _floor_near(cr * _cols + nc, ch) or not _floor_near(nr * _cols + cc, ch)):
				continue
			_relax_column(cur, gc, nr * _cols + nc, ch, 1.41421 if diagonal else 1.0, goal, heap)


func _relax_column(cur: int, gc: float, ni: int, ch: float, base: float, goal: int, heap: Heap) -> void:
	var col: PackedByteArray = _column[ni]
	for nk in col:
		var nh: float = _layers[nk]._heights[ni]
		var dh := absf(nh - ch)
		if dh > STEP:
			continue
		_relax(int(nk) * _per + ni, gc + base + dh * 2.0, cur, 0, goal, heap)


func _expand_special(cur: int, goal: int, heap: Heap) -> void:
	var gc := _g[cur]
	var specials: Array = _door_edges.get(cur, [])
	var ls := _landing_nodes.find(cur)
	if ls >= 0 and _lift != null:
		specials = specials.duplicate()
		specials.append_array(_lift_edges(ls))
	for nb in specials:
		_relax(nb[0], gc + float(nb[1]), cur, 2 if str(nb[2]) == "door" else 1, goal, heap)


## Edge kind 0 walk, 1 lift, 2 door.
func _relax(n: int, ng: float, cur: int, kind: int, goal: int, heap: Heap) -> void:
	if _closed_gen[n] == _gen:
		return
	if _g_gen[n] != _gen or ng < _g[n]:
		_g[n] = ng
		_g_gen[n] = _gen
		_came[n] = cur
		_by_lift[n] = kind
		heap.push(ng + _hcost(n, goal), n)


func _trace(goal: int, pops: int) -> Dictionary:
	var path := PackedInt32Array()
	var kinds := PackedByteArray()
	var cur := goal
	while cur >= 0:
		path.append(cur)
		kinds.append(_by_lift[cur])
		cur = _came[cur]
	path.reverse()
	kinds.reverse()
	kinds[0] = 0
	return {"path": path, "kinds": kinds, "expanded": pops}


## The waypoint before a ride is marked in "lifts", the one before a shut door in "jumps".
func _emit(path: PackedInt32Array, kinds: PackedByteArray, to: Vector3, out: Dictionary) -> Dictionary:
	var pts := PackedVector3Array()
	var lifts := {}
	var jumps := {}
	var run: Array = []
	var run_layer := -1
	for idx in path.size():
		var id := path[idx]
		var k := id / _per
		var kind: int = kinds[idx] if idx > 0 else 0
		if kind != 0 or (run_layer >= 0 and k != run_layer):
			_flush_run(run, run_layer, pts)
			if kind == 1:
				lifts[pts.size() - 1] = str(_lift.elevator_id) + "/" + str(_landing_nodes.find(id))
			elif kind == 2:
				jumps[pts.size() - 1] = true
			run = []
		run_layer = k
		run.append(id % _per)
	_flush_run(run, run_layer, pts)
	if pts.is_empty():
		return out
	var last := pts[pts.size() - 1]
	var flat := Vector2(last.x - to.x, last.z - to.z)
	if flat.length() > 0.6 and flat.length() <= REACH * 2.0 and _layers[path[path.size() - 1] / _per].walkable(to):
		pts.append(Vector3(to.x, last.y, to.z))
		last = pts[pts.size() - 1]
	out.points = pts
	out.lifts = lifts
	out.jumps = jumps
	out.reached = Vector2(last.x - to.x, last.z - to.z).length() <= REACH
	return out


## Drops every cell seen in a straight line (and within a step) from the last one kept.
func _flush_run(run: Array, k: int, pts: PackedVector3Array) -> void:
	if run.is_empty() or k < 0:
		return
	var g = _layers[k]
	var kept: Array = [run[0]]
	var anchor: int = run[0]
	var i := 1
	while i < run.size():
		var j := i
		while j + 1 < run.size() and _sees_on(g, anchor, run[j + 1]):
			j += 1
		anchor = run[j]
		kept.append(anchor)
		i = j + 1
	for id in kept:
		pts.append(g.cell_pos(id % _cols, id / _cols))


func _sees_on(g, anchor: int, cand: int) -> bool:
	var a := Vector2i(anchor % _cols, anchor / _cols)
	var b := Vector2i(cand % _cols, cand / _cols)
	return g.visible(a, b) and absf(g._heights[cand] - g._heights[anchor]) <= STEP


## {"from", "to", "cells", "dh", "small", "small_size"}, or {} when never within reach.
func nearest_between(a: int, b: int, reach: int = 6) -> Dictionary:
	var size_a := 0
	var size_b := 0
	for id in _comp.size():
		if _comp[id] == a:
			size_a += 1
		elif _comp[id] == b:
			size_b += 1
	var small := a if size_a <= size_b else b
	var other := b if small == a else a
	var best := {}
	var best_score := INF
	for id in _comp.size():
		if _comp[id] != small:
			continue
		var hit := _closest_other(id, other, reach)
		if not hit.is_empty() and float(hit[0]) < best_score:
			best_score = hit[0]
			best = {"from": node_pos(id), "to": node_pos(hit[1]), "cells": hit[2], "dh": hit[3], "small": small,
				"small_size": mini(size_a, size_b)}
	return best


## [score, node id, cells, dh], or [].
func _closest_other(id: int, other: int, reach: int) -> Array:
	var i := id % _per
	var c := i % _cols
	var r := i / _cols
	var h := _height(id / _per, i)
	var side := 2 * reach + 1
	var best: Array = []
	var best_score := INF
	for n in side * side:
		var dr := n / side - reach
		var dc := n % side - reach
		var nc := c + dc
		var nr := r + dr
		if nc < 0 or nr < 0 or nc >= _cols or nr >= _rows:
			continue
		var ni := nr * _cols + nc
		for k in _column[ni]:
			var nid: int = int(k) * _per + ni
			if _comp[nid] != other:
				continue
			var dist := sqrt(float(dc * dc + dr * dr))
			var dh := absf(_height(k, ni) - h)
			var score := dist + dh * 0.5
			if score < best_score:
				best_score = score
				best = [score, nid, dist, dh]
	return best


## '.' routable somewhere, ',' floor only, '#' not floor, ' ' nothing; `marks` are [Vector3, "X"].
func ascii_all(max_cols := 120, marks: Array = []) -> String:
	if _layers.is_empty():
		return ""
	var step := maxi(1, int(ceil(float(_cols) / float(max_cols))))
	var grid: Array = []
	for r in range(0, _rows, step):
		var line := PackedStringArray()
		for c in range(0, _cols, step):
			line.append(_glyph(r * _cols + c))
		grid.append(line)
	for m in marks:
		var cr: Vector2i = _layers[0].cell_of(m[0])
		var gr := cr.y / step
		var gc := cr.x / step
		if gr >= 0 and gr < grid.size() and gc >= 0 and gc < grid[gr].size():
			grid[gr][gc] = str(m[1])
	var lines := []
	for line in grid:
		lines.append("".join(line))
	return "\n".join(lines)


func _glyph(i: int) -> String:
	var ch := " "
	for g in _layers:
		if not g.built:
			continue
		var v: int = g._cells[i]
		if v == 2:
			return "."
		elif v == 1:
			ch = ","
		elif ch == " " and g._heights[i] != -INF:
			ch = "#"
	return ch
