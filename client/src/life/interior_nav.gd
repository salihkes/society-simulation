extends RefCounted
## Walking inside a building from its geometry alone: ray-sampled floor cells, A* and a line-of-sight pull.

var cell_size := 1.0  # units (20 cm)
const FLOOR_TOL := 1.0  # a hit within this of the floor level is floor
var body_height := 5.1
var body_radius := 0.0  # optional round-body clearance instead of square erosion
var headroom := 8.0  # units of clear space a floor cell needs above it
var erode_cells := -1  # -1 = ERODE / cell_size, 0 = none
var worst_slice_ms := 0  # build_chunked: the longest stretch of work between two yields
const ERODE := 1  # local units kept clear of walls
const SNAP_CELLS := 8
const MASK := 1  # furniture (layer 3) is walked through

var origin := Vector3.INF  # workspace-local corner of cell (0, 0)
var floor_y := 0.0
var cols := 0
var rows := 0
var _cells := PackedByteArray()  # 0 blocked, 1 floor, 2 clear (routable)
var _heights := PackedFloat32Array()
var built := false
var floor_cells := 0


## `step_height` > 0 floods from `seeds` so stairs chain. Too slow for a large building: use build_chunked().
func build(space: PhysicsDirectSpaceState3D, world: Node3D, bounds: AABB, exclude: Array = [], sample_y: float = NAN,
		step_height: float = 0.0, seeds: Array = []) -> bool:
	var span := _prepare(space, world, bounds, sample_y)
	if span.is_empty():
		return false
	var hits := PackedFloat32Array()
	for r in rows:
		_sample_row(space, world, exclude, float(span.top), float(span.bottom), r, hits)
	if not _settle_floor(hits):
		return false
	if step_height > 0.0:
		var open: Array = _flood_seed(space, world, exclude, step_height, seeds)
		_flood_expand(space, world, exclude, step_height, open, 0x7fffffff)
		_erode(ceili(ERODE / cell_size))
		return built
	_flat_pass(space, world, exclude)
	_erode(0 if body_radius > 0 else ceili(ERODE / cell_size))
	return built


## Await it. At most `budget_ms` of work per rendered frame; only the step-flood path is chunked.
func build_chunked(tree: SceneTree, budget_ms: float, space: PhysicsDirectSpaceState3D, world: Node3D, bounds: AABB,
		exclude: Array = [], sample_y: float = NAN, step_height: float = 0.0, seeds: Array = []) -> bool:
	var span := _prepare(space, world, bounds, sample_y)
	if span.is_empty():
		return false
	var hits := PackedFloat32Array()
	var frame_start := Time.get_ticks_msec()
	for r in rows:
		_sample_row(space, world, exclude, float(span.top), float(span.bottom), r, hits)
		frame_start = await _yield_slice(tree, budget_ms, frame_start)
	if not _settle_floor(hits):
		return false
	if step_height > 0.0:
		var open: Array = _flood_seed(space, world, exclude, step_height, seeds)
		while not open.is_empty():
			_flood_expand(space, world, exclude, step_height, open, 120)
			frame_start = await _yield_slice(tree, budget_ms, frame_start)
		var erosion := (ceili(ERODE / cell_size) if erode_cells < 0 else erode_cells)
		var r := 0
		while r < rows:
			var r_end := mini(rows, r + 16)
			_erode(erosion, r, r_end)
			r = r_end
			frame_start = await _yield_slice(tree, budget_ms, frame_start)
		return built
	_flat_pass(space, world, exclude)
	_erode(0 if body_radius > 0 else ceili(ERODE / cell_size))
	return built


## Await it. Returns the start of the current slice.
func _yield_slice(tree: SceneTree, budget_ms: float, frame_start: int) -> int:
	if Time.get_ticks_msec() - frame_start <= budget_ms:
		return frame_start
	worst_slice_ms = maxi(worst_slice_ms, Time.get_ticks_msec() - frame_start)
	await tree.process_frame
	return Time.get_ticks_msec()


## {top, bottom} of the rays, or {} when there is nothing sensible to sample.
func _prepare(space: PhysicsDirectSpaceState3D, world: Node3D, bounds: AABB, sample_y: float) -> Dictionary:
	built = false
	if space == null or world == null:
		return {}
	var grown := bounds.grow(12.0)
	origin = Vector3(grown.position.x, 0.0, grown.position.z)
	cols = int(ceil(grown.size.x / cell_size)) + 1
	rows = int(ceil(grown.size.z / cell_size)) + 1
	if cols <= 2 or rows <= 2 or cols * rows > 250000:
		return {}
	_cells = PackedByteArray()
	_cells.resize(cols * rows)
	_heights = PackedFloat32Array()
	_heights.resize(cols * rows)
	floor_cells = 0
	return {"top": grown.end.y + 12.0 if is_nan(sample_y) else sample_y, "bottom": grown.position.y - 12.0}


func _sample_row(space: PhysicsDirectSpaceState3D, world: Node3D, exclude: Array, top: float, bottom: float, r: int,
		hits: PackedFloat32Array) -> void:
	for c in cols:
		var i := r * cols + c
		var p := _cell_pos(c, r)
		var q := PhysicsRayQueryParameters3D.create(world.to_global(Vector3(p.x, top, p.z)),
			world.to_global(Vector3(p.x, bottom, p.z)), MASK, exclude)
		# A ray that starts inside a wall reports the wall, so a wall cell is never floor.
		q.hit_from_inside = true
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			_heights[i] = -INF
			continue
		var y: float = world.to_local(hit.position).y
		_heights[i] = y
		hits.append(y)


## The height most cells share; the flood later replaces it with its first seed's.
func _settle_floor(hits: PackedFloat32Array) -> bool:
	if hits.is_empty():
		return false
	floor_y = _mode(hits, 0.5)
	return true


func _flat_pass(space: PhysicsDirectSpaceState3D, world: Node3D, exclude: Array) -> void:
	var capsule_query: PhysicsShapeQueryParameters3D = _capsule_query(world, exclude) if body_radius > 0 else null
	for r in rows:
		for c in cols:
			var i := r * cols + c
			var y: float = _heights[i]
			if y == -INF or absf(y - floor_y) > FLOOR_TOL:
				continue
			if _flat_cell_clear(space, world, exclude, capsule_query, c, r, y):
				_cells[i] = 1


func _capsule_query(world: Node3D, exclude: Array) -> PhysicsShapeQueryParameters3D:
	var scale: float = world.global_basis.get_scale().x
	var capsule := CapsuleShape3D.new()
	capsule.radius = (body_radius + 0.1) * scale
	capsule.height = body_height * scale
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.collision_mask = MASK
	query.exclude = exclude
	return query


func _flat_cell_clear(space: PhysicsDirectSpaceState3D, world: Node3D, exclude: Array,
		capsule_query: PhysicsShapeQueryParameters3D, c: int, r: int, y: float) -> bool:
	var p := _cell_pos(c, r)
	if not _headroom_clear(space, world, exclude, p, y):
		return false
	if capsule_query != null:
		capsule_query.transform.origin = world.to_global(Vector3(p.x, y + body_height * 0.5 + 0.45, p.z))
		if not space.intersect_shape(capsule_query, 1).is_empty():
			return false
	return true


## The first seed found sets floor_y.
func _flood_seed(space: PhysicsDirectSpaceState3D, world: Node3D, exclude: Array, step: float, seeds: Array) -> Array:
	var open: Array = []
	var seeded := false
	for sp in seeds:
		var best := _seed_cell(sp, step)
		if best.x < 0:
			continue
		var i := best.y * cols + best.x
		if not seeded:
			floor_y = _heights[i]
			seeded = true
		if _cells[i] == 0 and _headroom_ok(space, world, exclude, best.x, best.y):
			_cells[i] = 1
			open.append(best)
	return open


## Within four cells and three steps of its height, else (-1, -1).
func _seed_cell(sp: Vector3, step: float) -> Vector2i:
	var cr := _cell_of(sp)
	var best := Vector2i(-1, -1)
	var best_d := INF
	for dr in range(-4, 5):
		for dc in range(-4, 5):
			var c := cr.x + dc
			var r := cr.y + dr
			if c < 0 or r < 0 or c >= cols or r >= rows:
				continue
			var h: float = _heights[r * cols + c]
			if h == -INF or absf(h - sp.y) > step * 3.0:
				continue
			var d := float(dc * dc + dr * dr)
			if d < best_d:
				best_d = d
				best = Vector2i(c, r)
	return best


## At most `limit` cells this call; stairs are floor, a table top is too big a step.
func _flood_expand(space: PhysicsDirectSpaceState3D, world: Node3D, exclude: Array, step: float, open: Array,
		limit: int) -> void:
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var done := 0
	while not open.is_empty() and done < limit:
		done += 1
		var cur: Vector2i = open.pop_back()
		var h: float = _heights[cur.y * cols + cur.x]
		for d in dirs:
			var n: Vector2i = cur + d
			if _floods_into(space, world, exclude, step, n, h):
				_cells[n.y * cols + n.x] = 1
				open.append(n)


func _floods_into(space: PhysicsDirectSpaceState3D, world: Node3D, exclude: Array, step: float, n: Vector2i,
		h: float) -> bool:
	if n.x < 0 or n.y < 0 or n.x >= cols or n.y >= rows:
		return false
	var i := n.y * cols + n.x
	if _cells[i] != 0:
		return false
	var nh: float = _heights[i]
	if nh == -INF or absf(nh - h) > step:
		return false
	return _headroom_ok(space, world, exclude, n.x, n.y)


## Sets `built`.
func _erode(erosion: int, r0: int = 0, r1: int = -1) -> void:
	if r0 == 0:
		floor_cells = 0
	if r1 < 0:
		r1 = rows
	for r in range(r0, r1):
		for c in cols:
			var i := r * cols + c
			if _cells[i] == 0:
				continue
			floor_cells += 1
			if _floor_square(c, r, erosion):
				_cells[i] = 2
	built = floor_cells > 0


func _floor_square(c: int, r: int, erosion: int) -> bool:
	for dr in range(-erosion, erosion + 1):
		for dc in range(-erosion, erosion + 1):
			var rr := r + dr
			var cc := c + dc
			if rr < 0 or cc < 0 or rr >= rows or cc >= cols or _cells[rr * cols + cc] == 0:
				return false
	return true


func _headroom_ok(space: PhysicsDirectSpaceState3D, world: Node3D, exclude: Array, c: int, r: int) -> bool:
	return _headroom_clear(space, world, exclude, _cell_pos(c, r), _heights[r * cols + c])


func _headroom_clear(space: PhysicsDirectSpaceState3D, world: Node3D, exclude: Array, p: Vector3, y: float) -> bool:
	var up := PhysicsRayQueryParameters3D.create(world.to_global(Vector3(p.x, y + 0.6, p.z)),
		world.to_global(Vector3(p.x, y + headroom, p.z)), MASK, exclude)
	return space.intersect_ray(up).is_empty()


## -INF when nothing is under it.
func height_at(c: int, r: int) -> float:
	if not _in_grid(c, r):
		return -INF
	return _heights[r * cols + c]


func routable(c: int, r: int) -> bool:
	return _routable(c, r)


func cell_of(p: Vector3) -> Vector2i:
	return _cell_of(p)


func cell_pos(c: int, r: int) -> Vector3:
	var q := _cell_pos(c, r)
	q.y = _heights[r * cols + c]
	return q


func visible(a: Vector2i, b: Vector2i) -> bool:
	return _visible(a, b)


static func _mode(values: PackedFloat32Array, bucket: float) -> float:
	var counts := {}
	var best := 0.0
	var best_n := -1
	for v in values:
		var k := roundf(v / bucket)
		counts[k] = int(counts.get(k, 0)) + 1
		if int(counts[k]) > best_n:
			best_n = int(counts[k])
			best = k * bucket
	return best


func _cell_pos(c: int, r: int) -> Vector3:
	return Vector3(origin.x + (float(c) + 0.5) * cell_size, floor_y, origin.z + (float(r) + 0.5) * cell_size)


func _cell_of(p: Vector3) -> Vector2i:
	return Vector2i(int(floor((p.x - origin.x) / cell_size)), int(floor((p.z - origin.z) / cell_size)))


func _in_grid(c: int, r: int) -> bool:
	return c >= 0 and r >= 0 and c < cols and r < rows


func _routable(c: int, r: int) -> bool:
	return _in_grid(c, r) and _cells[r * cols + c] == 2


## Furniture is not sampled, so it does not count.
func walkable(p: Vector3) -> bool:
	if not built:
		return false
	var cr := _cell_of(p)
	return _in_grid(cr.x, cr.y) and _cells[cr.y * cols + cr.x] >= 1


func covers(p: Vector3) -> bool:
	if not built:
		return false
	var cr := _cell_of(p)
	return _in_grid(cr.x, cr.y)


## Else (-1, -1).
func _snap(p: Vector3) -> Vector2i:
	var cr := _cell_of(p)
	if _routable(cr.x, cr.y):
		return cr
	var best := Vector2i(-1, -1)
	var best_d := INF
	for dr in range(-ceili(SNAP_CELLS / cell_size), ceili(SNAP_CELLS / cell_size) + 1):
		for dc in range(-ceili(SNAP_CELLS / cell_size), ceili(SNAP_CELLS / cell_size) + 1):
			var c := cr.x + dc
			var r := cr.y + dr
			if not _routable(c, r):
				continue
			var d: float = float(dc * dc + dr * dr)
			if d < best_d:
				best_d = d
				best = Vector2i(c, r)
	return best


func snap_pos(p: Vector3) -> Vector3:
	var cr := _snap(p)
	if cr.x < 0:
		return p
	return cell_pos(cr.x, cr.y)


## Ends at `to` itself when no wall stands in the last step; empty when not connected.
func route(from: Vector3, to: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not built:
		return out
	var a := _snap(from)
	var goal := _cell_of(to)
	# Never the cell across a wall from the spot.
	var b := _snap_seeing(goal)
	if a.x < 0 or b.x < 0:
		return out
	var cells := _astar(a, b)
	if cells.is_empty():
		return out
	for cr in _pull(cells):
		out.append(cell_pos(cr.x, cr.y))
	var last := out[out.size() - 1]
	if last.distance_to(to) > 0.6 and _sees(b, goal):
		out.append(Vector3(to.x, last.y, to.z))
	return out


## Falls back to the plain nearest when nothing sees it.
func _snap_seeing(goal: Vector2i) -> Vector2i:
	if _routable(goal.x, goal.y):
		return goal
	var reach := ceili(SNAP_CELLS / cell_size)
	var candidates: Array = []
	for dr in range(-reach, reach + 1):
		for dc in range(-reach, reach + 1):
			var c := goal.x + dc
			var r := goal.y + dr
			if _routable(c, r):
				candidates.append([float(dc * dc + dr * dr), Vector2i(c, r)])
	candidates.sort_custom(func(x, y): return float(x[0]) < float(y[0]))
	for cand in candidates:
		if _sees(cand[1], goal):
			return cand[1]
	return candidates[0][1] if not candidates.is_empty() else Vector2i(-1, -1)


## The end cells themselves are not judged.
func _sees(a: Vector2i, b: Vector2i) -> bool:
	return _line_clear(a, b, 1, false)


## Eight ways, no corner cutting; [] when they do not connect.
func _astar(start: Vector2i, goal: Vector2i) -> Array:
	var open := [start]
	var came := {}
	var g := {start: 0.0}
	var f := {start: float((start - goal).length())}
	var closed := {}
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
	var guard := cols * rows * 4
	while not open.is_empty() and guard > 0:
		guard -= 1
		var bi := _cheapest(open, f)
		var cur: Vector2i = open[bi]
		open.remove_at(bi)
		if cur == goal:
			return _path_back(came, cur)
		closed[cur] = true
		for d in dirs:
			var n: Vector2i = cur + d
			if closed.has(n) or not _step_ok(cur, d):
				continue
			var ng: float = float(g[cur]) + (1.41421 if (d.x != 0 and d.y != 0) else 1.0)
			if ng >= float(g.get(n, INF)):
				continue
			came[n] = cur
			g[n] = ng
			f[n] = ng + float((n - goal).length())
			if not open.has(n):
				open.append(n)
	return []


## A linear scan: the grids are small.
static func _cheapest(open: Array, f: Dictionary) -> int:
	var bi := 0
	var bf: float = float(f[open[0]])
	for i in range(1, open.size()):
		if float(f[open[i]]) < bf:
			bf = float(f[open[i]])
			bi = i
	return bi


static func _path_back(came: Dictionary, cur: Vector2i) -> Array:
	var path := [cur]
	while came.has(cur):
		cur = came[cur]
		path.append(cur)
	path.reverse()
	return path


func _step_ok(cur: Vector2i, d: Vector2i) -> bool:
	if not _routable(cur.x + d.x, cur.y + d.y):
		return false
	if d.x != 0 and d.y != 0 and (not _routable(cur.x + d.x, cur.y) or not _routable(cur.x, cur.y + d.y)):
		return false
	return true


func _pull(cells: Array) -> Array:
	if cells.size() <= 2:
		return cells
	var out := [cells[0]]
	var anchor: Vector2i = cells[0]
	var i := 1
	while i < cells.size():
		var j := i
		while j + 1 < cells.size() and _visible(anchor, cells[j + 1]):
			j += 1
		anchor = cells[j]
		out.append(anchor)
		i = j + 1
	return out


func _visible(a: Vector2i, b: Vector2i) -> bool:
	return _line_clear(a, b, 2, true)


## `need`: 1 floor, 2 routable. The end cells are judged only when `ends` is true.
func _line_clear(a: Vector2i, b: Vector2i, need: int, ends: bool) -> bool:
	var dx := absi(b.x - a.x)
	var dy := absi(b.y - a.y)
	var x := a.x
	var y := a.y
	var n := 1 + dx + dy
	var sx := 1 if b.x > a.x else -1
	var sy := 1 if b.y > a.y else -1
	var err := dx - dy
	while n > 0:
		var judged := ends or ((x != a.x or y != a.y) and (x != b.x or y != b.y))
		if judged and not (_in_grid(x, y) and _cells[y * cols + x] >= need):
			return false
		if err > 0:
			x += sx
			err -= dy * 2
		elif err < 0:
			y += sy
			err += dx * 2
		else:
			x += sx
			y += sy
			err += dx * 2 - dy * 2
			n -= 1
		n -= 1
	return true


## '.' routable, ',' floor too near a wall, '#' not floor, ' ' nothing under the ray.
func ascii(max_cols := 120) -> String:
	var lines := []
	var step := maxi(1, int(ceil(float(cols) / float(max_cols))))
	for r in range(0, rows, step):
		var line := ""
		for c in range(0, cols, step):
			var v: int = _cells[r * cols + c]
			line += "." if v == 2 else ("," if v == 1 else ("#" if _heights[r * cols + c] != -INF else " "))
		lines.append(line)
	return "\n".join(lines)


## One flood instead of an A* per candidate when joining another walking graph.
func reachable_from(point: Vector3) -> Array:
	var start := _snap(point)
	if start.x < 0:
		return []
	var cells: Array = [start]
	var seen := {start: true}
	var cursor := 0
	while cursor < cells.size():
		var at: Vector2i = cells[cursor]
		cursor += 1
		for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next: Vector2i = at + direction
			if not seen.has(next) and _routable(next.x, next.y):
				seen[next] = true
				cells.append(next)
	return cells
