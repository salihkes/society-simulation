extends Node
class_name AmbientParliament

## The parliament chamber: places members, the speaker and the player as the server's `par` ops arrive.

const HOUSES := ["Lower", "Upper"]
## The council's house names -> the chamber's house nodes.
const COUNCIL_HOUSE := {"representatives": "Lower", "councillors": "Upper"}
const RISE_FORWARD := 0.6  # in front of the seat
const RISE_UP := 0.9  # seat surface -> standing body origin

var _manager = null
var _room: Node3D = null
var _rostrum: Node3D = null
var _door: Node3D = null
var _box: Node3D = null
var _speaker_seat: Node3D = null
var _seats := {}  # "Lower" -> [Marker3D], in Chair* order
var _gallery: Array = []
var _seated := {}  # member key -> Marker3D
var _speaker := ""
var sitting := false  # replicated
var matter := ""  # replicated
var verdict := ""  # replicated
var _before := {}  # my pid -> global position before /parliament


func setup(manager, room: Node3D) -> void:
	_manager = manager
	_room = room
	_rostrum = room.find_child("SpeakerStandsHereFacingTheHouse", true, false)
	_door = room.find_child("Door", true, false)
	_box = room.find_child("ImperialBox", true, false)
	var chair: Node = room.find_child("SpeakerChair", true, false)
	if chair != null:
		_speaker_seat = _seat_of(chair)
	for house in HOUSES:
		_seats[house] = _collect_chairs(room.find_child(house, true, false))
	_gallery = _collect_chairs(room.find_child("Gallery", true, false))
	_ensure_floor()
	print("[Parliament] %d lower, %d upper, %d gallery, speaker chair=%s, door=%s" % [
		_seats["Lower"].size(), _seats["Upper"].size(), _gallery.size(),
		_speaker_seat != null, _door != null])


## Skipped when the scene already has a StaticBody3D.
func _ensure_floor() -> void:
	if not _room.find_children("*", "StaticBody3D", true, false).is_empty():
		return
	for mi in _room.find_children("*", "MeshInstance3D", true, false):
		if _under_chair(mi) or mi.mesh == null:
			continue
		mi.create_trimesh_collision()


func _under_chair(n: Node) -> bool:
	var p := n
	while p != null and p != _room:
		var nm := str(p.name)
		if nm.begins_with("Chair") or nm.begins_with("Seat") or nm == "SpeakerChair":
			return true
		p = p.get_parent()
	return false


## "Chair10" follows "Chair9", whatever the padding.
func _collect_chairs(house: Node) -> Array:
	var out: Array = []
	if house == null:
		return out
	var chairs: Array = []
	for child in house.get_children():
		if not (child is Node3D):
			continue
		var n := str(child.name)
		if n.begins_with("Chair") or n.begins_with("Seat"):
			chairs.append(child)
	chairs.sort_custom(func(a, b):
		var na := _chair_no(str(a.name))
		var nb := _chair_no(str(b.name))
		return na < nb if na != nb else str(a.name) < str(b.name))
	for child in chairs:
		var m := _seat_of(child)
		if m != null:
			out.append(m)
	return out


## 0 when there is none.
static func _chair_no(n: String) -> int:
	var digits := ""
	for i in range(n.length() - 1, -1, -1):
		var ch := n[i]
		if ch < "0" or ch > "9":
			break
		digits = ch + digits
	return int(digits) if digits != "" else 0


static func _seat_of(chair: Node) -> Marker3D:
	for m in chair.get_children():
		if m is Marker3D:
			return m
	return null


func key() -> String:
	return "parliament"


## Workspace-local.
func place_pos() -> Vector3:
	return _local(_door if _door != null else _rostrum)


## The rostrum.
func centre_pos() -> Vector3:
	return _local(_rostrum if _rostrum != null else _door)


func seat_counts() -> Dictionary:
	var out := {}
	for civ in COUNCIL_HOUSE:
		var n: int = _seats.get(COUNCIL_HOUSE[civ], []).size()
		if n > 0:
			out[civ] = n
	return out


func seat_count(house := "Lower") -> int:
	return _seats.get(_house_name(house), []).size()


func _house_name(house: String) -> String:
	if COUNCIL_HOUSE.has(house):
		return COUNCIL_HOUSE[house]
	return house.capitalize()


## "parliament[.door|.rostrum|.speaker|.<house>.<i>|.gallery[.<i>]|.box]"; null when not one here.
func place_marker(place: String) -> Node3D:
	var parts := place.split(".")
	if parts.is_empty() or parts[0] != key():
		return null
	if parts.size() == 1:
		return _door
	match parts[1]:
		"door":
			return _door
		"rostrum":
			return _rostrum
		"speaker":
			return _speaker_seat if _speaker_seat != null else _rostrum
		"box":
			return _box
		"gallery":
			var gi := int(parts[2]) if parts.size() > 2 else 0
			return _gallery[gi] if gi >= 0 and gi < _gallery.size() else null
	var chairs: Array = _seats.get(_house_name(parts[1]), [])
	if parts.size() > 2:
		var i := int(parts[2])
		if i >= 0 and i < chairs.size():
			return chairs[i]
	return null


## Null when it is not one here.
func place_position(place: String):
	var m := place_marker(place)
	return _local(m) if m != null else null


## seat, open, rostrum, rise, sit, result, adjourn.
func on_par(data: Dictionary) -> void:
	match str(data.get("op", "")):
		"seat":
			_seat_members(_house_name(str(data.get("house", ""))),
				data.get("members", []), str(data.get("speaker", "")))
		"open":
			_open_sitting(data)
		"rostrum":
			_to_rostrum(str(data.get("member", "")))
		"rise":
			for k in _members_of(data):
				_set_standing(k, true)
		"sit":
			for k in _members_of(data):
				_set_standing(k, false)
		"result":
			verdict = str(data.get("verdict", ""))
		"adjourn":
			_adjourn()


func _open_sitting(data: Dictionary) -> void:
	sitting = true
	matter = str(data.get("matter", ""))
	verdict = ""
	var sp := str(data.get("speaker", ""))
	if sp != "":
		_speaker = sp
	if _speaker != "" and _speaker_seat != null:
		_seated[_speaker] = _speaker_seat
		_take_chair(_speaker)


## Members past the last chair stand at the door.
func _seat_members(house: String, members: Array, speaker: String) -> void:
	if speaker != "":
		_speaker = speaker
	var chairs: Array = _seats.get(house, [])
	var i := 0
	for m in members:
		var k := str(m)
		if k == _speaker and _speaker_seat != null:
			_seated[k] = _speaker_seat
		elif chairs.is_empty():
			continue
		elif i < chairs.size():
			_seated[k] = chairs[i]
			i += 1
		else:
			# Visible at the door, so a chamber short of chairs shows.
			_stand_at_back(k)
			continue
		_take_chair(k)


## Remembers the street they came from: the resident's door logic teleports them back there.
func _take_chair(key: String) -> void:
	if not _authority():
		return
	var m: Node3D = _seated.get(key)
	var body = _body(key)
	if m == null or body == null:
		return
	_remember_street(body)
	var pos := _local(m)
	body.steer_to = Vector3.INF
	body.steer_speed = 0.0
	body.position = pos + Vector3.UP * 1.0
	body.velocity = Vector3.ZERO
	body.sit_at(pos, _yaw_of(m))
	body.personal_space = false
	_pin_intent(body, pos)


func _set_standing(key: String, up: bool) -> void:
	if not _authority():
		return
	var body = _body(key)
	var m: Node3D = _seated.get(key)
	if body == null or m == null:
		return
	var pos := _local(m)
	if up:
		_hold_standing(body, pos + _fwd_of(m) * RISE_FORWARD + Vector3.UP * RISE_UP, _yaw_of(m))
	else:
		body.position = pos + Vector3.UP * 1.0
		body.velocity = Vector3.ZERO
		body.sit_at(pos, _yaw_of(m))
	_pin_intent(body, pos)


## {"member": k} or {"members": [k, ...]}.
static func _members_of(data: Dictionary) -> Array:
	var out: Array = []
	if data.has("members") and data.members is Array:
		for k in data.members:
			out.append(str(k))
	elif str(data.get("member", "")) != "":
		out.append(str(data.get("member", "")))
	return out


## Held there until "sit".
func _to_rostrum(key: String) -> void:
	if not _authority() or _rostrum == null:
		return
	var body = _body(key)
	if body == null or not _seated.has(key):
		return
	var pos := _local(_rostrum)
	# 3.0 is the standing body's height.
	_hold_standing(body, pos + Vector3.UP * 3.0, _yaw_of(_rostrum))
	_pin_intent(body, pos)


func _hold_standing(body, at: Vector3, yaw: float) -> void:
	if body.sitting:
		body.stand_up()
	body.position = at
	body.velocity = Vector3.ZERO
	body.steer_to = Vector3.INF
	body.steer_speed = 0.0
	body.personal_space = false
	if body.has_method("hold_idle"):
		body.hold_idle(999999.0)
	if body.get("character_model") != null:
		body.character_model.rotation.y = yaw


## Keeps an existing record (they were already inside somewhere).
func _remember_street(body) -> void:
	if not ("inside_door" in body) or body.inside_door != Vector3.INF:
		return
	var nav = _manager.get("nav")
	if nav != null and nav.is_walkable(Vector2(body.position.x, body.position.z)):
		body.inside_door = body.position


func _ensure_way_out(body) -> void:
	if not ("inside_door" in body) or body.inside_door != Vector3.INF:
		return
	var nav = _manager.get("nav")
	if nav == null or _door == null:
		return
	body.inside_door = nav.random_point_near(_local(_door), 80.0, _manager.rng())


func _stand_at_back(key: String) -> void:
	if not _authority() or _door == null:
		return
	var body = _body(key)
	if body == null:
		return
	_remember_street(body)
	var pos := _local(_door)
	if body.sitting:
		body.stand_up()
	body.position = pos + Vector3.UP * 1.0
	body.velocity = Vector3.ZERO
	if body.has_method("hold_idle"):
		body.hold_idle(999999.0)
	_pin_intent(body, pos)


## Players stay until they /leave.
func _adjourn() -> void:
	sitting = false
	if _authority():
		for key in _seated.keys():
			var body = _body(key)
			if body == null:
				continue
			if body.sitting:
				body.stand_up()
			body.personal_space = true
			_ensure_way_out(body)
			if body.has_method("class_over"):
				body.class_over()
	_seated.clear()
	_speaker = ""


## So the routine does not walk them back to the door.
func _pin_intent(body, at: Vector3) -> void:
	var entry = body.get("active_entry")
	if entry is Dictionary:
		entry["_pos"] = at


func snapshot() -> Dictionary:
	return {"o": 1 if sitting else 0, "m": matter, "v": verdict, "s": _speaker}


func apply_snapshot(data: Dictionary) -> void:
	sitting = int(data.get("o", 0)) == 1
	matter = str(data.get("m", ""))
	verdict = str(data.get("v", ""))
	_speaker = str(data.get("s", ""))


## "enter", "gallery", "box" or "leave" (back to where they were before).
func player_request(op: String) -> void:
	var body = _my_body()
	if body == null:
		return
	match op:
		"enter", "gallery", "box":
			var target: Node3D = _door
			if op == "gallery" and _gallery.size() > 0:
				target = _gallery[0]
			elif op == "box" and _box != null:
				target = _box
			if target == null:
				return
			if not _before.has(_me()):
				_before[_me()] = body.global_position
			body.global_position = target.global_position + Vector3.UP * 1.0
		"leave":
			if body.has_method("stand_from_seat"):
				body.stand_from_seat()
			if _before.has(_me()):
				body.global_position = _before[_me()]
				_before.erase(_me())


func player_inside() -> bool:
	return _before.has(_me())


func _authority() -> bool:
	return _manager != null and bool(_manager.is_authority())


func _me() -> String:
	return "u:" + str(_manager.local_username())


func _my_body():
	var b = _manager.local_player()
	return b if b != null and is_instance_valid(b) else null


func _body(key: String):
	if _manager == null:
		return null
	var b = _manager.residents().get(key)
	if b == null:
		b = _manager.residents().get("r_" + key)
	if b == null:
		b = _manager.peds().get(key)
	return b if b != null and is_instance_valid(b) else null


func _local(n: Node3D) -> Vector3:
	if n == null:
		return Vector3.INF
	return _manager.world().to_local(n.global_position)


## -Z, in workspace space.
func _fwd_of(n: Node3D) -> Vector3:
	var w: Node3D = _manager.world()
	var f: Vector3 = -(w.global_transform.affine_inverse() * n.global_transform).basis.z
	f.y = 0.0
	return f.normalized() if f.length_squared() > 0.001 else Vector3.ZERO


func _yaw_of(n: Node3D) -> float:
	var f := _fwd_of(n)
	if f == Vector3.ZERO:
		return 0.0
	return atan2(f.x, f.z) + PI
