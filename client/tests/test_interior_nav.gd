extends SceneTree
## The sampled-floor navigation on a small built interior: a floor, a wall
## with a doorway, a closed room. Routes go through the door and not through
## walls; a room with no door is unreachable; a wall spot snaps to floor.
##   Godot --headless --path client --script res://tests/test_interior_nav.gd

const Nav = preload("res://src/life/interior_nav.gd")

var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + message)


func _box(parent: Node3D, size: Vector3, at: Vector3, layer := 1) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	shape.shape = bs
	body.add_child(shape)
	body.position = at
	parent.add_child(body)
	return body


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var world := Node3D.new()
	world.name = "World"
	world.scale = Vector3.ONE * 0.2   # the city's scale: the nav must not care
	get_root().add_child(world)
	# Floor 60 x 60 units, top at y = 0.
	_box(world, Vector3(60, 1, 60), Vector3(0, -0.5, 0))
	# A wall along z = 0 with a 6-unit doorway at the middle.
	_box(world, Vector3(27, 10, 1), Vector3(-16.5, 5, 0))
	_box(world, Vector3(27, 10, 1), Vector3(16.5, 5, 0))
	# A closed room: four walls, no door, around (20, 20).
	_box(world, Vector3(12, 10, 1), Vector3(20, 5, 14))
	_box(world, Vector3(12, 10, 1), Vector3(20, 5, 26))
	_box(world, Vector3(1, 10, 12), Vector3(14, 5, 20))
	_box(world, Vector3(1, 10, 12), Vector3(26, 5, 20))
	# A table (furniture layer 3): not an obstacle, bodies walk through furniture.
	_box(world, Vector3(6, 4, 6), Vector3(-15, 2, -15), 4)
	for i in 4:
		await physics_frame
	var space := get_root().get_world_3d().direct_space_state
	var nav = Nav.new()
	var ok: bool = nav.build(space, world, AABB(Vector3(-30, -1, -30), Vector3(60, 12, 60)))
	check(ok, "a floor is found")
	print(nav.ascii(70))
	check(absf(nav.floor_y) < 0.6, "the floor level is the floor (%.2f)" % nav.floor_y)
	check(nav.walkable(Vector3(-10, 0, -10)), "open floor is walkable")
	check(nav.walkable(Vector3(0, 0, 0)), "the doorway is walkable")
	check(not nav.walkable(Vector3(10, 0, 0)), "a wall is not")
	check(nav.walkable(Vector3(-15, 0, -15)), "the floor under a table is still floor: furniture is ignored")
	var route: PackedVector3Array = nav.route(Vector3(-10, 0, -10), Vector3(10, 0, 10))
	check(route.size() >= 2, "a route across the wall exists (%d points)" % route.size())
	var through_door := false
	for p in route:
		if absf(p.x) < 3.5 and absf(p.z) < 3.0:
			through_door = true
	check(through_door, "and it goes through the doorway")
	for i in range(1, route.size()):
		var a: Vector3 = route[i - 1]
		var b: Vector3 = route[i]
		var crosses_wall := (a.z < 0) != (b.z < 0) and absf(lerpf(a.x, b.x, a.z / (a.z - b.z))) > 3.5
		check(not crosses_wall, "no leg of the route passes through the wall")
	check(nav.route(Vector3(-10, 0, -10), Vector3(20, 0, 20)).is_empty(), "a room with no door cannot be reached")
	var around: PackedVector3Array = nav.route(Vector3(-25, 0, -15), Vector3(-5, 0, -15))
	var straight := around.size() >= 2 and around.size() <= 3
	for p in around:
		if absf(p.z + 15.0) > 1.0:
			straight = false
	check(straight, "a table in the way is walked straight through (%d points)" % around.size())
	# A spot inside the wall's thickness, asked for from the south: the route
	# ends beside it on the south side, not through the wall from the north.
	var into_wall: PackedVector3Array = nav.route(Vector3(10, 0, -10), Vector3(10, 0, -0.3))
	check(into_wall.size() >= 2 and into_wall[into_wall.size() - 1].z < -0.2, "a spot in a wall is approached from the side one is on (ends at z=%.1f)" % (into_wall[into_wall.size() - 1].z if into_wall.size() > 0 else 99.0))
	for i in range(1, into_wall.size()):
		check((into_wall[i - 1].z < 0) == (into_wall[i].z < 0) or absf(into_wall[i].x) < 3.5, "no leg of it crosses the wall")
	var snapped: Vector3 = nav.snap_pos(Vector3(10, 0, 0))
	check(nav.walkable(snapped) and snapped.distance_to(Vector3(10, 0, 0)) < 4.0, "a spot inside a wall snaps to the floor beside it")
	var last: Vector3 = route[route.size() - 1]
	check(last.distance_to(Vector3(10, 0, 10)) < 1.5, "the route ends on the spot asked for")
	print("Interior nav tests: ", "PASS" if failures == 0 else "FAIL ", failures)
	quit(0 if failures == 0 else 1)
