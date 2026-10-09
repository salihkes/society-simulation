extends Node3D
## School walking on a baked navmesh; the game uses building_nav.gd, this is kept for test_school_nav.gd.

const MESH := "res://assets/art/models/interiors/school/school_navmesh.res"
const NEAR := 3.0  # workspace units
const FLOOR_GAP := 5.0  # a jump this tall between waypoints is a lift ride
const DOOR_REACH := 5.0
const LIFT_COST := 3.0
const LIFT_ENTER := 4.0  # so one ride beats a chain of one-floor hops
const SEAM_CANDIDATES := [Vector3(-37.0, 0.1, -296.7), Vector3(-65.1, 0.1, -296.8), Vector3(78.0, 0.1, -297.6)]

var ready_ok := false
var _manager = null
var _world: Node3D = null
var _map: RID
var _region: NavigationRegion3D = null
var _links: Array = []  # link nodes attach to the map, server links did not
var _seam := Vector3.INF  # workspace
var _entrance := Vector3.INF  # the lift's ground landing
var _lift = null
var _bounds := AABB()


func setup(manager, world: Node3D) -> void:
	_manager = manager
	_world = world
	if not ResourceLoader.exists(MESH):
		print("[SchoolNav] no baked mesh (%s): the school is reached by jumps" % MESH)
		return
	var nm: NavigationMesh = load(MESH)
	if nm == null or nm.get_polygon_count() == 0:
		return
	var gnm := _global_mesh(nm)
	_map = get_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(_map, gnm.cell_size)
	NavigationServer3D.map_set_cell_height(_map, gnm.cell_height)
	_region = NavigationRegion3D.new()
	_region.top_level = true
	add_child(_region)
	_region.global_transform = Transform3D.IDENTITY
	_region.navigation_mesh = gnm
	_finish.call_deferred()


func _global_mesh(nm: NavigationMesh) -> NavigationMesh:
	var gnm := NavigationMesh.new()
	gnm.cell_size = nm.cell_size * _world.scale.x
	gnm.cell_height = nm.cell_height * _world.scale.y
	var gv := PackedVector3Array()
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for v in nm.get_vertices():
		gv.append(_world.to_global(v))
		lo = lo.min(v)
		hi = hi.max(v)
	_bounds = AABB(lo, hi - lo)
	gnm.set_vertices(gv)
	for i in nm.get_polygon_count():
		gnm.add_polygon(nm.get_polygon(i))
	return gnm


func _finish() -> void:
	# A new region answers queries only after a sync or two.
	for i in 6:
		await get_tree().physics_frame
	NavigationServer3D.map_force_update(_map)
	for i in 3:
		await get_tree().physics_frame
	_closest(Vector3.ZERO)  # warms the map
	for e in get_tree().get_nodes_in_group("elevators"):
		if e.has_node("Landing0/Approach"):
			_lift = e
			break
	# A landing's marker stands a step off the corridor's edge.
	NavigationServer3D.map_set_link_connection_radius(_map, 2.0)
	_link_lift()
	_link_doors()
	# Links attach on a later sync.
	for i in 90:
		await get_tree().physics_frame
		NavigationServer3D.map_force_update(_map)
		if _links_attached():
			break
	for c in SEAM_CANDIDATES:
		var s := _closest(c)
		if s.distance_to(c) < NEAR:
			_seam = s
			break
	if _lift != null:
		_entrance = _world.to_local(_lift.get_node("Landing0/Approach").global_position)
	ready_ok = true
	print("[SchoolNav] %d polygons, %d links, seam %s, entrance %s" % [_region.navigation_mesh.get_polygon_count(),
		_links.size(), str(_seam.snapped(Vector3(1, 1, 1))) if _seam != Vector3.INF else "none",
		str(_entrance.snapped(Vector3(1, 1, 1))) if _entrance != Vector3.INF else "none"])


func _links_attached() -> bool:
	if _links.is_empty():
		return true
	var ln: NavigationLink3D = _links[0]
	var path := NavigationServer3D.map_get_path(_map, ln.start_position, ln.end_position, true)
	return path.size() >= 2 and path.size() <= 4 and absf(path[path.size() - 1].y - ln.end_position.y) < 0.5


## Dearer than stairs, so one floor is climbed on foot.
func _link_lift() -> void:
	if _lift == null or not ("FLOORS" in _lift):
		return
	var n: int = _lift.FLOORS.size()
	var pts: Array = []
	for i in n:
		var a: Node3D = _lift.get_node_or_null("Landing%d/Approach" % i)
		pts.append(_world.to_global(_closest(_world.to_local(a.global_position))) if a != null else null)
	for i in n:
		for j in range(i + 1, n):
			if pts[i] == null or pts[j] == null:
				continue
			_links.append(_make_link(pts[i], pts[j], LIFT_COST, LIFT_ENTER))


func _make_link(a: Vector3, b: Vector3, cost: float = 1.0, enter: float = 0.0) -> NavigationLink3D:
	var ln := NavigationLink3D.new()
	ln.top_level = true
	add_child(ln)
	ln.global_transform = Transform3D.IDENTITY
	ln.start_position = a
	ln.end_position = b
	ln.bidirectional = true
	ln.travel_cost = cost
	ln.enter_cost = enter
	return ln


## So a door leaf shut in the model does not cut the room off the map.
func _link_doors() -> void:
	if _manager == null:
		return
	for sch in _manager.places.schools:
		if sch == null or not is_instance_valid(sch) or sch._room == null:
			continue
		var door: Node3D = sch._room.find_child("Door", true, false)
		if door == null:
			continue
		var d: Vector3 = _world.to_local(door.global_position)
		var f: Vector3 = _world.to_local(door.global_position - door.global_transform.basis.z) - d
		f.y = 0.0
		if f.length_squared() < 0.001:
			continue
		f = f.normalized()
		var a := _closest(d + f * DOOR_REACH)
		var b := _closest(d - f * DOOR_REACH)
		if a.distance_to(d + f * DOOR_REACH) > NEAR or b.distance_to(d - f * DOOR_REACH) > NEAR or a.distance_to(b) < 2.0:
			continue
		_links.append(_make_link(_world.to_global(a), _world.to_global(b)))


func _closest(p: Vector3) -> Vector3:
	return _world.to_local(NavigationServer3D.map_get_closest_point(_map, _world.to_global(p)))


func covers(p: Vector3) -> bool:
	if not ready_ok or not _bounds.grow(NEAR).has_point(p):
		return false
	return _closest(p).distance_to(p) <= NEAR


func seam() -> Vector3:
	return _seam


func entrance() -> Vector3:
	return _entrance


func bounds() -> AABB:
	return _bounds


## True when there is no entrance.
func inside(p: Vector3) -> bool:
	if _entrance == Vector3.INF:
		return true
	if p.y > _entrance.y + 6.0:
		return true
	return bool(route(p, _entrance).reached)


## {"points", "lifts": {i: place}, "reached"} in workspace units.
func route(from: Vector3, to: Vector3) -> Dictionary:
	var out := {"points": PackedVector3Array(), "lifts": {}, "reached": false}
	if not ready_ok:
		return out
	var path := NavigationServer3D.map_get_path(_map, _world.to_global(from), _world.to_global(to), true)
	if path.size() < 2:
		return out
	var pts := PackedVector3Array()
	for p in path:
		pts.append(_world.to_local(p))
	var k := 1
	while k < pts.size() - 1:
		if absf(pts[k].y - pts[k - 1].y) > FLOOR_GAP and absf(pts[k + 1].y - pts[k].y) > FLOOR_GAP:
			pts.remove_at(k)
		else:
			k += 1
	for i in range(1, pts.size()):
		if absf(pts[i].y - pts[i - 1].y) > FLOOR_GAP and _lift != null and _lift.has_method("nearest_floor"):
			var to_y: float = _lift.to_local(_world.to_global(pts[i])).y
			out.lifts[i - 1] = str(_lift.elevator_id) + "/" + str(_lift.nearest_floor(to_y))
	out.points = pts
	var last: Vector3 = pts[pts.size() - 1]
	var flat: Vector3 = last - to
	flat.y = 0.0
	out.reached = flat.length() <= NEAR + 1.0 and absf(last.y - to.y) <= FLOOR_GAP + 1.0
	return out
