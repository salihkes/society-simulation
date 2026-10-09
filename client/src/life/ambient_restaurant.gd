extends Node3D

## An ambient restaurant: invites passers-by, sends its waiter to take orders and serve, and lets players dine.

const WAITER_SCRIPT := "res://src/life/restaurant_waiter.gd"
const DialogRegistry := preload("res://src/life/dialog/dialog_registry.gd")
const LimbRigScript := preload("res://src/character/limb_rig.gd")

## Replicated as ints: append new ones at the end.
enum Phase { EMPTY, COMING, SEATED, ASKING, ORDERED, COOKING, DELIVERING, EATING, RECOMMEND }

## Dish i speaks registry lines <dialog_prefix>_order_<i>, _serve_<i> and _usual_<i>.
const DISH_COUNT := 6
const RECOMMEND_DISH := 5
const TABLE_CONVS: Array = ["table_weather", "table_food"]
const SEAT_COOLDOWN := 20.0

@export var open_hour := 11.0
@export var close_hour := 23.5
## Seconds, roughly.
@export var invite_min := 15.0
@export var invite_max := 40.0
## Workspace units.
@export var invite_radius := 350.0
## Chance an invitation is for a pair who eat (and chat) together.
@export var pair_chance := 0.5
@export var recommend_chance := 0.25
@export var compliment_chance := 0.4
## Its tables append after the terrace seats, so existing seat indices stay valid.
@export var indoor_layout_path: NodePath
## Prefix of this restaurant's dialog registry lines.
@export var dialog_prefix := ""

var _indoor_layout = null
var _registering := false
var _manager = null
var _waiter_key := ""
var _seats: Array = []  # see _new_seat
var _food_template: Node3D = null
var _kitchen := Vector3.INF  # workspace-local; also the waiter's station
var _invite_timer := 10.0
var _tick := 0.0
var _carry: Node3D = null
var _task_queue: Array = []  # ["ask:0", "pickup:3", ...]
## Session-scoped: diner id -> their last dish, for "the usual".
var _regulars: Dictionary = {}
var _player_greet_cd := 0.0
var _waiter_hold := 0.0

var _ui: CanvasLayer = null
var _prompt: Label = null
var _menu: PanelContainer = null
var _prompt_action := ""
var _menu_dismissed := false
var _key_cd := 0.0

## Seat index -> {node, rig, has_limbs}.
var _seated_players: Dictionary = {}


func _ready():
	set_process(true)


func rest_key() -> String:
	return str(name)


## The waiter's station, which is clear of the chairs, else the seats' centroid.
func place_pos() -> Vector3:
	if _kitchen != Vector3.INF:
		return _kitchen
	return _seat_centroid()


## The interior's entrance, or a walkable spot near the terrace clear of every chair.
func approach_pos() -> Vector3:
	if _indoor_layout != null and _indoor_layout.ready_ok:
		return _indoor_layout.entrance()
	var c := _seat_centroid()
	if _manager == null or _seats.is_empty():
		return c
	var best := c
	var best_score := -INF
	for i in 14:
		var p: Vector3 = _manager.nav.random_point_near(c, 32.0, _manager.rng())
		if p.distance_to(c) > 34.0:
			continue
		var dmin := INF
		for s in _seats:
			dmin = minf(dmin, p.distance_to(Vector3(s.pos)))
		# Clear of chairs, but not so far the arrival check fails.
		var score := minf(dmin, 12.0) - maxf(p.distance_to(c) - 24.0, 0.0)
		if score > best_score:
			best_score = score
			best = p
	return best


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
	_greet_player(delta)
	_player_ui_tick(delta)
	_apply_player_poses(delta)
	if not _manager.is_authority():
		return
	_tick += delta
	if _tick < 0.25:
		return
	var step := _tick
	_tick = 0.0
	_waiter_hold = maxf(_waiter_hold - step, 0.0)
	_configure_waiter()
	_validate_seats()
	_dispatch_waiter()
	_run_seats(step)
	_run_table_talk(step)
	_run_invites(step)


## Local and cosmetic only.
func _greet_player(delta):
	_player_greet_cd -= delta
	if _player_greet_cd > 0.0 or not _manager.has_network() or not is_open():
		return
	var pl = _manager.local_player()
	if pl == null or not is_instance_valid(pl):
		return
	var w = _waiter()
	if w == null:
		return
	var p_local: Vector3 = _manager.world().to_local(pl.global_position)
	if p_local.distance_to(_kitchen) > 30.0 or w.position.distance_to(_kitchen) > 8.0:
		_player_greet_cd = 2.0
		return
	_player_greet_cd = 120.0
	w.say_line(dialog_prefix + "_ask", 4.0)


## (reachable from the door, total)
func _indoor_reach() -> Vector2i:
	var reach := 0
	var indoor := 0
	for s in _seats:
		if not bool(s.get("indoor", false)):
			continue
		indoor += 1
		if _indoor_layout.ready_ok \
				and not _indoor_layout.nav.route(_indoor_layout.entrance(), Vector3(s.approach)).is_empty():
			reach += 1
	return Vector2i(reach, indoor)


func _register():
	if _registering: return
	var root := get_tree().current_scene
	if root == null:
		return
	var mgr = root.find_child("AmbientManager", true, false)
	if mgr == null or mgr.world() == null:
		return
	_registering = true
	_indoor_layout = get_node_or_null(indoor_layout_path) if not indoor_layout_path.is_empty() else null
	if _indoor_layout != null:
		await _indoor_layout.prepare(mgr.world(), mgr.nav)
	_manager = mgr
	_scan_tables()
	if _indoor_layout != null:
		await _resample_until_reachable(mgr)
	_manager.places.register_restaurant(self)
	_add_waiter()


## World geometry keeps settling after boot, so an early floor blocks seats; resample up to ten times.
func _resample_until_reachable(mgr) -> void:
	var reach := _indoor_reach()
	for attempt in 10:
		if reach.x == reach.y:
			break
		print("[Restaurant %s] floor sampled before the building settled (%d/%d seats reachable); sampling again"
			% [rest_key(), reach.x, reach.y])
		await get_tree().create_timer(3.0).timeout
		await _indoor_layout.prepare(mgr.world(), mgr.nav)
		reach = _indoor_reach()
	print("[Restaurant %s] indoor floor %s: %d/%d seats reachable from the door" % [rest_key(),
		"built" if _indoor_layout.ready_ok else "NOT built", reach.x, reach.y])


## A resident-pool body: the authority simulates him, peers interpolate him from "res".
func _add_waiter() -> void:
	_waiter_key = "r_w_" + rest_key().to_lower()
	_manager.add_service_ped(_waiter_key, {
		"id": "w_" + rest_key().to_lower(),
		"kind": 0,
		"script": WAITER_SCRIPT,
		"skin": "res://assets/entities/character/clothing/Waiter1_diff.png",
		"accessories": ["res://assets/entities/character/accessories/MessyHair/messyhair.tscn"],
	})


func _scan_tables():
	_seats = []
	_kitchen = Vector3.INF
	var template_xfs: Array = []  # table-local
	var centroid := Vector3.ZERO
	var tables: Array = []
	var authored_tables := get_children()
	if _indoor_layout != null:
		authored_tables.append_array(_indoor_layout.get_children())
	for child in authored_tables:
		if not (child is Node3D):
			continue
		if str(child.name).to_lower().begins_with("kitchen"):
			_kitchen = _manager.world().to_local((child as Node3D).global_position)
			continue
		if _scan_table(child, template_xfs):
			tables.append(child)
			centroid += (child as Node3D).global_position
	if not tables.is_empty():
		centroid /= float(tables.size())
	for s in _seats:
		_place_seat(s, template_xfs)
	if _kitchen == Vector3.INF and not tables.is_empty():
		_kitchen = _manager.world().to_local(centroid)
	_manager.add_no_loiter(_kitchen, 26.0)
	if _indoor_layout != null:
		_manager.add_no_loiter(_manager.world().to_local(centroid), 26.0)
	_pair_mates()
	print("[Restaurant %s] tables=%d seats=%d" % [rest_key(), tables.size(), _seats.size()])


## The first table with food guides provides the guides for all. False if it has no seats.
func _scan_table(table: Node3D, template_xfs: Array) -> bool:
	var seats_here: Array = []
	var foods_here: Array = []
	for sub in table.get_children():
		if sub is Marker3D:
			seats_here.append(sub)
		elif sub is Node3D and (sub.owner == owner or sub.scene_file_path != ""):
			# Only authored nodes are guides; a GLB's own mesh nodes must stay untouched.
			foods_here.append(sub)
	if seats_here.is_empty():
		return false
	seats_here.sort_custom(func(a, b): return str(a.name) < str(b.name))
	foods_here.sort_custom(func(a, b): return str(a.name) < str(b.name))
	if not foods_here.is_empty() and template_xfs.is_empty():
		for f in foods_here:
			template_xfs.append((f as Node3D).transform)
		_food_template = foods_here[0]
	for f in foods_here:
		(f as Node3D).visible = false
	for s_i in seats_here.size():
		_seats.append(_new_seat(table, seats_here[s_i], s_i))
	return true


func _new_seat(table: Node3D, marker: Marker3D, food_i: int) -> Dictionary:
	return {
		"table": table, "marker": marker, "food_i": food_i,
		"ped": "", "phase": Phase.EMPTY, "timer": 0.0, "line": -1,
		"food": null, "queued": false,
		"ov": 0, "cv": 0, "tc": "", "tl": -1, "tt": 0.0, "pline": -1,
	}


func _place_seat(s: Dictionary, template_xfs: Array) -> void:
	# Extra seats nudge the guide so dishes don't overlap.
	var xf := Transform3D()
	if not template_xfs.is_empty():
		xf = template_xfs[int(s.food_i) % template_xfs.size()]
		if int(s.food_i) >= template_xfs.size():
			xf.origin += Vector3(0.12, 0.0, 0.12)
	else:
		xf.origin = Vector3(0, 0.22, 0)
	s["food_xf"] = xf
	var m: Node3D = s.marker
	s["pos"] = _manager.world().to_local(m.global_position)
	var fwd: Vector3 = -m.global_basis.z
	fwd = (_manager.world().global_basis.inverse() * fwd)
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	s["yaw"] = atan2(fwd.x, fwd.z) + PI
	var out: Vector3 = Vector3(s.pos) - _manager.world().to_local((s.table as Node3D).global_position)
	out.y = 0.0
	if out.length_squared() < 0.0001:
		out = Vector3.RIGHT
	s["service"] = Vector3(s.pos) + out.normalized() * 4.5
	s["indoor"] = m.has_node("Approach")
	s["approach"] = s.pos
	if bool(s.indoor):
		_place_indoor_seat(s, m)


## Approached and served from its open aisle end; the dish sits on the Food marker.
func _place_indoor_seat(s: Dictionary, m: Node3D) -> void:
	s.approach = _manager.world().to_local(m.get_node("Approach").global_position)
	s.service = _manager.world().to_local(m.get_node("Service").global_position)
	var food_marker: Node3D = m.get_node("Food")
	var table: Node3D = s.table
	var food_basis := Basis.IDENTITY
	if _food_template != null:
		food_basis = table.global_basis.inverse() * _food_template.global_basis
	s.food_xf = Transform3D(food_basis, table.to_local(food_marker.global_position))


## Honours a marker's "mate" meta when set.
func _pair_mates() -> void:
	for i in _seats.size():
		_seats[i]["mate"] = -1
	for i in _seats.size():
		if int(_seats[i].mate) >= 0: continue
		var wanted := str(_seats[i].marker.get_meta("mate", ""))
		for j in _seats.size():
			if j != i and _seats[j].table == _seats[i].table and int(_seats[j].mate) < 0 \
					and (wanted == "" or str(_seats[j].marker.name) == wanted):
				_seats[i]["mate"] = j
				_seats[j]["mate"] = i
				break


func _waiter():
	if _manager == null:
		return null
	var w = _manager.residents().get(_waiter_key)
	if w != null and is_instance_valid(w):
		return w
	return null


func _configure_waiter():
	var w = _waiter()
	if w == null:
		return
	if "restaurant" in w and w.restaurant == null:
		w.restaurant = self
		w.station = _kitchen


## Players' seats are "u:<username>"; their requests reach the authority as "rest_req".
static func _is_player_id(pid: String) -> bool:
	return pid.begins_with("u:")


## Null for players and empty seats.
func _diner(seat: Dictionary):
	var pid := str(seat.ped)
	if pid == "" or _is_player_id(pid):
		return null
	return _body_by_id(pid)


func _body_by_id(pid: String):
	var p = _manager.peds().get(pid)
	if p == null:
		p = _manager.residents().get(pid)
	if p != null and is_instance_valid(p):
		return p
	return null


## False when closed, full, or the body is busy.
func request_seat(body) -> bool:
	if not is_open() or body == null or not is_instance_valid(body):
		return false
	if body.sitting or body.errand_owner != null:
		return false
	var i := _available_seat()
	if i >= 0:
		_invite_to_seat(i, str(body.ped_id))
		return true
	return false


## -1 when none.
func _available_seat() -> int:
	var free: Array[int] = []
	for i in _seats.size():
		if int(_seats[i].phase) == Phase.EMPTY and float(_seats[i].timer) <= 0.0:
			free.append(i)
	return free[_manager.rng().randi_range(0, free.size() - 1)] if not free.is_empty() else -1


func route_between(from: Vector3, to: Vector3) -> Dictionary:
	return _indoor_layout.route_between(from, to) if _indoor_layout != null else {}


func errand_arrival_radius(tag: String) -> float:
	var i := int(tag.get_slice(":", 1))
	var indoor_seat := tag.begins_with("seat:") and i >= 0 and i < _seats.size() \
			and bool(_seats[i].get("indoor", false))
	return 0.8 if indoor_seat else 25.0


func _stand_diner(ped, seat: Dictionary) -> void:
	ped.stand_up()
	if bool(seat.get("indoor", false)):
		# Stand in the booth's aisle, not inside the bench/table collision.
		ped.position = Vector3(seat.approach) + Vector3.UP * ped.STAND_HEIGHT
		ped.velocity = Vector3.ZERO


func _send_diner_off(ped, seat: Dictionary) -> void:
	if ped.sitting:
		_stand_diner(ped, seat)
	if ped.errand_owner == self:
		ped.errand_owner = null
		ped.errand_dest = Vector3.INF
		ped.errand_tag = ""
		ped.enter_idle()
	ped.set_emotion("")


func _diner_body(seat: Dictionary) -> Node3D:
	var pid := str(seat.ped)
	if _is_player_id(pid):
		return _manager.player_by_id(pid)
	return _diner(seat)


func _player_bubble(node: Node3D, text: String):
	if node != null and node.has_method("show_chat_bubble"):
		node.show_chat_bubble(text)


func is_open() -> bool:
	var h: float = _manager.current_hour()
	return h >= open_hour and h <= close_hour


func _dish(s: Dictionary) -> int:
	return clampi(int(s.line), 0, DISH_COUNT - 1)


func _order_line(dish: int) -> Dictionary:
	return DialogRegistry.line("%s_order_%d" % [dialog_prefix, dish])


func _validate_seats():
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		if int(s.phase) == Phase.EMPTY:
			continue
		if _is_player_id(str(s.ped)):
			var body := _diner_body(s)
			if body == null or _manager.world().to_local(body.global_position) \
					.distance_to(Vector3(s.pos)) > 15.0:
				_reset_seat(i, "player walked away")
			continue
		var ped = _diner(s)
		if ped == null:
			_reset_seat(i, "diner vanished")


## Phase is left to the caller.
func _clear_seat(s: Dictionary, cooldown: float) -> void:
	s.ped = ""
	s.timer = cooldown
	s.line = -1
	s.queued = false
	s.ov = 0
	s.cv = 0
	s.tc = ""
	s.tl = -1


func _reset_seat(i: int, why := ""):
	var s: Dictionary = _seats[i]
	var ped = _diner(s)
	if ped != null and str(ped.ped_id).begins_with("r_") and int(s.phase) != Phase.EMPTY:
		print("[Restaurant %s] %s lost seat %d%s in %s: %s" % [rest_key(), ped.ped_id, i,
			" (indoor)" if bool(s.get("indoor", false)) else "", Phase.keys()[int(s.phase)],
			why if why != "" else "?"])
	if ped != null:
		_send_diner_off(ped, s)
	if ped != null and ped.has_method("meal_over") and int(s.phase) != Phase.EMPTY:
		ped.meal_over(false)
	_clear_food(s)
	if int(s.phase) == Phase.DELIVERING:
		_detach_carry()
	_task_queue.erase("ask:%d" % i)
	_task_queue.erase("pickup:%d" % i)
	_clear_seat(s, SEAT_COOLDOWN)
	s.phase = Phase.EMPTY
	s.pline = -1


func _run_seats(delta):
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		s.timer = float(s.timer) - delta
		match int(s.phase):
			Phase.COMING:
				if float(s.timer) <= 0.0:
					_reset_seat(i, "never arrived (timeout)")
			Phase.SEATED:
				if float(s.timer) <= 0.0 and not bool(s.queued):
					s.queued = true
					_task_queue.append("ask:%d" % i)
			Phase.ASKING:
				if float(s.timer) <= 0.0:
					_take_order(i, s)
					s.timer = 4.5
			Phase.RECOMMEND:
				if float(s.timer) <= 0.0:
					_set_phase(i, Phase.ORDERED)
					s.timer = 4.5
			Phase.ORDERED:
				if float(s.timer) <= 0.0:
					_regulars[str(s.ped)] = int(s.line)
					s.cv = 1 if _manager.rng().randf() < compliment_chance else 0
					_set_phase(i, Phase.COOKING)
					s.timer = _manager.rng().randf_range(22.0, 40.0)
					s.queued = false
			Phase.COOKING:
				if float(s.timer) <= 0.0 and not bool(s.queued):
					s.queued = true
					_task_queue.append("pickup:%d" % i)
			Phase.EATING:
				if float(s.timer) <= 0.0:
					_finish_meal(i)


## A regular gets "the usual" (ov 2), some take the recommendation (ov 1), the rest pick.
func _take_order(i: int, s: Dictionary) -> void:
	var pid := str(s.ped)
	if _is_player_id(pid):
		_take_player_order(i, s)
	elif _regulars.has(pid):
		s.line = int(_regulars[pid])
		s.ov = 2
		_set_phase(i, Phase.ORDERED)
	elif _manager.rng().randf() < recommend_chance:
		s.line = RECOMMEND_DISH
		s.ov = 1
		_set_phase(i, Phase.RECOMMEND)
	else:
		s.line = _manager.rng().randi_range(0, DISH_COUNT - 1)
		s.ov = 0
		_set_phase(i, Phase.ORDERED)


## Without a dish the waiter waits once more, then gives up on the seat.
func _take_player_order(i: int, s: Dictionary) -> void:
	if int(s.get("pline", -1)) >= 0:
		s.line = clampi(int(s.pline), 0, DISH_COUNT - 1)
		s.ov = 0
		_set_phase(i, Phase.ORDERED)
		s.timer = 3.0
	elif not bool(s.get("pwait", false)):
		s["pwait"] = true
		s.timer = 45.0
	else:
		s.erase("pwait")
		_reset_seat(i, "player never ordered")


func _finish_meal(i: int):
	var s: Dictionary = _seats[i]
	var ped = _diner(s)  # null for players; they get up themselves
	_set_phase(i, Phase.EMPTY)
	if ped != null:
		_stand_diner(ped, s)
		ped.set_emotion("")
		if ped.has_method("meal_over"):
			ped.meal_over(true)
	_clear_seat(s, SEAT_COOLDOWN)


func _talk_ok(ph: int) -> bool:
	return ph == Phase.SEATED or ph == Phase.COOKING or ph == Phase.EATING


## The lower seat index of the pair holds the conversation state.
func _run_table_talk(delta):
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		var m := int(s.get("mate", -1))
		if m <= i:
			continue
		var sm: Dictionary = _seats[m]
		if not (_talk_ok(int(s.phase)) and _talk_ok(int(sm.phase))):
			s.tc = ""
			s.tl = -1
			continue
		s.tt = float(s.tt) - delta
		if float(s.tt) > 0.0:
			continue
		if str(s.tc) == "":
			s.tc = TABLE_CONVS[_manager.rng().randi_range(0, TABLE_CONVS.size() - 1)]
			s.tl = -1
			s.tt = _manager.rng().randf_range(4.0, 8.0)
			continue
		var entries: Array = DialogRegistry.conv(str(s.tc))
		var idx := int(s.tl) + 1
		if idx >= entries.size():
			s.tc = ""
			s.tl = -1
			s.tt = _manager.rng().randf_range(25.0, 45.0)
			continue
		s.tl = idx
		s.tt = float(entries[idx].get("gap", 7.0))
		_speak_table_line(i, m, str(s.tc), idx)


func _speak_table_line(lead: int, mate: int, conv: String, idx: int):
	var entries: Array = DialogRegistry.conv(conv)
	if idx < 0 or idx >= entries.size():
		return
	var entry: Dictionary = entries[idx]
	var seat_i := lead if int(entry.get("s", 0)) == 0 else mate
	if seat_i < 0 or seat_i >= _seats.size():
		return
	var ped = _diner(_seats[seat_i])
	if ped != null:
		ped.say_line(str(entry.get("l", "")), 5.0)


func _run_invites(delta):
	_invite_timer -= delta
	if _invite_timer > 0.0 or not is_open():
		return
	_invite_timer = _manager.rng().randf_range(invite_min, invite_max)
	var free := _available_seat()
	if free < 0:
		return
	var seat: Dictionary = _seats[free]
	var candidates := _invite_candidates(seat)
	if candidates.is_empty():
		return
	var chosen: String = str(candidates[_manager.rng().randi_range(0, candidates.size() - 1)])
	var mate_seat := int(seat.get("mate", -1))
	if mate_seat >= 0 and int(_seats[mate_seat].phase) == Phase.EMPTY \
			and float(_seats[mate_seat].timer) <= 0.0 \
			and _manager.rng().randf() < pair_chance:
		var companion := _pick_companion(chosen, candidates)
		if companion != "":
			_invite_to_seat(mate_seat, companion)
	_invite_to_seat(free, chosen)


func _invite_candidates(seat: Dictionary) -> Array:
	var candidates: Array = []
	for id in _manager.peds():
		var p = _manager.peds()[id]
		if p == null or not is_instance_valid(p):
			continue
		if p.sitting or p.errand_owner != null or p.calling:
			continue
		var sp: String = _manager.ped_scene_paths[p.kind % _manager.ped_scene_paths.size()]
		if not sp.contains("character/humanoid"):
			continue
		if p.position.distance_to(Vector3(seat.pos)) > invite_radius:
			continue
		candidates.append(id)
	return candidates


## Prefers a different voice so the table talk has two; "" if nobody is close enough.
func _pick_companion(chosen: String, candidates: Array) -> String:
	var pa = _manager.peds()[chosen]
	var best := ""
	var best_score := INF
	for id in candidates:
		if str(id) == chosen:
			continue
		var p = _manager.peds()[id]
		var score: float = p.position.distance_to(pa.position)
		if p.voice_id() != pa.voice_id():
			score -= 100.0
		if score < best_score:
			best_score = score
			best = str(id)
	if best != "" and best_score < 80.0:
		return best
	return ""


func _invite_to_seat(i: int, ped_id: String):
	var seat: Dictionary = _seats[i]
	seat.ped = ped_id
	seat.timer = 150.0
	_set_phase(i, Phase.COMING)
	_body_by_id(ped_id).assign_errand(self, Vector3(seat.approach), "seat:%d" % i)


func errand_finished(ped, tag: String, ok: bool):
	if not tag.begins_with("seat:"):
		return
	var i := int(tag.substr(5))
	if i < 0 or i >= _seats.size():
		return
	var s: Dictionary = _seats[i]
	if str(s.ped) != str(ped.ped_id) or int(s.phase) != Phase.COMING:
		return
	if not ok:
		if bool(s.get("indoor", false)):
			print("[Restaurant %s] %s could not reach indoor seat %d: %s" % [rest_key(), ped.ped_id, i,
				_indoor_layout.last_block if _indoor_layout != null else "?"])
		_reset_seat(i, "walk to the seat failed")
		return
	var delta := Vector3(s.approach) - Vector3(ped.position)
	delta.y = 0.0
	if bool(s.get("indoor", false)) and delta.length() > errand_arrival_radius(tag):
		_reset_seat(i, "arrived %.1f from the booth's aisle" % delta.length())
		return
	ped.sit_at(Vector3(s.pos), float(s.yaw))
	_set_phase(i, Phase.SEATED)
	s.timer = _manager.rng().randf_range(6.0, 12.0)
	s.queued = false


## A task whose seat moved on is dropped.
func _dispatch_waiter():
	if _waiter_hold > 0.0:
		return
	var w = _waiter()
	if w == null or not ("waiter_goto" in w) or w.has_task() or _task_queue.is_empty():
		return
	var tag: String = str(_task_queue.pop_front())
	var i := int(tag.get_slice(":", 1))
	if i < 0 or i >= _seats.size():
		return
	var s: Dictionary = _seats[i]
	if tag.begins_with("ask:"):
		if int(s.phase) != Phase.SEATED:
			return
		w.waiter_goto(Vector3(s.service), tag)
	elif tag.begins_with("pickup:"):
		if int(s.phase) != Phase.COOKING:
			return
		w.waiter_goto(_kitchen, tag)


## Events use it so his lines aren't cut short by the next customer.
func hold_waiter(seconds: float):
	_waiter_hold = maxf(_waiter_hold, seconds)


## ask -> ASKING, pickup -> DELIVERING, deliver -> EATING.
func waiter_task_done(tag: String):
	_waiter_hold = maxf(_waiter_hold, 4.0)  # finish the moment first
	var i := int(tag.get_slice(":", 1))
	if i < 0 or i >= _seats.size():
		return
	var s: Dictionary = _seats[i]
	var w = _waiter()
	if tag.begins_with("ask:"):
		if int(s.phase) != Phase.SEATED:
			return
		_set_phase(i, Phase.ASKING)
		s.timer = 3.5
	elif tag.begins_with("pickup:"):
		if int(s.phase) != Phase.COOKING:
			return
		_set_phase(i, Phase.DELIVERING)
		if w != null:
			w.waiter_goto(Vector3(s.service), "deliver:%d" % i)
	elif tag.begins_with("deliver:"):
		if int(s.phase) != Phase.DELIVERING:
			return
		_set_phase(i, Phase.EATING)
		# Players eat at their own pace (finish with the interact key).
		s.timer = 600.0 if _is_player_id(str(s.ped)) else _manager.rng().randf_range(70.0, 140.0)


func waiter_task_failed(tag: String) -> void:
	var i := int(tag.get_slice(":", 1))
	if i >= 0 and i < _seats.size():
		_reset_seat(i, "waiter could not get there (" + tag + ")")


func _my_pid() -> String:
	return "u:" + str(_manager.local_username())


func _my_seat() -> int:
	var pid := _my_pid()
	for i in _seats.size():
		if str(_seats[i].ped) == pid:
			return i
	return -1


func _interaction_distance(seat: Dictionary, pos: Vector3) -> float:
	if bool(seat.get("indoor", false)):
		return pos.distance_to(Vector3(seat.approach) + Vector3.UP * 3.0)
	return pos.distance_to(Vector3(seat.pos))


func _player_ui_tick(delta):
	_key_cd = maxf(_key_cd - delta, 0.0)
	if not _manager.has_network():
		return
	var pl = _manager.local_player()
	if pl == null or not is_instance_valid(pl):
		return
	_ensure_ui()
	var my_pos: Vector3 = _manager.world().to_local(pl.global_position)
	var mine := _my_seat()
	_prompt_action = ""
	var show_menu := false
	if mine >= 0:
		var ph := int(_seats[mine].phase)
		# Standing up is always available, so nobody is trapped in a chair.
		_prompt_action = "leave:%d" % mine
		if ph == Phase.EATING:
			_prompt.text = Labels.text("finish_meal", "Finish") + " [E]"
		else:
			_prompt.text = Labels.text("stand", "Stand") + " [E]"
			if (ph == Phase.SEATED or ph == Phase.ASKING) and not _menu_dismissed:
				show_menu = true
	else:
		_menu_dismissed = false
		if is_open():
			var best := _nearest_free_seat(my_pos)
			if best >= 0:
				_prompt_action = "sit:%d" % best
				_prompt.text = Labels.text("sit", "Sit") + " [E]"
	_prompt.visible = _prompt_action != ""
	_menu.visible = show_menu


func _nearest_free_seat(my_pos: Vector3) -> int:
	var best := -1
	var best_d := 6.0
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		if int(s.phase) != Phase.EMPTY or float(s.timer) > 0.0:
			continue
		var d := _interaction_distance(s, my_pos)
		if bool(s.get("indoor", false)) and d > 4.0: continue
		if d < best_d:
			best_d = d
			best = i
	return best


func _unhandled_key_input(event: InputEvent):
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo or k.keycode != KEY_E:
		return
	if _prompt_action == "" or _key_cd > 0.0:
		return
	_key_cd = 0.4
	var i := int(_prompt_action.get_slice(":", 1))
	if _prompt_action.begins_with("sit:"):
		_send_player_request({"action": "sit", "seat": i})
	elif _prompt_action.begins_with("leave:"):
		_send_player_request({"action": "leave", "seat": i})


func _order_pressed(line: int):
	var mine := _my_seat()
	if mine < 0:
		return
	_menu_dismissed = true
	_send_player_request({"action": "order", "seat": mine, "line": line})


func _send_player_request(d: Dictionary):
	d["type"] = "rest_req"
	d["rest"] = rest_key()
	d["p"] = _my_pid()
	if _manager.is_authority():
		handle_player_request(d)
	elif _manager.has_network():
		_manager.send_to_server(d)


func _ensure_ui():
	if _ui != null and is_instance_valid(_ui):
		return
	_ui = CanvasLayer.new()
	_ui.layer = 45
	add_child(_ui)
	var font := SystemFont.new()
	font.font_names = PackedStringArray([
		"Hiragino Sans", "Yu Gothic UI", "Meiryo",
		"Noto Sans CJK JP", "Noto Sans JP"])
	_make_prompt(font)
	_make_menu(font)


func _make_prompt(font: Font) -> void:
	_prompt = Label.new()
	_prompt.anchor_left = 0.5
	_prompt.anchor_right = 0.5
	_prompt.anchor_top = 1.0
	_prompt.anchor_bottom = 1.0
	_prompt.offset_left = -160.0
	_prompt.offset_right = 160.0
	_prompt.offset_top = -170.0
	_prompt.offset_bottom = -120.0
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_override("font", font)
	_prompt.add_theme_font_size_override("font_size", 34)
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_prompt.add_theme_constant_override("outline_size", 8)
	_prompt.visible = false
	_ui.add_child(_prompt)


func _make_menu(font: Font) -> void:
	_menu = PanelContainer.new()
	_menu.anchor_left = 0.5
	_menu.anchor_right = 0.5
	_menu.anchor_top = 0.5
	_menu.anchor_bottom = 0.5
	_menu.offset_left = -240.0
	_menu.offset_right = 240.0
	_menu.offset_top = -190.0
	_menu.offset_bottom = 190.0
	_menu.visible = false
	_ui.add_child(_menu)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_menu.add_child(box)
	var title := Label.new()
	title.text = Labels.text("order_question", "What will you have?")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", 30)
	box.add_child(title)
	for i in DISH_COUNT:
		var btn := Button.new()
		btn.text = str(_order_line(i).get("text", "dish %d" % i))
		btn.add_theme_font_override("font", font)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(_order_pressed.bind(i))
		box.add_child(btn)


# The player's own client pins the body to the chair; each peer bends the limbs from seat state.

func _apply_player_poses(delta):
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		var occupied: bool = _is_player_id(str(s.ped)) and int(s.phase) != Phase.EMPTY
		if occupied and not _seated_players.has(i):
			if not _seat_player(i, s):
				continue
		elif not occupied and _seated_players.has(i):
			_release_player(i)
		if _seated_players.has(i):
			_pose_player(i, delta)


## Pins them to the seat on their own client. False if the body is not found.
func _seat_player(i: int, s: Dictionary) -> bool:
	var body := _diner_body(s)
	if body == null:
		return false
	var rig = LimbRigScript.new()
	var cm = body.get_node_or_null("CharacterModel")
	var has_limbs: bool = rig.resolve(cm)
	_seated_players[i] = {"node": body, "rig": rig, "has_limbs": has_limbs}
	if str(s.ped) == _my_pid() and body.has_method("sit_on_seat"):
		var hip: Vector3 = Vector3(s.pos) + Vector3.UP * (1.0 if has_limbs else 1.2)
		body.sit_on_seat(_manager.world().to_global(hip), float(s.yaw))
	return true


func _pose_player(i: int, delta: float) -> void:
	var entry: Dictionary = _seated_players[i]
	var node = entry.node
	if node == null or not is_instance_valid(node):
		_seated_players.erase(i)
		return
	if not bool(entry.has_limbs):
		return
	var rig = entry.rig
	var w := minf(delta * 6.0, 1.0)
	rig.pitch_toward(rig.left_leg, 1.5, w)
	rig.pitch_toward(rig.right_leg, 1.5, w)
	rig.pitch_toward(rig.left_arm, 0.35, w)
	rig.pitch_toward(rig.right_arm, 0.35, w)


func _release_player(i: int):
	var entry: Dictionary = _seated_players.get(i, {})
	_seated_players.erase(i)
	var node = entry.get("node")
	if node == null or not is_instance_valid(node):
		return
	if bool(entry.get("has_limbs", false)):
		var rig = entry.rig
		rig.relax(1.0)
	if node.has_method("stand_from_seat"):
		node.stand_from_seat()
	if bool(_seats[i].get("indoor", false)) and node == _manager.player_by_id(_my_pid()):
		node.global_position = _manager.world().to_global(Vector3(_seats[i].approach) + Vector3.UP * 3.0)


## "sit", "order" or "leave".
func handle_player_request(data: Dictionary):
	if _manager == null or not _manager.is_authority():
		return
	var pid := str(data.get("p", ""))
	if not _is_player_id(pid):
		return
	var action := str(data.get("action", ""))
	var i := int(data.get("seat", -1))
	if i < 0 or i >= _seats.size():
		return
	var s: Dictionary = _seats[i]
	match action:
		"sit":
			_player_sit(i, s, pid)
		"order":
			if str(s.ped) != pid:
				return
			s.pline = clampi(int(data.get("line", 0)), 0, DISH_COUNT - 1)
			if int(s.phase) == Phase.ASKING:
				s.erase("pwait")
				s.line = int(s.pline)
				s.ov = 0
				_set_phase(i, Phase.ORDERED)
				s.timer = 3.0
		"leave":
			if str(s.ped) != pid:
				return
			if int(s.phase) == Phase.EATING:
				s.cv = 1  # finishing the meal earns the compliment
				_finish_meal(i)
			else:
				_reset_seat(i, "player left before eating")


func _player_sit(i: int, s: Dictionary, pid: String) -> void:
	if int(s.phase) != Phase.EMPTY or float(s.timer) > 0.0 or not is_open():
		return
	for occupied in _seats:
		if str(occupied.ped) == pid: return
	var body = _manager.player_by_id(pid)
	var reach := 5.0 if bool(s.get("indoor", false)) else 12.0
	if body == null or _interaction_distance(s, _manager.world().to_local(body.global_position)) > reach:
		return
	s.ped = pid
	_set_phase(i, Phase.SEATED)  # they walked over themselves
	s.timer = _manager.rng().randf_range(4.0, 8.0)
	s.queued = false
	s.pline = -1


func _set_phase(i: int, new_phase: int):
	var s: Dictionary = _seats[i]
	var old := int(s.phase)
	s.phase = new_phase
	_apply_phase_visuals(i, old, new_phase)


func _apply_phase_visuals(i: int, old_phase: int, new_phase: int):
	var s: Dictionary = _seats[i]
	var w = _waiter()
	var ped = _diner(s)
	if new_phase == Phase.ASKING and old_phase != Phase.ASKING and w != null:
		w.say_line(dialog_prefix + "_ask", 4.0)
	if new_phase == Phase.RECOMMEND and old_phase != Phase.RECOMMEND and w != null:
		w.say_line(dialog_prefix + "_recommend", 4.5)
	if new_phase == Phase.ORDERED and old_phase != Phase.ORDERED:
		_say_order(s, ped)
	if new_phase == Phase.COOKING and old_phase != Phase.COOKING \
			and int(s.get("ov", 0)) == 2 and w != null and int(s.line) >= 0:
		w.say_line("%s_usual_%d" % [dialog_prefix, _dish(s)], 4.0)
	if new_phase == Phase.DELIVERING and old_phase != Phase.DELIVERING:
		_attach_carry()
	if old_phase == Phase.DELIVERING and new_phase != Phase.DELIVERING:
		_detach_carry()
	if new_phase == Phase.EATING and old_phase != Phase.EATING:
		_spawn_food(s)
		if ped != null:
			ped.set_emotion("happy")
		if old_phase == Phase.DELIVERING and w != null and int(s.line) >= 0:
			w.say_line("%s_serve_%d" % [dialog_prefix, _dish(s)], 4.0)
	if new_phase != Phase.EATING and old_phase == Phase.EATING:
		_end_meal_visuals(s, ped, new_phase)


## ov 1 accepts the recommendation, ov 2 asks for the usual, else names the dish.
func _say_order(s: Dictionary, ped) -> void:
	if ped != null:
		match int(s.get("ov", 0)):
			1:
				ped.say_line(dialog_prefix + "_accept", 4.0)
			2:
				ped.say_line(dialog_prefix + "_usual_req", 4.0)
			_:
				ped.say_line("%s_order_%d" % [dialog_prefix, _dish(s)], 5.0)
	elif _is_player_id(str(s.ped)):
		_player_bubble(_diner_body(s), str(_order_line(_dish(s)).get("text", "")))


## Players always compliment.
func _end_meal_visuals(s: Dictionary, ped, new_phase: int) -> void:
	_clear_food(s)
	if ped != null:
		ped.set_emotion("")
		if new_phase == Phase.EMPTY and int(s.get("cv", 0)) == 1:
			ped.say_line(dialog_prefix + "_compliment", 3.5)
	elif _is_player_id(str(s.ped)) and new_phase == Phase.EMPTY:
		var compliment: Dictionary = DialogRegistry.line(dialog_prefix + "_compliment")
		_player_bubble(_diner_body(s), str(compliment.get("text", "")))


func _spawn_food(s: Dictionary):
	_clear_food(s)
	if _food_template == null or not is_instance_valid(_food_template):
		return
	var food: Node3D = _food_template.duplicate() as Node3D
	food.visible = true
	(s.table as Node3D).add_child(food)
	food.transform = s.food_xf
	s.food = food
	var clink_stream = load("res://assets/art/sound/city/plate_clink.wav")
	if clink_stream != null:
		var clink := AudioStreamPlayer3D.new()
		clink.stream = clink_stream
		clink.max_distance = 30.0
		clink.volume_db = -8.0
		(s.table as Node3D).add_child(clink)
		clink.position = s.food_xf.origin
		clink.play()
		clink.finished.connect(clink.queue_free)


func _clear_food(s: Dictionary):
	var f = s.get("food")
	if f != null and is_instance_valid(f):
		(f as Node3D).queue_free()
	s.food = null


func _attach_carry():
	_detach_carry()
	var w = _waiter()
	if w == null or _food_template == null or not is_instance_valid(_food_template):
		return
	var holder: Node3D = w.character_model if w.character_model != null else w
	_carry = _food_template.duplicate() as Node3D
	_carry.visible = true
	holder.add_child(_carry)
	# Models face -Z. The guide's basis in world terms keeps the dish's size whatever the scales.
	var tbl := _food_template.get_parent() as Node3D
	_carry.global_transform = Transform3D(
		tbl.global_basis * _food_template.transform.basis,
		holder.to_global(Vector3(0.0, 2.2, -1.4)))


func _detach_carry():
	if _carry != null and is_instance_valid(_carry):
		_carry.queue_free()
	_carry = null


## Diners there are sent off and the cooldown keeps invites away for `seconds`.
func event_hold_seats(idxs: Array, seconds: float):
	for i in idxs:
		var si := int(i)
		if si < 0 or si >= _seats.size():
			continue
		if int(_seats[si].phase) != Phase.EMPTY:
			_reset_seat(si, "an event took the seat")
		_seats[si].timer = seconds


func seat_info(i: int) -> Dictionary:
	if i < 0 or i >= _seats.size():
		return {}
	var s: Dictionary = _seats[i]
	return {"pos": s.pos, "yaw": s.yaw, "service": s.service}


func waiter_body():
	return _waiter()


## Visual only; run on every peer.
func event_food(i: int, on: bool):
	if i < 0 or i >= _seats.size():
		return
	if on:
		_spawn_food(_seats[i])
	else:
		_clear_food(_seats[i])


func snapshot() -> Dictionary:
	var seats := []
	for s in _seats:
		var entry := {"p": s.ped, "ph": int(s.phase), "l": int(s.line),
			"ov": int(s.get("ov", 0)), "cv": int(s.get("cv", 0))}
		if str(s.get("tc", "")) != "":
			entry["tc"] = s.tc
			entry["tl"] = int(s.tl)
		seats.append(entry)
	return {"s": seats}


func apply_snapshot(data: Dictionary):
	var seats: Array = data.get("s", [])
	for i in mini(seats.size(), _seats.size()):
		var incoming: Dictionary = seats[i]
		var s: Dictionary = _seats[i]
		var new_p := str(incoming.get("p", ""))
		s.line = int(incoming.get("l", -1))
		s.ov = int(incoming.get("ov", 0))
		s.cv = int(incoming.get("cv", 0))
		var ph := int(incoming.get("ph", 0))
		if ph != int(s.phase):
			var old := int(s.phase)
			# The leave visuals run with the departing occupant still attached.
			if ph != Phase.EMPTY:
				s.ped = new_p
			s.phase = ph
			_apply_phase_visuals(i, old, ph)
		s.ped = new_p
		var tc := str(incoming.get("tc", ""))
		var tl := int(incoming.get("tl", -1))
		if tc != "" and tl >= 0 and (tc != str(s.tc) or tl != int(s.tl)):
			_speak_table_line(i, int(s.get("mate", -1)), tc, tl)
		s.tc = tc
		s.tl = tl


## A new authority starts dining afresh; a demoted peer mirrors snapshots.
func set_authority(is_auth: bool):
	for i in _seats.size():
		var s: Dictionary = _seats[i]
		_clear_food(s)
		var ped = _diner(s)
		if ped != null and is_auth:
			_send_diner_off(ped, s)
		_clear_seat(s, 10.0)
		s.phase = Phase.EMPTY
	_detach_carry()
	_task_queue = []


## Once the order is in, they take the meal with them; before that, they simply go.
func release_resident(pid: String):
	for i in _seats.size():
		if str(_seats[i].ped) != pid:
			continue
		var phase := int(_seats[i].phase)
		if phase in [Phase.ORDERED, Phase.COOKING, Phase.DELIVERING, Phase.EATING]:
			print("[Restaurant %s] %s called away; takes the meal to go (seat %d, %s)" % [
				rest_key(), pid, i, Phase.keys()[phase]])
			if phase == Phase.DELIVERING:
				_detach_carry()
			_finish_meal(i)
		else:
			_reset_seat(i, "released: the resident was given something else to do")
