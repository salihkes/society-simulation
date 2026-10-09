extends SceneTree
## The chamber component on the real legislature scene, with stub bodies —
## no city, server or model. Run:
##   Godot --headless --path client -s res://tests/test_parliament.gd
const Parliament = preload("res://src/life/ambient_parliament.gd")

class Body extends Node3D:
	var ped_id := ""
	var sitting := false
	var velocity := Vector3.ZERO
	var steer_to := Vector3.INF
	var steer_speed := 0.0
	var personal_space := true
	var idle_timer := 0.0
	var active_entry: Dictionary = {}
	var inside_door := Vector3.INF
	var character_model: Node3D = null
	var sat_at := Vector3.INF
	var sat_yaw := 0.0
	var class_overs := 0
	func _init(): character_model = Node3D.new(); add_child(character_model)
	func sit_at(pos: Vector3, yaw: float, _how := "chair"): sitting = true; sat_at = pos; sat_yaw = yaw
	func stand_up(): sitting = false
	func enter_idle(): pass
	func hold_idle(s): enter_idle(); idle_timer = s
	func class_over(): class_overs += 1

class Nav extends RefCounted:
	var walkable := true
	func is_walkable(_p: Vector2) -> bool: return walkable
	func random_point_near(p: Vector3, _r: float, _rng) -> Vector3: return p + Vector3(5, 0, 0)

class Manager extends Node:
	var nav = Nav.new()
	var _rng = RandomNumberGenerator.new()
	var _world: Node3D = null
	var _is_authority := true
	var _residents: Dictionary = {}
	var _peds: Dictionary = {}
	var _nc = null
	func world(): return _world
	func rng(): return _rng
	func is_authority(): return _is_authority
	func residents(): return _residents
	func peds(): return _peds
	func local_player(): return _nc.players.local_player if _nc != null else null
	func local_username() -> String: return "tester"

var fails := 0
func check(ok: bool, what: String):
	if not ok:
		fails += 1
		print("FAIL: " + what)

func _init():
	var world := Node3D.new()
	world.position = Vector3(10, 0, -5)   # the workspace is not at the origin; positions must be local to it
	get_root().add_child.call_deferred(world)
	var room: Node3D = (load("res://assets/scenes/legislature.tscn") as PackedScene).instantiate()
	world.add_child(room)
	var man := Manager.new()
	man._world = world
	world.add_child(man)
	for k in ["r_a", "r_b", "r_c", "r_speaker"]:
		var b := Body.new(); b.ped_id = k; b.active_entry = {"do": "go", "place": "parliament.door"}
		world.add_child(b); man._residents[k] = b
	process_frame.connect(_run.bind(world, room, man), CONNECT_ONE_SHOT)

func _run(world: Node3D, room: Node3D, man: Manager):
	var par = Parliament.new()
	room.add_child(par)
	par.setup(man, room)
	# THE MODEL IS THE ARITHMETIC: chairs built = seats.
	check(par.seat_count("Lower") == 85, "85 lower seats, got %d" % par.seat_count("Lower"))
	check(par.seat_count("Upper") == 0, "no upper house built")
	check(par.seat_counts() == {"representatives": 85}, "seat_counts names the built house only: %s" % par.seat_counts())
	check(par.key() == "parliament", "key")
	# Places, workspace-local (the world is offset by (10,0,-5)).
	var door = par.place_position("parliament.door")
	check(door != null and door.is_equal_approx(Vector3(-306, 1.2, 287)), "door is workspace-local (global would be offset): %s" % door)
	check(par.place_position("parliament") == door, "bare 'parliament' is the door")
	check(par.place_position("parliament.representatives.0") != null, "chair 0 by council name")
	check(par.place_position("parliament.Lower.84") != null, "chair 84 by world name")
	check(par.place_position("parliament.representatives.85") == null, "chair 85 does not exist")
	check(par.place_position("parliament.councillors.0") == null, "no upper chairs")
	check(par.place_position("parliament.speaker") != null, "the Speaker's chair")
	check(par.place_position("School") == null, "not our place")
	check(par.place_marker("parliament.representatives.0").name == "Marker3D", "seat marker is a Marker3D")
	check(par.place_marker("parliament.representatives.0").get_parent().name == "Chair01", "seat 0 is Chair01")
	check(par.place_marker("parliament.representatives.84").get_parent().name == "Chair85", "seat 84 is Chair85")
	# Every seat faces the Speaker's chair (the marker's -Z is the facing).
	var sp: Vector3 = par.place_position("parliament.speaker")
	var worst := 1.0
	for i in 85:
		var m: Node3D = par.place_marker("parliament.representatives.%d" % i)
		var f: Vector3 = par._fwd_of(m)
		var d: Vector3 = sp - par._local(m); d.y = 0.0
		worst = minf(worst, f.dot(d.normalized()))
	check(worst > 0.3, "all seats face the Speaker (worst cos %.2f)" % worst)
	var sf: Vector3 = par._fwd_of(par.place_marker("parliament.speaker"))
	var c0 := Vector3.ZERO
	for i in 85: c0 += par._local(par.place_marker("parliament.representatives.%d" % i))
	var dd: Vector3 = c0 / 85.0 - sp; dd.y = 0.0
	check(sf.dot(dd.normalized()) > 0.9, "the Speaker faces the house")
	# The room got a floor to stand on.
	check(not room.find_children("*", "StaticBody3D", true, false).is_empty(), "trimesh floor built")
	# A sitting: seat, open, rise, sit, adjourn.
	var a: Body = man._residents["r_a"]; var s: Body = man._residents["r_speaker"]
	par.on_par({"op": "seat", "house": "representatives", "members": ["r_speaker", "r_a", "r_b"], "speaker": "r_speaker"})
	check(a.sitting and a.sat_at.is_equal_approx(par.place_position("parliament.representatives.0")), "a took chair 0 (the Speaker is not counted)")
	check(man._residents["r_b"].sat_at.is_equal_approx(par.place_position("parliament.representatives.1")), "b took chair 1")
	check(s.sitting and s.sat_at.is_equal_approx(par.place_position("parliament.speaker")), "the Speaker took the Speaker's chair")
	check(a.active_entry.get("_pos") == a.sat_at, "the door intent is pinned to the seat")
	check(a.inside_door == Vector3.ZERO, "a remembers the street it was taken from (the way back out): %s" % a.inside_door)
	check(not par.sitting, "not open yet")
	par.on_par({"op": "open", "matter": "水道", "speaker": "r_speaker"})
	check(par.sitting and par.matter == "水道", "open")
	par.on_par({"op": "rise", "member": "r_a"})
	check(not a.sitting and a.position.y > a.sat_at.y and a.position.distance_to(a.sat_at) < 1.5, "a rose beside the seat: %s vs %s" % [a.position, a.sat_at])
	check(a.idle_timer > 1000.0 and not a.personal_space, "a is held standing")
	check(absf(a.character_model.rotation.y - a.sat_yaw) < 0.001, "a faces the Speaker while standing")
	par.on_par({"op": "rise", "member": "r_nobody"})   # not seated: nothing happens
	par.on_par({"op": "sit", "member": "r_a"})
	check(a.sitting and a.sat_at.is_equal_approx(par.place_position("parliament.representatives.0")), "a sat again")
	# Called to the rostrum: on the floor at the marker, facing the house, then back.
	var ros: Vector3 = par.place_position("parliament.rostrum")
	par.on_par({"op": "rostrum", "member": "r_a"})
	check(not a.sitting and Vector2(a.position.x, a.position.z).is_equal_approx(Vector2(ros.x, ros.z)) and a.position.y > ros.y, "a stands at the rostrum: %s vs %s" % [a.position, ros])
	check(absf(a.character_model.rotation.y - par._yaw_of(par._rostrum)) < 0.001, "a faces the house from the rostrum")
	par.on_par({"op": "rostrum", "member": "r_nobody"})
	par.on_par({"op": "sit", "member": "r_a"})
	check(a.sitting, "a returned to the seat")
	# The vote: a list rises and sits together.
	var b: Body = man._residents["r_b"]
	par.on_par({"op": "rise", "members": ["r_a", "r_b"]})
	check(not a.sitting and not b.sitting, "those in favour rise together")
	par.on_par({"op": "sit", "members": ["r_a", "r_b"]})
	check(a.sitting and b.sitting, "and sit together")
	par.on_par({"op": "result", "verdict": "Passed"})
	check(par.verdict == "Passed", "verdict kept")
	# Members of a house that is not built are left where they are.
	var c: Body = man._residents["r_c"]
	par.on_par({"op": "seat", "house": "councillors", "members": ["r_c"]})
	check(not c.sitting, "no upper house: c stays in the city")
	# A presiding officer from a house that is not built still takes the chair.
	par.on_par({"op": "seat", "house": "speaker", "members": ["r_c"], "speaker": "r_c"})
	check(c.sitting and c.sat_at.is_equal_approx(par.place_position("parliament.speaker")), "a Speaker from the other house takes the Speaker's chair")
	par.on_par({"op": "seat", "house": "representatives", "members": ["r_speaker", "r_a", "r_b"], "speaker": "r_speaker"})
	# Peers replicate the flags, not the bodies.
	var snap: Dictionary = par.snapshot()
	var peer = Parliament.new(); room.add_child(peer)
	var pman := Manager.new(); pman._world = world; pman._is_authority = false; world.add_child(pman)
	peer.setup(pman, room)
	peer.apply_snapshot(snap)
	check(peer.sitting and peer.matter == "水道" and peer.verdict == "Passed", "snapshot round trip")
	peer.on_par({"op": "seat", "house": "representatives", "members": ["r_a"]})
	check(a.sitting, "a non-authority peer moves nobody")
	# One member was taken from somewhere unwalkable: they still get a way out.
	man.nav.walkable = false
	var d := Body.new(); d.ped_id = "r_d"; d.position = Vector3(-280, 5, 280); world.add_child(d); man._residents["r_d"] = d
	par.on_par({"op": "seat", "house": "representatives", "members": ["r_speaker", "r_a", "r_b", "r_d"], "speaker": "r_speaker"})
	check(d.inside_door == Vector3.INF, "d was not on a street when sent for")
	par.on_par({"op": "adjourn"})
	check(not par.sitting and not a.sitting and not s.sitting and a.class_overs == 1, "adjourn: everyone rises and their intent is done")
	check(d.inside_door != Vector3.INF and d.inside_door.distance_to(par.place_position("parliament.door")) < 10.0, "d is given a way out near the building: %s" % d.inside_door)
	print("test_parliament: %s" % ("OK" if fails == 0 else "%d FAILED" % fails))
	quit(1 if fails > 0 else 0)
