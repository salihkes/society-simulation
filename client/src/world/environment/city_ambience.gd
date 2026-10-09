extends Node
## City ambience beds and gull calls set by the game clock, the season and the weather; no network.

const DIR := "res://assets/art/sound/city"

@export var traffic_day_db := -6.0
@export var people_day_db := -9.0
@export var cicadas_db := -12.0

var _traffic: AudioStreamPlayer = null
var _people: AudioStreamPlayer = null
var _cicadas: AudioStreamPlayer = null
var _gull: AudioStreamPlayer = null
var _env_ctl = null
var _weather = null
var _gull_timer := 20.0
var _poll := 0.0
var _t_target := -80.0
var _p_target := -80.0
var _c_target := -80.0


func _ready():
	_traffic = _make_loop(DIR + "/city_day_traffic.mp3")
	_people = _make_loop(DIR + "/city_day_people.mp3")
	_cicadas = _make_loop(DIR + "/night_cicadas.mp3")
	_gull = AudioStreamPlayer.new()
	add_child(_gull)


## A silent looping player; on web its stream arrives with the sound pack.
func _make_loop(path: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.volume_db = -80.0
	player.autoplay = true
	add_child(player)
	if ResourceLoader.exists(path):
		_assign_loop(player, path)
	else:
		var pm = get_node_or_null("/root/PCKManager")
		if pm != null and pm.has_method("when_available"):
			pm.when_available(path, func(): _assign_loop(player, path))
		else:
			push_warning("[CityAmbience] Missing stream: " + path)
	return player


func _assign_loop(player: AudioStreamPlayer, path: String) -> void:
	if not is_instance_valid(player):
		return
	var stream = load(path)
	if stream == null:
		push_warning("[CityAmbience] Missing stream: " + path)
		return
	var s = stream.duplicate()
	if "loop" in s:
		s.loop = true
	player.stream = s
	if not player.playing:
		player.play()


## The game hour from EnvironmentController, else the system clock.
func _hour() -> float:
	if _env_ctl == null or not is_instance_valid(_env_ctl):
		var root := get_tree().current_scene
		if root != null:
			_env_ctl = root.find_child("EnvironmentController", true, false)
	if _env_ctl != null:
		return float(_env_ctl.current_time) * 24.0
	var t := Time.get_time_dict_from_system()
	return float(t.hour) + float(t.minute) / 60.0


## True from about mid-May to mid-September by the system date.
func _summer() -> bool:
	var date := Time.get_datetime_dict_from_system()
	var doy := int(date.get("month", 6)) * 30 + int(date.get("day", 15))
	return doy >= 165 and doy <= 285


## Decibels to lower the beds by for the current weather.
func _weather_duck() -> float:
	if _weather == null or not is_instance_valid(_weather):
		var root := get_tree().current_scene
		if root != null:
			_weather = root.find_child("WeatherController", true, false)
	if _weather == null:
		return 0.0
	if _weather.is_precipitating():
		return -12.0
	if str(_weather.current_type()) == "windy":
		return -4.0
	return 0.0


func _process(delta):
	# Ease every layer towards its target so day fades into night.
	for pair in [[_traffic, _t_target], [_people, _p_target], [_cicadas, _c_target]]:
		var player: AudioStreamPlayer = pair[0]
		if player != null:
			player.volume_db = move_toward(player.volume_db, float(pair[1]), delta * 6.0)
	_poll += delta
	if _poll >= 1.0:
		_poll = 0.0
		_update_targets()
	_gull_timer -= delta
	if _gull_timer <= 0.0:
		_gull_timer = randf_range(25.0, 70.0)
		_maybe_play_gull()


func _update_targets() -> void:
	var h := _hour()
	var duck := _weather_duck()
	var day := h >= 7.0 and h < 19.0
	var evening := h >= 19.0 and h < 23.0
	if day:
		_t_target = traffic_day_db + duck
		_p_target = people_day_db + duck
	elif evening:
		_t_target = traffic_day_db - 6.0 + duck
		_p_target = people_day_db - 9.0 + duck
	else:
		_t_target = traffic_day_db - 16.0 + duck
		_p_target = -80.0
	_c_target = cicadas_db + duck if (_summer() and h >= 9.0 and h < 19.5) else -80.0


func _maybe_play_gull() -> void:
	var h := _hour()
	if h >= 6.5 and h < 20.0 and _weather_duck() > -10.0 and _gull != null:
		var clip = load(DIR + ("/gull_1.mp3" if randf() < 0.5 else "/gull_2.mp3"))
		if clip != null:
			_gull.stream = clip
			_gull.volume_db = randf_range(-10.0, -3.0)
			_gull.play()
