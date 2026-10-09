extends "res://src/life/ambient_pedestrian.gd"
## A resident: a pedestrian with an identity and a daily routine; it always makes its appointment, teleporting if it must.

const Schedule := preload("res://src/life/resident_schedule.gd")

const ARRIVE_RADIUS := 14.0
const LOITER_RADIUS := 35.0
const NEAR_TRIES := 4
const NEAR_RADIUS := 50.0
const STUCK_TELEPORT_AFTER := 3
const CHECK_PERIOD := 0.5  # seconds between home and engagement checks
const FALLEN_Y := -200.0

var resident_def: Dictionary = {}
var life_meal_result := ""
var life_move_failed := ""

# No household: at the home spot they are off the map (hidden, no collision, not replicated).
var home_hidden := false
var _home_check := 0.0
var _home_layer := 0

var _stuck_fails := 0
var _teleport_after_route := false
var inside_door := Vector3.INF  # the way back out
var active_entry: Dictionary = {}
var _action_running := false
var _action_audio: AudioStreamPlayer3D = null

# Sorted by ("at", "seq").
var _plan: Array = []
var _plan_day := -1
var _plan_seq := 0

var _engage_check := 0.0

# A "sit" entry's seat; the base body does not tick its route loop while seated, so _watch_seat() does.
var routine_seated := false
var _seat_entry: Dictionary = {}

var _marker_cache: Dictionary = {}


func life_arrived(id: String) -> bool:
	return str(active_entry.get("life_id", "")) == id and _action_running


func _hide_at_home_now() -> bool:
	if manager == null or ped_id.begins_with("r_evt_") or str(resident_def.get("script", "")) != "":
		return false
	if sitting or errand_owner != null:
		return false
	if manager.has_method("household_of") and manager.household_of(ped_id) != null:
		return false
	if not _entry_is_home(active_entry):
		return false
	if _action_running:
		return true
	# One at-home entry giving way to another: stay hidden in between.
	var flat := Schedule.home_pos(resident_def) - position
	flat.y = 0.0
	return home_hidden and flat.length() <= ARRIVE_RADIUS


func _entry_is_home(entry: Dictionary) -> bool:
	if entry.is_empty() or entry.has("place") or entry.has("marker"):
		return false
	if not str(entry.get("do", "")) in ["", "go", "sleep", "stay"]:
		return false
	var home := Schedule.home_pos(resident_def)
	var p := Schedule.entry_pos(entry)
	return home != Vector3.INF and p != Vector3.INF and p.distance_to(home) <= Schedule.HOME_RADIUS


func _set_home_hidden(on: bool):
	if on == home_hidden:
		return
	home_hidden = on
	visible = not on
	# Players walk through the spot, not into someone nobody can see.
	if on:
		_home_layer = collision_layer
		collision_layer = 0
	else:
		collision_layer = _home_layer
	print("[Resident %s] %s" % [ped_id, "home, off the map" if on else "out of the house, back on the map"])


## The clock jumped: holders let go, reactions and the day's plan (the mind's too) are dropped.
func reset_day():
	if manager != null:
		_release_holders()
	_stop_action()
	if sitting:
		stand_up()
	steer_to = Vector3.INF
	active_entry = {}
	_action_running = false
	life_meal_result = ""
	life_move_failed = ""
	_plan = []
	_plan_day = -1
	enter_idle()
	idle_timer = 0.2


func _release_holders():
	if str(active_entry.get("do", "")) in ["attend", "teach"] and manager.has_method("school_leave"):
		manager.school_leave(self, str(active_entry.get("place", "")))
	if manager.has_method("household_release"):
		manager.household_release(ped_id)
	var places = manager.get("places")
	if places == null:
		return
	for owner in [places.restaurants, places.courses]:
		for o in owner:
			if o != null and is_instance_valid(o) and o.has_method("release_resident"):
				o.release_resident(ped_id)


## Replaces reactions, never the underlying routine.
func clear_reactions():
	for entry in _plan:
		if entry.get("imm", false):
			entry["done"] = true
	_stop_action()
	active_entry = {}
	_action_running = false
	life_meal_result = ""
	life_move_failed = ""


func _ready():
	super()
	if resident_def.has("speed"):
		walk_speed = float(resident_def.speed)
	idle_min = float(resident_def.get("idle_min", 1.0))
	idle_max = float(resident_def.get("idle_max", 4.0))


func _routine() -> Array:
	return resident_def.get("routine", [])


## Null for event cast, someone walking to a seat, and people in class or in a match.
func _engaged_player() -> Node3D:
	if manager == null or ped_id.begins_with("r_evt_"):
		return null
	if errand_owner != null and errand_dest != Vector3.INF:
		return null
	if str(active_entry.get("do", "")) in ["teach", "attend"] \
			or (manager.has_method("in_classroom") and manager.in_classroom(self)) \
			or (manager.has_method("in_match") and manager.in_match(self)):
		return null
	var eng = manager.get("engagement")
	if eng == null:
		return null
	return eng.engaged_player(self)


func _physics_process(delta):
	if _is_authority and position.y < FALLEN_Y:
		_recover_fall()
	if _is_authority:
		_home_check -= delta
		if _home_check <= 0.0:
			_home_check = CHECK_PERIOD
			_set_home_hidden(_hide_at_home_now())
	if _is_authority and sitting and routine_seated:
		_watch_seat()
	if _is_authority and not sitting:
		_face_engaged_player(delta)
	super(delta)


## A random street point when the routine's spot is itself below the world.
func _recover_fall():
	var back: Vector3 = _current_dest()
	if back.y < -100.0 and manager != null and manager.nav != null and not manager.nav.is_empty():
		back = manager.nav.random_point(manager.rng())
	print("[Resident %s] fell out of the world at %s — back to %s" % [ped_id, position, back])
	position = back + Vector3.UP * 3.0
	velocity = Vector3.ZERO


func _face_engaged_player(delta: float):
	_engage_check -= delta
	if _engage_check > 0.0:
		return
	_engage_check = CHECK_PERIOD
	var engaged := _engaged_player()
	if engaged == null:
		return
	if _state == State.WALKING:
		enter_idle()
	idle_timer = maxf(idle_timer, 2.0)
	var d: Vector3 = manager.world().to_local(engaged.global_position) - position
	d.y = 0.0
	if d.length_squared() > 0.01 and character_model:
		character_model.rotation.y = atan2(d.x, d.z) + PI


func voice_id() -> String:
	var v := str(resident_def.get("voice", ""))
	return v if v != "" else super()


## The manager's game day, else days since the epoch.
func _day_index() -> int:
	if manager != null and manager.has_method("current_day"):
		return manager.current_day()
	return int(Time.get_unix_time_from_system() / 86400.0)


func _entry_hour(entry: Dictionary, idx: int) -> float:
	return Schedule.entry_hour(ped_id, entry, idx, _day_index())


## Monday = 0, or -1 when no clock says.
func _weekday() -> int:
	if manager != null and manager.has_method("current_weekday"):
		return int(manager.current_weekday())
	return -1


func _entry_active_today(entry: Dictionary, idx: int) -> bool:
	if entry.has("days") and _weekday() < 0:
		return true  # no clock to say which day: keep the entry
	return Schedule.active_today(ped_id, entry, idx, _day_index(), _weekday())


## Entry keys: hour, pos|marker|place, door, action, do, how, face_deg, emotion, audio, skin, prop, jitter, chance, days.
func _default_plan() -> Array:
	var out := []
	var routine := _routine()
	for idx in routine.size():
		var entry: Dictionary = routine[idx]
		if not _entry_active_today(entry, idx):
			continue
		var intent: Dictionary = entry.duplicate()
		intent["at"] = _entry_hour(entry, idx)
		intent["seq"] = _plan_seq
		_plan_seq += 1
		out.append(intent)
	_sort_plan(out)
	return out


func _sort_plan(plan: Array):
	plan.sort_custom(func(a, b):
		var aa := float(a.get("at", 0.0))
		var bb := float(b.get("at", 0.0))
		if aa == bb:
			return int(a.get("seq", 0)) < int(b.get("seq", 0))
		return aa < bb)


## Queued immediate intents carry over: a life order may still be waiting on them.
func _ensure_plan():
	var day := _day_index()
	if day == _plan_day:
		return
	var hour: float = manager.current_hour() if manager != null else 0.0
	var old_seq := int(_scheduled_in(_plan, hour).get("seq", -1))
	var carried: Array = _plan.filter(func(i): return i.get("imm", false) and not i.get("done", false))
	_plan_day = day
	_plan = _default_plan()
	var new_seq := int(_scheduled_in(_plan, hour).get("seq", -1))
	for it in carried:
		if int(it.get("sched_seq", -1)) == old_seq:
			it["sched_seq"] = new_seq
		_plan.append(it)
	_sort_plan(_plan)


## The latest whose hour has passed, else the day's last (it wraps from yesterday).
func _scheduled_in(plan: Array, hour: float) -> Dictionary:
	var best: Dictionary = {}
	var best_at := -1.0
	var best_seq := -1
	var latest: Dictionary = {}
	var latest_at := -1.0
	for intent in plan:
		if intent.get("imm", false):
			continue
		var at := float(intent.get("at", 0.0))
		var seq := int(intent.get("seq", 0))
		if at > latest_at:
			latest_at = at
			latest = intent
		if at <= hour and (at > best_at or (at == best_at and seq > best_seq)):
			best_at = at
			best_seq = seq
			best = intent
	return best if not best.is_empty() else latest


## Without "at" it queues FIFO ahead of the schedule for "for" real seconds, or until the entry changes when 0.
func push_intent(intent: Dictionary):
	if manager == null:
		return
	_ensure_plan()
	var it: Dictionary = intent.duplicate()
	it["seq"] = _plan_seq
	_plan_seq += 1
	var immediate := not it.has("at")
	if immediate:
		var sched := current_entry(true)
		it["imm"] = true
		it["at"] = manager.current_hour()
		it["for_s"] = float(it.get("for", _default_seconds(it)))
		it["sched_seq"] = int(sched.get("seq", -1))
		if not it.has("skin") and sched.has("skin"):
			it["skin"] = sched.skin
	# Already doing exactly this: acknowledge it again (a lesson waits for "did: teach") and queue nothing.
	if immediate and _action_running and str(it.get("do", "")) in ["teach", "attend"] \
			and str(active_entry.get("do", "")) == str(it.get("do", "")) \
			and str(active_entry.get("place", "")) == str(it.get("place", "")):
		if manager != null and manager.has_method("observe"):
			manager.observe({"who": ped_id, "did": str(it.get("do", "")), "place": str(it.get("place", "")),
				"at": manager.places.district_names_at(position)})
		return
	if str(it.get("do", "")) == "dismiss":
		for i in _plan:
			if i.get("imm", false) and str(i.get("do", "")) in ["teach", "attend"]:
				i["done"] = true
	_plan.append(it)
	_sort_plan(_plan)
	if immediate and not sitting:
		# React promptly: drop the current walk and re-evaluate next tick.
		enter_idle()
		idle_timer = 0.0


## The res_plan message.
func set_plan(intents: Array, replace: bool):
	_ensure_plan()
	if replace:
		_plan = []
	for intent in intents:
		if typeof(intent) == TYPE_DICTIONARY:
			push_intent(intent)


func _default_seconds(it: Dictionary) -> float:
	match str(it.get("do", "")):
		"say":
			return float(it.get("secs", 5.0)) + 2.0
		"emote", "wait":
			return 15.0
	return 0.0  # destinations last until the scheduled entry changes


func _entry_action(entry: Dictionary) -> String:
	if entry.has("action"):
		return str(entry.action)
	if entry.has("then"):
		return str(entry.then)
	if entry.get("done", false):
		return "wander"  # the activity (a meal) is over; hang around
	match str(entry.get("do", "")):
		"stay", "sleep", "work", "sit", "say", "emote", "wait", "talk", "teach", "attend", "dismiss", "ride":
			return "stay"
	return "wander"


## Re-plans today from the current routine on the next tick.
func replan_today() -> void:
	_plan_day = -1


## Keeps the next route from ending in a teleport.
func clear_route_recovery() -> void:
	_teleport_after_route = false
	_stuck_fails = 0


## scheduled_only ignores immediate intents; the FIFO head leaves the plan when it expires.
func current_entry(scheduled_only := false) -> Dictionary:
	_ensure_plan()
	if _plan.is_empty():
		return {}
	var sched: Dictionary = _scheduled_in(_plan, manager.current_hour())
	if scheduled_only:
		return sched
	var now_msec := Time.get_ticks_msec()
	var imms: Array = _plan.filter(func(i): return i.get("imm", false))
	imms.sort_custom(func(a, b): return int(a.get("seq", 0)) < int(b.get("seq", 0)))
	for head in imms:
		if not head.has("started_msec"):
			head["started_msec"] = now_msec
		if _intent_expired(head, sched, now_msec):
			_plan.erase(head)
			continue
		return head
	return sched


func _intent_expired(head: Dictionary, sched: Dictionary, now_msec: int) -> bool:
	if head.get("done", false):
		return true
	# A life order owns its own completion (a restaurant's service, lift legs).
	if head.has("life_id") and manager.life_controller != null and manager.life_controller.orders.has(ped_id) \
			and str(manager.life_controller.orders[ped_id].id) == str(head.life_id):
		return false
	var for_s := float(head.get("for_s", 0.0))
	if for_s > 0.0:
		return now_msec - int(head.started_msec) >= int(for_s * 1000.0)
	return int(head.get("sched_seq", -1)) != int(sched.get("seq", -1))


func _current_dest() -> Vector3:
	var entry := current_entry()
	if entry.is_empty():
		return position
	return _entry_pos(entry)


func _find_marker(marker_name: String) -> Node3D:
	if _marker_cache.has(marker_name):
		var cached = _marker_cache[marker_name]
		if cached != null and is_instance_valid(cached):
			return cached
	var root := get_tree().current_scene
	var found: Node3D = null
	if root:
		var node := root.find_child(marker_name, true, false)
		if node is Node3D:
			found = node
	if found == null:
		push_warning("[Resident %s] Marker not found: %s" % [ped_id, marker_name])
	_marker_cache[marker_name] = found
	return found


## Resolved once and kept on the entry: place, else marker, else "pos", else right here.
func _entry_pos(entry: Dictionary) -> Vector3:
	if entry.has("_pos"):
		return entry._pos
	var dest := position
	var found := false
	if entry.has("place") and manager.get("places") != null:
		var pp = manager.places.place_position(str(entry.place))
		if pp != null:
			dest = pp
			found = true
	if not found and (entry.has("marker") or entry.has("place")):
		var m := _find_marker(str(entry.get("marker", entry.get("place", ""))))
		if m != null:
			dest = manager.world().to_local(m.global_position)
			found = true
	if not found:
		var p = entry.get("pos", null)
		if typeof(p) == TYPE_ARRAY and p.size() >= 3:
			dest = Vector3(float(p[0]), float(p[1]), float(p[2]))
			found = true
	# People sharing a spot each stand at their own stable offset instead of inside one another.
	if found and _entry_action(entry) == "stay" and str(entry.get("do", "")) == "":
		var a := float(hash(ped_id) % 360) * PI / 180.0
		dest += Vector3(cos(a), 0.0, sin(a)) * 1.3
	# A meal or a shop is reached from a walkable spot beside it; the errand walks the last stretch.
	if found and str(entry.get("do", "")) in ["eat", "course", "buy"] \
			and not manager.nav.is_walkable(Vector2(dest.x, dest.z)):
		var near: Vector3 = manager.nav.random_point_near(dest, 40.0, manager.rng())
		if near.distance_to(dest) <= 60.0:
			dest = near
	if found:
		entry["_pos"] = dest
	return dest


## Empty means stay here: an action started, a teleport done, or a lift leg queued.
func _request_route() -> PackedVector3Array:
	precise_route = false
	if errand_owner != null and errand_dest != Vector3.INF:
		return super()
	var entry := current_entry()
	if entry != active_entry:
		_adopt_entry(entry)
	if entry.is_empty():
		return _route_without_routine()
	var verb := str(entry.get("do", ""))
	if verb == "dismiss":
		_start_action(entry)
		return PackedVector3Array()
	if verb == "ride" and not entry.has("pos"):
		# The lift owns approach and exit; a ride with a "pos" is walked to first.
		if not entry.get("done", false):
			_start_action(entry)
		return PackedVector3Array()
	var dest := _entry_pos(entry)
	var flat := dest - position
	flat.y = 0.0
	var dist := flat.length()
	if _queue_home_lift(entry, dest):
		return PackedVector3Array()
	var r = _indoor_route(entry, dest, dist)
	if typeof(r) != TYPE_NIL:
		return r
	if verb in ["teach", "attend"] and dist > ARRIVE_RADIUS:
		return _route_to_school(entry, dest)
	r = _route_out_of_school(entry, dest, dist)
	if typeof(r) != TYPE_NIL:
		return r
	if dist > ARRIVE_RADIUS + LOITER_RADIUS and inside_door != Vector3.INF \
			and not manager.nav.is_walkable(Vector2(position.x, position.z)):
		var out_door := inside_door
		inside_door = Vector3.INF
		_teleport_to(out_door)
		return PackedVector3Array()
	if dist <= ARRIVE_RADIUS + LOITER_RADIUS:
		return _route_at_stop(entry, dest, dist)
	return _route_toward(entry, dest)


func _adopt_entry(entry: Dictionary):
	_stop_action()
	_stuck_fails = 0
	active_entry = entry
	if manager != null and manager.has_method("observe") and not entry.is_empty():
		manager.observe({"who": ped_id, "going": str(entry.get("name", entry.get("do", ""))),
			"place": str(entry.get("marker", entry.get("place", ""))),
			"at": manager.places.district_names_at(position)})
	# School verbs default to the uniform, everything else to the base skin.
	var skin := str(entry.get("skin", ""))
	if skin == "" and str(entry.get("do", "")) in ["attend", "teach"]:
		skin = str(resident_def.get("uniform", ""))
	if skin == "":
		skin = str(resident_def.get("skin", ""))
	set_outfit(skin, accessory_paths)
	if entry.has("prop") or held_prop != "":
		set_prop(str(entry.get("prop", "")))


func _route_without_routine() -> PackedVector3Array:
	if _engaged_player() != null:
		return PackedVector3Array()
	var patch := float(resident_def.get("wander_radius", 0.0))
	if patch > 0.0:
		var dest: Vector3 = manager.nav.random_point_near(position, patch, manager.rng())
		return manager.nav.find_route(position, dest)
	return manager.request_ped_route(self)


## True when a ride was queued ahead of the entry.
func _queue_home_lift(entry: Dictionary, dest: Vector3) -> bool:
	if not manager.has_method("household_lift_leg") or entry.get("lift", false) \
			or str(entry.get("do", "")) == "ride" or errand_owner != null:
		return false
	var leg: Dictionary = manager.household_lift_leg(self, dest)
	if leg.is_empty():
		return false
	entry["lift"] = true
	var lp: Vector3 = leg.pos
	print("[Resident %s] takes the lift %s" % [ped_id, str(leg.ride)])
	_insert_before(entry, {"do": "ride", "place": str(leg.ride), "pos": [lp.x, lp.y, lp.z], "for": 240.0, "name": "the lift"})
	return true


## Null when none applies.
func _indoor_route(entry: Dictionary, dest: Vector3, dist: float):
	if manager.has_method("restaurant_route") and dist > 0.8:
		var dining: Dictionary = manager.restaurant_route(position, dest)
		if not dining.is_empty():
			precise_route = true
			_teleport_after_route = false
			return dining.route
	if manager.has_method("household_ground_route") and dist > 3.0:
		var ground: Dictionary = manager.household_ground_route(position, dest)
		if not ground.is_empty():
			precise_route = true
			_teleport_after_route = false
			if ground.route.is_empty():
				_teleport_to(dest)
			return ground.route
	if manager.has_method("interior_route") and dist > arrival_threshold * 2.0:
		var indoors: PackedVector3Array = manager.interior_route(position, dest)
		if indoors.size() > 0:
			precise_route = true
			_teleport_after_route = false
			return indoors
	if entry.get("lift", false) and entry.has("door"):
		if dist > arrival_threshold * 2.0:
			_teleport_to(dest)
			return PackedVector3Array()
		_start_action(entry)
		return PackedVector3Array()
	return null


## The school's own floors, else the lift landing, else a jump.
func _route_to_school(entry: Dictionary, dest: Vector3) -> PackedVector3Array:
	var nav = manager.get("school_nav")
	if nav != null and nav.ready_ok and not entry.get("walked", false):
		var r = _school_nav_route(nav, entry, dest)
		if typeof(r) != TYPE_NIL:
			return r
	if not entry.get("lift", false) and manager.has_method("school_lift_leg") and (nav == null or not nav.ready_ok):
		var leg: Dictionary = manager.school_lift_leg(self, str(entry.get("place", "")))
		if not leg.is_empty():
			entry["lift"] = true
			print("[Resident %s] to the lift landing, then %s" % [ped_id, str(leg.ride)])
			_arrive_at(Vector3(leg.landing))
			inside_door = Vector3.INF
			_insert_before(entry, {"do": "ride", "place": str(leg.ride), "for": 240.0, "name": "the lift up to class"})
			return PackedVector3Array()
	_teleport_to(dest)
	inside_door = Vector3.INF
	return PackedVector3Array()


## Null when the surface cannot help.
func _school_nav_route(nav, entry: Dictionary, dest: Vector3):
	if nav.covers(position) and nav.entrance() != Vector3.INF and not nav.inside(position):
		return _walk_up_to_school(nav, entry)
	if nav.covers(position):
		var r: Dictionary = nav.route(position, dest)
		if r.get("points", PackedVector3Array()).size() < 2:
			return null
		entry["walked"] = true  # one walk per intent; what is left after it is a jump
		print("[Resident %s] walks to %s: %d waypoints%s%s" % [ped_id, str(entry.get("place", "")), r.points.size(),
			(", lift at " + str(r.lifts.values())) if not r.lifts.is_empty() else "", "" if r.reached else ", the mesh stops short (jump at the end)"])
		return _follow_leg(r, not bool(r.reached))
	var seam: Vector3 = nav.seam()
	if seam != Vector3.INF and not entry.get("to_seam", false):
		var to_seam: PackedVector3Array = manager.nav.find_route(position, seam)
		if to_seam.size() > 0:
			entry["to_seam"] = true
			print("[Resident %s] walks the street to the school (%d waypoints)" % [ped_id, to_seam.size()])
			_teleport_after_route = false
			return to_seam
	# No street to the seam, or off the surface there: arrive inside at street level.
	if nav.entrance() != Vector3.INF and not entry.get("entered", false):
		entry["entered"] = true
		return _arrive_inside(nav.entrance())
	return null


## Steps the last bit where the surface stops short of the entrance.
func _walk_up_to_school(nav, entry: Dictionary) -> PackedVector3Array:
	if entry.get("entered", false):
		return _arrive_inside(nav.entrance())
	var leg: Dictionary = nav.route(position, nav.entrance())
	entry["entered"] = true
	if leg.get("points", PackedVector3Array()).size() >= 2 and not bool(leg.reached):
		print("[Resident %s] walks up to the school (%d waypoints); the entrance is uncut — a step inside at the end" % [ped_id, leg.points.size()])
		_interior = true
		_route_lifts = {}
		_route_jumps = {}
		_teleport_after_route = false
		return leg.points
	if bool(leg.get("reached", false)):
		return _follow_leg(leg, false)
	return _arrive_inside(nav.entrance())


## Null when not leaving it.
func _route_out_of_school(entry: Dictionary, dest: Vector3, dist: float):
	var snav = manager.get("school_nav")
	var leaving: bool = snav != null and snav.ready_ok and dist > ARRIVE_RADIUS \
			and not manager.nav.is_walkable(Vector2(position.x, position.z)) \
			and snav.covers(position) and not snav.covers(dest) and snav.seam() != Vector3.INF \
			and not entry.get("to_seam_out", false)
	if not leaving:
		return null
	var out_leg: Dictionary = snav.route(position, snav.seam())
	if out_leg.get("points", PackedVector3Array()).size() < 2:
		return null
	entry["to_seam_out"] = true
	print("[Resident %s] walks out of the school (%d waypoints%s)" % [ped_id, out_leg.points.size(), ", lift" if not out_leg.lifts.is_empty() else ""])
	return _follow_leg(out_leg, false)


func _follow_leg(leg: Dictionary, teleport_after: bool) -> PackedVector3Array:
	_interior = true
	_route_lifts = leg.lifts.duplicate()
	_route_jumps = leg.get("jumps", {}).duplicate()
	_teleport_after_route = teleport_after
	return leg.points


func _arrive_inside(p: Vector3) -> PackedVector3Array:
	_arrive_at(p)
	inside_door = Vector3.INF
	return PackedVector3Array()


## A spot off the walk zones (an interior) is held.
func _route_at_stop(entry: Dictionary, dest: Vector3, dist: float) -> PackedVector3Array:
	_teleport_after_route = false
	var action := _entry_action(entry)
	if action != "stay" and not manager.nav.is_walkable(Vector2(dest.x, dest.z)):
		if dist > ARRIVE_RADIUS:
			_teleport_to(dest)
		# An errand the activity starts walks the last stretch next tick.
		_start_action(entry)
		idle_timer = 4.0
		return PackedVector3Array()
	if action == "stay":
		return _hold_spot(entry, dest, dist)
	_start_action(entry)
	if errand_owner != null and errand_dest != Vector3.INF:
		return super._request_route()  # the action got us a seat: walk to it now
	var loiter: Vector3 = manager.nav.random_point_near(dest, LOITER_RADIUS, manager.rng())
	return manager.nav.find_route(position, loiter)


func _hold_spot(entry: Dictionary, dest: Vector3, dist: float) -> PackedVector3Array:
	if dist > arrival_threshold * 2.0:
		var route: PackedVector3Array = manager.nav.find_route(position, dest)
		if route.is_empty():
			route.append(dest)
		return route
	_start_action(entry)
	if entry.has("face_deg") and character_model:
		character_model.rotation.y = deg_to_rad(float(entry.face_deg))
	if str(entry.get("do", "")) == "sit" and not sitting:
		_sit_by_routine(entry, dest)
	idle_timer = 3.0
	return PackedVector3Array()


## Via its door, else straight, else as near as reachable (teleporting the rest), else teleport now.
func _route_toward(entry: Dictionary, dest: Vector3) -> PackedVector3Array:
	if entry.has("door"):
		var dm := _find_marker(str(entry.door))
		if dm != null:
			var door_pos: Vector3 = manager.world().to_local(dm.global_position)
			var door_route: PackedVector3Array = manager.nav.find_route(position, door_pos)
			if door_route.size() > 0:
				_teleport_after_route = true
				return door_route
	var route: PackedVector3Array = manager.nav.find_route(position, dest)
	if route.size() > 0:
		_teleport_after_route = false
		return route
	for i in NEAR_TRIES:
		var near: Vector3 = manager.nav.random_point_near(dest, NEAR_RADIUS, manager.rng())
		route = manager.nav.find_route(position, near)
		if route.size() > 0:
			_teleport_after_route = true
			return route
	_teleport_to(dest)
	return PackedVector3Array()


func _on_errand_unreachable():
	if _strict_errand():
		super()
		return
	_teleport_to(errand_dest)
	_errand_notify(true)


func _on_route_arrived():
	if errand_owner != null and errand_dest != Vector3.INF:
		if _strict_errand():
			super()
			return
		if _errand_fails >= 2:
			_teleport_to(errand_dest)
			_errand_notify(true)
			return
		super()
		return
	if _teleport_after_route:
		_teleport_after_route = false
		var dest := _current_dest()
		if position.distance_to(dest) > ARRIVE_RADIUS:
			inside_door = position  # remember the way back out
			_teleport_to(dest)


## An errand is teleported to its seat on the second failure, the routine after STUCK_TELEPORT_AFTER.
func _on_route_abandoned():
	if errand_owner != null and errand_dest != Vector3.INF:
		if _strict_errand():
			super()
			return
		if _errand_fails >= 1:
			_teleport_to(errand_dest)
			_errand_notify(true)
		else:
			super()
		return
	_stuck_fails += 1
	if _stuck_fails < STUCK_TELEPORT_AFTER:
		return
	_stuck_fails = 0
	var dest := _current_dest()
	var flat := dest - position
	flat.y = 0.0
	var radius := arrival_threshold * 2.0 if _entry_action(active_entry) == "stay" else ARRIVE_RADIUS
	if flat.length() <= radius and absf(dest.y - position.y) <= ARRIVE_RADIUS:
		return
	var from := position
	_teleport_to(dest)
	if manager != null and manager.has_method("observe"):
		manager.observe({"who": ped_id, "did": "travel_recovered", "place": str(active_entry.get("place", "")), "reason": "blocked route; used teleport recovery",
			"from": _snap(from),
			"to": _snap(dest),
			"from_walkable": manager.nav.is_walkable(Vector2(from.x, from.z)) if manager.nav != null else null,
			"doing": str(active_entry.get("do", active_entry.get("name", "")))})


func _snap(v: Vector3) -> Array:
	return [snappedf(v.x, 0.1), snappedf(v.y, 0.1), snappedf(v.z, 0.1)]


## Each person a step along a narrow spot rather than all on one point.
func _arrive_at(dest: Vector3):
	play_door_sound()
	var along: float = float(int(abs(hash(ped_id))) % 7) - 3.0
	position = dest + Vector3(0.0, 2.0, along)
	velocity = Vector3.ZERO
	enter_idle()


func _insert_before(entry: Dictionary, intent: Dictionary):
	var at_seq: int = int(entry.get("seq", 0))
	for i in _plan:
		if i.get("imm", false) and int(i.get("seq", 0)) >= at_seq:
			i["seq"] = int(i["seq"]) + 1
	_plan_seq += 1
	var it: Dictionary = intent.duplicate()
	it["imm"] = true
	it["seq"] = at_seq
	it["at"] = float(entry.get("at", manager.current_hour()))
	it["for_s"] = float(it.get("for", 120.0))
	it["sched_seq"] = int(entry.get("sched_seq", -1))
	if entry.has("skin"):
		it["skin"] = entry.skin
	_plan.append(it)
	_sort_plan(_plan)
	_stop_action()
	active_entry = {}
	enter_idle()
	idle_timer = 0.1


## A stable per-person spot around it, so people sharing a destination do not land on one another.
func _teleport_to(dest: Vector3):
	play_door_sound()  # remotes derive the same from the position jump
	var a: float = float(int(abs(hash(ped_id))) % 360) * TAU / 360.0
	var r: float = 3.0 + float(int(abs(hash(ped_id + "r"))) % 50) / 10.0
	# A "stay" action must land within the radius that starts it.
	if _entry_action(active_entry) == "stay":
		r = minf(r, arrival_threshold)
	var spot: Vector3 = dest + Vector3(cos(a) * r, 0.0, sin(a) * r)
	# Only where there is ground: a balcony edge is a metre away.
	if not _ground_under(spot) and _ground_under(dest):
		spot = dest
	if manager != null and manager.has_method("interior_snap"):
		spot = manager.interior_snap(spot)  # onto an indoor floor, not into a wall
	position = spot + Vector3.UP * 2.0
	velocity = Vector3.ZERO
	enter_idle()


func _ground_under(p: Vector3) -> bool:
	if manager == null or manager.world() == null or not is_inside_tree():
		return true
	var space := get_viewport().world_3d.direct_space_state
	if space == null:
		return true
	var w: Node3D = manager.world()
	var q := PhysicsRayQueryParameters3D.create(w.to_global(p + Vector3.UP * 4.0), w.to_global(p - Vector3.UP * 12.0))
	q.collide_with_areas = false
	q.exclude = [get_rid()]
	return not space.intersect_ray(q).is_empty()


func _start_action(entry: Dictionary):
	if _action_running:
		return
	_stuck_fails = 0
	_action_running = true
	if entry.has("life_id"):
		entry["started_msec"] = Time.get_ticks_msec()
	personal_space = false  # posted at a spot (a lectern): hold it
	var emotion := str(entry.get("emotion", entry.get("e", "")))
	if emotion != "":
		set_emotion(emotion)
	var verb := str(entry.get("do", ""))
	if not _request_verb(entry, verb):
		return
	if manager != null and manager.has_method("observe") and entry.has("do"):
		manager.observe({"who": ped_id, "did": verb,
			"place": str(entry.get("place", entry.get("marker", ""))),
			"at": manager.places.district_names_at(position)})
	_play_action_audio(str(entry.get("audio", "")))


## A refused request marks the entry done; false only for a refused ride, already recovered from.
func _request_verb(entry: Dictionary, verb: String) -> bool:
	if verb == "say" and manager != null and manager.has_method("resident_say"):
		# Said on the authority and relayed, so every player sees and hears it.
		manager.resident_say(self, entry)
	elif verb == "eat" and manager != null and manager.has_method("request_meal"):
		var place := str(entry.get("place", entry.get("marker", "")))
		if not manager.request_meal(self, place):
			life_meal_result = "no meal available"
			entry["done"] = true
			manager.observe({"who": ped_id, "failed": "eat", "place": place})
	elif verb == "buy" and manager != null and manager.has_method("request_shop"):
		var place := str(entry.get("place", ""))
		if not manager.request_shop(self, place):
			life_meal_result = "the shop is closed or full"
			entry["done"] = true
			manager.observe({"who": ped_id, "failed": "buy", "place": place})
	elif verb == "course" and manager != null and manager.has_method("request_course"):
		var place := str(entry.get("place", ""))
		if not manager.request_course(self, place, str(entry.get("role", ""))):
			entry["done"] = true
			manager.observe({"who": ped_id, "failed": "course", "place": place})
	elif verb == "teach" and manager != null and manager.has_method("request_teach"):
		if not manager.request_teach(self, str(entry.get("place", ""))):
			entry["done"] = true
	elif verb == "attend" and manager != null and manager.has_method("request_attend"):
		if not manager.request_attend(self, str(entry.get("place", ""))):
			entry["done"] = true
	elif verb == "ride" and manager != null and manager.has_method("request_elevator_ride"):
		if not manager.request_elevator_ride(self, str(entry.get("place", ""))):
			_ride_refused(entry)
			return false
	elif verb == "dismiss" and manager != null and manager.has_method("school_leave"):
		manager.school_leave(self, str(entry.get("place", "")))
		entry["done"] = true
	return true


func _ride_refused(entry: Dictionary):
	entry["done"] = true
	var landing = manager.places.place_position(str(entry.get("place", "")))
	if landing == null:
		manager.observe({"who": ped_id, "failed": "ride", "place": str(entry.get("place", "")), "reason": "lift destination missing"})
		return
	var from := position
	_arrive_at(landing)
	manager.observe({"who": ped_id, "did": "travel_recovered", "place": str(entry.get("place", "")), "reason": "lift unavailable; used teleport recovery",
		"from": _snap(from)})


## The mind's spoken lines are played by resident_say instead.
func _play_action_audio(audio_path: String):
	if not (audio_path.begins_with("res://") or audio_path.begins_with("user://")):
		return
	var stream = load(audio_path)
	if stream == null or not (stream is AudioStream):
		push_warning("[Resident %s] Cannot load action audio: %s" % [ped_id, audio_path])
		return
	if _action_audio == null:
		_action_audio = AudioStreamPlayer3D.new()
		_action_audio.max_distance = 40.0
		_action_audio.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(_action_audio)
	# A copy, so the shared resource keeps its own loop setting.
	var s = stream.duplicate()
	if "loop" in s:
		s.loop = true
	_action_audio.stream = s
	_action_audio.play()


func class_over():
	if not active_entry.is_empty():
		active_entry["done"] = true
	personal_space = true
	enter_idle()
	idle_timer = 0.2
	if manager != null and manager.has_method("observe"):
		manager.observe({"who": ped_id, "did": "class_over", "place": str(active_entry.get("place", ""))})


## The marker is the seat surface; "face_deg" overrides its facing.
func _sit_by_routine(entry: Dictionary, seat: Vector3):
	var yaw: float = character_model.rotation.y if character_model else 0.0
	if entry.has("face_deg"):
		yaw = deg_to_rad(float(entry.face_deg))
	else:
		var m: Node3D = null
		if entry.has("place") and manager.get("places") != null:
			m = manager.places.place_marker(str(entry.place))  # a named chair ("parliament.<house>.<i>")
		if m == null:
			m = _find_marker(str(entry.get("marker", entry.get("place", ""))))
		if m != null:
			yaw = _marker_yaw(m)
	steer_to = Vector3.INF
	steer_speed = 0.0
	sit_at(seat, yaw, str(entry.get("how", "chair")))
	routine_seated = true
	_seat_entry = entry
	if manager != null and manager.has_method("observe"):
		manager.observe({"who": ped_id, "did": "sit",
			"place": str(entry.get("name", entry.get("marker", entry.get("place", "")))),
			"at": manager.places.district_names_at(position)})


## -Z, the convention the school uses for desks.
func _marker_yaw(n: Node3D) -> float:
	var fwd: Vector3 = -(manager.world().global_transform.affine_inverse() * n.global_transform).basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		return 0.0
	return atan2(fwd.x, fwd.z) + PI


## A reaction without a destination is done from the seat; anything else stands us up.
func _watch_seat():
	var entry := current_entry()
	if entry == active_entry:
		return
	if entry == _seat_entry:
		active_entry = entry
		return
	var verb := str(entry.get("do", ""))
	if verb in ["say", "emote", "wait"] and not (entry.has("marker") or entry.has("place") or entry.has("pos")):
		active_entry = entry
		_action_running = false
		_start_action(entry)
		return
	_stop_action()
	idle_timer = 0.2


## Every course intent is done, the queued ones too.
func course_over(ok: bool):
	for i in _plan:
		if str(i.get("do", "")) == "course":
			i["done"] = true
	if str(active_entry.get("do", "")) == "course":
		active_entry["done"] = true
	personal_space = true
	if not sitting:
		enter_idle()
		idle_timer = 0.2
	if manager != null and manager.has_method("observe"):
		manager.observe({"who": ped_id, "did": "course_over" if ok else "missed_course",
			"place": str(active_entry.get("place", ""))})


func meal_over(ok: bool):
	life_meal_result = "ate" if ok else "left_hungry"
	if not active_entry.is_empty():
		active_entry["done"] = true
	if manager != null and manager.has_method("observe"):
		manager.observe({"who": ped_id, "did": "ate" if ok else "left_hungry",
			"place": str(active_entry.get("place", active_entry.get("marker", "")))})


func shop_over(ok: bool, item: String, restores: Dictionary):
	life_meal_result = "bought" if ok else "left_empty_handed"
	if not active_entry.is_empty():
		active_entry["done"] = true
	if manager != null and manager.has_method("observe"):
		var rec := {"who": ped_id, "did": "bought" if ok else "left_empty_handed",
			"place": str(active_entry.get("place", ""))}
		if ok:
			rec["item"] = item
			rec["restores"] = restores
		manager.observe(rec)


func _stop_action():
	if routine_seated:
		routine_seated = false
		_seat_entry = {}
		stand_up()
	if not _action_running:
		return
	_action_running = false
	personal_space = true
	set_emotion("")
	if _action_audio != null and is_instance_valid(_action_audio):
		_action_audio.stop()
