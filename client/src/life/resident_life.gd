extends RefCounted
## Carries out the mind's life actions on resident bodies and reports each one back by id; decides nothing.

const DONE_STATES := ["completed", "failed", "cancelled"]
const COMPLETED_KEEP := 256  # so a repeat gets the same answer
const NEARBY_RADIUS := 22.0
const ARRIVE_RADIUS := 6.0
const SENSE_PERIOD := 5.0

var _manager
var orders: Dictionary = {}
var manual: Dictionary = {}
var _sense_timer := 0.0
var _completed: Dictionary = {}


func _init(manager):
	_manager = manager


func _body(pid: String):
	var body = _manager.residents().get(pid)
	return body if body != null and is_instance_valid(body) else null


func controlled(pid: String) -> bool:
	return bool(manual.get(pid, false)) or orders.has(pid)


func occupies(pid: String) -> bool:
	return bool(manual.get(pid, false)) or (orders.has(pid) and str(orders[pid].verb) != "continue")


func _result(pid: String, id: String, status: String, reason: String = ""):
	_manager.observe({"who": pid, "life_result": {"id": id, "status": status, "reason": reason}})
	if status in DONE_STATES:
		_completed[id] = {"pid": pid, "status": status, "reason": reason}
		if _completed.size() > COMPLETED_KEEP:
			_completed.erase(_completed.keys()[0])


## Where they are now, else their "class" room; a student without one gets the first room.
func _school_for(pid: String):
	var first = null
	for s in _manager.places.schools:
		if s == null or not is_instance_valid(s):
			continue
		if first == null:
			first = s
		if s._teacher == pid or s.pupils_present().has(pid) or _has_seat(s, pid):
			return s
	var klass := str(_manager.resident_def(pid).get("class", ""))
	if klass != "":
		for s in _manager.places.schools:
			if s != null and is_instance_valid(s) and s.matches_class(klass):
				return s
	return first if bool(_manager.resident_def(pid).get("student", false)) and klass == "" else null


func _has_seat(school, pid: String) -> bool:
	for seat in school._seats:
		if str(seat.ped) == pid:
			return true
	return false


func _seated(pid: String) -> bool:
	for s in _manager.places.schools:
		if s != null and is_instance_valid(s) and _has_seat(s, pid):
			return true
	return false


## {pid: name}
func _nearby(b) -> Dictionary:
	var nearby := {}
	for pid in _manager.residents():
		var other = _body(str(pid))
		if other == null or other == b:
			continue
		if b.get("home_hidden") == true or other.get("home_hidden") == true:
			continue
		if b.position.distance_to(other.position) <= NEARBY_RADIUS:
			nearby[str(pid)] = str(_manager.resident_def(pid).get("name", pid))
	return nearby


func _household_of(pid: String):
	return _manager.household_of(pid) if _manager.has_method("household_of") else null


func _households() -> Array:
	return _manager.households() if _manager.has_method("households") else []


func _household_by(id: String):
	for hh in _households():
		if str(hh.id) == id:
			return hh
	return null


## Their own, or one they were welcomed into.
func _house_at(pid: String):
	for hh in _households():
		if hh.allowed_in(pid) and hh.at_home(pid):
			return hh
	return null


## {"household:<id>": name}
func _visitable(pid: String) -> Dictionary:
	var out := {}
	var def: Dictionary = _manager.resident_def(pid)
	var known := {}
	for k in ["friends", "parents", "children", "guardians"]:
		for rid in def.get(k, []):
			known["r_" + str(rid).trim_prefix("r_")] = true
	for hh in _households():
		if hh.member(pid) or hh.door_pos() == Vector3.INF:
			continue
		for m in hh.members():
			if known.has(m):
				out["household:" + str(hh.id)] = str(hh.def.get("name", hh.id))
				break
	return out


## A director may give any verb the place allows.
func _available(pid: String, b, director := false) -> Array:
	var sch = _school_for(pid)
	var house = _house_at(pid)
	if not director:
		var busy := _busy_verbs(pid, b, sch, house)
		if not busy.is_empty():
			return busy
	var verbs: Array = ["continue", "rest", "study", "go", "eat", "sleep"]
	if not _manager.places.shops.is_empty():
		verbs.append("buy")
	if house != null:
		if not house.objects_for(pid).is_empty():
			verbs.append("use")
		if house.member(pid) and not house.knocking().is_empty():
			verbs.append("welcome")
	elif not _visitable(pid).is_empty():
		verbs.append("visit")
	if sch != null and bool(_manager.resident_def(pid).get("student", false)):
		verbs.append("attend")
	if _seated(pid):
		verbs.append("listen")
	if not _nearby(b).is_empty():
		verbs.append_array(["say", "approach", "invite", "accept", "decline"])
	if sch != null and sch.pupils_present().has(pid) and sch.match_.has_yard():
		verbs.append("yard")
		if sch.in_break and sch.match_.has_pitch():
			verbs.append("play")
	return verbs


## [] when they are free.
func _busy_verbs(pid: String, b, sch, house) -> Array:
	if sch != null and sch.pupils_present().has(pid) and (sch.assembly_.active() or sch.assembly_.in_rite()):
		return ["continue"]
	if sch != null and sch._teacher == pid and not sch.in_break:
		return ["continue"]
	if b.errand_owner != null:
		return ["continue"]
	if sch != null and sch.match_.playing(pid):
		return ["continue", "leave_game"]
	if house != null and house.activity(pid).begins_with("meal"):
		return ["continue", "say"] if not _nearby(b).is_empty() else ["continue"]
	return []


func _release(pid: String, b):
	for sch in _manager.places.schools:
		if sch == null or not is_instance_valid(sch):
			continue
		sch.match_.leave_game(pid)
		sch._release_pid(pid)
		sch.enrolled.erase(pid)
		sch.outside.erase(pid)
		sch.match_.forget(pid)
	for restaurant in _manager.places.restaurants:
		if restaurant != null and is_instance_valid(restaurant):
			restaurant.release_resident(pid)
	for course in _manager.places.courses:
		if course != null and is_instance_valid(course):
			course.release_resident(pid)
	if _manager.has_method("household_release"):
		_manager.household_release(pid)
	if b.sitting:
		b.stand_up()
	b.steer_to = Vector3.INF
	b.steer_speed = 0.0
	b.set_prop("")
	b.set_emotion("")
	b.personal_space = true
	if b.has_method("clear_reactions"):
		b.clear_reactions()
	b.hold_idle(0.1)


## Only the one with `id`, when given.
func cancel(pid: String, id: String = "", reason: String = "interrupted"):
	if not orders.has(pid):
		return
	var order: Dictionary = orders[pid]
	if id != "" and id != str(order.id):
		return
	orders.erase(pid)
	var b = _body(pid)
	if b != null:
		b.set_prop("")
		b.set_emotion("")
		if not b.sitting:
			b.hold_idle(0.1)
		if str(order.verb) in ["go", "eat", "buy", "sleep", "play", "use", "visit"]:
			_release(pid, b)
		if str(order.verb) == "visit":
			var hh = _household_by(str(order.get("household", "")))
			if hh != null:
				hh.leave(pid)
	_result(pid, str(order.id), "cancelled", reason)


func transition():
	for pid in orders.keys():
		var sch = _school_for(str(pid))
		if sch != null and (sch.pupils_present().has(pid) or sch._teacher == pid) and not bool(manual.get(pid, false)):
			cancel(str(pid), "", "school activity changed")


func handle(data: Dictionary):
	var pid := str(data.get("id", ""))
	var sch = _manager.places.school(str(data.get("school", ""))) if str(data.get("school", "")) != "" else null
	if sch == null:
		sch = _school_for(pid)
	if str(data.get("cmd", "")) == "life_control":
		_set_manual(pid, bool(data.get("manual", false)))
		return
	if str(data.get("cmd", "")) == "life_cancel":
		cancel(pid, str(data.get("action_id", "")))
		return
	var id := str(data.get("action_id", ""))
	if id == "":
		return
	if _completed.has(id):
		var old: Dictionary = _completed[id]
		_result(pid, id, str(old.status), str(old.reason))
		return
	if orders.has(pid) and str(orders[pid].id) == id:
		return
	var b = _body(pid)
	var action: Dictionary = data.get("action", {})
	var verb := str(action.get("do", ""))
	if b == null:
		_result(pid, id, "failed", "student body missing")
		return
	var available := _available(pid, b, bool(data.get("director", false)))
	if sch != null and _seated(pid) and available.has("listen") and sch._teacher != "" and not sch.in_break:
		available.append("ask")
	if not available.has(verb):
		_result(pid, id, "failed", "activity unavailable now")
		return
	if bool(manual.get(pid, false)) and not bool(data.get("director", false)):
		_result(pid, id, "failed", "director has control")
		return
	cancel(pid)
	var seconds := clampf(float(action.get("seconds", 60.0)), 10.0, 300.0)
	var order := {"id": id, "verb": verb, "left": seconds, "target": str(action.get("target", "")), "dest": Vector3.INF}
	orders[pid] = order
	_result(pid, id, "started")
	_start(pid, b, sch, order, action, data, seconds)


func _set_manual(pid: String, on: bool):
	manual[pid] = on
	var body = _body(pid)
	if body == null or orders.has(pid):
		return
	if bool(manual[pid]):
		_release(pid, body)
	else:
		body.hold_idle(0.1)


func _start(pid: String, b, sch, order: Dictionary, action: Dictionary, data: Dictionary, seconds: float):
	var verb := str(order.verb)
	var id := str(order.id)
	match verb:
		"continue":
			pass
		"say", "ask", "invite", "accept", "decline":
			_start_speech(pid, b, sch, verb, action, data)
		"study", "listen", "rest":
			b.set_prop("notebook" if verb == "study" else "")
			b.set_emotion("serious" if verb == "study" else "")
			if not b.sitting:
				b.hold_idle(seconds + 1.0)
		"attend":
			_release(pid, b)
			if sch.request_seat(b):
				finish(pid, true, "joined school" if sch.in_break else "seated in class")
			else:
				finish(pid, false, "no desk available")
		"leave_game":
			sch.match_.leave_game(pid)
			sch.match_.go_yard(b)
			finish(pid, true, "left the game")
		"play":
			if not sch.match_.join_game(pid):
				finish(pid, false, "game unavailable or full")
		"yard":
			_release(pid, b)
			sch.match_.go_yard(b)
			finish(pid, true, "went to the yard")
		"approach":
			_start_approach(pid, b, sch, order, action, seconds)
		"go", "eat", "buy", "sleep":
			_start_trip(pid, b, order, action, data, seconds)
		"use":
			# The household reports the end through finish().
			var house = _house_at(pid)
			if house == null:
				finish(pid, false, "not in a house")
				return
			var err: String = house.start_use(pid, str(action.get("object", "")), seconds, id)
			if err != "":
				finish(pid, false, err)
		"welcome":
			_start_welcome(pid, action)
		"visit":
			_start_visit(pid, b, order, action, seconds)


## Only those within earshot hear it.
func _start_speech(pid: String, b, sch, verb: String, action: Dictionary, data: Dictionary):
	var target := str(action.get("target", sch._teacher if verb == "ask" else ""))
	if not _nearby(b).has(target) and not (verb == "ask" and _seated(pid)):
		finish(pid, false, "listener moved away")
		return
	if str(data.get("text", "")).strip_edges() == "":
		finish(pid, false, "speech could not be rendered")
		return
	_manager.resident_say(b, {"text": str(data.get("text", "")), "read": str(action.get("text", "")), "audio": str(data.get("audio", "")), "secs": 6.0})
	for witness in _nearby(b):
		_manager.observe({"who": witness, "heard": pid, "text": str(action.get("text", "")), "addressed": witness == target, "at": _manager.places.district_names_at(b.position)})
	_manager.observe({"who": pid, "said": str(action.get("text", "")), "with": target})
	finish(pid, true, "spoken")


func _start_approach(pid: String, b, sch, order: Dictionary, action: Dictionary, seconds: float):
	var target = _body(str(action.get("target", "")))
	if target == null or not _nearby(b).has(str(action.get("target", ""))):
		finish(pid, false, "person moved away")
		return
	var was_present: bool = sch != null and sch.pupils_present().has(pid)
	_release(pid, b)
	# Keep membership so the next bell can invite the student back.
	if was_present:
		sch.enrolled.append(pid)
	order.dest = target.position + Vector3(3, 0, 0)
	var route: PackedVector3Array = _manager.nav.find_route(b.position, order.dest)
	if route.is_empty() and was_present:
		sch.walk_direct(b, order.dest)
	elif not route.is_empty():
		b.walk_route(route)
		b.idle_timer = seconds + 1.0
	else:
		finish(pid, false, "no walkable route to person")


func _start_trip(pid: String, b, order: Dictionary, action: Dictionary, data: Dictionary, seconds: float):
	var verb := str(order.verb)
	var dest = _manager.places.place_position(str(action.get("place", "")))
	var explicit = data.get("destination", null)
	if explicit is Array and explicit.size() == 3:
		dest = Vector3(float(explicit[0]), float(explicit[1]), float(explicit[2]))
	if dest == null:
		finish(pid, false, "place no longer exists")
		return
	_release(pid, b)
	order.dest = dest
	var intent := {"do": verb, "place": str(action.get("place", "")), "then": "wander" if verb in ["eat", "buy"] else "stay", "for": seconds, "life_id": str(order.id)}
	if explicit is Array:
		intent.erase("place")
		intent["pos"] = explicit
	b.push_intent(intent)


func _start_welcome(pid: String, action: Dictionary):
	var house = _house_at(pid)
	var guest := str(action.get("target", ""))
	if house == null or not house.member(pid) or not house.knocking().has(guest):
		finish(pid, false, "nobody is at the door")
		return
	if house.welcome(pid, guest):
		finish(pid, true, "let " + guest + " in")
	else:
		finish(pid, false, "could not open the door")


## The people inside decide.
func _start_visit(pid: String, b, order: Dictionary, action: Dictionary, seconds: float):
	var target := str(action.get("household", action.get("place", ""))).trim_prefix("household:")
	var hh = _household_by(target)
	if hh == null or hh.door_pos() == Vector3.INF:
		finish(pid, false, "no such home")
		return
	_release(pid, b)
	var door: Vector3 = hh.door_pos()
	order.dest = door
	order["household"] = target
	order["knocked"] = false
	b.push_intent({"do": "go", "pos": [door.x, door.y, door.z], "then": "stay", "for": seconds + 30.0,
		"life_id": str(order.id), "name": "calling at " + str(hh.def.get("name", target))})


func finish(pid: String, ok: bool, reason: String):
	if not orders.has(pid):
		return
	var order: Dictionary = orders[pid]
	orders.erase(pid)
	_result(pid, str(order.id), "completed" if ok else "failed", reason)


func tick(delta: float):
	for pid in manual:
		if bool(manual[pid]) and not orders.has(pid):
			var held = _body(str(pid))
			if held != null and not held.sitting:
				held.hold_idle(999999.0)
	for pid in orders.keys():
		_tick_order(str(pid), orders[pid], delta)
	_sense_timer -= delta
	if _sense_timer > 0:
		return
	_sense_timer = SENSE_PERIOD
	for pid in _manager.residents():
		_send_view(pid)


func _tick_order(pid: String, order: Dictionary, delta: float):
	var verb := str(order.verb)
	var b = _body(pid)
	if b == null:
		finish(pid, false, "body disappeared")
		return
	if verb != "sleep" or b.life_arrived(str(order.id)):
		order.left = float(order.left) - delta
	if verb == "play" and _school_for(pid) != null and _school_for(pid).match_.playing(pid):
		finish(pid, true, "joined the game")
	elif verb == "approach" and (_body(str(order.target)) == null or _body(str(order.target)).position.distance_to(order.dest) > 15.0):
		_release(pid, b)
		finish(pid, false, "person moved away")
	elif verb == "go" and b.life_arrived(str(order.id)):
		finish(pid, true, "arrived")
	elif verb == "approach" and b.position.distance_to(order.dest) < ARRIVE_RADIUS:
		finish(pid, true, "arrived")
	elif verb in ["go", "eat", "buy", "sleep"] and b.life_move_failed != "":
		var reason := str(b.life_move_failed)
		_release(pid, b)
		finish(pid, false, reason)
	elif verb in ["eat", "buy"] and "life_meal_result" in b and b.life_meal_result != "":
		finish(pid, b.life_meal_result in ["ate", "bought"], b.life_meal_result)
		b.life_meal_result = ""
	elif verb == "use":
		# The household finishes a use; only the case where it dropped them is handled here.
		var house = _house_at(pid)
		if house == null or house.use_phase(pid) == "":
			finish(pid, false, "the use ended early")
	elif verb == "visit":
		_tick_visit(pid, b, order)
	elif verb in ["go", "eat", "buy"]:
		# The restaurant or shop ends these; the order's duration cannot cut them short.
		pass
	elif float(order.left) <= 0.0:
		var moving: bool = verb in ["approach", "play"] or (verb == "sleep" and not b.life_arrived(str(order.id)))
		if moving:
			_release(pid, b)
		finish(pid, not moving, "could not finish in time" if moving else "spent time " + verb)


func _tick_visit(pid: String, b, order: Dictionary):
	var hh = _household_by(str(order.get("household", "")))
	if hh == null:
		_release(pid, b)
		finish(pid, false, "home vanished")
	elif b.life_move_failed != "":
		var why := str(b.life_move_failed)
		_release(pid, b)
		finish(pid, false, why)
	elif not bool(order.knocked):
		if b.position.distance_to(order.dest) < ARRIVE_RADIUS:
			order.knocked = true
			if not hh.knock(pid):
				_release(pid, b)
				finish(pid, false, "nobody home")
		elif float(order.left) <= 0.0:
			_release(pid, b)
			finish(pid, false, "could not reach the door in time")
	elif hh.welcomed(pid):
		finish(pid, true, "welcomed in")
	elif float(order.left) <= 0.0:
		hh.leave(pid)
		_release(pid, b)
		finish(pid, false, "nobody answered the door")


## Scripted people, event cast and extras get none.
func _send_view(pid):
	var def: Dictionary = _manager.resident_def(pid)
	if def.has("script") and str(def.script) != "" or str(pid).begins_with("r_evt_") or (def.get("life", true) is bool and not def.get("life", true)):
		return
	var b = _body(str(pid))
	if b == null:
		return
	var sch = _school_for(str(pid))
	var present: Array = sch.pupils_present() if sch != null else []
	var view := {
		"school": sch.key() if sch != null else "",
		"phase": ("break" if sch.in_break else "class") if sch != null and present.has(pid) else "city",
		"seated": _seated(str(pid)),
		"teaching": sch != null and sch._teacher == pid,
		"in_school": present.has(pid),
		"nearby": _nearby(b),
		"available": _available(str(pid), b),
		"director_available": _available(str(pid), b, true),
		"manual": bool(manual.get(pid, false)),
		"activity": _activity(pid, b),
		"at": _manager.places.district_names_at(b.position),
	}
	view["weather"] = b.weather_reaction.snapshot()
	if present.has(pid):
		view["present"] = present
		view["teacher"] = sch._teacher
	_add_home_view(str(pid), view)
	_manager.observe({"who": pid, "life_view": view})


## "travelling" on the way to bed.
func _activity(pid, b) -> String:
	if orders.has(pid):
		return "travelling" if str(orders[pid].verb) == "sleep" and not b.life_arrived(str(orders[pid].id)) else str(orders[pid].verb)
	return str(b.get("active_entry").get("do", "")) if b.get("active_entry") is Dictionary else ""


func _add_home_view(pid: String, view: Dictionary):
	var own = _household_of(pid)
	view["home"] = str(own.id) if own != null else ""
	view["at_home"] = own != null and own.at_home(pid)
	var house = _house_at(pid)
	if house != null:
		view["house"] = str(house.id)
		view["objects"] = house.objects_for(pid)
		if house.member(pid):
			view["knocking"] = house.knocking()
		var doing: String = house.activity(pid)
		if doing != "" and not orders.has(pid):
			view["activity"] = doing
	var visitable := _visitable(pid)
	if not visitable.is_empty():
		view["households"] = visitable
