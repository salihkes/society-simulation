extends SceneTree
## school_nav.gd against the baked mesh and the school scenes: the surface
## is found, the street seam and the entrance are known, a walk on one
## floor needs no lift, a walk between floors without a stair rides it.
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path client -s tests/test_school_nav.gd
const SCHOOL_NAV := preload("res://src/life/school_nav.gd")
const AMBIENT_SCHOOL := preload("res://src/life/ambient_school.gd")
var failures := 0

func check(c: bool, msg: String) -> void:
	if not c:
		failures += 1
		push_error("SCHOOL NAV: " + msg)
	print(("ok   " if c else "FAIL ") + msg)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var ws := Node3D.new()
	ws.scale = Vector3(0.2, 0.2, 0.2)
	root.add_child(ws)
	for p in ["res://assets/art/models/unitedcity/city.scn", "res://assets/art/models/interiors/school/classrooms.tscn",
			"res://assets/art/models/classroomsample/classroomsample.tscn", "res://assets/art/models/interiors/school/elevator.tscn"]:
		var n = load(p).instantiate()
		if p.ends_with("elevator.tscn"):
			n.position = Vector3(0, 0, -404)
		ws.add_child(n)
	await physics_frame
	# A stand-in manager: the rooms, for the door links.
	var rooms: Array = []
	for lect in ws.find_children("TeacherStandsHereFacingTheClass", "Marker3D", true, false):
		rooms.append({"_room": lect.get_parent()})
	var manager := Node.new()
	manager.set_script(GDScript.new())
	var stub := RefCounted.new()
	var nav = SCHOOL_NAV.new()
	ws.add_child(nav)
	nav._manager = _Stub.new(rooms)
	nav._world = ws
	nav.setup(nav._manager, ws)
	for i in 40:
		await physics_frame
		if nav.ready_ok:
			break
	check(nav.ready_ok, "mesh loaded and on the map")
	check(nav.seam() != Vector3.INF, "street seam found: " + str(nav.seam()))
	check(nav.entrance() != Vector3.INF, "entrance known: " + str(nav.entrance()))
	var landing0 := Vector3(-4, 2.8, -404)
	var landing4 := Vector3(-4, 72.7, -404)
	var landing5 := Vector3(-4, 83.5, -404)
	check(nav.covers(landing0), "the ground landing is on the surface")
	check(not nav.covers(Vector3(0, 2, 0)), "the city centre is not")
	var r := nav.route(Vector3(-23, 55, -428), landing0)
	check(r.reached and r.lifts.is_empty(), "yard -> ground landing walks without the lift (%d points)" % r.points.size())
	r = nav.route(landing5, landing4)
	check(r.reached, "12 level -> 11 level is reachable (%d points, lift %s)" % [r.points.size(), str(r.lifts)])
	r = nav.route(landing0, landing5)
	var ys := PackedFloat32Array()
	for p in r.points:
		if ys.is_empty() or absf(ys[ys.size() - 1] - p.y) > 1.0:
			ys.append(snappedf(p.y, 1.0))
	check(r.reached and r.lifts.size() == 1 and r.lifts.values()[0] == "SchoolElevator/5",
		"ground landing -> 12 level is one lift ride: lifts %s, reached %s, %d points, heights %s" % [str(r.lifts), str(r.reached), r.points.size(), str(ys)])
	r = nav.route(landing0, Vector3(-79, 83.8, -516.9))
	check(r.points.size() >= 2, "ground landing -> 12B door gives a walk (%d points, reached %s)" % [r.points.size(), str(r.reached)])
	quit(1 if failures > 0 else 0)

class _Stub:
	var places := _Places.new()
	func _init(rooms: Array):
		for r in rooms:
			places.schools.append(_Room.new(r["_room"]))

class _Places:
	var schools: Array = []

class _Room:
	var _room: Node3D
	func _init(n: Node3D):
		_room = n
