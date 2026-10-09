## The schoolyard and its pitch: breaks outside, yard duty, and the kickabout with its replicated ball.
class_name SchoolMatch
extends RefCounted

const YARD_CLIPS := ["res://assets/art/sound/city/school_yard_jp.mp3", "res://assets/art/sound/city/school_yard_gr.mp3"]
# The world node is scaled 0.2: 5 local units per metre.
const BALL_R := 0.9
const REACH := 2.4  # a body this close takes a free ball
const KICK_REACH := 3.4  # the player's E works this close
const GOAL_FRAC := 0.18  # goal mouth half-width, as a share of the pitch half-width
const RUN_MULT := 1.35
const BALL_G := 49.0  # local units
const PICKUP_SPEED := 45.0  # a ball faster than this is not caught, it passes

# SchoolYard marker; Pitch with a box CollisionShape3D.
var yard := Vector3.INF
var yard_fwd := Vector3.FORWARD  # the SchoolYard marker's facing: toward the building

var _s: AmbientSchool = null
var _m: AmbientManager = null
var _yard_gy := INF  # ground under the marker
var _spectators: Dictionary = {}  # pids watching from the touchline
var _wander_t: Dictionary = {}  # pid -> seconds until the next stroll
var _pitch_c := Vector3.INF
var _pitch_x := Vector3.RIGHT  # across the pitch (unit)
var _pitch_z := Vector3.FORWARD  # along the pitch, goal to goal (unit)
var _pitch_half := Vector2(30, 55)
var _match: Dictionary = {}  # authority: players, teams, the ball's flight
var _life_players: Array = []  # pids waiting for enough players to start a match

# Replicated.
var team_names: Array[String] = [Labels.text("team_white", "White"), Labels.text("team_red", "Red")]
var _kick_seq := 0  # counter: every change plays a kick on _kick_pid
var _kick_pid := ""
var _score := [0, 0]
var _ball_pos := Vector3.INF  # INF = no ball out
var _seen_kick := -1

# Every peer.
var _yard_player: AudioStreamPlayer3D = null
var _yard_clip_idx := -1
var _ball_node: MeshInstance3D = null


func _init(school: AmbientSchool, manager: AmbientManager):
	_s = school
	_m = manager


func find(w: Node3D):
	_find_yard(w)
	_find_pitch(w)


func _find_yard(w: Node3D):
	var node: Node3D = w.find_child("SchoolYard", true, false)
	if node == null:
		return
	yard = w.to_local(node.global_position)
	var f: Vector3 = -(w.global_transform.affine_inverse() * node.global_transform).basis.z
	f.y = 0.0
	if f.length_squared() > 0.001:
		yard_fwd = f.normalized()


## Its long side runs goal to goal.
func _find_pitch(w: Node3D):
	var pitch: Node3D = w.find_child("Pitch", true, false)
	if pitch == null:
		return
	var shape: CollisionShape3D = pitch.find_child("*", true, false) as CollisionShape3D
	if shape == null:
		for c in pitch.get_children():
			if c is CollisionShape3D:
				shape = c
	if shape == null or not shape.shape is BoxShape3D:
		return
	var gx: Transform3D = w.global_transform.affine_inverse() * shape.global_transform
	_pitch_c = gx.origin
	var size: Vector3 = (shape.shape as BoxShape3D).size
	var ax: Vector3 = gx.basis.x.normalized()
	var az: Vector3 = gx.basis.z.normalized()
	if size.x > size.z:
		_pitch_z = ax
		_pitch_x = az
		_pitch_half = Vector2(size.z * 0.5, size.x * 0.5)
	else:
		_pitch_z = az
		_pitch_x = ax
		_pitch_half = Vector2(size.x * 0.5, size.z * 0.5)
	_pitch_z.y = 0.0
	_pitch_x.y = 0.0
	_pitch_z = _pitch_z.normalized()
	_pitch_x = _pitch_x.normalized()


func has_yard() -> bool:
	return yard != Vector3.INF


func has_pitch() -> bool:
	return _pitch_c != Vector3.INF


func forget(pid: String):
	_spectators.erase(pid)
	_wander_t.erase(pid)


func clear_crowd():
	_spectators = {}
	_wander_t = {}


func clear_waiting():
	_life_players.clear()


## Up to ten who play take the pitch; the rest go to the yard.
func pe_time():
	var pupils: Array = _s.pupils_present()
	_s.clear_resident_seats()
	_s.outside = []
	_s.in_break = true
	end_match()
	_s.enrolled = pupils.duplicate()
	var players: Array = []
	for pid in pupils:
		if _s.life_controller.controlled(str(pid)):
			continue
		var b = _s.body_of(pid)
		if b == null:
			continue
		b.stand_up()
		b.set_prop("")
		b.set_emotion("")
		var def: Dictionary = _m.resident_def(pid)
		if bool(def.get("football", true)) and _pitch_c != Vector3.INF:
			players.append(pid)
		else:
			go_yard(b)
	players.shuffle()
	for pid in players.slice(10):
		var b = _s.body_of(pid)
		if b != null:
			go_yard(b)
	start_match(players.slice(0, 10), true)
	teacher_to_yard()
	if _s.resident_teacher():
		_m.observe({"who": _s.teacher_pid(), "did": "pe_lesson", "place": _s.key()})


## class_time brings them back to the lectern.
func teacher_to_yard():
	if _s.teacher_out or yard == Vector3.INF or not _s.resident_teacher():
		return
	var tb = _s.body_of(_s.teacher_pid())
	if tb == null:
		return
	_s.teacher_out = true
	var along: float = (float(_s.room_index()) - float(_s.room_count() - 1) * 0.5) * 4.0
	var spot: Vector3 = yard + Vector3(3.0, 0.0, 3.0 + along)
	if _pitch_c != Vector3.INF:
		var p := Vector2(-(_pitch_half.x + 4.0), along)
		spot = _pw(p, ground_at(_pw(p, _pitch_c.y), yard.y))
	tb.position = spot + Vector3.UP * _s.DROP
	tb.velocity = Vector3.ZERO
	tb.set_prop("")
	_s.hold(tb)
	if tb.character_model and _pitch_c != Vector3.INF:
		var d: Vector3 = _pw(Vector2.ZERO, spot.y) - spot
		tb.character_model.rotation.y = atan2(d.x, d.z) + PI
	_s.pin_intent(tb, spot)


## Where a player stepping out lands: the touchline, else the marker.
func entry_spot() -> Vector3:
	var spot: Vector3 = yard
	if _pitch_c != Vector3.INF:
		var p := Vector2(_pitch_half.x + 3.0, 0.0)
		spot = _pw(p, ground_at(_pw(p, _pitch_c.y), yard.y))
	return spot


# The ball is kinematic: the authority flies, bounces and rolls it, and replicates its position.

## x across, y goal to goal.
func _pl(v: Vector3) -> Vector2:
	var d: Vector3 = v - _pitch_c
	return Vector2(d.dot(_pitch_x), d.dot(_pitch_z))


func _pw(p: Vector2, y: float) -> Vector3:
	var out: Vector3 = _pitch_c + _pitch_x * p.x + _pitch_z * p.y
	out.y = y
	return out


func _on_pitch(p: Vector2, margin: float = 0.0) -> bool:
	return absf(p.x) <= _pitch_half.x + margin and absf(p.y) <= _pitch_half.y + margin


## Looks past bodies; `fallback` when nothing is hit.
func ground_at(p: Vector3, fallback: float) -> float:
	if not _s.is_inside_tree():
		return fallback
	var space: PhysicsDirectSpaceState3D = _s.get_viewport().world_3d.direct_space_state
	if space == null:
		return fallback
	var w: Node3D = _m.world()
	var q := PhysicsRayQueryParameters3D.create(w.to_global(p + Vector3.UP * 8.0), w.to_global(p - Vector3.UP * 14.0))
	q.collide_with_areas = false
	var excluded: Array[RID] = []
	for _try in 4:
		q.exclude = excluded
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			return fallback
		if not (hit.collider is CharacterBody3D or hit.collider is RigidBody3D):
			return w.to_local(hit.position).y
		excluded.append(hit.rid)
	return fallback


func _attack_dir(team: int) -> float:
	return 1.0 if team == 0 else -1.0


func _goal_of(team: int) -> Vector2:
	return Vector2(0.0, _pitch_half.y * _attack_dir(team))


## While a match is on, 60% watch from a touchline.
func go_yard(b):
	var rng: RandomNumberGenerator = _m.rng()
	var spot: Vector3
	var face_to := Vector3.INF
	if not _match.is_empty() and rng.randf() < 0.6:
		var side: float = -1.0 if rng.randf() < 0.5 else 1.0
		var p := Vector2(side * (_pitch_half.x + 2.5 + rng.randf() * 2.0), rng.randf_range(-0.6, 0.6) * _pitch_half.y)
		spot = _pw(p, ground_at(_pw(p, _pitch_c.y), yard.y))
		face_to = _pw(Vector2(0.0, p.y), spot.y)
	else:
		spot = yard + Vector3(rng.randf_range(-6.0, 6.0), 0.0, rng.randf_range(-6.0, 6.0))
	b.position = spot + Vector3.UP * _s.DROP
	b.velocity = Vector3.ZERO
	b.set_prop("")
	_s.stop_steering(b)
	if face_to != Vector3.INF:
		_spectators[str(b.ped_id)] = true
	else:
		_spectators.erase(str(b.ped_id))
		_wander_t[str(b.ped_id)] = rng.randf_range(1.0, 5.0)
	_s.hold(b)
	if face_to != Vector3.INF and b.character_model:
		var d: Vector3 = face_to - spot
		b.character_model.rotation.y = atan2(d.x, d.z) + PI
	_s.pin_intent(b, spot)
	_s.outside.append(str(b.ped_id))
	_m.observe({"who": str(b.ped_id), "did": "yard_break", "place": _s.key()})


func yard_tick(delta: float):
	if yard == Vector3.INF or _s.assembly_.active():
		return
	if _yard_gy == INF:
		_yard_gy = ground_at(yard, yard.y)
	var rng: RandomNumberGenerator = _m.rng()
	for pid in _s.outside:
		if _spectators.has(pid) or playing(pid) or pid == _s.teacher_pid() or _s.life_controller.occupies(str(pid)):
			continue
		var b = _s.body_of(pid)
		if b == null:
			continue
		if b.steer_to != Vector3.INF:
			var flat: Vector3 = b.steer_to - b.position
			flat.y = 0.0
			if flat.length() < 1.2:
				b.steer_to = Vector3.INF  # arrived: stand a while
				_wander_t[pid] = rng.randf_range(6.0, 18.0)
			continue
		_wander_t[pid] = float(_wander_t.get(pid, rng.randf_range(2.0, 10.0))) - delta
		if float(_wander_t[pid]) > 0.0:
			continue
		_wander_t[pid] = rng.randf_range(6.0, 18.0)
		_start_stroll(b, rng)


## Up to eight tries, 4-24 units from the marker.
func _start_stroll(b, rng: RandomNumberGenerator):
	for _try in 8:
		var ang: float = rng.randf() * TAU
		var r: float = rng.randf_range(4.0, 24.0)
		var p: Vector3 = yard + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		if _pitch_c != Vector3.INF and _on_pitch(_pl(p), 4.0):
			continue
		var gy: float = ground_at(p, INF)
		if gy == INF or absf(gy - _yard_gy) > 2.5:
			continue
		p.y = b.position.y
		b.steer_speed = b.walk_speed * 0.75
		b.steer_to = p
		return


## Room 0 only, so the school is heard from the street; the clips take turns per break.
func yard_sound_tick():
	var want: bool = _s.in_break and not _s.assembly_.active() and yard != Vector3.INF and _s.room_index() == 0
	if _yard_player == null or not is_instance_valid(_yard_player):
		if not want:
			return
		_yard_player = _s.make_player(240.0, 16.0, yard)
		_yard_player.volume_db = -4.0
	if want and not _yard_player.playing:
		_yard_clip_idx = (_yard_clip_idx + 1) % YARD_CLIPS.size()
		var stream = load(YARD_CLIPS[_yard_clip_idx])
		if stream != null:
			stream = stream.duplicate()
			if "loop" in stream:
				stream.loop = true
			_yard_player.stream = stream
			_yard_player.play()
	elif not want and _yard_player.playing:
		_yard_player.stop()


## With fewer than four, no pitch, or another room's turn (outside PE), they go to the yard.
func start_match(pids: Array, own_period := false):
	if _pitch_c == Vector3.INF or pids.size() < 4 or (not own_period and not _m.pitch_turn(_s)):
		for pid in pids:
			var b = _s.body_of(pid)
			if b != null:
				go_yard(b)
		return
	var rng: RandomNumberGenerator = _m.rng()
	pids = pids.duplicate()
	pids.shuffle()
	pids = pids.slice(0, 10)
	var team: Dictionary = {}
	var count := [0, 0]
	for pid in pids:
		var t := _pick_team(pid, team, count)
		team[pid] = t
		count[t] += 1
	var gy: float = ground_at(_pitch_c, yard.y if yard != Vector3.INF else _pitch_c.y)
	_match = {"players": pids, "team": team, "base": {}, "keeper": ["", ""], "speed": {},
		"humans": {}, "hteam": {}, "state": "dead", "holder": "", "holder_t": 0.0, "plan_t": 0.0,
		"pos": _pw(Vector2.ZERO, gy + BALL_R), "vel": Vector3.ZERO, "gy": gy,
		"last_team": -1, "possess": rng.randi_range(0, 1), "dead_t": 1.5, "chaser": "",
		"shout_cd": 2.0, "move_t": {}, "scan_t": 0.0, "start_msec": Time.get_ticks_msec()}
	_score = [0, 0]
	_ball_pos = _match.pos
	for t in 2:
		var side: Array = pids.filter(func(p): return int(team[p]) == t)
		for i in side.size():
			var pid: String = str(side[i])
			if i == 0 and side.size() >= 3:
				_match.keeper[t] = pid
			_match.base[pid] = _pw(_base_spot(t, i, side.size()), gy)
			var b = _s.body_of(pid)
			if b != null:
				_line_up(b, pid, t)
	print("[School] kickabout: %s %d v %s %d" % [team_names[0], count[0], team_names[1], count[1]])


## A friend's side if it is not ahead and has room, else the smaller one.
func _pick_team(pid: String, team: Dictionary, count: Array) -> int:
	var def: Dictionary = _m.resident_def(pid)
	for f in def.get("friends", []):
		var fp := "r_" + str(f)
		if team.has(fp) and count[team[fp]] <= count[1 - team[fp]] and count[team[fp]] < 5:
			return team[fp]
	var t: int = 0 if count[0] <= count[1] else 1
	if count[t] >= 5:
		t = 1 - t
	return t


## With three or more, the first keeps goal; the rest in two loose rows on their own half.
func _base_spot(t: int, i: int, n_side: int) -> Vector2:
	var own: float = -_attack_dir(t)
	var has_keeper: bool = n_side >= 3
	if i == 0 and has_keeper:
		return Vector2(0.0, own * (_pitch_half.y - 5.0))
	var j: int = i - (1 if has_keeper else 0)
	var n: int = n_side - (1 if has_keeper else 0)
	var across: float = lerpf(-0.5, 0.5, (float(j) + 0.5) / maxf(float(n), 1.0)) * _pitch_half.x
	var depth: float = (0.2 + 0.3 * float(j % 2)) * _pitch_half.y
	return Vector2(across, own * depth)


func _line_up(b, pid: String, t: int):
	var spot: Vector3 = _match.base[pid]
	b.position = spot + Vector3.UP * _s.DROP
	b.velocity = Vector3.ZERO
	b.set_prop("")
	b.set_emotion("happy")
	b.personal_space = false
	b.steer_speed = b.walk_speed * RUN_MULT
	b.steer_to = spot
	_s.hold(b)
	_s.pin_intent(b, spot)
	_s.outside.append(pid)
	_m.observe({"who": pid, "did": "football", "place": _s.key(), "team": team_names[t]})


func end_match():
	if _match.is_empty():
		return
	var sc := "%s %d - %d %s" % [team_names[0], int(_score[0]), int(_score[1]), team_names[1]]
	var players: Array = _match.players
	for pid in players:
		var b = _s.body_of(pid)
		if b != null:
			b.set_emotion("")
			b.personal_space = true
			_s.stop_steering(b)
		_m.observe({"who": pid, "did": "match_end", "place": _s.key(), "score": sc,
			"team": team_names[int(_match.team.get(pid, 0))]})
	if not players.is_empty():
		_shout(_s.body_of(players[_m.rng().randi_range(0, players.size() - 1)]), "fb_gg", true)
	print("[School] kickabout ends " + sc)
	_match = {}
	_ball_pos = Vector3.INF


## Joins the smaller side (up to ten), or waits until four want to play.
func join_game(pid: String) -> bool:
	if not _s.in_break or _pitch_c == Vector3.INF:
		return false
	if playing(pid):
		return true
	if _match.is_empty():
		if not _life_players.has(pid):
			_life_players.append(pid)
		if _life_players.size() >= 4:
			start_match(_life_players.duplicate())
			_life_players.clear()
		return true
	if _match.players.size() >= 10:
		return false
	var b = _s.body_of(pid)
	if b == null:
		return false
	var counts := [0, 0]
	for player in _match.players:
		counts[int(_match.team[player])] += 1
	var side := 0 if counts[0] <= counts[1] else 1
	_match.players.append(pid)
	_match.team[pid] = side
	var spot: Vector3 = _pw(Vector2(0.0, -_attack_dir(side) * _pitch_half.y * 0.3), float(_match.gy))
	_match.base[pid] = spot
	b.position = spot + Vector3.UP * _s.DROP
	b.velocity = Vector3.ZERO
	b.personal_space = false
	b.steer_to = spot
	b.steer_speed = b.walk_speed * RUN_MULT
	if not _s.outside.has(pid):
		_s.outside.append(pid)
	_s.pin_intent(b, spot)
	_m.observe({"who": pid, "did": "football", "place": _s.key(), "team": team_names[side]})
	return true


## The keeper is replaced, a ball they had goes dead to the other side; under two players it ends.
func leave_game(pid: String):
	_life_players.erase(pid)
	if _match.is_empty() or not _match.players.has(pid):
		return
	var side := int(_match.team[pid])
	_match.players.erase(pid)
	for field in ["team", "base", "speed", "move_t"]:
		_match[field].erase(pid)
	if str(_match.keeper[side]) == pid:
		var remaining: Array = _match.players.filter(func(p): return int(_match.team[p]) == side)
		_match.keeper[side] = remaining[0] if remaining.size() >= 3 else ""
	if str(_match.holder) == pid or str(_match.chaser) == pid:
		_match.chaser = ""
		_dead_ball(_pl(_match.pos), 1 - side, 1.0)
	var b = _s.body_of(pid)
	if b != null:
		_s.stop_steering(b)
		b.personal_space = true
	_m.observe({"who": pid, "did": "left_game", "place": _s.key()})
	if _match.players.size() < 2:
		end_match()


func playing(pid: String) -> bool:
	return not _match.is_empty() and (_match.players.has(pid) or _match.humans.has(pid))


## One voice at a time unless forced.
func _shout(b, line: String, force := false):
	if b == null or _match.is_empty():
		return
	if not force and float(_match.shout_cd) > 0.0:
		return
	_match.shout_cd = 3.5
	_m.resident_say(b, {"line": line, "secs": 2.5})


func _kick_anim(pid: String):
	_kick_seq += 1
	_kick_pid = pid
	_seen_kick = _kick_seq
	var b = _s.body_of(pid)
	if b != null and b.has_method("kick"):
		b.kick()


## INF if gone.
func _body_pos(pid: String) -> Vector3:
	var b = _s.body_of(pid)
	if b == null:
		return Vector3.INF
	return _m.world().to_local(b.global_position) if pid.begins_with("u:") else b.position


## The model faces -Z.
func _facing(b) -> Vector3:
	if b == null or b.get("character_model") == null:
		return _pitch_z
	var yaw: float = b.character_model.rotation.y
	return -Vector3(sin(yaw), 0.0, cos(yaw))


func _face(b, to: Vector3, delta: float, rate: float = 5.0):
	if b == null or b.get("character_model") == null:
		return
	var d: Vector3 = to - b.position
	d.y = 0.0
	if d.length_squared() > 0.04:
		b.character_model.rotation.y = lerp_angle(b.character_model.rotation.y, atan2(d.x, d.z) + PI, minf(delta * rate, 1.0))


## Clamped inside the pitch; closer than min_gap they stop.
func _move(pid: String, to: Vector3, delta: float, min_gap: float = 2.5):
	var b = _s.body_of(pid)
	if b == null:
		return
	var p: Vector2 = _pl(to)
	p.x = clampf(p.x, -_pitch_half.x + 1.5, _pitch_half.x - 1.5)
	p.y = clampf(p.y, -_pitch_half.y + 1.5, _pitch_half.y - 1.5)
	to = _pw(p, b.position.y)
	var flat: Vector3 = to - b.position
	flat.y = 0.0
	if flat.length() < min_gap:
		b.steer_to = b.position
		return
	b.steer_to = to


func _kick_ball(pid: String, to: Vector2, shot: bool):
	var from: Vector2 = _pl(_match.pos)
	var d: float = from.distance_to(to)
	var dir: Vector3 = (_pw(to, 0.0) - _pw(from, 0.0)).normalized()
	var speed: float
	var up: float
	if shot:
		speed = 70.0
		up = 10.0 + _m.rng().randf() * 8.0
	else:
		speed = clampf(d * 1.6 + 15.0, 25.0, 60.0)
		up = minf(6.0 + d * 0.25, 16.0) + _m.rng().randf() * 3.0
	_match.vel = dir * speed + Vector3.UP * up
	_match.pos.y = float(_match.gy) + BALL_R + 0.1
	_match.state = "free"
	_match.holder = ""
	_match.possess = -1
	_match.last_team = int(_match.team.get(pid, _match.humans.get(pid, -1)))
	_match.last_kick = pid
	_match.was_shot = shot
	_match.chaser = ""
	_kick_anim(pid)


## Dead for `secs`, then free for the side that gets it.
func _dead_ball(at: Vector2, possess: int, secs: float):
	_match.state = "dead"
	_match.dead_t = secs
	_match.possess = possess
	_match.holder = ""
	_match.chaser = ""
	_match.vel = Vector3.ZERO
	_match.pos = _pw(at, float(_match.gy) + BALL_R)


## Players on the pitch are in, those off it out; one who comes back keeps their side.
func _scan_humans():
	var humans: Dictionary = _match.humans
	var cands: Array = []
	var lp = _s.my_body()
	if lp != null:
		cands.append(lp)
	var players = _m.world().get_node_or_null("Players")
	if players != null:
		for c in players.get_children():
			if c is Node3D and c != lp:
				cands.append(c)
	var seen := {}
	for c in cands:
		var pid := "u:" + str(c.name)
		seen[pid] = true
		var on: bool = _on_pitch(_pl(_m.world().to_local(c.global_position)), 1.0)
		if on and not humans.has(pid):
			var t: int = _human_team(pid, humans)
			humans[pid] = t
			_match.hteam[pid] = t
			print("[School] %s joins the kickabout on %s" % [pid, team_names[t]])
		elif not on and humans.has(pid):
			humans.erase(pid)
	for pid in humans.keys():
		if not seen.has(pid):
			humans.erase(pid)


func _human_team(pid: String, humans: Dictionary) -> int:
	if _match.hteam.has(pid):
		return int(_match.hteam[pid])
	var cnt := [0, 0]
	for p in _match.players:
		cnt[int(_match.team[p])] += 1
	for h in humans:
		cnt[int(humans[h])] += 1
	return 0 if cnt[0] <= cnt[1] else 1


func _team_of(pid: String) -> int:
	return int(_match.team.get(pid, _match.humans.get(pid, -1)))


func _side(team: int, same: bool) -> Array:
	var out: Array = []
	for p in _match.players:
		if (int(_match.team[p]) == team) == same:
			out.append(p)
	for h in _match.humans:
		if (int(_match.humans[h]) == team) == same:
			out.append(h)
	return out


## [pid, distance] on the ground plane.
func _nearest_of(pids: Array, to: Vector3, exclude: String = "") -> Array:
	var best := ""
	var best_d := INF
	for p in pids:
		if p == exclude:
			continue
		var bp: Vector3 = _body_pos(p)
		if bp == Vector3.INF:
			continue
		var d: float = Vector2(bp.x, bp.z).distance_to(Vector2(to.x, to.z))
		if d < best_d:
			best_d = d
			best = p
	return [best, best_d]


## Everyone, or the residents of the side it was given to.
func _takers() -> Array:
	if int(_match.possess) < 0:
		return _match.players
	return _side(int(_match.possess), true).filter(func(p): return not p.begins_with("u:"))


func _decide(pid: String):
	var rng: RandomNumberGenerator = _m.rng()
	var team: int = _team_of(pid)
	var hp: Vector3 = _body_pos(pid)
	var here: Vector2 = _pl(hp)
	var goal: Vector2 = _goal_of(team)
	var goal_half: float = _pitch_half.x * GOAL_FRAC
	var mates: Array = _side(team, true)
	var opps: Array = _side(team, false)
	var pressure: float = float(_nearest_of(opps, hp)[1])
	var is_keeper: bool = _match.keeper.has(pid)
	var dgoal: float = here.distance_to(goal)
	if not is_keeper and dgoal < 0.45 * _pitch_half.y and rng.randf() < (0.7 if dgoal < 0.25 * _pitch_half.y else 0.45):
		# Aimed inside the posts, not always well.
		var aim: Vector2 = goal + Vector2(rng.randf_range(-1.35, 1.35) * goal_half, 0.0)
		_kick_ball(pid, aim, true)
		return
	var must_pass: bool = is_keeper or pressure < 7.0 or rng.randf() < 0.55
	if must_pass and mates.size() > 0:
		var best: String = _best_pass(pid, team, here, mates, opps, rng)
		if best != "":
			var mp: Vector2 = _pl(_body_pos(best))
			mp.y += _attack_dir(team) * rng.randf_range(1.0, 4.0)  # into the space ahead of them
			if rng.randf() < 0.3 and not best.begins_with("u:"):
				_shout(_s.body_of(best), "fb_here")
			_kick_ball(pid, mp, false)
			return
		if is_keeper:
			_kick_ball(pid, Vector2(rng.randf_range(-0.4, 0.4) * _pitch_half.x, _attack_dir(team) * 0.3 * _pitch_half.y), false)
			return
	var run: Vector2 = here + (goal - here).normalized() * rng.randf_range(6.0, 11.0) + Vector2(rng.randf_range(-4.0, 4.0), 0.0)
	_match.plan_t = rng.randf_range(1.2, 2.4)
	_match.dribble_to = _pw(run, hp.y)
	_move(pid, _match.dribble_to, 1.0, 1.0)


## "" if none. Ahead and unmarked score well, distance badly; a human mate is favoured.
func _best_pass(pid: String, team: int, here: Vector2, mates: Array, opps: Array,
		rng: RandomNumberGenerator) -> String:
	var best := ""
	var best_s := -INF
	for m in mates:
		if m == pid:
			continue
		var mp: Vector3 = _body_pos(m)
		if mp == Vector3.INF:
			continue
		var ml: Vector2 = _pl(mp)
		var d: float = here.distance_to(ml)
		if d < 4.0 or d > 0.9 * _pitch_half.y:
			continue
		var ahead: float = (ml.y - here.y) * _attack_dir(team)
		var open: float = minf(float(_nearest_of(opps, mp)[1]), 12.0)
		var s: float = ahead * 0.6 + open * 1.2 - d * 0.25 + rng.randf() * 4.0
		if m.begins_with("u:"):
			s += 6.0
		if _match.keeper.has(m):
			s -= 8.0
		if s > best_s:
			best_s = s
			best = m
	return best


func kick_tick(delta: float):
	if _match.is_empty():
		return
	_match.shout_cd = float(_match.shout_cd) - delta
	_match.scan_t = float(_match.scan_t) - delta
	if float(_match.scan_t) <= 0.0:
		_match.scan_t = 0.5
		_scan_humans()
		_drop_strays()
		if _match.players.size() < 2:
			end_match()
			return
	var pos: Vector3 = _match.pos
	_match.gy = ground_at(pos, float(_match.gy))
	match str(_match.state):
		"dead":
			_match.dead_t = float(_match.dead_t) - delta
			if float(_match.dead_t) <= 0.0:
				_match.state = "free"
				_match.vel = Vector3.ZERO
				_match.possess_t = 8.0
		"held":
			_ball_held_tick(delta)
		"free":
			_ball_free_tick(delta)
	_ball_pos = _match.pos
	_players_tick(delta)


func _drop_strays():
	for p in _match.players.duplicate():
		var bp: Vector3 = _body_pos(p)
		var pb = _s.body_of(p)
		if pb != null and bp != Vector3.INF:
			_s.pin_intent(pb, bp)
		if bp != Vector3.INF and _on_pitch(_pl(bp), 12.0):
			continue
		_match.players.erase(p)
		if pb != null:
			_s.stop_steering(pb)
		if _match.holder == p:
			_match.holder = ""
			_match.state = "free"


func _ball_held_tick(delta: float):
	var hb = _s.body_of(_match.holder)
	if hb == null or str(_match.holder).begins_with("u:"):
		_match.state = "free"
		return
	var gy: float = float(_match.gy)
	_match.holder_t = float(_match.holder_t) + delta
	_match.plan_t = float(_match.plan_t) - delta
	var feet: Vector3 = hb.position + _facing(hb) * 1.4
	_match.pos = Vector3(feet.x, gy + BALL_R, feet.z)
	if not _on_pitch(_pl(hb.position), -1.0):
		_match.plan_t = 0.0
	if float(_match.plan_t) <= 0.0 or (float(_match.holder_t) > 0.4
			and float(_nearest_of(_side(_team_of(_match.holder), false), hb.position)[1]) < 6.0):
		_match.holder_t = 0.0
		_decide(_match.holder)
	elif _match.has("dribble_to"):
		_move(_match.holder, _match.dribble_to, delta, 1.0)


func _ball_free_tick(delta: float):
	var gy: float = float(_match.gy)
	var pos: Vector3 = _match.pos
	var vel: Vector3 = _match.vel
	vel.y -= BALL_G * delta
	pos += vel * delta
	if pos.y <= gy + BALL_R:
		pos.y = gy + BALL_R
		if vel.y < -2.0:
			vel.y = -vel.y * 0.42
			vel.x *= 0.75
			vel.z *= 0.75
		else:
			vel.y = 0.0
			var f: float = maxf(1.0 - 1.4 * delta, 0.0)
			vel.x *= f
			vel.z *= f
			if Vector2(vel.x, vel.z).length() < 0.4:
				vel = Vector3.ZERO
	_match.vel = vel
	_match.pos = pos
	if int(_match.possess) >= 0:
		_match.possess_t = float(_match.get("possess_t", 8.0)) - delta
		if float(_match.possess_t) <= 0.0:
			_match.possess = -1
	var pl: Vector2 = _pl(pos)
	var last_pid: String = str(_match.get("last_kick", ""))
	if absf(pl.y) > _pitch_half.y:
		_ball_over_goal_line(pl, pos.y - gy, last_pid)
	elif absf(pl.x) > _pitch_half.x:
		_ball_over_touchline(pl, last_pid)
	else:
		_try_pickup(pos, vel, gy, last_pid)


## A goal if inside the posts, low, and last touched by the attackers; otherwise a ball out.
func _ball_over_goal_line(pl: Vector2, height: float, last_pid: String):
	var rng: RandomNumberGenerator = _m.rng()
	var goal_half: float = _pitch_half.x * GOAL_FRAC
	var end_sign: float = signf(pl.y)
	var scoring: int = 0 if end_sign > 0.0 else 1
	if absf(pl.x) < goal_half and height < 5.0 and int(_match.last_team) == scoring:
		_score_goal(scoring, last_pid)
		return
	var resident_kicker: bool = last_pid != "" and not last_pid.begins_with("u:")
	if bool(_match.get("was_shot", false)) and absf(pl.x) < goal_half * 2.5 and resident_kicker:
		_shout(_s.body_of(last_pid), "fb_close")
	elif resident_kicker and rng.randf() < 0.4:
		_shout(_s.body_of(last_pid), "fb_sorry")
	var t: int = int(_match.last_team)
	_dead_ball(Vector2(clampf(pl.x, -_pitch_half.x + 3.0, _pitch_half.x - 3.0), end_sign * (_pitch_half.y - 3.0)),
		(1 - t) if t >= 0 else rng.randi_range(0, 1), 1.5)


func _score_goal(scoring: int, last_pid: String):
	var rng: RandomNumberGenerator = _m.rng()
	_score[scoring] = int(_score[scoring]) + 1
	print("[School] GOAL %s — %s %d - %d %s" % [team_names[scoring], team_names[0], int(_score[0]),
			int(_score[1]), team_names[1]])
	if last_pid != "":
		_m.observe({"who": last_pid, "did": "goal", "place": _s.key(),
			"score": "%d-%d" % [int(_score[0]), int(_score[1])]})
	var side: Array = _side(scoring, true).filter(func(p): return not p.begins_with("u:"))
	for p in side:
		var b = _s.body_of(p)
		if b != null:
			b.set_emotion("happy")
	if not side.is_empty():
		_shout(_s.body_of(side[rng.randi_range(0, side.size() - 1)]), "fb_goal", true)
	_dead_ball(Vector2.ZERO, 1 - scoring, 4.0)


func _ball_over_touchline(pl: Vector2, last_pid: String):
	var rng: RandomNumberGenerator = _m.rng()
	var t: int = int(_match.last_team)
	if last_pid != "" and not last_pid.begins_with("u:") and rng.randf() < 0.4:
		_shout(_s.body_of(last_pid), "fb_sorry")
	_dead_ball(Vector2(signf(pl.x) * (_pitch_half.x - 3.0), clampf(pl.y, -_pitch_half.y + 3.0, _pitch_half.y - 3.0)),
		(1 - t) if t >= 0 else rng.randi_range(0, 1), 1.5)


func _try_pickup(pos: Vector3, vel: Vector3, gy: float, last_pid: String):
	var rng: RandomNumberGenerator = _m.rng()
	var near: Array = _nearest_of(_takers(), pos)
	if str(near[0]) == "" or float(near[1]) >= REACH or pos.y - gy >= 3.0 \
			or Vector2(vel.x, vel.z).length() >= PICKUP_SPEED:
		return
	_match.state = "held"
	_match.holder = str(near[0])
	_match.holder_t = 0.0
	_match.plan_t = rng.randf_range(0.3, 0.9)
	_match.possess = -1
	_match.erase("dribble_to")
	var hb = _s.body_of(_match.holder)
	if hb != null:
		hb.steer_to = hb.position
	if last_pid != "" and last_pid != str(near[0]) and _team_of(last_pid) == _team_of(str(near[0])) \
			and rng.randf() < 0.25:
		_shout(_s.body_of(str(near[0])), "fb_nice")


func _players_tick(delta: float):
	var free: bool = str(_match.state) == "free" or str(_match.state) == "dead"
	if free:
		var allowed: Array = _takers()
		var landing: Vector3 = _match.pos + Vector3(_match.vel.x, 0.0, _match.vel.z) * 0.5
		var field: Array = allowed.filter(func(p): return not _match.keeper.has(p))
		var near: Array = _nearest_of(field if not field.is_empty() else allowed, landing)
		_match.chaser = str(near[0])
	for pid in _match.players:
		var b = _s.body_of(pid)
		if b == null:
			continue
		b.idle_timer = _s.IDLE_FOREVER
		var t: int = int(_match.team[pid])
		if pid == str(_match.holder):
			continue
		if _match.keeper.has(pid):
			_move(pid, _keeper_target(b, t, free), delta, 1.6)
		elif free and pid == str(_match.chaser):
			_move(pid, _match.pos + Vector3(_match.vel.x, 0.0, _match.vel.z) * 0.5, delta, 1.2)
		else:
			_move(pid, _field_target(pid, b, t), delta, 4.0)
		if Vector2(b.velocity.x, b.velocity.z).length() < 2.0:
			_face(b, _match.pos, delta)


func _keeper_target(b, t: int, free: bool) -> Vector3:
	var goal_half: float = _pitch_half.x * GOAL_FRAC
	var own: float = -_attack_dir(t)
	var bl: Vector2 = _pl(_match.pos)
	var box: bool = absf(bl.y - own * _pitch_half.y) < 0.22 * _pitch_half.y and absf(bl.x) < goal_half * 2.0
	if free and box and int(_match.possess) != 1 - t:
		return _match.pos
	return _pw(Vector2(clampf(bl.x * 0.7, -goal_half, goal_half), own * (_pitch_half.y - 4.0)), b.position.y)


func _field_target(pid: String, b, t: int) -> Vector3:
	var base: Vector3 = _match.base.get(pid, b.position)
	var spot: Vector2 = _pl(base).lerp(_pl(_match.pos), 0.35)
	var has_it: bool = str(_match.state) == "held" and _team_of(str(_match.holder)) == t
	spot.y += _attack_dir(t) * (6.0 if has_it else -4.0)
	return _pw(spot, b.position.y)


## Aimed into the goal mouth it is a shot, otherwise a 22-unit pass.
func human_kick(pid: String):
	if _match.is_empty():
		return
	var hp: Vector3 = _body_pos(pid)
	if hp == Vector3.INF:
		return
	var flat: Vector3 = _match.pos - hp
	flat.y = 0.0
	if flat.length() > KICK_REACH or str(_match.state) == "dead":
		return
	if not _match.humans.has(pid):
		_scan_humans()
		if not _match.humans.has(pid):
			return
	var team: int = int(_match.humans[pid])
	var dir: Vector2 = Vector2(flat.dot(_pitch_x), flat.dot(_pitch_z)).normalized()
	if dir.length_squared() < 0.01:
		dir = Vector2(0.0, _attack_dir(team))
	var here: Vector2 = _pl(_match.pos)
	var goal: Vector2 = _goal_of(team)
	var shot := false
	if dir.y * _attack_dir(team) > 0.3:
		var k: float = (goal.y - here.y) / dir.y  # distance along dir to the goal line
		var x_at: float = here.x + dir.x * k
		shot = absf(x_at) < _pitch_half.x * GOAL_FRAC * 1.2 and k < 0.6 * _pitch_half.y
	var to: Vector2 = here + dir * (0.6 * _pitch_half.y if shot else 22.0)
	if str(_match.state) == "held":
		var hb = _s.body_of(_match.holder)
		if hb != null:
			_s.hold(hb)
	_kick_ball(pid, to, shot)


## The "ball", "sc", "dbg" and "kk" keys of the school's snapshot, in that order.
func write_snapshot(snap: Dictionary):
	if _ball_pos != Vector3.INF:
		snap["ball"] = [snappedf(_ball_pos.x, 0.01), snappedf(_ball_pos.y, 0.01), snappedf(_ball_pos.z, 0.01)]
		snap["sc"] = [int(_score[0]), int(_score[1])]
		if not _match.is_empty():
			var hp: Vector3 = _body_pos(str(_match.holder)) if str(_match.holder) != "" else Vector3.INF
			snap["dbg"] = [str(_match.state), str(_match.holder), snappedf(_match.gy, 0.01),
				[snappedf(hp.x, 0.1), snappedf(hp.y, 0.1), snappedf(hp.z, 0.1)] if hp != Vector3.INF else null]
	if _kick_seq > 0:
		snap["kk"] = [_kick_seq, _kick_pid]


## `first`: the baseline snapshot, whose kick is not replayed.
func apply_snapshot(data: Dictionary, first: bool):
	var ball = data.get("ball", null)
	var has_ball: bool = typeof(ball) == TYPE_ARRAY and ball.size() >= 3
	_ball_pos = Vector3(float(ball[0]), float(ball[1]), float(ball[2])) if has_ball else Vector3.INF
	var sc = data.get("sc", null)
	if typeof(sc) == TYPE_ARRAY and sc.size() >= 2:
		_score = [int(sc[0]), int(sc[1])]
	var kk = data.get("kk", null)
	if typeof(kk) == TYPE_ARRAY and kk.size() >= 2:
		_kick_seq = int(kk[0])
		_kick_pid = str(kk[1])
	if first:
		_seen_kick = _kick_seq


## The authority already did.
func kick_cue():
	if _kick_seq != _seen_kick:
		if _seen_kick >= 0 and not _m.is_authority():
			var kb = _s.body_of(_kick_pid)
			if kb != null and kb.has_method("kick"):
				kb.kick()
		_seen_kick = _kick_seq


func render_ball(delta: float):
	if _ball_pos == Vector3.INF:
		if _ball_node != null and is_instance_valid(_ball_node):
			_ball_node.visible = false
		return
	if _ball_node == null or not is_instance_valid(_ball_node):
		_ball_node = MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = BALL_R
		sm.height = BALL_R * 2.0
		_ball_node.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.95, 0.95, 0.9)
		_ball_node.material_override = mat
		_m.container().add_child(_ball_node)
		_ball_node.position = _ball_pos
	_ball_node.visible = true
	_ball_node.position = _ball_node.position.lerp(_ball_pos, minf(delta * 12.0, 1.0))
	_ball_node.rotate_y(delta * 3.0)


func kick_prompt(my_pos: Vector3) -> bool:
	return _ball_pos != Vector3.INF and Vector2(my_pos.x, my_pos.z).distance_to(Vector2(_ball_pos.x, _ball_pos.z)) < KICK_REACH


## "" when there is no ball out or the player is far from the pitch.
func scoreboard(my_pos: Vector3) -> String:
	var near_pitch: bool = _ball_pos != Vector3.INF and _pitch_c != Vector3.INF \
			and Vector2(my_pos.x, my_pos.z).distance_to(Vector2(_pitch_c.x, _pitch_c.z)) < _pitch_half.y + 40.0
	if not near_pitch:
		return ""
	return "%s %d  -  %d %s" % [team_names[0], int(_score[0]), int(_score[1]), team_names[1]]
