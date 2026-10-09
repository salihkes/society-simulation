extends RefCounted
## Directed lane graph for ambient traffic: links, crossings and signal stop lines, workspace-local.

var junction_dist := 45.0
const SNAP_DIST := 12.0  # within this, the end is already on the road
const UTURN_DOT := -0.85  # reject turns sharper than ~148 degrees
## Lanes meeting at a shallower angle are the same road, not a crossing.
const CROSS_MIN_ANGLE := 0.44  # ~25 degrees
## Crossings this close to a lane end are left to the junction links.
const CROSS_END_MARGIN := 25.0
const TURN_BLEND := 10.0

var _points: Array = []  # PackedVector3Array per lane
var _cum: Array = []  # cumulative distances per lane
var _length := PackedFloat32Array()
# Per lane, by dist: {id, lane, dist, other_dist, angle, pos}; both lanes share `id`.
var _crossings: Array = []
# Per lane: [{lane, dist, exit, entry, len}]
var _links: Array = []
var _start_heading := PackedVector3Array()
var _end_heading := PackedVector3Array()
# Per lane, by dist: {sig, dist, group} where the lane enters a signal's circle.
var _lane_signals: Array = []
var _signal_ref := PackedFloat32Array()  # per signal: group-0 folded heading
var _signal_count := 0


func is_empty() -> bool:
	return _points.is_empty()


func lane_count() -> int:
	return _points.size()


func lane_length(lane: int) -> float:
	return _length[lane]


func outgoing(lane: int) -> Array:
	return _links[lane]


func signal_count() -> int:
	return _signal_count


## {sig, dist, group} at most 1 m behind `d`, or {}; a car further past is committed.
func next_signal_stop(lane: int, d: float) -> Dictionary:
	for entry in _lane_signals[lane]:
		if float(entry.dist) >= d - 1.0:
			return entry
	return {}


func group_for_heading(sig: int, dir: Vector3) -> int:
	if sig < 0 or sig >= _signal_ref.size() or is_nan(_signal_ref[sig]):
		return 0
	return _phase_group(_folded_angle(_flat_dir(dir)), _signal_ref[sig])


## Group 0 within 45 degrees of the reference heading, else 1.
static func _phase_group(a: float, ref: float) -> int:
	var diff := absf(a - ref)
	diff = minf(diff, PI - diff)
	return 0 if diff < PI / 4.0 else 1


## `signals`: [{"pos", "radius"}]. Lanes under 2 points or 0.5 m are dropped.
func build(lanes: Array, signals: Array = []) -> void:
	_points = []
	_cum = []
	_length = PackedFloat32Array()
	_links = []
	_start_heading = PackedVector3Array()
	_end_heading = PackedVector3Array()
	_lane_signals = []
	_signal_ref = PackedFloat32Array()
	_signal_count = signals.size()

	for lane in lanes:
		var pts: PackedVector3Array = lane
		if pts.size() < 2:
			continue
		var cum := PackedFloat32Array()
		cum.append(0.0)
		var total := 0.0
		for i in range(1, pts.size()):
			total += pts[i].distance_to(pts[i - 1])
			cum.append(total)
		if total < 0.5:
			continue
		_points.append(pts)
		_cum.append(cum)
		_length.append(total)
		_start_heading.append(_flat_dir(pts[1] - pts[0]))
		_end_heading.append(_flat_dir(pts[pts.size() - 1] - pts[pts.size() - 2]))

	_build_links()
	_build_crossings()
	_assign_signals(signals)


static func _flat_dir(v: Vector3) -> Vector3:
	v.y = 0.0
	if v.length_squared() < 0.0001:
		return Vector3.FORWARD
	return v.normalized()


## U-turns are always refused.
func _link_ok(exit: Vector3, end_h: Vector3, entry: Vector3, entry_dir: Vector3, gap: float) -> bool:
	if end_h.dot(entry_dir) < UTURN_DOT:
		return false
	if gap <= SNAP_DIST:
		# Already on the road: the connector direction is noise.
		return true
	var bridge_dir := _flat_dir(entry - exit)
	return bridge_dir.dot(entry_dir) > 0.0 and end_h.dot(bridge_dir) > -0.2


static func _make_link(lane: int, dist: float, exit: Vector3, entry: Vector3) -> Dictionary:
	return {"lane": lane, "dist": dist, "exit": exit, "entry": entry,
		"len": exit.distance_to(entry)}


func _build_crossings() -> void:
	_crossings = []
	for i in _points.size():
		_crossings.append([])
	var next_id := 0
	for i in _points.size():
		for j in range(i + 1, _points.size()):
			next_id = _cross_lane_pair(i, j, next_id)
	for i in _points.size():
		_crossings[i].sort_custom(func(x, y): return float(x.dist) < float(y.dist))


## Returns the next unused id.
func _cross_lane_pair(i: int, j: int, next_id: int) -> int:
	for si in range(_points[i].size() - 1):
		for sj in range(_points[j].size() - 1):
			if _add_crossing(i, si, j, sj, next_id):
				next_id += 1
	return next_id


func _add_crossing(i: int, si: int, j: int, sj: int, id: int) -> bool:
	var a: PackedVector3Array = _points[i]
	var b: PackedVector3Array = _points[j]
	var hit := _segment_cross(a[si], a[si + 1], b[sj], b[sj + 1])
	if hit.is_empty():
		return false
	var da: float = _cum[i][si] + a[si].distance_to(a[si + 1]) * float(hit.t)
	var db: float = _cum[j][sj] + b[sj].distance_to(b[sj + 1]) * float(hit.u)
	if da < CROSS_END_MARGIN or da > _length[i] - CROSS_END_MARGIN:
		return false
	if db < CROSS_END_MARGIN or db > _length[j] - CROSS_END_MARGIN:
		return false
	var angle: float = _seg_dir(i, si).angle_to(_seg_dir(j, sj))
	# Near-parallel is the same road; near-opposite is a two-way pair. Neither is a junction.
	if angle < CROSS_MIN_ANGLE or angle > PI - CROSS_MIN_ANGLE:
		return false
	var at: Vector3 = a[si].lerp(a[si + 1], float(hit.t))
	_crossings[i].append({"id": id, "lane": j, "dist": da,
		"other_dist": db, "angle": angle, "pos": at})
	_crossings[j].append({"id": id, "lane": i, "dist": db,
		"other_dist": da, "angle": angle, "pos": at})
	return true


## Flat; {} when they miss.
static func _segment_cross(a1: Vector3, a2: Vector3, b1: Vector3, b2: Vector3) -> Dictionary:
	var p := Vector2(a1.x, a1.z)
	var r := Vector2(a2.x - a1.x, a2.z - a1.z)
	var q := Vector2(b1.x, b1.z)
	var s := Vector2(b2.x - b1.x, b2.z - b1.z)
	var denom := r.cross(s)
	if absf(denom) < 0.0001:
		return {}
	var t := (q - p).cross(s) / denom
	var u := (q - p).cross(r) / denom
	if t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0:
		return {}
	return {"t": t, "u": u}


func crossings_near(lane: int, d: float, ahead: float, behind := 8.0) -> Array:
	var out: Array = []
	if lane < 0 or lane >= _crossings.size():
		return out
	for c in _crossings[lane]:
		var cd: float = float(c.dist)
		if cd < d - behind:
			continue
		if cd > d + ahead:
			break
		out.append(c)
	return out


## Starts in reach, else merges into lane bodies, else a turn-around.
func _build_links() -> void:
	for i in _points.size():
		var exit: Vector3 = _points[i][_points[i].size() - 1]
		var end_h := _end_heading[i]
		var links := _links_to_starts(i, exit, end_h)
		if links.is_empty():
			links = _links_into_bodies(i, exit, end_h)
		if links.is_empty():
			links = _turnaround_link(i, exit)
		_links.append(links)


func _links_to_starts(i: int, exit: Vector3, end_h: Vector3) -> Array:
	var links: Array = []
	for j in _points.size():
		if j == i:
			continue
		var start: Vector3 = _points[j][0]
		var gap := exit.distance_to(start)
		if gap <= junction_dist and _link_ok(exit, end_h, start, _start_heading[j], gap):
			links.append(_make_link(j, 0.0, exit, start))
	return links


## Every lane within SNAP_DIST (parallel copies of one road), else the closest merge.
func _links_into_bodies(i: int, exit: Vector3, end_h: Vector3) -> Array:
	var snap_links: Array = []
	var best: Dictionary = {}
	var best_gap := junction_dist + 1.0
	for j in _points.size():
		if j == i:
			continue
		var cand := _closest_merge(j, exit, end_h)
		if cand.is_empty():
			continue
		var cand_gap: float = cand.len
		if cand_gap <= SNAP_DIST:
			snap_links.append(cand)
		if cand_gap < best_gap:
			best_gap = cand_gap
			best = cand
	if not snap_links.is_empty():
		return snap_links
	if not best.is_empty():
		return [best]
	return []


## {} when none is in reach; the last 5 m of `j` are skipped.
func _closest_merge(j: int, exit: Vector3, end_h: Vector3) -> Dictionary:
	var pts: PackedVector3Array = _points[j]
	var cum: PackedFloat32Array = _cum[j]
	var cand: Dictionary = {}
	var cand_gap := junction_dist + 1.0
	for seg in range(pts.size() - 1):
		var entry := Geometry3D.get_closest_point_to_segment(exit, pts[seg], pts[seg + 1])
		var gap := exit.distance_to(entry)
		if gap > junction_dist:
			continue
		var entry_dist: float = cum[seg] + pts[seg].distance_to(entry)
		if entry_dist > _length[j] - 5.0:
			continue
		var entry_dir := _flat_dir(pts[seg + 1] - pts[seg])
		if not _link_ok(exit, end_h, entry, entry_dir, gap):
			continue
		if gap < cand_gap:
			cand_gap = gap
			cand = _make_link(j, entry_dist, exit, entry)
	return cand


## Dead-end last resort; the other passes refuse it because mid-road it would be a U-turn.
func _turnaround_link(i: int, exit: Vector3) -> Array:
	var turn: Dictionary = {}
	var turn_gap := junction_dist * 4.0
	for j in _points.size():
		if j == i:
			continue
		var start: Vector3 = _points[j][0]
		var gap := exit.distance_to(start)
		if gap < turn_gap:
			turn_gap = gap
			turn = _make_link(j, 0.0, exit, start)
	if turn.is_empty():
		return []
	return [turn]


func _assign_signals(signals: Array) -> void:
	for s in signals.size():
		_signal_ref.append(NAN)
	for i in _points.size():
		_lane_signals.append(_signal_entries(i, signals))
	# The first approach seen at a signal sets its group-0 heading.
	for i in _points.size():
		for entry in _lane_signals[i]:
			var s := int(entry.sig)
			var a := _folded_angle(entry.heading)
			if is_nan(_signal_ref[s]):
				_signal_ref[s] = a
			entry.group = _phase_group(a, _signal_ref[s])
			entry.erase("heading")


func _signal_entries(i: int, signals: Array) -> Array:
	var entries: Array = []
	var pts: PackedVector3Array = _points[i]
	var cum: PackedFloat32Array = _cum[i]
	for s in signals.size():
		var sig: Dictionary = signals[s]
		var center: Vector3 = sig.get("pos", Vector3.ZERO)
		var radius: float = float(sig.get("radius", 60.0))
		for seg in range(pts.size() - 1):
			var da := _flat_dist(pts[seg], center)
			var db := _flat_dist(pts[seg + 1], center)
			if da <= radius or db > radius:
				continue
			var t: float = clampf((da - radius) / maxf(da - db, 0.001), 0.0, 1.0)
			var seg_len: float = cum[seg + 1] - cum[seg]
			entries.append({
				"sig": s,
				"dist": cum[seg] + seg_len * t,
				"group": 0,
				"heading": _flat_dir(pts[seg + 1] - pts[seg]),
			})
	entries.sort_custom(func(a, b): return float(a.dist) < float(b.dist))
	return entries


static func _flat_dist(a: Vector3, b: Vector3) -> float:
	a.y = 0.0
	b.y = 0.0
	return a.distance_to(b)


static func _folded_angle(h: Vector3) -> float:
	return fposmod(atan2(h.x, h.z), PI)


## Corners are rounded, so a car always faces the way it travels.
func sample(lane: int, d: float) -> Transform3D:
	var pts: PackedVector3Array = _points[lane]
	var cum: PackedFloat32Array = _cum[lane]
	d = clampf(d, 0.0, _length[lane])
	var corner := _corner_at(lane, d)
	if not corner.is_empty():
		return _sample_corner(lane, corner)
	var seg := 0
	while seg < cum.size() - 2 and cum[seg + 1] < d:
		seg += 1
	var seg_len: float = maxf(cum[seg + 1] - cum[seg], 0.001)
	var t: float = (d - cum[seg]) / seg_len
	return Transform3D(Basis.looking_at(_seg_dir(lane, seg), Vector3.UP),
		pts[seg].lerp(pts[seg + 1], t))


## `corner` is {k, b, u}.
func _sample_corner(lane: int, corner: Dictionary) -> Transform3D:
	var pts: PackedVector3Array = _points[lane]
	var k := int(corner.k)
	var b: float = corner.b
	var u: float = corner.u
	var p1: Vector3 = pts[k]
	var p0: Vector3 = p1 + (pts[k - 1] - p1).normalized() * b
	var p2: Vector3 = p1 + (pts[k + 1] - p1).normalized() * b
	var iu := 1.0 - u
	var pos: Vector3 = p0 * (iu * iu) + p1 * (2.0 * iu * u) + p2 * (u * u)
	var tan_v: Vector3 = (p1 - p0) * (2.0 * iu) + (p2 - p1) * (2.0 * u)
	tan_v.y = 0.0
	if tan_v.length_squared() < 0.0001:
		tan_v = _seg_dir(lane, k)
	return Transform3D(Basis.looking_at(tan_v.normalized(), Vector3.UP), pos)


## {k, b, u}; the rounding never eats more than half a segment, so corners cannot overlap.
func _corner_at(lane: int, d: float) -> Dictionary:
	var pts: PackedVector3Array = _points[lane]
	var cum: PackedFloat32Array = _cum[lane]
	for k in range(1, pts.size() - 1):
		var b: float = minf(TURN_BLEND, minf(
			(cum[k] - cum[k - 1]) * 0.5, (cum[k + 1] - cum[k]) * 0.5))
		if b < 0.05:
			continue
		if d < cum[k] - b:
			break
		if d <= cum[k] + b:
			return {"k": k, "b": b, "u": (d - (cum[k] - b)) / (2.0 * b)}
	return {}


## {pos, tan} at parameter `u`.
static func hermite(p0: Vector3, d0: Vector3, p1: Vector3, d1: Vector3, u: float) -> Dictionary:
	var m: float = p0.distance_to(p1)
	var u2 := u * u
	var u3 := u2 * u
	var pos: Vector3 = p0 * (2.0 * u3 - 3.0 * u2 + 1.0) \
		+ d0 * m * (u3 - 2.0 * u2 + u) \
		+ p1 * (-2.0 * u3 + 3.0 * u2) \
		+ d1 * m * (u3 - u2)
	var tan_v: Vector3 = p0 * (6.0 * u2 - 6.0 * u) \
		+ d0 * m * (3.0 * u2 - 4.0 * u + 1.0) \
		+ p1 * (-6.0 * u2 + 6.0 * u) \
		+ d1 * m * (3.0 * u2 - 2.0 * u)
	tan_v.y = 0.0
	if tan_v.length_squared() < 0.0001:
		tan_v = d1
	return {"pos": pos, "tan": tan_v.normalized()}


static func hermite_length(p0: Vector3, d0: Vector3, p1: Vector3, d1: Vector3) -> float:
	var total := 0.0
	var prev: Vector3 = p0
	for i in range(1, 9):
		var at: Vector3 = hermite(p0, d0, p1, d1, float(i) / 8.0).pos
		total += prev.distance_to(at)
		prev = at
	return maxf(total, 0.001)


func _seg_dir(lane: int, seg: int) -> Vector3:
	var pts: PackedVector3Array = _points[lane]
	seg = clampi(seg, 0, pts.size() - 2)
	var dir: Vector3 = pts[seg + 1] - pts[seg]
	dir.y = 0.0
	return dir.normalized() if dir.length_squared() > 0.0001 else Vector3.FORWARD


## Radians, summed in steps so an S-bend still counts.
func turn_ahead(lane: int, d: float, span := 34.0) -> float:
	var steps := 4
	var step: float = span / float(steps)
	var total := 0.0
	var prev: Vector3 = -sample(lane, d).basis.z
	for i in range(1, steps + 1):
		var at: float = minf(d + step * float(i), _length[lane])
		var here: Vector3 = -sample(lane, at).basis.z
		total += absf(prev.signed_angle_to(here, Vector3.UP))
		prev = here
		if at >= _length[lane]:
			break
	return total


## {lane, dist, err} with err squared; lane is -1 when there are no lanes.
func nearest_on_network(p: Vector3) -> Dictionary:
	var best := {"lane": -1, "dist": 0.0, "err": INF}
	for lane in _points.size():
		var pts: PackedVector3Array = _points[lane]
		var cum: PackedFloat32Array = _cum[lane]
		for seg in range(pts.size() - 1):
			var closest := Geometry3D.get_closest_point_to_segment(p, pts[seg], pts[seg + 1])
			var err := closest.distance_squared_to(p)
			if err < best.err:
				best.err = err
				best.lane = lane
				best.dist = cum[seg] + pts[seg].distance_to(closest)
	return best


## Offset to the left: the opposite lane of a two-way road.
static func reversed_offset(pts: PackedVector3Array, offset: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in pts.size():
		var prev: Vector3 = pts[maxi(i - 1, 0)]
		var next: Vector3 = pts[mini(i + 1, pts.size() - 1)]
		var tangent := next - prev
		tangent.y = 0.0
		if tangent.length_squared() < 0.0001:
			tangent = Vector3.FORWARD
		var right := tangent.normalized().cross(Vector3.UP)
		out.append(pts[i] - right * offset)
	out.reverse()
	return out
