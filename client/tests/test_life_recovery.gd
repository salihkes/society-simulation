extends SceneTree
## The real resident's stuck-route recovery must apply to autonomous trips.
class Body extends "res://src/life/resident_npc.gd":
	var recovered := false
	var destination := Vector3(100, 40, 0)
	func _current_dest() -> Vector3: return destination
	func current_entry(_scheduled_only := false) -> Dictionary: return active_entry
	func _entry_pos(_entry: Dictionary) -> Vector3: return destination
	func _teleport_to(dest: Vector3):
		position = dest
		recovered = true

class ErrandOwner extends RefCounted:
	var result := false
	func errand_finished(_body, _tag, ok): result = ok

class RealBody extends "res://src/life/resident_npc.gd":
	func play_door_sound(): pass

class Nav extends RefCounted:
	func find_route(_a, b): return PackedVector3Array([b])
	func is_walkable(_point): return true

class Manager extends RefCounted:
	var nav = Nav.new()
	var school_nav = null

func _initialize():
	var body = Body.new()
	body.active_entry = {"do": "go", "then": "stay", "life_id": "autonomous-trip"}
	for attempt in body.STUCK_TELEPORT_AFTER:
		body._on_route_abandoned()
	var ok: bool = body.recovered and body.position == body.destination and body.life_move_failed == ""
	body.recovered = false
	body.position = body.destination + Vector3(8, 0, 0)
	body.manager = Manager.new()
	for attempt in body.STUCK_TELEPORT_AFTER:
		body._request_route()  # A reroute is not evidence that the obstruction cleared.
		body._on_route_abandoned()
	ok = ok and body.recovered
	var owner = ErrandOwner.new()
	body.errand_owner = owner
	body.errand_dest = Vector3(300, 0, 0)
	body._errand_fails = 1
	body._on_route_abandoned()
	ok = ok and owner.result and body.position == Vector3(300, 0, 0)
	owner.result = false
	body.errand_owner = owner
	body.errand_dest = Vector3(600, 0, 0)
	body._on_errand_unreachable()
	ok = ok and owner.result and body.position == Vector3(600, 0, 0)
	var real = RealBody.new()
	real.ped_id = "r_test"
	real.active_entry = {"do": "go", "then": "stay", "life_id": "trip"}
	real._teleport_to(Vector3.ZERO)
	ok = ok and Vector2(real.position.x, real.position.z).length() <= real.arrival_threshold * 2.0
	real.free()
	if not ok:
		push_error("Autonomous travel must use the resident's teleport recovery")
	body.free()
	print("Life travel recovery tests: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
