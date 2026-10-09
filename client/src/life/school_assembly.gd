## The yard assembly with its anthem and march back in, and the stand-bow-sit rite in class.
class_name SchoolAssembly
extends RefCounted

const ANTHEM_CLIP := "res://assets/art/sound/city/kimigayo.ogg"
const STANCE_NAMES := ["", "attention", "at_ease"]
## ASM_STEPS "at" is seconds from the rows forming; stance 0 easy, 1 attention, 2 at ease.
const ANTHEM_AT := 6.5
const ANTHEM_S := 59.0
const ASM_STEPS := [
	{"at": 1.5, "line": "as_at_ease", "stance": 2},
	{"at": 4.0, "line": "as_attention", "stance": 1},
	{"at": ANTHEM_AT, "anthem": true},
	{"at": ANTHEM_AT + ANTHEM_S + 1.5, "line": "as_bow", "bow": true},
	{"at": ANTHEM_AT + ANTHEM_S + 5.0, "line": "as_at_ease", "stance": 2},
	{"at": ANTHEM_AT + ANTHEM_S + 7.5, "words": true},
	{"at": ANTHEM_AT + ANTHEM_S + 12.5, "to_class": true},
]
const ASM_COLUMNS := 2  # pupils abreast in a class's block
const ASM_ACROSS := 2.6  # between the two columns
const ASM_BACK := 2.4  # between ranks, front to back
const ASM_GAP := 6.0  # between one class's block and the next

var _s: AmbientSchool = null
var _m: AmbientManager = null

# Replicated.
var _anthem := 0  # counter: plays on every change
var _bow := 0  # counter: a bow by everyone near _bow_at
var _bow_at := 0  # 0 = the yard, 1 = the classroom
var _stance := 0  # index into STANCE_NAMES
var _seen_anthem := -1
var _seen_bow := -1
var _seen_stance := -1

# Authority only.
var _asm: Dictionary = {}
var _march: Dictionary = {}  # pid -> {t, state, dest, since} filing in after the assembly
var _march_teacher := false  # the teacher follows the class in once the last pupil is inside
var _rite: Dictionary = {}  # the stand-bow-sit rite in progress
var _class_started := false  # the opening rite is done: latecomers apologise
var _late_q: Array = []  # [{pid, t, step}] latecomers about to say sorry
var _rite_delay := -1.0  # seconds until the opening rite (after class_time)

# Every peer.
var _anthem_player: AudioStreamPlayer3D = null


func _init(school: AmbientSchool, manager: AmbientManager):
	_s = school
	_m = manager


func active() -> bool:
	return not _asm.is_empty()


func in_rite() -> bool:
	return not _rite.is_empty()


## The opening rite follows in three seconds.
func class_begins():
	_asm = {}
	_rite = {}
	_class_started = false
	_rite_delay = 3.0


## Seated after the opening rite: they will say sorry for being late.
func note_seated(pid: String):
	if _class_started and _rite.is_empty() and _s.teacher_pid() != "":
		_late_q.append({"pid": pid, "t": 0.8, "step": 0})


## "am" opens the week, any other kind closes it. If gather() formed the rows, this starts the ceremony.
func start(kind: String):
	if not _s.match_.has_yard():
		return
	if not _asm.is_empty() and int(_asm.step) < 0:
		var tb = _s.teacher_body()
		if tb != null:
			teacher_to_front(tb)
		_asm.kind = kind
		_asm.step = 0
		_asm.t = 0.0
		print("[School %s] assembly (%s): %d in rows" % [_s.key(), kind, _s.outside.size()])
		return
	_lay_rows(kind)
	print("[School %s] assembly (%s): %d in rows" % [_s.key(), kind, _s.outside.size()])


## The ceremony waits (step -1) for start().
func gather(kind: String):
	if not _s.match_.has_yard():
		return
	_lay_rows(kind)
	_asm.step = -1
	print("[School %s] gathering: %d here already" % [_s.key(), _s.outside.size()])


## Two columns per class, the rooms' blocks side by side facing the SchoolYard marker's way.
func _lay_rows(kind: String):
	var pupils: Array = _s.pupils_present()
	_s.clear_resident_seats()
	_s.outside = []
	_s.match_.end_match()
	_s.in_break = false
	_s.enrolled = pupils.duplicate()
	var yard: Vector3 = _s.match_.yard
	var fwd: Vector3 = _s.match_.yard_fwd
	var right: Vector3 = fwd.cross(Vector3.UP).normalized()
	var gy: float = _s.match_.ground_at(yard, yard.y)
	_s.match_.clear_crowd()
	var per_row := ASM_COLUMNS
	var slot: float = float(_s.room_index()) - float(_s.room_count() - 1) * 0.5
	var block: Vector3 = right * (slot * (per_row * ASM_ACROSS + ASM_GAP))
	var front: Vector3 = Vector3(yard.x, gy, yard.z) + fwd * 6.0 + block
	_march = {}
	_march_teacher = false
	_asm = {"kind": kind, "t": 0.0, "step": 0, "fwd": fwd, "right": right, "gy": gy, "block": block,
		"front": front, "per_row": per_row, "n": 0}
	pupils.sort()
	for i in pupils.size():
		var b = _s.body_of(pupils[i])
		if b == null:
			continue
		join_rows(b)
		_s.outside.append(pupils[i])
	var tb = _s.teacher_body()
	if tb != null:
		teacher_to_front(tb)


func teacher_to_front(tb):
	if _asm.is_empty() or tb == null:
		return
	var front: Vector3 = _asm.front
	var fwd: Vector3 = _asm.fwd
	_s.teacher_out = true
	tb.set_prop("")
	tb.steer_to = Vector3.INF
	tb.position = front + Vector3.UP * _s.DROP
	tb.velocity = Vector3.ZERO
	_s.hold(tb)
	if tb.character_model:
		tb.character_model.rotation.y = atan2(-fwd.x, -fwd.z) + PI
	_s.pin_intent(tb, front)


func _asm_spot(i: int) -> Vector3:
	var per_row: int = int(_asm.per_row)
	var row: int = i / per_row
	var col: int = i % per_row
	var fwd: Vector3 = _asm.fwd
	var right: Vector3 = _asm.right
	var yard: Vector3 = _s.match_.yard
	return Vector3(yard.x, float(_asm.gy), yard.z) + Vector3(_asm.block) - fwd * (2.0 + row * ASM_BACK) \
			+ right * ((col - (per_row - 1) * 0.5) * ASM_ACROSS)


## The next place in the rows.
func join_rows(b):
	_asm_place(b, int(_asm.n))
	_asm.n = int(_asm.n) + 1


func _asm_place(b, i: int):
	var spot: Vector3 = _asm_spot(i)
	var fwd: Vector3 = _asm.fwd
	b.stand_up()
	b.set_prop("")
	b.set_emotion("serious")
	b.personal_space = false
	b.steer_to = Vector3.INF
	b.position = spot + Vector3.UP * _s.DROP
	b.velocity = Vector3.ZERO
	_s.hold(b)
	if b.character_model:
		b.character_model.rotation.y = atan2(fwd.x, fwd.z) + PI
	_s.pin_intent(b, spot)


## Authority only: the ceremony, the march in, the rite and latecomers.
func tick(delta: float):
	_assembly_tick(delta)
	_march_tick(delta)
	_rite_tick(delta)
	_late_tick(delta)
	if _rite_delay >= 0.0:
		_rite_delay -= delta
		if _rite_delay < 0.0:
			rite("start")


## Only room 0 starts the anthem: one yard, one anthem.
func _assembly_tick(delta: float):
	if _asm.is_empty():
		return
	_asm.t = float(_asm.t) + delta
	var t: float = float(_asm.t)
	var step: int = int(_asm.step)
	if step < 0 or step >= ASM_STEPS.size():
		return
	var st: Dictionary = ASM_STEPS[step]
	if t < float(st.at):
		return
	_asm.step = step + 1
	var tb = _s.teacher_body()
	var kind := str(_asm.kind)
	if st.has("stance"):
		_stance = int(st.stance)
	if st.has("line") and tb != null:
		_m.resident_say(tb, {"line": str(st.line), "secs": 1.5})
	if st.get("anthem", false) and _s.room_index() == 0:
		_anthem += 1
	if st.get("bow", false):
		_bow_at = 0
		_bow += 1
	if st.get("words", false) and tb != null:
		_m.resident_say(tb, {"line": "as_morning" if kind == "am" else "as_friday", "secs": 4.0})
	if st.get("to_class", false):
		_end_assembly(kind, tb)


## After "am" the class files in rank by rank; otherwise they stand about until sent home.
func _end_assembly(kind: String, tb):
	if tb != null:
		_m.resident_say(tb, {"line": "as_to_class" if kind == "am" else "as_dismissed", "secs": 2.0})
	_stance = 0
	var fwd: Vector3 = _asm.fwd
	var right: Vector3 = _asm.right
	var front: Vector3 = _asm.front
	_asm = {}
	for pid in _s.outside:
		var b = _s.body_of(pid)
		if b != null:
			b.set_emotion("")
			b.personal_space = true
	if kind != "am":
		_s.in_break = true
		return
	var order: Array = _s.outside.duplicate()
	for i in order.size():
		var row: int = i / ASM_COLUMNS
		var col: int = i % ASM_COLUMNS
		var dest: Vector3 = front + fwd * 8.0 + right * ((col - (ASM_COLUMNS - 1) * 0.5) * 1.6)
		_march[order[i]] = {"t": 1.5 + row * 1.4 + col * 0.35, "state": "wait", "dest": dest, "since": 0.0}
	_s.outside = []
	_march_teacher = tb != null
	print("[School %s] to the classroom: %d file in" % [_s.key(), _march.size()])


## Each pupil takes a desk on arrival, on timeout, or when they stop walking.
func _march_tick(delta: float):
	if _march.is_empty():
		if _march_teacher:
			_teacher_follows_in()
		return
	for pid in _march.keys():
		var m: Dictionary = _march[pid]
		var b = _s.body_of(str(pid))
		if b == null:
			_march.erase(pid)
			continue
		if str(m.state) == "wait":
			m.t = float(m.t) - delta
			if float(m.t) <= 0.0:
				_start_march_walk(b, m)
			continue
		m.since = float(m.since) + delta
		var flat: Vector3 = b.position - Vector3(m.dest)
		flat.y = 0.0
		var limit: float = 240.0 if m.get("long", false) else 14.0
		var walking: bool = b.is_walking() or b.waiting_for_lift()
		if flat.length() < 2.5 or float(m.since) > limit or not walking:
			_march.erase(pid)
			b.personal_space = true
			b.set_prop("")
			_s.request_seat(b)


func _start_march_walk(b, m: Dictionary):
	m.state = "walk"
	b.personal_space = false
	var door: Vector3 = _s.door()
	var r: Dictionary = _m.school_route(b.position, door) if door != Vector3.INF else {}
	if r.is_empty() or not b.follow_school_route(r):
		_s.walk_direct(b, Vector3(m.dest))
	else:
		m.dest = door
		m.long = true


func _teacher_follows_in():
	_march_teacher = false
	var tb = _s.teacher_body()
	if tb != null:
		_s.teacher_out = false
		_s.take_lectern(tb)


func _play_anthem():
	if _anthem_player == null or not is_instance_valid(_anthem_player):
		_anthem_player = _s.make_player(260.0, 20.0, _s.match_.yard if _s.match_.has_yard() else _s.door())
	var stream = load(ANTHEM_CLIP)
	if stream != null:
		_anthem_player.stream = stream
		_anthem_player.play()


## Called by the class rep. Needs a resident teacher and three seated pupils.
func rite(kind: String):
	if not _s.resident_teacher():
		return
	var pupils: Array = _s.seated_residents()
	if pupils.size() < 3:
		if kind == "start":
			_class_started = true
		return
	pupils.sort_custom(func(a, b):
		return str(_m.resident_def(a).get("name", a)) < str(_m.resident_def(b).get("name", b)))
	_rite = {"kind": kind, "t": 0.0, "step": 0, "rep": pupils[0], "pupils": pupils}


func _rite_tick(delta: float):
	if _rite.is_empty():
		return
	_rite.t = float(_rite.t) + delta
	var t: float = float(_rite.t)
	var step: int = int(_rite.step)
	var rep = _s.body_of(str(_rite.rep))
	var pupils: Array = _rite.pupils
	var starting: bool = str(_rite.kind) == "start"
	if step == 0:
		if rep != null:
			_m.resident_say(rep, {"line": "kiritsu", "secs": 1.5})
		_rite.step = 1
	elif step == 1 and t > 1.2:
		_rite_stand(pupils)
		_rite.step = 2
	elif step == 2 and t > 2.8:
		if rep != null:
			_m.resident_say(rep, {"line": "rei", "secs": 1.2})
		_rite.step = 3
	elif step == 3 and t > 3.4:
		_bow_at = 1
		_bow += 1
		_rite.step = 4
	elif step == 4 and t > 6.0:
		if starting:
			if rep != null:
				_m.resident_say(rep, {"line": "chakuseki", "secs": 1.2})
		else:
			_rite_thanks(pupils)
		_rite.step = 5
	elif step == 5 and t > (7.2 if starting else 9.0):
		if starting:
			_s.sit_back_down()
			_class_started = true
		else:
			_rite_release(pupils)
		_rite = {}


func _rite_stand(pupils: Array):
	for pid in pupils:
		var b = _s.body_of(pid)
		if b == null:
			continue
		var yaw: float = b.sit_yaw if "sit_yaw" in b else 0.0
		b.stand_up()
		b.set_prop("")
		b.personal_space = false
		b.idle_timer = _s.IDLE_FOREVER
		b.steer_to = b.position
		if b.character_model:
			b.character_model.rotation.y = yaw


## Four voiced lines, the rest as speech bubbles.
func _rite_thanks(pupils: Array):
	var n := 0
	for pid in pupils:
		var b = _s.body_of(pid)
		if b == null:
			continue
		if n < 4:
			_m.resident_say(b, {"line": "arigato", "secs": 2.5})
		else:
			b.say(str(_m.DialogRegistry.line("arigato").get("text", "")) if "DialogRegistry" in _m else "", 2.5)
		n += 1


func _rite_release(pupils: Array):
	for pid in pupils:
		var b = _s.body_of(pid)
		if b != null:
			b.personal_space = true
			b.steer_to = Vector3.INF
	_class_started = false


func _late_tick(delta: float):
	for e in _late_q.duplicate():
		e.t = float(e.t) - delta
		if float(e.t) > 0.0:
			continue
		var b = _s.body_of(str(e.pid))
		if int(e.get("step", 0)) == 0:
			if b != null:
				_m.resident_say(b, {"line": "late_sorry", "secs": 2.5})
			e.step = 1
			e.t = 2.2
		else:
			var tb = _s.teacher_body()
			if tb != null:
				_m.resident_say(tb, {"line": "late_sit", "secs": 1.8})
			_late_q.erase(e)


## The "an", "bw" and "st" keys of the school's snapshot, in that order.
func write_snapshot(snap: Dictionary):
	snap["an"] = _anthem
	snap["bw"] = [_bow, _bow_at]
	snap["st"] = _stance


## `first`: the baseline snapshot, whose cues are not replayed.
func apply_snapshot(data: Dictionary, first: bool):
	_anthem = int(data.get("an", _anthem))
	if first:
		_seen_anthem = _anthem
	var bw = data.get("bw", null)
	if typeof(bw) == TYPE_ARRAY and bw.size() >= 2:
		_bow = int(bw[0])
		_bow_at = int(bw[1])
	if first:
		_seen_bow = _bow
	_stance = int(data.get("st", 0))
	if first:
		_seen_stance = _stance


## The anthem, the bow and the stance, each once per change.
func cues():
	_anthem_cue()
	_bow_cue()
	_stance_cue()


func _anthem_cue():
	if _anthem != _seen_anthem:
		if _seen_anthem >= 0:
			_play_anthem()
		_seen_anthem = _anthem


## Within 40 units; in the yard the teacher receives the bow, in class they return it.
func _bow_cue():
	if _bow == _seen_bow:
		return
	if _seen_bow >= 0:
		var at: Vector3 = _s.match_.yard if _bow_at == 0 else _s.lectern()
		for pid in _m.residents().keys():
			var pb = _s.body_of(pid)
			if pb == null or not pb.has_method("bow") or at == Vector3.INF:
				continue
			if pid == _s.teacher_pid() and _bow_at == 0:
				continue
			if pb.position.distance_to(at) < 40.0:
				pb.bow()
	_seen_bow = _bow


## "easy" releases everyone.
func _stance_cue():
	if _stance == _seen_stance:
		return
	_seen_stance = _stance
	var stance_name: String = STANCE_NAMES[clampi(_stance, 0, STANCE_NAMES.size() - 1)]
	for pid in _m.residents().keys():
		var pb = _s.body_of(pid)
		if pb == null or not ("stance" in pb) or not _s.match_.has_yard():
			continue
		if pb.position.distance_to(_s.match_.yard) < 40.0 or (stance_name == "" and str(pb.stance) != ""):
			pb.stance = stance_name
