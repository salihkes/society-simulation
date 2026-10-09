extends Node3D
## An art course: timetabled sessions where one named group of residents sits at the tables and an instructor teaches.

enum Phase { EMPTY, COMING, SEATED }
enum IPhase { NONE, COMING, TEACHING }

## Weekdays: Monday = 0.
@export var sessions: Array[Dictionary] = [
	{"group": "students", "days": [1, 3], "start": 16.5, "end": 18.0},
	{"group": "parents", "days": [2], "start": 17.0, "end": 18.5},
	{"group": "parents", "days": [5], "start": 10.5, "end": 12.0},
]
## Game hours before the start the invitations go out.
@export var lead := 0.4
## Game hours before its end.
@export var late_until := 0.5
@export var tip_min := 50.0
@export var tip_max := 100.0
## Prefix of the instructor's dialog registry lines.
@export var dialog_prefix := ""

const TIP_COUNT := 4

var _manager = null
var _seats: Array = []  # {marker, pos, yaw, ped, phase, timer}
var _spot := Vector3.INF  # workspace-local
var _spot_yaw := 0.0
var _instructor := ""  # "" = none
var _iphase: int = IPhase.NONE
var _session: Dictionary = {}  # {i, day, group, invited: {pid: role}, started}
var _on := false  # replicated
var _line := ""  # replicated
var _line_n := 0  # replicated: bumps on every line
var _tip_timer := 0.0
var _pin_cd := 0.0
var _tick := 0.0


func _ready():
	set_process(true)


func course_key() -> String:
	return str(name)


func place_pos() -> Vector3:
	return _seat_centroid()


## The intent walks here and the errand does the last stretch to the seat.
func approach_pos() -> Vector3:
	var c := _seat_centroid()
	if _manager == null or _seats.is_empty():
		return c
	var best := c
	var best_score := -INF
	for i in 14:
		var p: Vector3 = _manager.nav.random_point_near(c, 32.0, _manager.rng())
		if p.distance_to(c) > 34.0:
			continue
		var score := minf(_nearest_seat_dist(p), 12.0) - maxf(p.distance_to(c) - 24.0, 0.0)
		if score > best_score:
			best_score = score
			best = p
	return best


func _nearest_seat_dist(p: Vector3) -> float:
	var dmin := INF
	for s in _seats:
		dmin = minf(dmin, p.distance_to(Vector3(s.pos)))
	return dmin


## {group, days, start, end} each.
func sessions_info() -> Array:
	var out := []
	for s in sessions:
		out.append({"group": str(s.get("group", "")), "days": s.get("days", []),
			"start": float(s.get("start", 0.0)), "end": float(s.get("end", 0.0))})
	return out


func is_open() -> bool:
	return _on


func _seat_centroid() -> Vector3:
	if _seats.is_empty():
		if _manager != null and _manager.world() != null:
			return _manager.world().to_local(global_position)
		return position
	var c := Vector3.ZERO
	for s in _seats:
		c += Vector3(s.pos)
	return c / float(_seats.size())


func _process(delta):
	if _manager == null:
		_tick += delta
		if _tick >= 0.5:
			_tick = 0.0
			_register()
		return
	if not _manager.is_authority():
		return
	_tick += delta
	if _tick < 0.25:
		return
	var step := _tick
	_tick = 0.0
	_validate_seats(step)
	_run_sessions(step)
	_mind_instructor(step)


func _register():
	var root := get_tree().current_scene
	if root == null:
		return
	var mgr = root.find_child("AmbientManager", true, false)
	if mgr == null or mgr.world() == null:
		return
	_manager = mgr
	_scan_room()
	_manager.places.register_course(self)


func _scan_room():
	_seats = []
	var w: Node3D = _manager.world()
	var centroid := Vector3.ZERO
	var tables := 0
	for child in get_children():
		if not (child is Node3D):
			continue
		if child is Marker3D and str(child.name).to_lower().begins_with("instructor"):
			_spot = w.to_local((child as Node3D).global_position)
			_spot_yaw = _yaw_of(child)
			continue
		var seats_here := _table_seats(child)
		if seats_here.is_empty():
			continue
		tables += 1
		centroid += w.to_local((child as Node3D).global_position)
		for m in seats_here:
			_seats.append({"marker": m, "pos": w.to_local((m as Node3D).global_position),
				"yaw": _yaw_of(m), "ped": "", "phase": Phase.EMPTY, "timer": 0.0})
	if tables > 0:
		centroid /= float(tables)
	if _spot == Vector3.INF:
		_spot = centroid
	_manager.add_no_loiter(_seat_centroid(), 24.0)
	print("[ArtCourse %s] tables=%d seats=%d instructor_spot=%s" % [
		course_key(), tables, _seats.size(), _spot])


func _table_seats(table: Node) -> Array:
	var out: Array = []
	for sub in table.get_children():
		if sub is Marker3D:
			out.append(sub)
	out.sort_custom(func(a, b): return str(a.name) < str(b.name))
	return out


func _yaw_of(m: Node3D) -> float:
	var fwd: Vector3 = -m.global_basis.z
	fwd = _manager.world().global_basis.inverse() * fwd
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	return atan2(fwd.x, fwd.z) + PI


func _body(pid: String):
	if pid == "" or _manager == null:
		return null
	var b = _manager.residents().get(pid)
	if b != null and is_instance_valid(b):
		return b
	return null


func _seat_of(pid: String) -> int:
	for i in _seats.size():
		if str(_seats[i].ped) == pid:
			return i
	return -1


func _seated_count() -> int:
	var n := 0
	for s in _seats:
		if int(s.phase) == Phase.SEATED:
			n += 1
	return n


func _today(s: Dictionary, wd: int) -> bool:
	var days = s.get("days", [])
	if typeof(days) != TYPE_ARRAY or days.is_empty():
		return true
	for d in days:
		if int(d) == wd:
			return true
	return false


func _run_sessions(step: float):
	var hour: float = _manager.current_hour()
	var day: int = _manager.current_day()
	var wd: int = _manager.current_weekday()
	if not _session.is_empty():
		_run_open_session(step, hour, day)
		return
	for i in sessions.size():
		var s: Dictionary = sessions[i]
		if not _today(s, wd):
			continue
		if hour >= float(s.start) - lead and hour < float(s.end) - late_until:
			_open_session(i, day, str(s.get("group", "")))
			return


func _run_open_session(step: float, hour: float, day: int):
	var i := int(_session.i)
	if i < 0 or i >= sessions.size():
		_end_session()
		return
	var s: Dictionary = sessions[i]
	# Also ends when the clock jumped: a new day, or set back before the invitations.
	if int(_session.day) != day or hour >= float(s.end) \
			or hour < float(s.start) - lead - 0.5:
		_end_session()
		return
	if not bool(_session.started) and hour >= float(s.start):
		_start_teaching()
	_run_lesson(step)


## "courses": {"<course>": "parents" | "instructor" | {"group", "chance", "guest": {group: chance}}}
func _role_for(def: Dictionary, group: String) -> String:
	var courses = def.get("courses", {})
	var entry = courses.get(course_key(), null) if typeof(courses) == TYPE_DICTIONARY else null
	var my_group := ""
	var chance := 1.0
	var guest: Dictionary = {}
	if typeof(entry) == TYPE_STRING:
		my_group = str(entry)
	elif typeof(entry) == TYPE_DICTIONARY:
		my_group = str(entry.get("group", ""))
		chance = float(entry.get("chance", 1.0))
		if typeof(entry.get("guest", {})) == TYPE_DICTIONARY:
			guest = entry.get("guest", {})
	elif bool(def.get("student", false)):
		my_group = "students"
	if my_group == "instructor":
		return "instructor"
	if my_group == group:
		return "member" if _manager.rng().randf() < chance else ""
	if guest.has(group):
		return "guest" if _manager.rng().randf() < float(guest[group]) else ""
	return ""


func _busy(pid: String, body) -> bool:
	if body.errand_owner != null:
		return true
	if _manager.in_classroom(body) or _manager.in_match(body):
		return true
	var active = body.get("active_entry")
	if typeof(active) == TYPE_DICTIONARY and str(active.get("do", "")) in ["teach", "attend"]:
		return true
	if body.sitting and not bool(body.get("routine_seated")):
		return true
	var lc = _manager.life_controller
	if lc != null and lc.has_method("controlled") and lc.controlled(pid):
		return true
	return false


func _open_session(i: int, day: int, group: String):
	_session = {"i": i, "day": day, "group": group, "invited": {}, "started": false}
	_on = true
	var names := []
	for key in _manager.resident_defs():
		var def: Dictionary = _manager.resident_defs()[key]
		var role := _role_for(def, group)
		if role == "":
			continue
		var body = _body(str(key))
		if body == null or not body.has_method("push_intent"):
			continue
		if _busy(str(key), body):
			continue
		_session.invited[str(key)] = role
		body.push_intent({"do": "course", "place": course_key(), "role": role,
			"name": "art class at " + course_key()})
		names.append(str(key))
	print("[ArtCourse %s] %s session opens (day %d): invited %s" % [
		course_key(), group, day, names])
	_manager.observe({"world": "course_open", "place": course_key(), "group": group,
		"invited": names})


## False when not invited, no session, busy, or nothing is free.
func request_seat(body, role: String = "") -> bool:
	if _session.is_empty() or body == null or not is_instance_valid(body):
		return false
	var pid := str(body.ped_id)
	if not _session.invited.has(pid):
		return false
	if role == "":
		role = str(_session.invited[pid])
	if role == "instructor":
		if _instructor != "" and _instructor != pid:
			return false
		_instructor = pid
		_set_iphase(IPhase.COMING)
		body.assign_errand(self, _spot, "teach")
		return true
	if _seat_of(pid) >= 0:
		return true
	if body.sitting or body.errand_owner != null:
		return false
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		if int(s.phase) == Phase.EMPTY and float(s.timer) <= 0.0:
			s.ped = pid
			s.timer = 150.0
			_set_phase(i, Phase.COMING)
			body.assign_errand(self, Vector3(s.pos), "seat:%d" % i)
			return true
	return false


## A failed walk ends with a step onto the place, as at a door.
func errand_finished(ped, tag: String, ok: bool):
	if tag == "teach":
		if str(ped.ped_id) != _instructor:
			return
		if not ok:
			_step_to(ped, _spot)
		_pin_instructor(ped)
		_set_iphase(IPhase.TEACHING)
		return
	if not tag.begins_with("seat:"):
		return
	var i := int(tag.substr(5))
	if i < 0 or i >= _seats.size():
		return
	var s: Dictionary = _seats[i]
	if str(s.ped) != str(ped.ped_id) or int(s.phase) != Phase.COMING:
		return
	if not ok:
		_step_to(ped, Vector3(s.pos))
	ped.sit_at(Vector3(s.pos), float(s.yaw))
	_set_phase(i, Phase.SEATED)
	s.timer = 0.0
	if _iphase == IPhase.TEACHING and _seated_count() == 1:
		_speak(dialog_prefix + "_greet")
	_manager.observe({"who": str(ped.ped_id), "did": "art_class", "place": course_key(),
		"teacher": _instructor, "present": _present()})


func _present() -> Array:
	var out := []
	for o in _seats:
		if int(o.phase) == Phase.SEATED:
			out.append(o.ped)
	return out


func _step_to(ped, pos: Vector3):
	ped.position = pos + Vector3.UP * 2.0
	ped.velocity = Vector3.ZERO
	if ped.has_method("play_door_sound"):
		ped.play_door_sound()


func _pin_instructor(ped):
	ped.personal_space = false
	ped.hold_idle(999999.0)
	if ped.character_model != null:
		ped.character_model.rotation.y = _spot_yaw


func _mind_instructor(step: float):
	if _instructor == "" or _session.is_empty():
		return
	var b = _body(_instructor)
	if b == null:
		_instructor = ""
		_set_iphase(IPhase.NONE)
		return
	_pin_cd -= step
	if _pin_cd > 0.0 or _iphase != IPhase.TEACHING:
		return
	_pin_cd = 3.0
	if b.errand_owner != null or b.sitting:
		return
	var d: Vector3 = b.position - _spot
	d.y = 0.0
	if d.length() > 6.0:
		_set_iphase(IPhase.COMING)
		b.assign_errand(self, _spot, "teach")


func _validate_seats(step: float):
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		s.timer = float(s.timer) - step
		if int(s.phase) == Phase.EMPTY:
			continue
		var ped = _body(str(s.ped))
		if ped == null or (int(s.phase) == Phase.COMING and float(s.timer) <= 0.0):
			_reset_seat(i)


func _reset_seat(i: int):
	var s: Dictionary = _seats[i]
	var ped = _body(str(s.ped))
	if ped != null:
		if ped.sitting:
			ped.stand_up()
		_release_errand(ped)
		ped.set_prop("")
		ped.set_emotion("")
	s.ped = ""
	s.phase = Phase.EMPTY
	s.timer = 5.0


func _release_errand(ped):
	if ped.errand_owner == self:
		ped.errand_owner = null
		ped.errand_dest = Vector3.INF


func _release_instructor():
	var b = _body(_instructor)
	if b != null:
		b.personal_space = true
		_release_errand(b)
	_instructor = ""
	_set_iphase(IPhase.NONE)


func _start_teaching():
	_session.started = true
	_tip_timer = _manager.rng().randf_range(tip_min, tip_max)
	if _iphase == IPhase.TEACHING:
		_speak(dialog_prefix + "_begin")


func _run_lesson(step: float):
	if not bool(_session.started) or _iphase != IPhase.TEACHING:
		return
	_tip_timer -= step
	if _tip_timer > 0.0:
		return
	_tip_timer = _manager.rng().randf_range(tip_min, tip_max)
	if _seated_count() > 0:
		_speak("%s_tip_%d" % [dialog_prefix, _manager.rng().randi_range(1, TIP_COUNT)])


## Everyone invited is released, whether seated, walking or never left.
func _end_session():
	var group := str(_session.get("group", ""))
	if _iphase == IPhase.TEACHING and _seated_count() > 0:
		_speak(dialog_prefix + "_end")
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		if int(s.phase) == Phase.EMPTY:
			continue
		var ped = _body(str(s.ped))
		if ped != null and int(s.phase) == Phase.SEATED:
			ped.say_line("art_thanks", 4.0)
		_reset_seat(i)
	_release_instructor()
	for pid in _session.get("invited", {}):
		var b = _body(str(pid))
		if b != null and b.has_method("course_over"):
			b.course_over(true)
	_session = {}
	_on = false
	_manager.observe({"world": "course_close", "place": course_key(), "group": group})


func release_resident(pid: String):
	var i := _seat_of(pid)
	if i >= 0:
		_reset_seat(i)
	if pid == _instructor:
		_release_instructor()
	if not _session.is_empty():
		_session.invited.erase(pid)


func _set_phase(i: int, new_phase: int):
	var s: Dictionary = _seats[i]
	var old := int(s.phase)
	s.phase = new_phase
	_apply_phase_visuals(i, old, new_phase)


func _apply_phase_visuals(i: int, old_phase: int, new_phase: int):
	var ped = _body(str(_seats[i].ped))
	if ped == null:
		return
	if new_phase == Phase.SEATED and old_phase != Phase.SEATED:
		ped.set_prop("notebook")
		ped.set_emotion("serious")
	elif old_phase == Phase.SEATED and new_phase != Phase.SEATED:
		ped.set_prop("")
		ped.set_emotion("")


func _set_iphase(p: int):
	_iphase = p


func _speak(line_id: String):
	_line = line_id
	_line_n += 1
	_say_instructor(line_id)


func _say_instructor(line_id: String):
	var b = _body(_instructor)
	if b != null:
		b.say_line(line_id, 5.0)


func snapshot() -> Dictionary:
	var seats := []
	for s in _seats:
		seats.append({"p": s.ped, "ph": int(s.phase)})
	return {"on": 1 if _on else 0, "i": _instructor, "ip": int(_iphase),
		"ln": _line, "lc": _line_n, "s": seats}


func apply_snapshot(data: Dictionary):
	var was_on := _on
	_on = int(data.get("on", 0)) == 1
	var seats: Array = data.get("s", [])
	var leaving: Array = []
	for i in mini(seats.size(), _seats.size()):
		var incoming: Dictionary = seats[i]
		var s: Dictionary = _seats[i]
		var new_p := str(incoming.get("p", ""))
		var ph := int(incoming.get("ph", 0))
		if ph != int(s.phase):
			var old := int(s.phase)
			if old == Phase.SEATED and was_on and not _on and str(s.ped) != "":
				leaving.append(str(s.ped))
			if ph != Phase.EMPTY:
				s.ped = new_p
			s.phase = ph
			_apply_phase_visuals(i, old, ph)
		s.ped = new_p
	_instructor = str(data.get("i", ""))
	_iphase = int(data.get("ip", 0))
	var ln := str(data.get("ln", ""))
	var n := int(data.get("lc", 0))
	if n != _line_n:
		_line_n = n
		_line = ln
		if ln != "":
			_say_instructor(ln)
	for pid in leaving:
		var b = _body(pid)
		if b != null:
			b.say_line("art_thanks", 4.0)


## Only the new authority stands the sitters up.
func set_authority(_is_auth: bool):
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		var ped = _body(str(s.ped))
		if ped != null and _is_auth:
			if ped.sitting:
				ped.stand_up()
			ped.set_prop("")
			ped.set_emotion("")
		s.ped = ""
		s.phase = Phase.EMPTY
		s.timer = 5.0
	_instructor = ""
	_iphase = IPhase.NONE
	_session = {}
	_on = false
