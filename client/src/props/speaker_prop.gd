extends Node3D

## Street speaker: loops `stream` from a random offset, or plays once at `ring_hour`.

@export var stream: AudioStream = null
@export var stream_path := ""
@export var volume_db := 0.0
@export var max_distance := 60.0
@export var autoplay := true
@export var loop := true
@export var sync_start := false
## -1 loops; 0-23 plays once from the start each time the game clock enters that hour.
@export var ring_hour := -1

var _player: AudioStreamPlayer3D = null
var _env = null
var _poll := 0.0
var _rung := false


func _ready():
	var s: AudioStream = stream
	if s == null and stream_path != "":
		var loaded = load(stream_path)
		if loaded is AudioStream:
			s = loaded
	if s == null:
		return
	if loop and ring_hour < 0:
		# Duplicate so the shared resource stays as authored.
		s = s.duplicate()
		if "loop" in s:
			s.loop = true
		elif s is AudioStreamWAV:
			(s as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	_player = AudioStreamPlayer3D.new()
	_player.stream = s
	_player.volume_db = volume_db
	_player.max_distance = max_distance
	_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(_player)
	if ring_hour >= 0:
		call_deferred("_find_env")
		_poll = randf_range(0.0, 0.4)
		return
	set_process(false)
	if autoplay:
		play()


func _find_env():
	var root := get_tree().current_scene
	if root:
		_env = root.find_child("EnvironmentController", true, false)


func _process(delta):
	_poll += delta
	if _poll < 0.5:
		return
	_poll = 0.0
	var hour := -1
	if _env != null and is_instance_valid(_env):
		hour = int(float(_env.current_time) * 24.0)
	else:
		hour = Time.get_time_dict_from_system().hour
	if hour == ring_hour:
		if not _rung:
			_rung = true
			if _player:
				_player.play(0.0)
	else:
		_rung = false


func play():
	if _player == null:
		return
	var from := 0.0
	if not sync_start and _player.stream != null:
		var length: float = _player.stream.get_length()
		if length > 0.5:
			from = randf() * length
	_player.play(from)


func stop():
	if _player:
		_player.stop()
