## The amb_state snapshot: the authority builds and sends it, the other peers apply it.
class_name AmbientReplication
extends RefCounted

const SEND_INTERVAL := 0.1
const STALE_MSEC := 5000  # remote body unseen this long -> despawn

var remote_sigs: Array = []  # phase per signal, from the authority

var _m: AmbientManager = null
var _send_timer := 0.0
var _stale_timer := 0.0


func _init(manager: AmbientManager):
	_m = manager


static func snap_pos(n: Node3D, out: Dictionary) -> Dictionary:
	out["x"] = snappedf(n.position.x, 0.01)
	out["y"] = snappedf(n.position.y, 0.01)
	out["z"] = snappedf(n.position.z, 0.01)
	return out


func send_tick(delta):
	_send_timer += delta
	if _send_timer >= SEND_INTERVAL:
		_send_timer = 0.0
		send_state()


func receive_tick(delta):
	_stale_timer += delta
	if _stale_timer >= 1.0:
		_stale_timer = 0.0
		_despawn_stale()


func send_state():
	if not _m.is_online():
		return
	var weather = _m.weather_controller()
	var weather_state: Dictionary = weather.snapshot() if weather != null else {}
	var peds := _ped_states()
	var ress := _resident_states()
	var cars: Dictionary = _m.traffic.car_states()
	var trams: Dictionary = _m.traffic.tram_states()
	var elevators: Array = _m.get_tree().get_nodes_in_group("elevators")
	if peds.is_empty() and cars.is_empty() and trams.is_empty() and ress.is_empty() \
			and elevators.is_empty() and weather_state.is_empty():
		return
	var sigs := []
	for s in _m.traffic.lane_graph.signal_count():
		sigs.append(_m.computed_phase(s))
	var st = _m.places.states()
	var evt := {}
	var lifts := {}
	for elevator in elevators:
		lifts[elevator.elevator_id] = elevator.snapshot()
	var director = _m.event_director()
	if director != null:
		evt = director.snapshot()
	_m.send_to_server({"type": "amb_state", "peds": peds, "cars": cars,
		"trams": trams, "res": ress, "sigs": sigs, "rest": st.rest, "crs": st.crs,
		"sch": st.sch, "par": st.par, "evt": evt, "lifts": lifts, "weather": weather_state})


func _ped_states() -> Dictionary:
	var peds := {}
	var pool: Dictionary = _m.peds()
	for id in pool:
		var ped = pool[id]
		if ped == null or not is_instance_valid(ped):
			continue
		var st := snap_pos(ped, {})
		st["r"] = snappedf(ped.model_rot_y(), 0.01)
		st["s"] = snappedf(ped.current_speed(), 0.1)
		st["k"] = ped.kind
		st["f"] = ped.flag_code
		st["wx"] = ped.weather_reaction.snapshot()
		if ped.sitting:
			st["st"] = 1
			if ped.sit_how != "chair":
				st["sh"] = ped.sit_how
		if ped.skin_path != "":
			st["sk"] = ped.skin_path
		if not ped.accessory_paths.is_empty():
			st["ac"] = ped.accessory_paths
		if ped.calling:
			st["pc"] = ped.call_conv
			st["pl"] = ped.call_idx
		peds[id] = st
	return peds


## One at home without a house is left out, so it goes stale on the other peers.
func _resident_states() -> Dictionary:
	var ress := {}
	var pool: Dictionary = _m.residents()
	for id in pool:
		var body = pool[id]
		if body == null or not is_instance_valid(body) or _m.off_map(body):
			continue
		var def: Dictionary = _m.resident_def(id)
		var st := snap_pos(body, {})
		st["r"] = snappedf(body.model_rot_y(), 0.01)
		st["s"] = snappedf(body.current_speed(), 0.1)
		st["k"] = body.kind
		st["f"] = body.flag_code
		st["e"] = body.locked_emotion
		st["wx"] = body.weather_reaction.snapshot()
		st["sc"] = str(def.get("scene", ""))
		if body.skin_path != "":
			st["sk"] = body.skin_path
		if not body.accessory_paths.is_empty():
			st["ac"] = body.accessory_paths
		if body.sitting:
			st["st"] = 1
			if body.sit_how != "chair":
				st["sh"] = body.sit_how
		if str(body.get("arms_pose")) != "":
			st["ap"] = body.arms_pose
		if str(body.get("held_prop")) != "":
			st["pr"] = body.held_prop
		ress[id] = st
	return ress


## The weather on every peer, everything else only off-authority.
func apply_state(data: Dictionary):
	var weather = _m.weather_controller()
	if weather != null and data.get("weather") is Dictionary:
		var runtime: Dictionary = data.weather.duplicate(true)
		runtime["_initial"] = bool(data.get("initial", false))
		weather.apply_snapshot(runtime)
	if _m.is_authority():
		return
	var now := Time.get_ticks_msec()
	remote_sigs = data.get("sigs", [])
	_apply_peds(data.get("peds", {}), now)
	_apply_residents(data.get("res", {}), now)
	_m.traffic.apply_remote_cars(data.get("cars", {}), now)
	_m.traffic.apply_remote_trams(data.get("trams", {}), now)
	# Places last, so the bodies their states reference exist.
	_apply_places(data)


func _apply_peds(states: Dictionary, now: int):
	var pool: Dictionary = _m.peds()
	for id in states:
		var t: Dictionary = states[id]
		if pool.has(id) and is_instance_valid(pool[id]) \
				and (str(pool[id].flag_code) != str(t.get("f", "")) \
				or int(pool[id].kind) != int(t.get("k", 0))):
			# The authority gave this id another body (kind or flag).
			pool[id].queue_free()
			pool.erase(id)
		if not pool.has(id) or not is_instance_valid(pool[id]):
			_m.spawn_ped(id, int(t.get("k", 0)), Vector3(t.x, t.y, t.z),
				str(t.get("f", "")), str(t.get("sk", "")))
		if not pool.has(id):
			continue
		var ped = pool[id]
		ped.apply_remote_state(Vector3(t.x, t.y, t.z), float(t.get("r", 0.0)),
			float(t.get("s", 0.0)))
		ped.sitting = int(t.get("st", 0)) == 1
		ped.sit_how = str(t.get("sh", "chair"))
		ped.set_outfit(str(t.get("sk", "")), t.get("ac", []))
		ped.set_call(str(t.get("pc", "")), int(t.get("pl", -1)))
		ped.weather_reaction.apply_snapshot(t.get("wx", {}))
		ped.last_seen_msec = now


func _apply_residents(states: Dictionary, now: int):
	var pool: Dictionary = _m.residents()
	for id in states:
		var t: Dictionary = states[id]
		if not pool.has(id) or not is_instance_valid(pool[id]):
			_m.spawn_resident_remote(id, str(t.get("sc", "")), int(t.get("k", 0)),
				str(t.get("f", "")), Vector3(t.x, t.y, t.z))
		if not pool.has(id):
			continue
		var body = pool[id]
		body.apply_remote_state(Vector3(t.x, t.y, t.z), float(t.get("r", 0.0)),
			float(t.get("s", 0.0)))
		# "" unlocks back to mood drift.
		var emotion := str(t.get("e", ""))
		if body.locked_emotion != emotion:
			body.set_emotion(emotion)
		body.set_outfit(str(t.get("sk", "")), t.get("ac", []))
		body.sitting = int(t.get("st", 0)) == 1
		body.sit_how = str(t.get("sh", "chair"))
		body.arms_pose = str(t.get("ap", ""))
		if body.has_method("set_prop"):
			body.set_prop(str(t.get("pr", "")))
		body.weather_reaction.apply_snapshot(t.get("wx", {}))
		body.last_seen_msec = now


func _apply_places(data: Dictionary):
	_m.places.apply_remote(data)
	var director = _m.event_director()
	if director != null:
		director.apply_snapshot(data.get("evt", {}))


func _despawn_stale():
	var now := Time.get_ticks_msec()
	for pool in [_m.peds(), _m.traffic.cars, _m.traffic.trams, _m.residents()]:
		for id in pool.keys():
			var body = pool[id]
			if body == null or not is_instance_valid(body):
				pool.erase(id)
				continue
			if body.last_seen_msec > 0 and now - body.last_seen_msec > STALE_MSEC:
				body.queue_free()
				pool.erase(id)
