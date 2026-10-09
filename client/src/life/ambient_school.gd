class_name AmbientSchool
extends Node

## One classroom and its share of the school day: seats, lectern, breaks, bell and the player's HUD.

const BELL_CLIP := "res://assets/art/sound/city/school_bell.mp3"
const IDLE_FOREVER := 999999.0  # the body stays put
const HAND_SECS := 30.0  # a raised hand stays up this long
const DROP := 4.0  # bodies are placed this far above the ground and fall (origin is mid-body)

var _manager: AmbientManager = null
var _room: Node3D = null
var life_controller = null
var _lectern := Vector3.INF  # workspace-local, like every position here
var _lectern_yaw := 0.0
var _door := Vector3.INF
var _seats: Array = []  # {pos, yaw, ped}

# Replicated state (see snapshot()).
var _teacher := ""  # pid at the lectern ("r_…" or "u:…")
var _bell := 0  # counter: rings on every change
var _hands: Dictionary = {}  # "u:name" -> seconds left with the hand up
var in_break := false  # break manners in the room
var closed := false  # the school is shut today: nobody is seated
var _snap_applied := false  # a peer has seen the authority's state at least once
var _seen_bell := -1

# Authority only.
var enrolled: Array = []  # pids
var outside: Array = []
var _after_lunch := false  # the next break follows lunch (the long one)
var _last_break: Dictionary = {}  # pid -> what they did last break (habits repeat)
var teacher_out := false  # the teacher is in the yard, not at the lectern

# Every peer.
var _bell_player: AudioStreamPlayer3D = null
var _seated_players: Dictionary = {}  # seat index -> player node
var _before: Dictionary = {}  # my pid (":t" for the lectern) -> global position before entering
var _ui: CanvasLayer = null
var _prompt: Label = null
var _prompt_action := ""
var _key_cd := 0.0
var _score_label: Label = null
var match_: SchoolMatch = null  # the yard and the kickabout
var assembly_: SchoolAssembly = null  # the assembly and the rite
var board: SchoolBoard = null  # the blackboard


func setup(manager: AmbientManager, room: Node3D):
	life_controller = manager.life_controller
	_manager = manager
	_room = room
	match_ = SchoolMatch.new(self, manager)
	assembly_ = SchoolAssembly.new(self, manager)
	board = SchoolBoard.new(manager)
	var w: Node3D = _manager.world()
	var lect: Node3D = room.find_child("TeacherStandsHereFacingTheClass", true, false)
	if lect != null:
		_lectern = w.to_local(lect.global_position)
		_lectern_yaw = _yaw_of(lect)
	var door_node: Node3D = room.find_child("Door", true, false)
	if door_node != null:
		_door = w.to_local(door_node.global_position)
	board.find(room, w, _lectern)
	_find_seats(w)
	match_.find(w)
	print("[School %s] lectern=%s door=%s seats=%d yard=%s pitch=%s" % [key(), _lectern != Vector3.INF,
		_door != Vector3.INF, _seats.size(), match_.has_yard(), match_.has_pitch()])


## Every Marker3D child of a Desk* child, front row first.
func _find_seats(w: Node3D):
	for child in _room.get_children():
		if not (child is Node3D) or not str(child.name).begins_with("Desk"):
			continue
		for m in child.get_children():
			if m is Marker3D:
				_seats.append({"pos": w.to_local(m.global_position), "yaw": _yaw_of(m), "ped": ""})
	_seats.sort_custom(func(a, b):
		return a.pos.z < b.pos.z if absf(a.pos.z - b.pos.z) > 0.5 else a.pos.x < b.pos.x)


## Workspace space.
func _yaw_of(n: Node3D) -> float:
	var fwd: Vector3 = -(_manager.world().global_transform.affine_inverse() * n.global_transform).basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		return 0.0
	return atan2(fwd.x, fwd.z) + PI


func key() -> String:
	return str(_room.get_meta("place_id", "School")) if _room != null else "School"


func matches_place(place: String) -> bool:
	return place == "" or place == key() or (_room != null and place == str(_room.get_meta("place_alias", "")))


## "class_name" meta on the room, e.g. "12B".
func matches_class(klass: String) -> bool:
	return _room != null and klass != "" and klass == str(_room.get_meta("class_name", ""))


## 0 = the first found. The yard is shared, so rows, duty teacher and yard sounds go per room.
func room_index() -> int:
	return maxi(_manager.class_rooms().find(self), 0)


func room_count() -> int:
	return maxi(_manager.class_rooms().size(), 1)


## PlaceZone/Bounds box, or within 60 units of place_pos() without one.
func contains_position(workspace_position: Vector3) -> bool:
	var bounds := _room.get_node_or_null("PlaceZone/Bounds") as CollisionShape3D
	if bounds == null or not bounds.shape is BoxShape3D:
		return workspace_position.distance_to(place_pos()) < 60.0
	var local := bounds.to_local(_manager.world().to_global(workspace_position))
	var half := (bounds.shape as BoxShape3D).size * 0.5
	return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z


func place_entry() -> Dictionary:
	var entry := {"id": key(), "kind": "school", "pos": _manager.places.v3(place_pos()),
		"seats": seat_count(), "verbs": ["attend", "teach"],
		"name": str(_room.get_meta("class_name", key())), "grade": int(_room.get_meta("grade", 0))}
	var bounds := _room.get_node_or_null("PlaceZone/Bounds") as CollisionShape3D
	if bounds != null and bounds.shape is BoxShape3D:
		var half := (bounds.shape as BoxShape3D).size * 0.5
		var box := AABB(-half, half * 2.0)
		var transform: Transform3D = _manager.world().global_transform.affine_inverse() * bounds.global_transform
		box = transform * box
		entry["zone"] = {"min": _manager.places.v3(box.position), "max": _manager.places.v3(box.end)}
	return entry


## The yard during an assembly, else the door (or lectern).
func place_pos() -> Vector3:
	if assembly_.active() and match_.has_yard():
		return match_.yard
	return _door if _door != Vector3.INF else _lectern


func door() -> Vector3:
	return _door


func lectern() -> Vector3:
	return _lectern


func seat_count() -> int:
	return _seats.size()


func teacher_pid() -> String:
	return _teacher


func player_seated(username: String) -> bool:
	var pid := "u:" + username
	for s in _seats:
		if str(s.ped) == pid:
			return true
	return false


## "u:…" player, resident or pedestrian; null if gone.
func body_of(pid: String):
	if pid.begins_with("u:"):
		return _manager.player_by_id(pid)
	var b = _manager.residents().get(pid)
	if b == null:
		b = _manager.peds().get(pid)
	return b if b != null and is_instance_valid(b) else null


func resident_teacher() -> bool:
	return _teacher != "" and not _teacher.begins_with("u:")


func teacher_body():
	return body_of(_teacher) if resident_teacher() else null


func hold(b):
	if b.has_method("hold_idle"):
		b.hold_idle(IDLE_FOREVER)


func stop_steering(b):
	b.steer_to = Vector3.INF
	b.steer_speed = 0.0


## Except residents the life controller is driving.
func clear_resident_seats():
	for s in _seats:
		if str(s.ped) != "" and not str(s.ped).begins_with("u:") and not life_controller.controlled(str(s.ped)):
			s.ped = ""


## Teleported to the lectern, or to the front of the rows during an assembly.
func take_lectern(body) -> bool:
	if _lectern == Vector3.INF or body == null:
		return false
	_release_pid(str(body.ped_id))
	_teacher = str(body.ped_id)
	if body.sitting:
		body.stand_up()
	if assembly_.active():
		assembly_.teacher_to_front(body)
		return true
	stop_steering(body)
	body.position = _lectern + Vector3.UP * 1.0
	body.velocity = Vector3.ZERO
	hold(body)
	body.personal_space = false
	if body.character_model:
		body.character_model.rotation.y = _lectern_yaw
	pin_intent(body, _lectern)
	return true


## So the routine does not walk them back to the intent's original spot.
func pin_intent(body, at: Vector3):
	var entry = body.get("active_entry")
	if entry is Dictionary:
		entry["_pos"] = at


## During a break they are only enrolled; during an assembly they join the rows.
func request_seat(body) -> bool:
	if body == null:
		return false
	var pid := str(body.ped_id)
	if bool(life_controller.manual.get(pid, false)) and not life_controller.orders.has(pid):
		return false
	if closed:
		return false
	for i in _seats.size():
		if str(_seats[i].ped) == pid:
			return true
	if in_break:
		if not enrolled.has(pid):
			enrolled.append(pid)
		return true
	if assembly_.active():
		if not enrolled.has(pid):
			enrolled.append(pid)
		if not outside.has(pid):
			assembly_.join_rows(body)
			outside.append(pid)
		return true
	var i := _pick_seat(pid)
	if i < 0:
		return false
	var s: Dictionary = _seats[i]
	s.ped = pid
	stop_steering(body)
	body.position = Vector3(s.pos) + Vector3.UP * 1.0
	body.velocity = Vector3.ZERO
	body.sit_at(Vector3(s.pos), float(s.yaw))
	pin_intent(body, Vector3(s.pos))
	_class_manners(body)
	assembly_.note_seated(pid)
	return true


## Their usual desk if free, else nearest a seated friend, else nearest the usual one.
func _pick_seat(pid: String) -> int:
	if _seats.is_empty():
		return -1
	var usual := int(abs(hash(pid))) % _seats.size()
	if str(_seats[usual].ped) == "":
		return usual
	var def: Dictionary = _manager.resident_def(pid)
	var best := -1
	var best_d := INF
	for f in def.get("friends", []):
		var fpid := "r_" + str(f)
		for i in _seats.size():
			if str(_seats[i].ped) != fpid:
				continue
			var near: Array = _nearest_free_seat(Vector3(_seats[i].pos), best_d)
			if int(near[0]) >= 0:
				best = int(near[0])
				best_d = float(near[1])
	if best >= 0:
		return best
	return int(_nearest_free_seat(Vector3(_seats[usual].pos), INF)[0])


## [index, distance], or [-1, max_d] if there is none.
func _nearest_free_seat(at: Vector3, max_d: float) -> Array:
	var best := -1
	var best_d := max_d
	for j in _seats.size():
		if str(_seats[j].ped) != "":
			continue
		var d: float = Vector3(_seats[j].pos).distance_to(at)
		if d < best_d:
			best_d = d
			best = j
	return [best, best_d]


## A quarter take out a notebook, one in twenty has nodded off.
func _class_manners(body):
	var rng: RandomNumberGenerator = _manager.rng()
	var roll: float = rng.randf()
	body.set_prop("")
	body.set_emotion("")
	if roll < 0.25:
		body.set_prop("notebook")
	elif roll < 0.30:
		body.set_emotion("sad")  # nodded off


func _release_pid(pid: String):
	if _teacher == pid:
		_teacher = ""
	for s in _seats:
		if str(s.ped) == pid:
			s.ped = ""
			var b = body_of(pid)
			if b != null and not pid.begins_with("u:") and b.sitting:
				b.stand_up()


## Players stay until they /leave.
func dismiss():
	var t = teacher_body()
	if t != null:
		t.personal_space = true
		if t.has_method("hold_idle"):
			t.hold_idle(0.5)
		if t.has_method("class_over"):
			t.class_over()
	_teacher = "" if not _teacher.begins_with("u:") else _teacher
	for s in _seats:
		var pid := str(s.ped)
		if pid == "" or pid.begins_with("u:") or bool(life_controller.manual.get(pid, false)):
			continue
		var b = body_of(pid)
		s.ped = ""
		if b != null:
			b.stand_up()
			if b.has_method("class_over"):
				b.class_over()


## {"op": "sit"|"teach"|"stand"|"leave"|"kick"|"hand", "pid": "u:name", ["seat": i]}
func handle_player_request(data: Dictionary):
	var pid := str(data.get("pid", ""))
	if not pid.begins_with("u:"):
		return
	match str(data.get("op", "")):
		"sit":
			var i := int(data.get("seat", -1))
			if i < 0 or i >= _seats.size() or str(_seats[i].ped) != "":
				return
			_release_pid(pid)
			_seats[i].ped = pid
			_note_player_seat(pid, true)
		"teach":
			_release_pid(pid)
			if not resident_teacher():
				_teacher = pid
		"stand", "leave":
			_note_player_seat(pid, false)
			_release_pid(pid)
		"kick":
			match_.human_kick(pid)
		"hand":
			_raise_hand(pid)


## The resident teacher hears of it once.
func _raise_hand(pid: String):
	if not player_seated(pid.substr(2)) or _hands.has(pid):
		return
	_hands[pid] = HAND_SECS
	if resident_teacher():
		_manager.observe({"who": _teacher, "hand": "player:" + pid.substr(2), "in_class": true, "at": [key()]})


func _note_player_seat(pid: String, seated: bool):
	if not resident_teacher():
		return
	_manager.observe({"who": _teacher, ("seated" if seated else "stood"): "player:" + pid.substr(2), "at": [key()]})


## The amb_state "sch" section.
func snapshot() -> Dictionary:
	var out := []
	for s in _seats:
		out.append(str(s.ped))
	var snap := {"t": _teacher, "s": out, "b": _bell, "k": 1 if in_break else 0}
	match_.write_snapshot(snap)
	assembly_.write_snapshot(snap)
	board.write_snapshot(snap)
	if not _hands.is_empty():
		snap["hd"] = _hands.keys()
	return snap


## The first one is the baseline: a new peer does not replay the cues it missed.
func apply_snapshot(data: Dictionary):
	var first: bool = not _snap_applied
	_snap_applied = true
	_teacher = str(data.get("t", ""))
	var seats: Array = data.get("s", [])
	for i in mini(seats.size(), _seats.size()):
		_seats[i].ped = str(seats[i])
	in_break = int(data.get("k", 0)) == 1
	_bell = int(data.get("b", 0))
	match_.apply_snapshot(data, first)
	assembly_.apply_snapshot(data, first)
	if first:
		_seen_bell = _bell
	board.apply_snapshot(data.get("bd", []))
	_hands = {}
	for h in data.get("hd", []):
		_hands[str(h)] = HAND_SECS


func ring_bell():
	_bell += 1


func pupils_present() -> Array:
	var out: Array = []
	for s in _seats:
		var pid := str(s.ped)
		if pid != "" and not pid.begins_with("u:") and not out.has(pid):
			out.append(pid)
	for pid in enrolled:
		if not out.has(pid):
			out.append(pid)
	for pid in outside:
		if not out.has(pid):
			out.append(pid)
	return out


## Weighted by residents.json "breaks": "break_default" x3, last break's choice x2, yard after lunch.
func _pick_break(pid: String, def: Dictionary, plays: bool, yard_ok: bool, has_friends: bool) -> String:
	var rng: RandomNumberGenerator = _manager.rng()
	var w: Dictionary = def.get("breaks", {})
	var weights := {
		"football": float(w.get("football", 3.0)) if plays else 0.0,
		"friends": float(w.get("friends", 3.0)) if has_friends else 0.0,
		"read": float(w.get("read", 1.5)),
		"yard": float(w.get("yard", 2.0)) if yard_ok else 0.0,
		"window": float(w.get("window", 1.0)),
	}
	var pref := str(def.get("break_default", ""))
	if pref != "" and weights.has(pref):
		weights[pref] = float(weights[pref]) * 3.0
	var last := str(_last_break.get(pid, ""))
	if last != "" and weights.has(last):
		weights[last] = float(weights[last]) * 2.0
	if _after_lunch:
		weights["football"] = float(weights["football"]) * 1.6
		weights["yard"] = float(weights["yard"]) * 1.4
	var total := 0.0
	for k in weights:
		total += float(weights[k])
	if total <= 0.0:
		return "window"
	var roll: float = rng.randf() * total
	for k in weights:
		roll -= float(weights[k])
		if roll <= 0.0:
			return k
	return "window"


## Footballers start a kickabout; after lunch the teacher takes yard duty.
func break_time():
	life_controller.transition()
	in_break = true
	match_.end_match()
	match_.clear_crowd()
	var footballers: Array = []
	var pupils: Array = pupils_present()
	for pid in pupils:
		var pb = body_of(pid)
		if pb != null:
			stop_steering(pb)
	clear_resident_seats()
	outside = []
	enrolled = pupils.duplicate()
	var idle_out: Array = []  # pupils out in the yard without a ball
	var tally: Dictionary = {}
	for pid in pupils:
		if life_controller.controlled(str(pid)):
			continue
		var b = body_of(pid)
		if b == null:
			continue
		b.stand_up()
		b.set_emotion("")
		var activity := _send_on_break(pid, b, footballers, idle_out)
		tally[activity] = int(tally.get(activity, 0)) + 1
	# Two or three with a ball pull the others standing about into a game.
	while footballers.size() >= 2 and footballers.size() < 4 and not idle_out.is_empty():
		footballers.append(idle_out.pop_back())
	print("[School] break: %s → kickabout with %d" % [str(tally), footballers.size()])
	match_.start_match(footballers)
	if _after_lunch:
		match_.teacher_to_yard()
	_after_lunch = false


## Footballers are only collected; the match starts once everyone has chosen.
func _send_on_break(pid: String, b, footballers: Array, idle_out: Array) -> String:
	var rng: RandomNumberGenerator = _manager.rng()
	var def: Dictionary = _manager.resident_def(pid)
	var friends: Array = def.get("friends", [])
	var plays: bool = bool(def.get("football", true)) and match_.has_pitch()
	var yard_ok: bool = match_.has_yard()
	var activity: String = _pick_break(pid, def, plays, yard_ok, not friends.is_empty())
	_last_break[pid] = activity
	match activity:
		"football":
			footballers.append(pid)
		"yard":
			if plays:
				idle_out.append(pid)
			match_.go_yard(b)
		"friends":
			var f = body_of("r_" + str(friends[rng.randi_range(0, friends.size() - 1)]))
			if f != null:
				var toward: Vector3 = f.position + (b.position - f.position).normalized() * 3.0
				b.set_prop("")
				walk_direct(b, toward)
		"read":
			b.set_prop("notebook" if rng.randf() < 0.6 else "book")
			b.set_emotion("serious")
			b.personal_space = false
		_:
			b.set_prop("")
			walk_direct(b, _window_spot(b, rng))
	return activity


## Two units off the line from the lectern through the body.
func _window_spot(b, rng: RandomNumberGenerator) -> Vector3:
	if _lectern == Vector3.INF:
		return b.position
	var side: float = -1.0 if rng.randf() < 0.5 else 1.0
	return _lectern + (b.position - _lectern).normalized() * 2.0 * side


func class_time():
	match_.clear_waiting()
	life_controller.transition()
	in_break = false
	assembly_.class_begins()
	board.clear()
	match_.end_match()
	for pid in outside:
		var ob = body_of(pid)
		if ob != null:
			stop_steering(ob)
	outside = []
	match_.clear_crowd()
	if teacher_out:
		teacher_out = false
		var tb = teacher_body()
		if tb != null:
			take_lectern(tb)
	for pid in enrolled:
		if life_controller.controlled(str(pid)):
			continue
		var b = body_of(pid)
		if b == null:
			continue
		b.personal_space = true
		request_seat(b)
	enrolled = []


func make_player(max_distance: float, unit_size: float, at: Vector3) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.max_distance = max_distance
	p.unit_size = unit_size
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.position = at
	_manager.container().add_child(p)
	return p


## All rooms ring together, so the manager lets only one play it.
func _play_bell():
	if _manager.has_method("school_bell_gate") and not _manager.school_bell_gate():
		return
	if _bell_player == null or not is_instance_valid(_bell_player):
		_bell_player = make_player(220.0, 18.0, _door if _door != Vector3.INF else _lectern)
	var stream = load(BELL_CLIP)
	if stream != null:
		_bell_player.stream = stream
		_bell_player.play()


## The mind hears "ate", so nobody goes off to eat again.
func lunch():
	var pupils: Array = seated_residents()
	for pid in enrolled:
		if not pupils.has(pid):
			pupils.append(pid)
	in_break = false
	match_.end_match()
	outside = []
	enrolled = []
	for pid in pupils:
		if life_controller.controlled(str(pid)):
			continue
		var b = body_of(pid)
		if b == null:
			continue
		if not request_seat(b):
			continue
		b.set_prop("bento")
		b.set_emotion("happy" if _manager.rng().randf() < 0.4 else "")
		_manager.observe({"who": pid, "did": "ate", "place": key(), "meal": "bento"})
	in_break = true
	match_.teacher_to_yard()
	_after_lunch = true


## Residents at a desk, in seat order.
func seated_residents() -> Array:
	var out: Array = []
	for s in _seats:
		var pid := str(s.ped)
		if pid != "" and not pid.begins_with("u:"):
			out.append(pid)
	return out


## Every resident at a desk sits back down.
func sit_back_down():
	for i in _seats.size():
		var pid := str(_seats[i].ped)
		if pid == "" or pid.begins_with("u:"):
			continue
		var b = body_of(pid)
		if b != null:
			b.steer_to = Vector3.INF
			b.sit_at(Vector3(_seats[i].pos), float(_seats[i].yaw))
			_class_manners(b)


func free_period():
	break_time()


func seated_neighbours(pid: String, radius: float = 4.5) -> Array:
	var out: Array = []
	var mine := -1
	for i in _seats.size():
		if str(_seats[i].ped) == pid:
			mine = i
	if mine < 0:
		return out
	for i in _seats.size():
		var other := str(_seats[i].ped)
		if i != mine and other != "" and not other.begins_with("u:") \
				and Vector3(_seats[i].pos).distance_to(Vector3(_seats[mine].pos)) <= radius:
			out.append(other)
	return out


func walk_direct(b, to: Vector3):
	if b == null or not b.has_method("walk_route"):
		return
	b.walk_route(PackedVector3Array([to]))
	b.idle_timer = IDLE_FOREVER
	# The routine's "teleport the rest of the way" flag would end this walk with a jump back.
	if b.has_method("clear_route_recovery"):
		b.clear_route_recovery()
	b.reset_progress()


func set_authority(_is_auth: bool):
	pass


func _me() -> String:
	return "u:" + str(_manager.local_username())


func my_body():
	var b = _manager.local_player()
	return b if b != null and is_instance_valid(b) else null


func enter():
	var body = my_body()
	if body == null or _door == Vector3.INF:
		return
	if not _before.has(_me()):
		_before[_me()] = body.global_position
	body.global_position = _manager.world().to_global(_door + Vector3.UP * 1.0)


## Walking onto the pitch joins the match.
func enter_yard():
	var body = my_body()
	if body == null or not match_.has_yard():
		return
	if not _before.has(_me()):
		_before[_me()] = body.global_position
	var spot: Vector3 = match_.entry_spot()
	body.global_position = _manager.world().to_global(spot + Vector3.UP * DROP)


func leave():
	var body = my_body()
	if body == null:
		return
	if body.has_method("stand_from_seat"):
		body.stand_from_seat()
	if _before.has(_me()):
		body.global_position = _before[_me()]
		_before.erase(_me())


func _my_seat() -> int:
	var me := _me()
	for i in _seats.size():
		if str(_seats[i].ped) == me:
			return i
	return -1


func _ensure_ui():
	if _ui != null and is_instance_valid(_ui):
		return
	_ui = CanvasLayer.new()
	_ui.layer = 45
	add_child(_ui)
	var font := SystemFont.new()
	font.font_names = PackedStringArray(SchoolBoard.CJK_FONTS)
	_prompt = _hud_label(font, 34)
	_prompt.anchor_left = 0.5
	_prompt.anchor_right = 0.5
	_prompt.anchor_top = 1.0
	_prompt.anchor_bottom = 1.0
	_prompt.offset_left = -160.0
	_prompt.offset_right = 160.0
	_prompt.offset_top = -170.0
	_prompt.offset_bottom = -120.0
	_ui.add_child(_prompt)
	_score_label = _hud_label(font, 30)
	_score_label.anchor_left = 0.5
	_score_label.anchor_right = 0.5
	_score_label.offset_left = -140.0
	_score_label.offset_right = 140.0
	_score_label.offset_top = 18.0
	_score_label.offset_bottom = 60.0
	_ui.add_child(_score_label)


func _hud_label(font: Font, size: int) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 8)
	l.visible = false
	return l


func _player_ui_tick(delta):
	_key_cd = maxf(_key_cd - delta, 0.0)
	var body = my_body()
	if body == null:
		return
	_ensure_ui()
	var my_pos: Vector3 = _manager.world().to_local(body.global_position)
	_prompt_action = ""
	if _my_seat() >= 0:
		_prompt_action = "stand"
		_prompt.text = Labels.text("stand", "Stand") + " [E]   " \
				+ (Labels.text("raise_hand", "Hand") + " [H]" if not _hands.has(_me()) else "✋")
	elif _teacher == _me():
		_prompt_action = "stand"
		_prompt.text = Labels.text("step_down", "Step down") + " [E]"
	else:
		var seat := int(_nearest_free_seat(my_pos, 3.0)[0])
		if seat >= 0:
			_prompt_action = "sit:%d" % seat
			_prompt.text = Labels.text("sit", "Sit") + " [E]"
		elif _lectern != Vector3.INF and not resident_teacher() and my_pos.distance_to(_lectern) < 3.0:
			_prompt_action = "teach"
			_prompt.text = Labels.text("teach", "Teach") + " [E]"
		elif match_.kick_prompt(my_pos):
			_prompt_action = "kick"
			_prompt.text = Labels.text("kick", "Kick") + " [E]"
	_prompt.visible = _prompt_action != ""
	var score: String = match_.scoreboard(my_pos)
	_score_label.visible = score != ""
	if score != "":
		_score_label.text = score


## E does the prompted action; H raises a hand when seated.
func _unhandled_key_input(event: InputEvent):
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo or (k.keycode != KEY_E and k.keycode != KEY_H):
		return
	if _prompt_action == "" or _key_cd > 0.0:
		return
	_key_cd = 0.4
	if k.keycode == KEY_H:
		if _prompt_action == "stand" and _my_seat() >= 0:
			_manager.player_school_request("hand")
		return
	if _prompt_action.begins_with("sit:"):
		_manager.player_school_request("sit", int(_prompt_action.get_slice(":", 1)))
	else:
		_manager.player_school_request(_prompt_action)


func _process(delta):
	if _manager == null or not _manager.has_network():
		return
	if _hears_cues():
		_bell_cue()
	if _manager.is_authority():
		_authority_tick(delta)
	if _hears_cues():
		assembly_.cues()
	if _manager.is_authority() and in_break:
		match_.kick_tick(delta)
	match_.kick_cue()
	match_.render_ball(delta)
	match_.yard_sound_tick()
	if _manager.is_authority():
		_drop_absent_players()
	_player_ui_tick(delta)
	_seat_players()
	_player_at_lectern()


## The authority always, others after their first snapshot.
func _hears_cues() -> bool:
	return _manager.is_authority() or _snap_applied


func _bell_cue():
	if _bell != _seen_bell:
		if _seen_bell >= 0:
			_play_bell()
		_seen_bell = _bell


func _authority_tick(delta: float):
	assembly_.tick(delta)
	if in_break:
		match_.yard_tick(delta)
	for h in _hands.keys():
		_hands[h] = float(_hands[h]) - delta
		if float(_hands[h]) <= 0.0 or not player_seated(str(h).substr(2)):
			_hands.erase(h)


func _drop_absent_players():
	for s in _seats:
		var pid := str(s.ped)
		if pid.begins_with("u:") and body_of(pid) == null:
			_note_player_seat(pid, false)
			s.ped = ""
	if _teacher.begins_with("u:") and body_of(_teacher) == null:
		_teacher = ""


func _seat_players():
	var me := _me()
	for i in _seats.size():
		var pid := str(_seats[i].ped)
		var node = _seated_players.get(i)
		if pid.begins_with("u:") and node == null:
			var body = body_of(pid)
			if body == null:
				continue
			_seated_players[i] = body
			if pid == me and body.has_method("sit_on_seat"):
				var hip: Vector3 = Vector3(_seats[i].pos) + Vector3.UP * 1.0
				body.sit_on_seat(_manager.world().to_global(hip), float(_seats[i].yaw))
		elif (not pid.begins_with("u:")) and node != null:
			_seated_players.erase(i)
			if is_instance_valid(node) and node.has_method("stand_from_seat"):
				node.stand_from_seat()


func _player_at_lectern():
	var me := _me()
	var mine = my_body()
	if _teacher == me and mine != null and not _before.has(me + ":t"):
		_before[me + ":t"] = mine.global_position
		mine.global_position = _manager.world().to_global(_lectern + Vector3.UP * 1.0)
	elif _teacher != me and _before.has(me + ":t") and mine != null:
		mine.global_position = _before[me + ":t"]
		_before.erase(me + ":t")
