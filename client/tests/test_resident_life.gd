extends SceneTree
## Real physical action controller with lightweight bodies, no city/server/model.
const Controller = preload("res://src/life/resident_life.gd")

class Body extends Node3D:
	var weather_reaction = preload("res://src/life/citizen_weather.gd").new()
	var ped_id := ""
	var sitting := false
	var steer_to := Vector3.INF
	var steer_speed := 0.0
	var personal_space := true
	var prop := ""
	var emotion := ""
	var idle_timer := 0.0
	var active_entry: Dictionary = {}
	var _route := PackedVector3Array()
	var _route_idx := 0
	var _state := 0
	enum State {IDLE, WALKING}
	var errand_owner = null
	var life_meal_result := ""
	var life_move_failed := ""
	var intents: Array = []
	var arrived := false
	func life_arrived(_id): return arrived
	func stand_up(): sitting = false
	func set_prop(p): prop = p
	func set_emotion(e): emotion = e
	func enter_idle(): _state = State.IDLE
	func hold_idle(s): enter_idle(); idle_timer = s
	func walk_route(r): _route = r; _route_idx = 0; _state = State.WALKING
	func clear_reactions(): intents = []; active_entry = {}; life_move_failed = ""
	func push_intent(i): intents.append(i)

class Nav extends RefCounted:
	func find_route(_a, b): return PackedVector3Array([b])

class Yard extends RefCounted:
	var yard := Vector3(10, 0, 0)
	var _outside: Array
	func _init(outside: Array): _outside = outside
	func has_yard(): return yard != Vector3.INF
	func has_pitch(): return false
	func playing(_pid): return false
	func leave_game(_pid): pass
	func forget(_pid): pass
	func go_yard(b): b.position = yard; _outside.append(b.ped_id)

class Assembly extends RefCounted:
	func active(): return false
	func in_rite(): return false

class Room extends RefCounted:
	var _seats: Array = []
	var enrolled: Array = []
	var outside: Array = []
	var assembly_ = Assembly.new()
	var _teacher := ""
	var match_ = Yard.new(outside)
	var in_break := false
	var capacity := true
	func key(): return "School"
	func pupils_present(): return enrolled.duplicate()
	func _release_pid(pid):
		_seats = _seats.filter(func(s): return s.ped != pid)
	func request_seat(b):
		if not capacity: return false
		_seats.append({"ped": b.ped_id}); enrolled.append(b.ped_id); b.sitting = true
		return true
	func walk_direct(b, to): b._route = PackedVector3Array([to])

## A stand-in household (ambient_household.gd's surface as the life
## controller uses it): one member at home, things to use, a door.
class House extends RefCounted:
	var id := "h"
	var def := {"name": "home"}
	var members_: Array = []
	var home := true
	var offer := {"boho_bed#sleep": {"use": "sleep", "label": "sleep", "restores": {"energy": 1.0}, "free": 1}}
	var knocks: Array = []
	var started: Array = []
	var welcomed_: Array = []
	var released: Array = []
	var fail := ""
	var phase := ""
	func member(pid): return members_.has(pid)
	func members(): return members_.duplicate()
	func allowed_in(pid): return member(pid) or welcomed_.has(pid)
	func at_home(pid): return home and allowed_in(pid)
	func objects_for(pid): return offer if at_home(pid) else {}
	func activity(_pid): return ""
	func knocking(): return knocks.duplicate()
	func door_pos(): return Vector3(50, 0, 0)
	func start_use(pid, obj, _seconds, _life_id):
		if fail != "": return fail
		started.append(obj); phase = "going"; return ""
	func use_phase(_pid): return phase
	func release(_pid): released.append(_pid); phase = ""
	func welcome(_host, guest): welcomed_.append(guest); knocks.erase(guest); return true
	func knock(pid): knocks.append(pid); return true
	func welcomed(pid): return welcomed_.has(pid)
	func leave(pid): knocks.erase(pid)

class Places extends RefCounted:
	var restaurants: Array = []
	var courses: Array = []
	var shops: Array = []
	var schools: Array = []
	var room = null
	func school(_name): return room
	func district_names_at(_p): return ["city"]
	func place_position(pid): return Vector3(20, 0, 0) if pid == "park" else null

class Manager extends RefCounted:
	var _residents: Dictionary = {}
	var _resident_defs: Dictionary = {}
	func residents(): return _residents
	func resident_def(pid): return _resident_defs.get(pid, {})
	var records: Array = []
	var spoken: Array = []
	var nav = Nav.new()
	var places = Places.new()
	var houses: Array = []
	func observe(e): records.append(e)
	func resident_say(b, line): spoken.append({"who": b.ped_id, "line": line})
	func household_of(pid):
		for h in houses:
			if h.member(pid): return h
		return null
	func households(): return houses
	func household_release(pid):
		for h in houses: h.release(pid)

var failures := 0
func check(ok: bool, message: String):
	if not ok:
		failures += 1
		push_error(message)

func command(pid: String, id: String, verb: String, extra: Dictionary = {}) -> Dictionary:
	var action := {"do": verb, "seconds": 10.0}
	action.merge(extra, true)
	return {"cmd": "life", "id": pid, "action_id": id, "action": action, "text": "こんにちは"}

func outcome(m, id: String, status: String) -> bool:
	return m.records.any(func(e): return e.get("life_result", {}).get("id") == id and e.get("life_result", {}).get("status") == status)

func _initialize():
	var m = Manager.new()
	var a = Body.new(); a.ped_id = "r_alice"
	var b = Body.new(); b.ped_id = "r_bob"; b.position = Vector3(3, 0, 0)
	b.weather_reaction.weather_type = "storm"
	b.weather_reaction.exposed = true
	m._residents = {"r_alice": a, "r_bob": b}
	m._resident_defs = {"r_alice": {"student": true}, "r_bob": {}}
	var c = Controller.new(m)
	c.handle(command(a.ped_id, "study", "study"))
	check(a.prop == "notebook", "Study must give the body a notebook")
	c.tick(11.0)
	check(outcome(m, "study", "completed"), "Study should finish with a reported outcome")
	check(m.records.any(func(e): return e.get("who") == "r_bob" and e.has("life_view")), "Adults need perceptions even without a school")
	check(m.records.any(func(e): return e.get("who") == "r_bob" and e.get("life_view", {}).get("weather", {}).get("type") == "storm" and e.life_view.weather.exposed), "Resident decisions receive local weather exposure")
	c.handle(command(a.ped_id, "speak", "say", {"target": b.ped_id, "text": "hello"}))
	check(m.spoken.size() == 1, "Speech should physically play")
	check(m.records.any(func(e): return e.get("who") == b.ped_id and e.get("heard") == a.ped_id), "The listener must hear the line")
	c.handle(command(a.ped_id, "speak", "say", {"target": b.ped_id, "text": "hello"}))
	check(m.spoken.size() == 1, "Duplicate delivery must not repeat speech")
	b.position = Vector3(100, 0, 0)
	c.handle(command(a.ped_id, "gone", "say", {"target": b.ped_id, "text": "hello"}))
	check(outcome(m, "gone", "failed"), "A departed listener cannot hear speech")
	c.handle({"cmd": "life_control", "id": a.ped_id, "manual": true})
	c.handle(command(a.ped_id, "blocked", "rest"))
	check(outcome(m, "blocked", "failed"), "Autonomy cannot override director control")
	var ordered = command(a.ped_id, "ordered", "go", {"place": "park"}); ordered.director = true
	c.handle(ordered)
	check(a.intents.size() == 1, "Director should be able to order travel")
	c.handle({"cmd": "life_cancel", "id": a.ped_id, "action_id": "old-id"})
	check(c.orders.has(a.ped_id), "Stale cancellation must not cancel a newer order")
	c.handle({"cmd": "life_cancel", "id": a.ped_id, "action_id": "ordered"})
	check(a.intents.is_empty(), "Cancellation must release the travel intent")
	m.places.room = Room.new()
	m.places.schools = [m.places.room]
	c.handle({"cmd": "life_control", "id": a.ped_id, "manual": false})
	m.places.room.capacity = false
	c.handle(command(a.ped_id, "full", "attend"))
	check(outcome(m, "full", "failed"), "A full classroom must report failure")
	m.places.room.capacity = true
	c.handle(command(a.ped_id, "seat", "attend"))
	check(a.sitting and outcome(m, "seat", "completed"), "Attend must actually seat the pupil")
	c.handle(command(b.ped_id, "adult", "go", {"place": "park"}))
	c.transition()
	check(c.orders.has(b.ped_id), "A school bell must not cancel an adult's trip in the city")
	c.tick(90.0)
	check(c.orders.has(b.ped_id), "A short duration must not cancel a journey before arrival")
	b.arrived = true
	c.tick(0.1)
	check(outcome(m, "adult", "completed"), "Travel completes when the body reports arrival")
	b.arrived = false
	c.handle(command(b.ped_id, "meal", "eat", {"place": "park"}))
	c.tick(180.0)
	check(c.orders.has(b.ped_id), "Dining must allow restaurant service and eating to finish")
	b.life_meal_result = "ate"
	c.tick(0.1)
	check(outcome(m, "meal", "completed"), "Only the restaurant's result completes a meal")
	c.handle(command(b.ped_id, "sleep", "sleep", {"place": "park"}))
	c.tick(90.0)
	check(c.orders.has(b.ped_id) and c.orders[b.ped_id].left == 10.0, "Travel must not consume sleeping time")
	b.arrived = true  # The movement system accepts arrival despite its final position jitter.
	c.tick(11.0)
	check(outcome(m, "sleep", "completed"), "Sleep finishes after arrival even outside a separate distance tolerance")
	b.arrived = false
	c.handle(command(b.ped_id, "blocked-trip", "go", {"place": "park"}))
	b.life_move_failed = "blocked path"
	c.tick(0.1)
	check(outcome(m, "blocked-trip", "failed"), "An unrecoverable route error must report failure")

	# Households: things to use at home, a visitor at the door.
	var house = House.new()
	house.members_ = ["r_alice"]
	m.houses = [house]
	m._resident_defs["r_bob"] = {"friends": ["alice"]}
	c.tick(5.1)
	var alice_view = null
	var bob_view = null
	for e in m.records:
		if e.has("life_view") and e.get("who") == "r_alice": alice_view = e.life_view
		if e.has("life_view") and e.get("who") == "r_bob": bob_view = e.life_view
	check(bob_view != null and bob_view.school == "", "An unrelated adult has no assigned classroom")
	check(alice_view != null and alice_view.get("home") == "h" and alice_view.get("objects", {}).has("boho_bed#sleep") and alice_view.get("available", []).has("use"),
		"At home the view names the house, its things, and offers use")
	check(bob_view != null and bob_view.get("households", {}).has("household:h") and bob_view.get("available", []).has("visit"),
		"A friend of a member may visit that home")
	c.handle(command(a.ped_id, "use1", "use", {"object": "boho_bed#sleep"}))
	check(house.started == ["boho_bed#sleep"] and c.orders.has(a.ped_id), "Use reaches the household and stays open until it reports")
	c.finish(a.ped_id, true, "used the bed")   # as ambient_household does when the use ends
	check(outcome(m, "use1", "completed"), "The household's report completes the use")
	house.fail = "nothing free to use there"
	c.handle(command(a.ped_id, "use2", "use", {"object": "boho_bed#sleep"}))
	check(outcome(m, "use2", "failed"), "A use the house refuses fails at once")
	house.fail = ""
	house.knocks = ["r_bob"]
	c.tick(5.1)
	c.handle(command(a.ped_id, "w1", "welcome", {"target": "r_bob"}))
	check(house.welcomed_ == ["r_bob"] and outcome(m, "w1", "completed"), "Welcome lets the knocker in")
	c.handle(command(a.ped_id, "w2", "welcome", {"target": "r_nobody"}))
	check(outcome(m, "w2", "failed"), "Nobody at the door: nothing to welcome")
	house.welcomed_ = []          # bob is outside again, with a clean slate
	b.life_move_failed = ""
	b.intents = []
	b.position = Vector3(100, 0, 0)
	c.handle(command(b.ped_id, "v1", "visit", {"household": "household:h"}))
	check(c.orders.has(b.ped_id) and b.intents.size() == 1 and c.orders[b.ped_id].dest == Vector3(50, 0, 0), "A visit walks to the door")
	b.position = Vector3(50, 0, 0)
	c.tick(0.1)
	check(house.knocks.has("r_bob"), "At the door the visitor knocks")
	house.welcome("r_alice", "r_bob")
	c.tick(0.1)
	check(outcome(m, "v1", "completed"), "Being let in completes the visit")
	a.free(); b.free()
	print("Resident life world tests: ", "PASS" if failures == 0 else "FAIL ", failures)
	quit(0 if failures == 0 else 1)
