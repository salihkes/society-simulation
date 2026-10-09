extends NpcAction
## Plays an NPC audio clip with a talk animation; asks the server for it when not cached.

var audio_path: String = ""
var fallback_duration: float = 5.0

var _timer: float = 0.0
var _duration: float = 0.0
var _has_audio: bool = false
var _audio_player: AudioStreamPlayer3D = null


func start(npc: CharacterBody3D) -> void:
	_finished = false
	_timer = 0.0

	_audio_player = npc.get_node_or_null("SoundPlayer")
	if _audio_player == null or audio_path == "":
		_start_fallback(npc)
		return

	var cache_path = "user://npc_audio_cache/" + audio_path
	if _try_play(npc, cache_path):
		return

	var local_path = "res://assets/entities/pedestrians/audio/" + audio_path
	if _try_play(npc, local_path):
		return

	if npc._npc_manager_ref and npc._npc_manager_ref.has_method("request_npc_audio"):
		npc._npc_manager_ref.request_npc_audio(audio_path)
	_start_fallback(npc)


func _try_play(npc: CharacterBody3D, path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var stream = load(path) if path.begins_with("res://") else _load_user_audio(path)
	if stream == null:
		return false
	_audio_player.stream = stream
	_audio_player.play()
	_has_audio = true
	_duration = stream.get_length()
	if _duration <= 0.0:
		_duration = fallback_duration
	print("[PlayAudio] %s playing '%s' (%.1fs)" % [npc.name, path, _duration])
	npc.start_talk_animation(_duration)
	npc._broadcast_event("audio_play", {"path": audio_path, "duration": _duration})
	return true


## Builds an mp3/ogg/wav stream from a user:// file, which load() cannot read.
func _load_user_audio(path: String):
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var data = file.get_buffer(file.get_length())
	file.close()

	if path.ends_with(".mp3"):
		var stream = AudioStreamMP3.new()
		stream.data = data
		return stream
	elif path.ends_with(".ogg"):
		var stream = AudioStreamOggVorbis.load_from_buffer(data)
		return stream
	elif path.ends_with(".wav"):
		var stream = AudioStreamWAV.new()
		stream.data = data
		return stream
	return null


func _start_fallback(npc: CharacterBody3D):
	_has_audio = false
	_duration = fallback_duration
	# The NPC's _on_audio_cached() looks this up to call late_play().
	npc.set_meta("_pending_audio_action", self)
	print("[PlayAudio] %s fallback talk for %.1fs (audio not yet cached: '%s')" % [npc.name, _duration, audio_path])
	npc.start_talk_animation(_duration)
	npc._broadcast_event("audio_play", {"path": audio_path, "duration": _duration})


func process(npc: CharacterBody3D, delta: float) -> void:
	_timer += delta
	if _timer >= _duration:
		_finished = true
	elif _has_audio and _audio_player and not _audio_player.playing:
		_finished = true


func stop(npc: CharacterBody3D) -> void:
	if _has_audio and _audio_player and _audio_player.playing:
		_audio_player.stop()
	npc.stop_talk_animation()
	npc._broadcast_event("audio_stop", {})
	npc.remove_meta("_pending_audio_action")


## Starts audio that arrived from the server while the action is running.
func late_play(npc: CharacterBody3D, cache_path: String):
	if _audio_player == null:
		return
	var stream = npc._load_cached_audio(cache_path)
	if stream:
		_audio_player.stream = stream
		_audio_player.play()
		_has_audio = true
		print("[PlayAudio] %s late-loaded: %s" % [npc.name, cache_path])
