extends Node3D

## Two-car tram: two ambient car units coupled back to back so the pair bends through curves.

const CAR_SCRIPT := preload("res://src/life/ambient_car.gd")

var tram_id := ""
var model_path := ""
var model_yaw_deg := 0.0
var car_len := 66.0
var last_seen_msec := 0

var _is_authority := true
var _units: Array = []  # [faces +track tangent, faces -track tangent]
var _remote_pos: Array = [Vector3.ZERO, Vector3.ZERO]
var _remote_rot: Array = [0.0, 0.0]
var _got_remote := false

const ROLL_LOOP := "res://assets/art/sound/city/tram_rolling_loop.mp3"
const BELL_CLIP := "res://assets/art/sound/city/tram_bell.mp3"
var _roll_players: Array = []
var _bell: AudioStreamPlayer3D = null
var _speed_est := 0.0
var _audio_prev := Vector3.INF
var _stopped_t := 0.0


func _ready():
	for i in 2:
		var unit := Node3D.new()
		unit.set_script(CAR_SCRIPT)
		unit.name = "Car%d" % i
		unit.model_path = model_path
		unit.model_yaw_deg = model_yaw_deg
		unit.target_len = car_len
		add_child(unit)
		unit.set_authority(true)
		_units.append(unit)


func units() -> Array:
	return _units


func set_authority(is_auth: bool) -> void:
	_is_authority = is_auth
	if not is_auth:
		for i in 2:
			_remote_pos[i] = _units[i].position
			_remote_rot[i] = _units[i].rotation.y


## Positions are workspace-local.
func set_driven_units(p0: Vector3, y0: float, p1: Vector3, y1: float, speed: float) -> void:
	_units[0].set_driven_state(p0, y0, speed)
	_units[1].set_driven_state(p1, y1, speed)


## The first update snaps.
func apply_remote_units(p0: Vector3, y0: float, p1: Vector3, y1: float) -> void:
	if not _got_remote:
		_units[0].set_driven_state(p0, y0, 0.0)
		_units[1].set_driven_state(p1, y1, 0.0)
		_got_remote = true
	_remote_pos = [p0, p1]
	_remote_rot = [y0, y1]
	last_seen_msec = Time.get_ticks_msec()


func _process(delta: float):
	_update_audio(delta)
	if _is_authority:
		return
	for i in 2:
		var unit: Node3D = _units[i]
		unit.position = unit.position.lerp(_remote_pos[i], delta * 10.0)
		unit.rotation.y = lerp_angle(unit.rotation.y, _remote_rot[i], delta * 10.0)


func _update_audio(delta: float):
	if _units.size() < 2 or delta <= 0.0:
		return
	if _roll_players.is_empty():
		_build_audio()
	var p0: Vector3 = (_units[0] as Node3D).position
	if _audio_prev == Vector3.INF:
		_audio_prev = p0
	_speed_est = lerpf(_speed_est, p0.distance_to(_audio_prev) / delta, minf(delta * 6.0, 1.0))
	_audio_prev = p0
	var rolling := clampf(_speed_est / 10.0, 0.0, 1.0)
	for roll in _roll_players:
		(roll as AudioStreamPlayer3D).volume_db = move_toward(
			(roll as AudioStreamPlayer3D).volume_db, -34.0 + rolling * 24.0, delta * 25.0)
		(roll as AudioStreamPlayer3D).pitch_scale = 0.8 + rolling * 0.5
	if _speed_est < 0.4:
		_stopped_t += delta
	else:
		if _stopped_t > 2.5 and _bell != null and _bell.stream != null:
			_bell.play()
		_stopped_t = 0.0


func _build_audio():
	for u in _units:
		var roll := AudioStreamPlayer3D.new()
		roll.stream = CAR_SCRIPT.looped_stream(ROLL_LOOP)
		roll.max_distance = 80.0
		roll.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		roll.volume_db = -80.0
		roll.autoplay = true
		(u as Node3D).add_child(roll)
		_roll_players.append(roll)
	_bell = AudioStreamPlayer3D.new()
	var bell_clip = load(BELL_CLIP)
	if bell_clip != null:
		_bell.stream = bell_clip
	_bell.max_distance = 130.0
	_bell.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	(_units[0] as Node3D).add_child(_bell)


## The unit facing the travel direction (dir >= 0: unit 0, else unit 1).
func lead_frame(dir: int) -> Transform3D:
	var lead: Node3D = _units[0] if dir >= 0 else _units[1]
	return lead.global_transform
