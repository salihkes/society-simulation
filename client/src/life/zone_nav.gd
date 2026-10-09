extends RefCounted
## Free-roam navigation over drawn walk zones: random destinations and A* routes, workspace-local.

const SEGMENT_SAMPLE_STEP := 3.0  # units between walkability samples
const SMOOTH_MAX_SKIP := 24

var _zones_2d: Array = []  # per zone, XZ
var _zones_3d: Array = []

# Flat triangle arrays, indexed by tri id.
var _tri_zone := PackedInt32Array()
var _tri_idx: Array = []  # indices into the zone poly
var _tri_pts: Array = []  # size 3, XZ
var _tri_centroid := PackedVector2Array()
var _tri_area := PackedFloat32Array()
var _total_area := 0.0

var _astar := AStar2D.new()
var _portals: Dictionary = {}  # "a:b" (a<b) -> crossing point
var _congested: Dictionary = {}  # tri id -> A* weight while a crowd stands in it


func is_empty() -> bool:
	return _tri_pts.is_empty()


## Degenerate zones are skipped with a warning.
func build(zones: Array) -> void:
	_zones_2d = []
	_zones_3d = []
	_tri_zone = PackedInt32Array()
	_tri_idx = []
	_tri_pts = []
	_tri_centroid = PackedVector2Array()
	_tri_area = PackedFloat32Array()
	_total_area = 0.0
	_astar.clear()
	_portals.clear()
	for zone in zones:
		var poly3: PackedVector3Array = zone
		if poly3.size() < 3:
			continue
		var poly2 := PackedVector2Array()
		for p in poly3:
			poly2.append(Vector2(p.x, p.z))
		var indices := Geometry2D.triangulate_polygon(poly2)
		if indices.is_empty():
			poly2.reverse()
			poly3 = poly3.duplicate()
			poly3.reverse()
			indices = Geometry2D.triangulate_polygon(poly2)
			if indices.is_empty():
				push_warning("[AmbientZoneNav] Degenerate zone skipped (%d points)" % poly2.size())
				continue
		_add_zone(poly2, poly3, indices)
	_build_graph()


## Slivers under 0.01 square units are left out.
func _add_zone(poly2: PackedVector2Array, poly3: PackedVector3Array, indices: PackedInt32Array) -> void:
	var zone_idx := _zones_2d.size()
	_zones_2d.append(poly2)
	_zones_3d.append(poly3)
	for t in range(0, indices.size(), 3):
		var i0 := indices[t]
		var i1 := indices[t + 1]
		var i2 := indices[t + 2]
		var a := poly2[i0]
		var b := poly2[i1]
		var c := poly2[i2]
		var area: float = absf((b - a).cross(c - a)) * 0.5
		if area < 0.01:
			continue
		_tri_zone.append(zone_idx)
		_tri_idx.append([i0, i1, i2])
		_tri_pts.append(PackedVector2Array([a, b, c]))
		_tri_centroid.append((a + b + c) / 3.0)
		_tri_area.append(area)
		_total_area += area


func _build_graph() -> void:
	var count := _tri_pts.size()
	for i in count:
		_astar.add_point(i, _tri_centroid[i])
	for i in count:
		for j in range(i + 1, count):
			if _tri_zone[i] == _tri_zone[j]:
				_link_shared_edge(i, j)
			else:
				_link_overlap(i, j)


func _link_shared_edge(i: int, j: int) -> void:
	var shared := _shared_edge(i, j)
	if shared.size() == 2:
		_link(i, j, (_vertex_3d(i, shared[0]) + _vertex_3d(i, shared[1])) * 0.5)


func _link_overlap(i: int, j: int) -> void:
	if _tri_centroid[i].distance_squared_to(_tri_centroid[j]) > _overlap_reject_radius(i, j):
		return
	var inter := Geometry2D.intersect_polygons(_tri_pts[i], _tri_pts[j])
	if inter.is_empty():
		return
	var mid := Vector2.ZERO
	var n := 0
	for poly in inter:
		for p in poly:
			mid += p
			n += 1
	if n == 0:
		return
	mid /= float(n)
	_link(i, j, Vector3(mid.x, _height_in_tri(i, mid), mid.y))


func _overlap_reject_radius(i: int, j: int) -> float:
	var r := 0.0
	for p in _tri_pts[i]:
		r = maxf(r, _tri_centroid[i].distance_squared_to(p))
	for p in _tri_pts[j]:
		r = maxf(r, _tri_centroid[j].distance_squared_to(p))
	return r * 4.0


func _link(a: int, b: int, portal: Vector3) -> void:
	_astar.connect_points(a, b)
	_portals["%d:%d" % [mini(a, b), maxi(a, b)]] = portal


func _shared_edge(a: int, b: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for ia in _tri_idx[a]:
		for ib in _tri_idx[b]:
			if ia == ib:
				out.append(ia)
	return out


func _vertex_3d(tri: int, poly_index: int) -> Vector3:
	return _zones_3d[_tri_zone[tri]][poly_index]


func tri_at(p2: Vector2) -> int:
	for i in _tri_pts.size():
		if Geometry2D.point_is_inside_triangle(p2, _tri_pts[i][0], _tri_pts[i][1], _tri_pts[i][2]):
			return i
	return -1


func nearest_tri(p2: Vector2) -> int:
	var inside := tri_at(p2)
	if inside >= 0:
		return inside
	var best := -1
	var best_d := INF
	for i in _tri_centroid.size():
		var d := _tri_centroid[i].distance_squared_to(p2)
		if d < best_d:
			best_d = d
			best = i
	return best


func is_walkable(p2: Vector2) -> bool:
	for poly in _zones_2d:
		if Geometry2D.is_point_in_polygon(p2, poly):
			return true
	return false


func _segment_walkable(a: Vector2, b: Vector2) -> bool:
	var length := a.distance_to(b)
	var steps := maxi(1, int(ceil(length / SEGMENT_SAMPLE_STEP)))
	for s in steps + 1:
		if not is_walkable(a.lerp(b, float(s) / float(steps))):
			return false
	return true


func _height_in_tri(tri: int, p2: Vector2) -> float:
	var a: Vector2 = _tri_pts[tri][0]
	var b: Vector2 = _tri_pts[tri][1]
	var c: Vector2 = _tri_pts[tri][2]
	var ya: float = _vertex_3d(tri, _tri_idx[tri][0]).y
	var yb: float = _vertex_3d(tri, _tri_idx[tri][1]).y
	var yc: float = _vertex_3d(tri, _tri_idx[tri][2]).y
	var v0: Vector2 = b - a
	var v1: Vector2 = c - a
	var v2: Vector2 = p2 - a
	var den: float = v0.cross(v1)
	if absf(den) < 0.0001:
		return ya
	var w1: float = v2.cross(v1) / den
	var w2: float = v0.cross(v2) / den
	return ya * (1.0 - w1 - w2) + yb * w1 + yc * w2


func height_at(p2: Vector2) -> float:
	var tri := nearest_tri(p2)
	if tri < 0:
		return 0.0
	return _height_in_tri(tri, p2)


## Triangles weighted by area.
func random_point(rng: RandomNumberGenerator) -> Vector3:
	if _tri_pts.is_empty():
		return Vector3.ZERO
	return _random_point_in_tri(_pick_tri_weighted(rng), rng)


## Anywhere on the zones when no triangle is near.
func random_point_near(origin: Vector3, radius: float, rng: RandomNumberGenerator) -> Vector3:
	if _tri_pts.is_empty():
		return origin
	var o2 := Vector2(origin.x, origin.z)
	var candidates := PackedInt32Array()
	var weights := PackedFloat32Array()
	var total := 0.0
	for i in _tri_pts.size():
		if _tri_centroid[i].distance_to(o2) <= radius:
			candidates.append(i)
			weights.append(_tri_area[i])
			total += _tri_area[i]
	if candidates.is_empty():
		return random_point(rng)
	var roll := rng.randf() * total
	for k in candidates.size():
		roll -= weights[k]
		if roll <= 0.0:
			return _random_point_in_tri(candidates[k], rng)
	return _random_point_in_tri(candidates[candidates.size() - 1], rng)


func _pick_tri_weighted(rng: RandomNumberGenerator) -> int:
	var roll := rng.randf() * _total_area
	for i in _tri_area.size():
		roll -= _tri_area[i]
		if roll <= 0.0:
			return i
	return _tri_area.size() - 1


func _random_point_in_tri(tri: int, rng: RandomNumberGenerator) -> Vector3:
	var r1 := sqrt(rng.randf())
	var r2 := rng.randf()
	var a: Vector2 = _tri_pts[tri][0]
	var b: Vector2 = _tri_pts[tri][1]
	var c: Vector2 = _tri_pts[tri][2]
	var p2: Vector2 = a * (1.0 - r1) + b * (r1 * (1.0 - r2)) + c * (r1 * r2)
	return Vector3(p2.x, _height_in_tri(tri, p2), p2.y)


## Weights crowded triangles so routes go round a standing crowd.
func update_congestion(people_local: Array) -> void:
	for id in _congested:
		_astar.set_point_weight_scale(int(id), 1.0)
	_congested = {}
	var counts := {}
	for p in people_local:
		var tri := tri_at(Vector2(p.x, p.z))
		if tri >= 0:
			counts[tri] = int(counts.get(tri, 0)) + 1
	for tri in counts:
		var c := int(counts[tri])
		if c >= 2:
			var w := 1.0 + float(c - 1) * 3.0
			_astar.set_point_weight_scale(int(tri), w)
			_congested[tri] = w


func _segment_congested(a: Vector2, b: Vector2) -> bool:
	if _congested.is_empty():
		return false
	var steps := maxi(1, int(ceil(a.distance_to(b) / SEGMENT_SAMPLE_STEP)))
	for s in steps + 1:
		var tri := tri_at(a.lerp(b, float(s) / float(steps)))
		if tri >= 0 and _congested.has(tri):
			return true
	return false


## `to` is always last; empty when there is no connected route.
func find_route(from: Vector3, to: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	if _tri_pts.is_empty():
		return out
	var a2 := Vector2(from.x, from.z)
	var b2 := Vector2(to.x, to.z)
	if _segment_walkable(a2, b2) and not _segment_congested(a2, b2):
		out.append(to)
		return out
	var ta := nearest_tri(a2)
	var tb := nearest_tri(b2)
	if ta < 0 or tb < 0:
		return out
	var ids := _astar.get_id_path(ta, tb)
	if ids.is_empty():
		return out
	for k in range(ids.size() - 1):
		var key := "%d:%d" % [mini(ids[k], ids[k + 1]), maxi(ids[k], ids[k + 1])]
		if _portals.has(key):
			out.append(_portals[key])
	out.append(to)
	return _smooth(from, out)


## Greedy string-pull, at most SMOOTH_MAX_SKIP waypoints ahead.
func _smooth(from: Vector3, route: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var anchor := Vector2(from.x, from.z)
	var i := 0
	while i < route.size():
		var best := i
		var limit := mini(route.size() - 1, i + SMOOTH_MAX_SKIP)
		for j in range(limit, i, -1):
			if _segment_walkable(anchor, Vector2(route[j].x, route[j].z)):
				best = j
				break
		out.append(route[best])
		anchor = Vector2(route[best].x, route[best].z)
		i = best + 1
	return out
