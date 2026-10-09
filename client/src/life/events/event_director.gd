extends Node

## Runs scripted street events from events/<id>/event.json cues; remote peers mirror the clock and run VISUAL_CUES only.

const EVENTS_DIR := "res://assets/entities/ambient/events"
const CLIPS_DIR := "res://assets/art/sound/events"
const ACTOR_SCRIPT := "res://src/life/events/event_actor.gd"
const AMBULANCE_MODEL := "res://assets/entities/vehicles/definitions/ambulance.tres"
const SIREN_CLIP := "res://assets/art/sound/city/siren_loop.mp3"
const AMB_CAR_ID := "evt_amb"
const VISUAL_CUES := ["say", "food", "line"]  # executed on every peer
const BEACON_COLOR := Color(1.0, 0.12, 0.08)

## Dev mode: fired force_delay seconds after load, once per session. Empty = the daily roll.
@export var force_event := ""
@export var force_delay := 60.0
## Rolled once at lunch or dinner time.
@export var event_chance := 0.15
@export var amb_approach_dist := 260.0
@export var amb_speed := 22.0

var _manager = null
var _tick := 0.0
var _force_timer := -1.0
var _rolled_day := -1

var _event_id := ""
var _elapsed := 0.0
var _cues: Array = []
var _clips: Dictionary = {}
var _cue_idx := 0
var _cast_keys: Array = []
var _hold_seats: Array = []
var _hold_timer := 0.0

var _amb_state := ""
var _amb_lane := -1
var _amb_dist := 0.0
var _amb_target := 0.0
var _amb_park_pos := Vector3.INF
var _amb_release_t := 0.0
# Derived on every peer from the car's existence.
var _siren: AudioStreamPlayer3D = null
var _beacons: Array = []  # [{light: OmniLight3D, mat: StandardMaterial3D}]


func _process(delta):
	if _manager == null:
		_try_register(delta)
		return

	_derive_siren(delta)

	if _event_id != "":
		_elapsed += delta
		_run_cues()
		if _manager.is_authority():
			_drive_event(delta)
		return

	if not _manager.is_authority():
		return
	if force_event != "":
		_tick_forced_event(delta)
	else:
		_maybe_roll(delta)


func _try_register(delta):
	_tick += delta
	if _tick >= 0.5:
		_tick = 0.0
		_register()


func _register():
	var root := get_tree().current_scene
	if root == null:
		return
	var mgr = root.find_child("AmbientManager", true, false)
	if mgr == null or mgr.world() == null:
		return
	_manager = mgr
	_manager.register_event_director(self)


func _drive_event(delta):
	_configure_actors()
	_drive_ambulance(delta)
	_refresh_seat_hold(delta)


func _refresh_seat_hold(delta):
	_hold_timer -= delta
	if _hold_timer > 0.0:
		return
	_hold_timer = 20.0
	var r = _restaurant()
	if r != null and not _hold_seats.is_empty():
		r.event_hold_seats(_hold_seats, 60.0)


func _tick_forced_event(delta):
	if _force_timer < 0.0:
		_force_timer = force_delay
	_force_timer -= delta
	if _force_timer <= 0.0:
		_force_timer = 999999.0  # once per session
		start_event(force_event)


func _restaurant():
	if _manager == null or _manager.places.restaurants.is_empty():
		return null
	var r = _manager.places.restaurants[0]
	return r if is_instance_valid(r) else null


## Once per real (UTC) day during 12-14 or 19-21 game time.
func _maybe_roll(_delta):
	var hour: float = _manager.current_hour()
	var day := int(Time.get_unix_time_from_system() / 86400.0)
	if _rolled_day == day:
		return
	if (hour >= 12.0 and hour < 14.0) or (hour >= 19.0 and hour < 21.0):
		_rolled_day = day
		if _manager.rng().randf() < event_chance:
			start_event("safiye")


## False if event.json is unusable.
func _load_event(id: String) -> bool:
	var f := FileAccess.open("%s/%s/event.json" % [EVENTS_DIR, id], FileAccess.READ)
	if f == null:
		push_warning("[Events] Missing event.json for '%s'" % id)
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	_cues = parsed.get("cues", [])
	_cues.sort_custom(func(a, b): return float(a.get("t", 0)) < float(b.get("t", 0)))
	_hold_seats = parsed.get("hold_seats", [])
	var cf := FileAccess.open("%s/%s/clips.json" % [EVENTS_DIR, id], FileAccess.READ)
	if cf != null:
		var cp = JSON.parse_string(cf.get_as_text())
		if typeof(cp) == TYPE_DICTIONARY:
			_clips = cp.get("clips", {})
	return true


## Ignored while another one runs.
func start_event(id: String):
	if _event_id != "" or not _manager.is_authority():
		return
	if not _load_event(id):
		return
	print("[Events] Starting '%s'" % id)
	_event_id = id
	_elapsed = 0.0
	_cue_idx = 0
	_cast_keys = []
	_hold_timer = 0.0


func _end_event():
	print("[Events] '%s' finished" % _event_id)
	for key in _cast_keys:
		_manager.remove_service_ped(str(key))
	_cast_keys = []
	_manager.traffic.remove_event_car(AMB_CAR_ID)
	var r = _restaurant()
	if r != null:
		for i in _hold_seats:
			r.event_food(int(i), false)
	_event_id = ""
	_cues = []
	_cue_idx = 0
	_amb_state = ""
	_amb_park_pos = Vector3.INF


## Visual cues run on every peer (stale ones skipped, except food); the rest on the authority only.
func _run_cues():
	var authority: bool = _manager.is_authority()
	while _cue_idx < _cues.size() and float(_cues[_cue_idx].get("t", 0.0)) <= _elapsed:
		var cue: Dictionary = _cues[_cue_idx]
		_cue_idx += 1
		var kind := str(cue.get("do", ""))
		var stale: bool = _elapsed - float(cue.get("t", 0.0)) > 6.0
		if VISUAL_CUES.has(kind):
			if not stale or kind == "food":  # food state must catch up
				_exec_cue(cue)
		elif authority:
			_exec_cue(cue)


func _exec_cue(cue: Dictionary):
	var kind := str(cue.get("do", ""))
	match kind:
		"spawn":
			_cue_spawn(cue)
		"goto":
			_cue_goto(cue)
		"sit":
			_cue_sit(cue)
		"stand":
			var body = _actor_body(str(cue.get("a", "")))
			if body != null and body.has_method("stand_up"):
				body.stand_up()
		"emote":
			var body = _actor_body(str(cue.get("a", "")))
			if body != null and body.has_method("set_emotion"):
				body.set_emotion(str(cue.get("e", "")))
		"say":
			_exec_say(cue)
		"line":
			_cue_line(cue)
		"food":
			var r = _restaurant()
			if r != null:
				r.event_food(int(cue.get("seat", 0)), bool(cue.get("on", true)))
		"amb_spawn":
			_amb_spawn()
		"amb_depart":
			_amb_depart()
		"despawn":
			var key := "r_evt_" + str(cue.get("a", ""))
			_manager.remove_service_ped(key)
			_cast_keys.erase(key)
		"end":
			_end_event()


func _cue_spawn(cue: Dictionary):
	var aid := str(cue.get("a", ""))
	var key := "r_evt_" + aid
	var sp := _resolve_pos(cue.get("at", [0, 2, 0]))
	var def := {
		"id": "evt_" + aid,
		"kind": int(cue.get("kind", 0)),
		"script": ACTOR_SCRIPT,
		"speed": float(cue.get("speed", 3.8)),
		"spawn_pos": [sp.x, sp.y, sp.z],
	}
	if cue.has("skin"):
		def["skin"] = str(cue.skin)
	_manager.add_service_ped(key, def)
	if not _cast_keys.has(key):
		_cast_keys.append(key)


func _cue_goto(cue: Dictionary):
	var body = _actor_body(str(cue.get("a", "")))
	if body == null or not body.has_method("goto"):
		return
	var dest := _resolve_pos(cue.get("to"))
	var off = cue.get("off", null)
	if typeof(off) == TYPE_ARRAY and off.size() >= 3:
		dest += Vector3(float(off[0]), float(off[1]), float(off[2]))
	body.goto(dest, float(cue.get("speed", -1.0)))


func _cue_sit(cue: Dictionary):
	var body = _actor_body(str(cue.get("a", "")))
	var r = _restaurant()
	if body == null or r == null:
		return
	var info: Dictionary = r.seat_info(int(cue.get("seat", 0)))
	if not info.is_empty():
		body.sit_at(Vector3(info.pos), float(info.yaw))


## Default speaker: the waiter, held in place while speaking.
func _cue_line(cue: Dictionary):
	var body = _actor_body(str(cue.get("a", "waiter")))
	if body == null or not body.has_method("say_line"):
		return
	var secs := float(cue.get("secs", 4.0))
	body.say_line(str(cue.get("line", "")), secs)
	var r = _restaurant()
	if str(cue.get("a", "waiter")) == "waiter" and r != null and r.has_method("hold_waiter"):
		r.hold_waiter(secs + 2.0)


func _exec_say(cue: Dictionary):
	var clip_name := str(cue.get("clip", ""))
	var clip: Dictionary = _clips.get(clip_name, {})
	if clip.is_empty():
		push_warning("[Events] Unknown clip: " + clip_name)
		return
	var body = _actor_body(str(clip.get("actor", "")))
	if body == null:
		return
	var text := str(clip.get("text", ""))
	var secs := float(cue.get("secs", 5.0))
	if text != "":
		body.say(text, secs)
	var path := "%s/%s/%s.mp3" % [CLIPS_DIR, _event_id, clip_name]
	if body.has_method("play_voice") and ResourceLoader.exists(path):
		body.play_voice(path)


## "waiter" is the restaurant waiter; null if absent.
func _actor_body(aid: String):
	if aid == "waiter":
		var r = _restaurant()
		return r.waiter_body() if r != null else null
	var body = _manager.residents().get("r_evt_" + aid)
	if body != null and is_instance_valid(body):
		return body
	return null


## POS: [x,y,z] workspace-local, or "@rest", "@seatN", "@serviceN", "@amb", "@waiter".
func _resolve_pos(raw) -> Vector3:
	if typeof(raw) == TYPE_ARRAY and raw.size() >= 3:
		return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	var token := str(raw)
	var r = _restaurant()
	if token == "@rest" and r != null:
		return r._kitchen
	if token == "@amb" and _amb_park_pos != Vector3.INF:
		return _amb_park_pos + Vector3(4, 0, 0)
	if token == "@waiter" and r != null:
		var w = r.waiter_body()
		if w != null:
			return w.position
	if token.begins_with("@seat") and r != null:
		var info: Dictionary = r.seat_info(int(token.substr(5)))
		if not info.is_empty():
			return Vector3(info.pos)
	if token.begins_with("@service") and r != null:
		var info2: Dictionary = r.seat_info(int(token.substr(8)))
		if not info2.is_empty():
			return Vector3(info2.service)
	return Vector3.ZERO


func _configure_actors():
	for key in _cast_keys:
		var body = _manager.residents().get(str(key))
		if body != null and is_instance_valid(body) and "director" in body \
				and body.director == null:
			body.director = self
			body.actor_id = str(key).trim_prefix("r_evt_")


## Cues are time-driven, so nothing waits on it.
func actor_arrived(aid: String, _pos: Vector3):
	pass


func _amb_spawn():
	var r = _restaurant()
	if r == null or _manager.traffic.lane_graph.is_empty():
		return
	var hit: Dictionary = _manager.traffic.lane_graph.nearest_on_network(r._kitchen)
	if int(hit.lane) < 0:
		return
	_amb_lane = int(hit.lane)
	_amb_target = float(hit.dist)
	_amb_dist = maxf(_amb_target - amb_approach_dist, 0.0)
	_amb_state = "arriving"
	var xf: Transform3D = _manager.traffic.lane_graph.sample(_amb_lane, _amb_target)
	_amb_park_pos = xf.origin
	# The ambulance model already faces its driving direction.
	_manager.traffic.spawn_event_car(AMB_CAR_ID, AMBULANCE_MODEL, 0.0, 20.0)


## The normal traffic sim drives it away; removed after _amb_release_t seconds.
func _amb_depart():
	_amb_state = "released"
	_amb_release_t = 45.0
	var sim: Dictionary = _manager.traffic.new_sim(_amb_lane, _amb_dist)
	sim.cruise = amb_speed
	_manager.traffic.car_sim[AMB_CAR_ID] = sim


func _drive_ambulance(delta):
	if _amb_state == "released":
		_amb_release_t -= delta
		if _amb_release_t <= 0.0:
			_amb_state = ""
			_manager.traffic.remove_event_car(AMB_CAR_ID)
		return
	if _amb_state != "arriving":
		return
	var car = _manager.traffic.cars.get(AMB_CAR_ID)
	if car == null or not is_instance_valid(car):
		return
	var lane_len: float = _manager.traffic.lane_graph.lane_length(_amb_lane)
	var gap: float = _manager.traffic.frontal_gap(car.global_transform, [car],
			_manager.people_positions_global())
	var speed: float = amb_speed
	if gap < _manager.car_look_ahead:
		var stop: float = _manager.car_stop_gap
		speed = amb_speed * clampf((gap - stop) / maxf(_manager.car_look_ahead - stop, 1.0),
				0.0, 1.0)
	_amb_dist = minf(_amb_dist + speed * delta, minf(_amb_target, lane_len))
	var xf: Transform3D = _manager.traffic.lane_graph.sample(_amb_lane, _amb_dist)
	var fwd: Vector3 = -xf.basis.z
	var origin: Vector3 = xf.origin
	origin.y = _manager.traffic.road_y(AMB_CAR_ID, origin)
	car.set_driven_state(origin, atan2(fwd.x, fwd.z) + PI, speed)
	if _amb_dist >= _amb_target or _amb_dist >= lane_len:
		_amb_state = "parked"


func _derive_siren(_delta):
	var car = _manager.traffic.cars.get(AMB_CAR_ID) if _manager != null else null
	var alive: bool = car != null and is_instance_valid(car)
	if alive and _siren == null:
		_start_siren(car)
	elif not alive:
		_siren = null
		_beacons = []
	_flash_beacons()


func _start_siren(car):
	_siren = AudioStreamPlayer3D.new()
	var stream = load(SIREN_CLIP)
	if stream != null:
		var s = stream.duplicate()
		if "loop" in s:
			s.loop = true
		_siren.stream = s
	_siren.max_distance = 220.0
	_siren.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_siren.autoplay = true
	car.add_child(_siren)
	_attach_beacons(car)


func _flash_beacons():
	var tsec := Time.get_ticks_msec() / 1000.0
	for i in _beacons.size():
		var b: Dictionary = _beacons[i]
		var on: bool = (fmod(tsec, 0.5) < 0.25) == (i % 2 == 0)
		var light = b.get("light")
		if light != null and is_instance_valid(light):
			light.light_energy = 5.0 if on else 0.15
		var mat = b.get("mat")
		if mat != null:
			mat.emission_energy_multiplier = 4.5 if on else 0.4


## A shadowed light per "sirenfront"/"sirenrear" bar, or one above the roof if there are none.
func _attach_beacons(car):
	_beacons = []
	for bar_name in ["sirenfront", "sirenrear"]:
		var node = car.find_child(bar_name, true, false)
		if node == null or not (node is Node3D):
			continue
		var mat: StandardMaterial3D = _glow_bar(node)
		# Shadows keep the flash out of the cabin and off the far side of walls.
		var light := _add_beacon_light(car)
		light.position = car.to_local((node as Node3D).global_position) + Vector3.UP * 1.2
		_beacons.append({"light": light, "mat": mat})
	if _beacons.is_empty():
		var fallback := _add_beacon_light(car)
		fallback.position = Vector3(0, 9.5, 0)
		_beacons.append({"light": fallback, "mat": null})


## Null if it has no mesh.
func _glow_bar(node: Node3D) -> StandardMaterial3D:
	var mi := _bar_mesh(node)
	if mi == null or mi.mesh == null:
		return null
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.06, 0.05)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.1, 0.08)
	for si in mi.mesh.get_surface_count():
		mi.set_surface_override_material(si, mat)
	return mat


func _bar_mesh(node: Node3D) -> MeshInstance3D:
	var mi: MeshInstance3D = node as MeshInstance3D
	if mi != null:
		return mi
	for c in node.get_children():
		if c is MeshInstance3D:
			return c
	return null


func _add_beacon_light(car) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.light_color = BEACON_COLOR
	light.omni_range = 16.0
	light.shadow_enabled = true
	car.add_child(light)
	return light


func snapshot() -> Dictionary:
	if _event_id == "":
		return {}
	return {"id": _event_id, "t": snappedf(_elapsed, 0.1)}


func apply_snapshot(data: Dictionary):
	if _manager == null or _manager.is_authority():
		return
	var id := str(data.get("id", ""))
	if id == "":
		if _event_id != "":
			_end_event()
		return
	var t := float(data.get("t", 0.0))
	if id != _event_id:
		if _load_event(id):
			_event_id = id
			_elapsed = t
			_cue_idx = 0
		return
	if absf(t - _elapsed) > 1.5:
		_elapsed = t
