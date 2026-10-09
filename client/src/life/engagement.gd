## How people engage with players: whom a player addresses, who hears their chat, and who stops for a look or a click.
class_name AmbientEngagement
extends RefCounted

## Network messages this module handles: type -> method (see protocol/messages.json).
const MESSAGES := {
	"npc_addr": "handle_npc_addr",
}

const ADDR_ANGLE_DEG := 35.0  # view cone in which a player addresses someone
const ENGAGE_STARE_DEG := 30.0  # half-angle of the cone a look counts in
const ENGAGE_STARE_S := 8.0  # a look holds someone this long
const ENGAGE_CLICK_S := 25.0  # a click holds until this long without a word
const ENGAGE_COOL_S := 10.0  # then they ignore that player for this long
const ENGAGE_STILL_S := 0.5  # the player must have stood still this long
const ENGAGE_REPLY_S := 90.0  # spoken to, they wait this long for the mind's answer

var _m: AmbientManager = null
var _addr_marker: Label3D = null
var _addr_timer := 0.0
var _addr_selected := ""  # clicked on: sticks until another click or Esc
var _addr_sent := ""  # whom the authority was last told we address

# Authority only.
var _addr_by_player := {}  # username -> pid clicked on
var _engage_pick := {}  # pid -> player node, from the last scan
var _engage_state := {}  # pid -> {who, since, kind, chat}
var _engage_cool := {}  # "pid|who" -> until (seconds)
var _engage_still := {}  # who -> {pos, t}
var _engage_timer := 0.0
var _engage_wait := {}  # pid -> {who, until}: spoken to, answer pending


func _init(manager: AmbientManager):
	_m = manager


## Computed on the speaker's client and sent with the chat message as "to".
func pick_addressee(text: String = "") -> String:
	var me: Node3D = _m.local_player()
	if me == null or not is_instance_valid(me) or _m.world() == null:
		return ""
	var my_pos: Vector3 = _m.world().to_local(me.global_position)
	var cands := _addressee_candidates(my_pos, _m.npc_talk_radius + 4.0)
	if cands.is_empty():
		return ""
	if _addr_selected != "":
		for c in cands:
			if c[0] == _addr_selected:
				return _addr_selected
	var named := _addressee_by_name(cands, text.strip_edges().to_lower())
	if named != "":
		return named
	return _addressee_in_view(cands, my_pos)


## [pid, body] pairs.
func _addressee_candidates(my_pos: Vector3, reach: float) -> Array:
	var cands: Array = []
	var residents: Dictionary = _m.residents()
	var peds: Dictionary = _m.peds()
	for key in residents:
		var b = residents[key]
		if b != null and is_instance_valid(b) and not _m.off_map(b) and b.position.distance_to(my_pos) <= reach:
			cands.append([str(key), b])
	for id in peds:
		var p = peds[id]
		if p != null and is_instance_valid(p) and not p.sitting and p.position.distance_to(my_pos) <= reach:
			cands.append([str(id), p])
	return cands


## Two letters or more.
func _addressee_by_name(cands: Array, head: String) -> String:
	if head == "":
		return ""
	for c in cands:
		var pid: String = c[0]
		var names: Array = [pid.trim_prefix("r_").to_lower()]
		var def: Dictionary = _m.resident_def(pid)
		if str(def.get("name", "")) != "":
			names.append(str(def.name).to_lower())
		for n in names:
			if n.length() >= 2 and head.begins_with(n):
				return pid
	return ""


func _addressee_in_view(cands: Array, my_pos: Vector3) -> String:
	var cam: Camera3D = _m.get_viewport().get_camera_3d() if _m.is_inside_tree() else null
	var best := ""
	var best_key := INF
	for c in cands:
		var b: Node3D = c[1]
		var d: float = b.position.distance_to(my_pos)
		var key: float = 1000.0 + d
		if cam != null:
			var to_b: Vector3 = (b.global_position - cam.global_position)
			to_b.y *= 0.3  # looking a little up or down at someone still counts
			var ang: float = rad_to_deg(acos(clampf(-cam.global_transform.basis.z.dot(to_b.normalized()), -1.0, 1.0)))
			if ang <= ADDR_ANGLE_DEG:
				key = ang + d * 0.5
		if key < best_key:
			best_key = key
			best = c[0]
	return best


## Every 0.2 s.
func addressee_tick(delta: float):
	_addr_timer -= delta
	if _addr_timer > 0.0:
		return
	_addr_timer = 0.2
	var focus = _m.get_viewport().gui_get_focus_owner() if _m.is_inside_tree() else null
	var typing: bool = focus is LineEdit or focus is TextEdit
	var pid: String = pick_addressee(str(focus.text) if (typing and focus is LineEdit) else "") if typing else ""
	var addressing: String = pid if typing else _addr_selected
	if addressing != _addr_sent:
		_addr_sent = addressing
		_send_addr(addressing)
	var body = null
	if pid != "":
		body = _m.residents().get(pid)
		if body == null:
			body = _m.peds().get(pid)
	if body == null or not is_instance_valid(body):
		if _addr_marker != null and is_instance_valid(_addr_marker):
			_addr_marker.visible = false
		return
	_ensure_addr_marker()
	_addr_marker.visible = true
	_addr_marker.modulate = Color(0.55, 1.0, 0.6) if pid == _addr_selected else Color(1.0, 0.85, 0.35)
	_addr_marker.position = body.position + Vector3.UP * (6.2 + 0.25 * sin(Time.get_ticks_msec() / 250.0))


func _ensure_addr_marker():
	if _addr_marker != null and is_instance_valid(_addr_marker):
		return
	_addr_marker = Label3D.new()
	_addr_marker.text = "▼"
	_addr_marker.font_size = 72
	_addr_marker.pixel_size = 0.006
	_addr_marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_addr_marker.no_depth_test = true
	_addr_marker.modulate = Color(1.0, 0.85, 0.35)
	_addr_marker.outline_size = 12
	_addr_marker.outline_modulate = Color(0.05, 0.05, 0.08, 0.9)
	_m.container().add_child(_addr_marker)


## A left click selects whom to address; Esc clears it.
func unhandled_input(event):
	var me = _m.local_player()
	if me == null or not _m.is_inside_tree():
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_addr_selected = ""
		_addr_timer = 0.0
		return
	if not (event is InputEventMouseButton) or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var cam: Camera3D = _m.get_viewport().get_camera_3d()
	if cam == null:
		return
	var from: Vector3 = cam.project_ray_origin(event.position)
	var to: Vector3 = from + cam.project_ray_normal(event.position) * 60.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	q.exclude = [me.get_rid()] if me is CollisionObject3D else []
	var hit: Dictionary = _m.get_viewport().world_3d.direct_space_state.intersect_ray(q)
	_addr_selected = _picked_person(hit.collider) if not hit.is_empty() else ""
	_addr_timer = 0.0


## Else "".
func _picked_person(n: Node) -> String:
	while n != null:
		var pid := str(n.get("ped_id")) if n.get("ped_id") != null else ""
		if pid != "" and (_m.residents().has(pid) or _m.peds().has(pid)):
			return pid
		n = n.get_parent()
	return ""


## Keyed by the player node's name, which the engagement scan sees.
func _send_addr(pid: String):
	var who: String = _m.local_username()
	var me = _m.local_player()
	if me != null and is_instance_valid(me):
		who = str(me.name)
	var d := {"type": "npc_addr", "p": who, "pid": pid}
	if _m.is_authority():
		handle_npc_addr(d)
	else:
		_m.send_to_server(d)


func handle_npc_addr(data: Dictionary):
	if not _m.is_authority():
		return
	var who := str(data.get("p", ""))
	if who == "":
		return
	var pid := str(data.get("pid", ""))
	if pid == "":
		_addr_by_player.erase(who)
	else:
		_addr_by_player[who] = pid


# A person stops for a player addressing them, never for one merely nearby; every hold has a leash.

## Until the reply arrives (reply_arrived) or ENGAGE_REPLY_S passes.
func _await_reply(pid: String, username: String):
	_engage_wait[pid] = {"who": username, "until": Time.get_ticks_msec() / 1000.0 + ENGAGE_REPLY_S}


func reply_arrived(pid: String):
	_engage_wait.erase(pid)


func engaged_player(body: Node) -> Node3D:
	if body == null:
		return null
	var p = _engage_pick.get(str(body.get("ped_id")))
	if p == null or not is_instance_valid(p):
		return null
	return p


func _engage_body(pid: String):
	var b = _m.residents().get(pid)
	if b == null:
		b = _m.peds().get(pid)
	if b == null or not is_instance_valid(b) or b.sitting or _m.off_map(b):
		return null
	return b


## Every 0.25 s.
func scan(delta: float):
	_engage_timer -= delta
	if _engage_timer > 0.0:
		return
	var dt: float = 0.25 - _engage_timer
	_engage_timer = 0.25
	var now: float = Time.get_ticks_msec() / 1000.0
	var pick := {}
	var world: Node3D = _m.world()
	if world == null:
		_engage_pick = pick
		return
	var reach: float = _m.npc_talk_radius + 4.0
	var inv: Basis = world.global_transform.basis.inverse()
	for pr in _engage_players():
		var who: String = pr[0]
		var node: Node3D = pr[1]
		var pos: Vector3 = world.to_local(node.global_position)
		var still: float = _update_stillness(who, pos, dt)
		var kind := "reply"
		var chosen := _engage_waiting(who, pos, reach, pick, now)
		if chosen == "":
			kind = "click"
			chosen = _engage_clicked(who, pos, reach, pick)
		if chosen == "" and still >= ENGAGE_STILL_S:
			kind = "stare"
			chosen = _engage_stare(who, node, pos, inv, pick)
		if chosen != "" and _engage_hold(chosen, who, kind, now):
			pick[chosen] = node
	for pid in _engage_state.keys():
		if not pick.has(pid):
			_engage_state.erase(pid)
	for k in _engage_cool.keys():
		if float(_engage_cool[k]) <= now:
			_engage_cool.erase(k)
	_engage_pick = pick


## [name, node] pairs.
func _engage_players() -> Array:
	var players: Array = []
	var seen := {}
	var me = _m.local_player()
	if me != null and is_instance_valid(me):
		players.append([str(me.name), me])
		seen[str(me.name)] = true
	for c in _m.remote_player_nodes():
		if not seen.has(str(c.name)):
			players.append([str(c.name), c])
			seen[str(c.name)] = true
	return players


## Within 0.4 units.
func _update_stillness(who: String, pos: Vector3, dt: float) -> float:
	var st: Dictionary = _engage_still.get(who, {"pos": pos, "t": 0.0})
	st["t"] = (float(st.t) + dt) if pos.distance_to(st.pos) < 0.4 else 0.0
	st["pos"] = pos
	_engage_still[who] = st
	return float(st.t)


## Drops waits that expired or whose person wandered off.
func _engage_waiting(who: String, pos: Vector3, reach: float, pick: Dictionary, now: float) -> String:
	for wpid in _engage_wait.keys():
		var w: Dictionary = _engage_wait[wpid]
		if float(w.until) <= now:
			print("[Ambient] %s gave up waiting to answer %s" % [wpid, w.who])
			_engage_wait.erase(wpid)
			continue
		if str(w.who) != who or pick.has(str(wpid)):
			continue
		var wb = _engage_body(str(wpid))
		if wb == null or wb.position.distance_to(pos) > reach * 1.5:
			_engage_wait.erase(wpid)
			continue
		return str(wpid)
	return ""


func _engage_clicked(who: String, pos: Vector3, reach: float, pick: Dictionary) -> String:
	var clicked := str(_addr_by_player.get(who, ""))
	if clicked == "" or pick.has(clicked):
		return ""
	var cb = _engage_body(clicked)
	if cb == null or cb.position.distance_to(pos) > reach:
		return ""
	_engage_cool.erase(clicked + "|" + who)
	return clicked


func _engage_stare(who: String, node: Node3D, pos: Vector3, inv: Basis, pick: Dictionary) -> String:
	var cm: Node3D = node.get_node_or_null("CharacterModel")
	var fwd: Vector3 = inv * (-(cm if cm != null else node).global_transform.basis.z)
	fwd.y = 0.0
	if fwd.length_squared() <= 0.001:
		return ""
	fwd = fwd.normalized()
	var best := {"pid": "", "d": _m.npc_talk_radius}
	var residents: Dictionary = _m.residents()
	for key in residents:
		_stare_consider(str(key), false, who, pos, fwd, pick, best)
	for key in _m.peds():
		if residents.has(key):
			continue
		_stare_consider(str(key), true, who, pos, fwd, pick, best)
	return best.pid


func _stare_consider(key: String, is_ped: bool, who: String, pos: Vector3, fwd: Vector3,
		pick: Dictionary, best: Dictionary):
	var b = _engage_body(key)
	if b == null or (is_ped and b.calling) or pick.has(key) or _engage_cool.has(key + "|" + who):
		return
	var d: Vector3 = b.position - pos
	d.y = 0.0
	var dist: float = d.length()
	if dist < 0.5 or dist >= float(best.d) or fwd.dot(d / dist) < cos(deg_to_rad(ENGAGE_STARE_DEG)):
		return
	best.d = dist
	best.pid = key


## False when the leash ran out: a look lasts ENGAGE_STARE_S, a click ENGAGE_CLICK_S after the last word.
func _engage_hold(chosen: String, who: String, kind: String, now: float) -> bool:
	var s: Dictionary = _engage_state.get(chosen, {})
	if str(s.get("who", "")) != who:
		s = {"who": who, "since": now, "kind": kind, "chat": 0.0}
		print("[Ambient] %s stops for %s (%s)" % [chosen, who, kind])
	elif str(s.get("kind", "")) != kind:
		print("[Ambient] %s held by %s: %s" % [chosen, who, kind])
	s["kind"] = kind
	var ref: float = float(s.since)
	var limit: float = ENGAGE_STARE_S
	if kind == "click" or float(s.chat) > float(s.since):
		ref = maxf(float(s.since), float(s.chat))
		limit = ENGAGE_CLICK_S
	if kind != "reply" and now - ref > limit:
		print("[Ambient] %s moves on from %s after %.0fs (%s)" % [chosen, who, now - ref, kind])
		_engage_cool[chosen + "|" + who] = now + ENGAGE_COOL_S
		_engage_state.erase(chosen)
		if kind == "click":
			_addr_by_player.erase(who)
		return false
	_engage_state[chosen] = s
	return true


## Goes to `to` when in reach, else to a class teacher, else the residents in earshot, else a pedestrian.
func on_player_chat(username: String, text: String, speaker: Node3D = null, to: String = ""):
	if not _m.is_authority() or text.strip_edges() == "" or text.begins_with("/"):
		return
	if speaker == null or not is_instance_valid(speaker):
		speaker = _m.player_by_id("u:" + username)
	if speaker == null or _m.world() == null:
		return
	var sp: Vector3 = _m.world().to_local(speaker.global_position)
	var now: float = Time.get_ticks_msec() / 1000.0
	for pid in _engage_state:
		if str(_engage_state[pid].get("who", "")) == username:
			_engage_state[pid]["chat"] = now
	if to != "" and _chat_to_named(username, text, sp, to):
		return
	if _chat_in_class(username, text, sp):
		return
	if _chat_to_residents(username, text, sp):
		return
	_chat_to_passerby(username, text, sp)


func _ped_heard(pid: String, body, username: String, text: String) -> Dictionary:
	return {"who": pid, "heard": "player:" + username, "text": text,
		"ped": true, "flag": str(body.flag_code), "voice": str(body.voice_id()),
		"at": _m.places.district_names_at(body.position)}


func _chat_to_named(username: String, text: String, sp: Vector3, to: String) -> bool:
	var residents: Dictionary = _m.residents()
	var tb = residents.get(to)
	if tb == null:
		tb = _m.peds().get(to)
	if tb == null or not is_instance_valid(tb) or _m.off_map(tb) \
			or tb.position.distance_to(sp) > (_m.npc_talk_radius + 4.0) * 1.5:
		return false
	_face_and_hold(tb, sp, 8.0)
	_await_reply(to, username)
	if residents.has(to):
		_m.observe({"who": to, "heard": "player:" + username, "text": text, "addressed": true,
			"voice": str(tb.voice_id()), "at": _m.places.district_names_at(tb.position)})
	else:
		_m.observe(_ped_heard(to, tb, username, text))
	return true


## True when the speaker is seated in a class.
func _chat_in_class(username: String, text: String, sp: Vector3) -> bool:
	for sch in _m.places.schools:
		if sch == null or not is_instance_valid(sch) or not sch.player_seated(username):
			continue
		var tp: String = sch.teacher_pid()
		var tb = _m.residents().get(tp)
		if tb != null and is_instance_valid(tb):
			_face_and_hold(tb, sp, 4.0)
			_await_reply(tp, username)
			_m.observe({"who": tp, "heard": "player:" + username, "text": text, "addressed": true,
				"voice": str(tb.voice_id()), "at": [sch.key()], "in_class": true})
		return true
	return false


## Only the nearest answers; false when nobody is in earshot.
func _chat_to_residents(username: String, text: String, sp: Vector3) -> bool:
	var listeners: Array = []
	var residents: Dictionary = _m.residents()
	for key in residents:
		var body = residents[key]
		if body == null or not is_instance_valid(body) or _m.off_map(body):
			continue
		var d: float = body.position.distance_to(sp)
		if d <= _m.npc_talk_radius + 4.0:
			listeners.append({"key": key, "body": body, "d": d})
	listeners.sort_custom(func(a, b): return a.d < b.d)
	for i in listeners.size():
		var l: Dictionary = listeners[i]
		var obs := {"who": l.key, "heard": "player:" + username, "text": text,
			"voice": str(l.body.voice_id()), "at": _m.places.district_names_at(l.body.position)}
		if i == 0:
			obs["addressed"] = true
			_face_and_hold(l.body, sp, 8.0)
			_await_reply(str(l.key), username)
		_m.observe(obs)
	return not listeners.is_empty()


func _chat_to_passerby(username: String, text: String, sp: Vector3):
	var best = null
	var best_d: float = _m.npc_talk_radius + 4.0
	var peds: Dictionary = _m.peds()
	for id in peds:
		var ped = peds[id]
		if ped == null or not is_instance_valid(ped) or ped.sitting or ped.calling:
			continue
		var d: float = ped.position.distance_to(sp)
		if d < best_d:
			best_d = d
			best = ped
	if best != null:
		_face_and_hold(best, sp, 8.0)
		_await_reply(str(best.ped_id), username)
		_m.observe(_ped_heard(str(best.ped_id), best, username, text))


func _face_and_hold(body, at_local: Vector3, seconds: float):
	if body.sitting or body.get("errand_owner") != null:
		return
	if body.has_method("enter_idle"):
		body.enter_idle()
		body.idle_timer = maxf(float(body.idle_timer), seconds)
	var cm = body.get("character_model")
	if cm != null:
		var d: Vector3 = at_local - body.position
		d.y = 0.0
		if d.length_squared() > 0.01:
			cm.rotation.y = atan2(d.x, d.z) + PI
