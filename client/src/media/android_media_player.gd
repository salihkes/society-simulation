class_name AndroidMediaPlayer
extends RefCounted
## Android playback via the media3 MediaBridge plugin when built in, else MediaPlayer; call poll() every frame.

signal prepared(width: int, height: int, duration_ms: int)
signal completed
signal failed(message: String)

enum State { IDLE, PREPARING, READY, PLAYING, PAUSED, ERROR }

var state: int = State.IDLE
var looping := false

var _mp = null # JavaObject android.media.MediaPlayer
var _thread: Thread
var _abandoned := false

## media3 (ExoPlayer) bridge, when the plugin is in the build.
var _bridge = null
var _bridge_ready := false

## ExoPlayer playback states.
const EXO_IDLE := 1
const EXO_BUFFERING := 2
const EXO_READY := 3
const EXO_ENDED := 4


static func is_supported() -> bool:
	return OS.has_feature("android")


## Null when the media3 plugin is not in this APK.
static func bridge_class():
	if not OS.has_feature("android"):
		return null
	var cls = JavaClassWrapper.wrap(Identity.value("android_package") + ".MediaBridge")
	JavaClassWrapper.get_exception()
	return cls


static func has_ffmpeg_decoders() -> bool:
	return bridge_class() != null


## `surface` is an android.view.Surface, or null for audio only; `prepared` or `failed` follows.
func open(source: String, surface = null, loop := false) -> bool:
	release()
	if not is_supported():
		_fail("AndroidMediaPlayer requires an Android build")
		return false
	_bridge = bridge_class()
	if _bridge != null:
		return _open_via_bridge(source, surface, loop)
	var MediaPlayer = JavaClassWrapper.wrap("android.media.MediaPlayer")
	if MediaPlayer == null:
		_fail("JavaClassWrapper could not wrap android.media.MediaPlayer")
		return false
	_mp = MediaPlayer.MediaPlayer()
	looping = loop
	if surface != null:
		_mp.setSurface(surface)
	_mp.setLooping(loop)
	var exc = JavaClassWrapper.get_exception()
	if exc:
		_fail(str(exc))
		return false
	_abandoned = false
	state = State.PREPARING
	_thread = Thread.new()
	_thread.start(_prepare_on_thread.bind(source))
	return true


## Needs the media3 bridge's FrameSplitter.
static func can_split() -> bool:
	return bridge_class() != null


## Each eye's surface comes later via set_split_output(); a valid offset/size plays an archive slice.
func open_split(source: String, offset: int = -1, size: int = -1, loop := false) -> bool:
	release()
	_bridge = bridge_class()
	if _bridge == null:
		_fail("Stereo video needs the media3 build")
		return false
	var runtime = Engine.get_singleton("AndroidRuntime")
	if runtime == null:
		_fail("No AndroidRuntime")
		return false
	_bridge.init(runtime.getActivity())
	looping = loop
	_bridge_ready = false
	_bridge.openSplit(source, offset, size, loop)
	return _check_bridge_open("media3 bridge could not open for stereo")


## `crop` is the eye's share of the frame, v=0 at the top (MediaProjection.eye_crop).
func set_split_output(eye: int, surface, crop: Rect2) -> bool:
	if _bridge == null:
		return false
	_bridge.setSplitOutput(eye, surface,
		crop.position.x, crop.position.y, crop.size.x, crop.size.y)
	return JavaClassWrapper.get_exception() == null


## Plays a video stored inside a ZIM archive without extracting it; media3 only.
func open_range(file_path: String, offset: int, size: int, surface = null, loop := false) -> bool:
	release()
	_bridge = bridge_class()
	if _bridge == null:
		_fail("Playing from inside an archive needs the media3 build")
		return false
	var runtime = Engine.get_singleton("AndroidRuntime")
	if runtime == null:
		_fail("No AndroidRuntime")
		return false
	_bridge.init(runtime.getActivity())
	looping = loop
	_bridge_ready = false
	_bridge.openRange(file_path, offset, size, surface, loop)
	return _check_bridge_open("media3 bridge could not open that range")


## MediaPlayer setDataSource + prepare block on I/O.
func _prepare_on_thread(source: String) -> void:
	var result := {"ok": false, "message": "", "width": 0, "height": 0, "duration": 0}
	_mp.setDataSource(source)
	var exc = JavaClassWrapper.get_exception()
	if exc == null:
		_mp.prepare()
		exc = JavaClassWrapper.get_exception()
	if exc != null:
		result.message = str(exc)
	else:
		result.ok = true
		result.width = int(_mp.getVideoWidth())
		result.height = int(_mp.getVideoHeight())
		result.duration = int(_mp.getDuration())
	call_deferred("_finish_prepare", result)


func _finish_prepare(result: Dictionary) -> void:
	if _thread:
		_thread.wait_to_finish()
		_thread = null
	if _abandoned:
		_do_release()
		return
	if not result.ok:
		_fail(str(result.message))
		return
	state = State.READY
	prepared.emit(result.width, result.height, result.duration)


func play() -> void:
	if _bridge != null:
		_bridge.play()
		return
	if _mp == null or state not in [State.READY, State.PAUSED]:
		return
	_mp.start()
	state = State.PLAYING


func pause() -> void:
	if _bridge != null:
		_bridge.pause()
		return
	if _mp == null or state != State.PLAYING:
		return
	_mp.pause()
	state = State.PAUSED


## Pauses and rewinds; MediaPlayer.stop() would force a re-prepare.
func stop() -> void:
	if _bridge != null:
		_bridge.stop()
		state = State.READY
		return
	if _mp == null or state not in [State.PLAYING, State.PAUSED]:
		return
	if state == State.PLAYING:
		_mp.pause()
	_mp.seekTo(0)
	state = State.READY


func seek_ms(ms: int) -> void:
	if _bridge != null:
		_bridge.seekTo(ms)
		return
	if _mp != null and state in [State.READY, State.PLAYING, State.PAUSED]:
		_mp.seekTo(ms)


func position_ms() -> int:
	if _bridge != null:
		return int(_bridge.getPositionMs())
	if _mp != null and state in [State.READY, State.PLAYING, State.PAUSED]:
		return int(_mp.getCurrentPosition())
	return 0


func duration_ms() -> int:
	if _bridge != null:
		return int(_bridge.getDurationMs())
	if _mp != null and state in [State.READY, State.PLAYING, State.PAUSED]:
		return int(_mp.getDuration())
	return 0


## [{index, type, mime, language}]; the bridge lists only audio and subtitle tracks.
func track_info() -> Array:
	if _bridge != null:
		return _bridge_track_info()
	var out: Array = []
	if _mp == null or state == State.IDLE or state == State.ERROR:
		return out
	var tracks = _mp.getTrackInfo()
	if JavaClassWrapper.get_exception() or tracks == null:
		return out
	var i := 0
	for t in tracks:
		out.append(_mp_track_entry(t, i))
		i += 1
	return out


func _bridge_track_info() -> Array:
	var parsed = JSON.parse_string(str(_bridge.getTracksJson()))
	if typeof(parsed) != TYPE_ARRAY:
		return []
	var mapped: Array = []
	for t in parsed:
		mapped.append({
			"index": int(t.get("index", 0)),
			"type": "audio" if str(t.get("kind", "")) == "audio" else "subtitle",
			"mime": str(t.get("mime", "")),
			"language": str(t.get("language", "")),
		})
	return mapped


func _mp_track_entry(t, i: int) -> Dictionary:
	var entry := {"index": i, "type": "other", "mime": "", "language": ""}
	if t == null:
		return entry
	match int(t.getTrackType()):
		1: entry.type = "video"
		2: entry.type = "audio"
		4: entry.type = "subtitle"
	JavaClassWrapper.get_exception()
	var fmt = t.getFormat()
	if JavaClassWrapper.get_exception() or fmt == null:
		return entry
	var mime = fmt.getString("mime")
	if not JavaClassWrapper.get_exception() and mime != null:
		entry.mime = str(mime)
	var lang = fmt.getString("language")
	if not JavaClassWrapper.get_exception() and lang != null:
		entry.language = str(lang)
	return entry


## `index` among the subtitle entries of track_info(); -1 turns them off. media3 only.
func select_text_track(index: int) -> bool:
	if _bridge == null:
		return false
	_bridge.selectTextTrack(index)
	return JavaClassWrapper.get_exception() == null


func select_track(index: int) -> bool:
	if _bridge != null:
		_bridge.selectAudioTrack(index)
		return JavaClassWrapper.get_exception() == null
	if _mp == null or state not in [State.READY, State.PLAYING, State.PAUSED]:
		return false
	_mp.selectTrack(index)
	return JavaClassWrapper.get_exception() == null


func set_volume(linear: float) -> void:
	if _bridge != null:
		_bridge.setVolume(clampf(linear, 0.0, 1.0))
		return
	if _mp != null and state != State.ERROR:
		var v := clampf(linear, 0.0, 1.0)
		_mp.setVolume(v, v)


## MediaPlayer only; does nothing with the bridge.
func set_stereo_volume(left: float, right: float) -> void:
	if _mp != null and state in [State.READY, State.PLAYING, State.PAUSED]:
		_mp.setVolume(clampf(left, 0.0, 1.0), clampf(right, 0.0, 1.0))


## Call every frame; emits the signals.
func poll() -> void:
	if _bridge != null:
		if state != State.IDLE and state != State.ERROR:
			_poll_bridge()
		return
	if state != State.PLAYING or _mp == null or looping:
		return
	if not _mp.isPlaying():
		var dur := duration_ms()
		if dur > 0 and position_ms() >= dur - 400:
			state = State.READY
			_mp.seekTo(0)
			completed.emit()
		else:
			# Paused externally (e.g. OS audio focus loss), not finished.
			state = State.PAUSED


## A MediaPlayer still preparing is freed when its thread finishes.
func release() -> void:
	if _bridge != null:
		_bridge.release()
		_bridge = null
		_bridge_ready = false
		state = State.IDLE
		return
	if _thread and _thread.is_alive():
		# The prepare thread still owns _mp; let _finish_prepare dispose of it.
		_abandoned = true
		return
	if _thread:
		_thread.wait_to_finish()
		_thread = null
	_do_release()


func _do_release() -> void:
	if _mp != null:
		_mp.release()
		JavaClassWrapper.get_exception() # swallow, we're done with it
		_mp = null
	state = State.IDLE


func _fail(message: String) -> void:
	state = State.ERROR
	push_warning("AndroidMediaPlayer: %s" % message)
	failed.emit(message)


func _open_via_bridge(source: String, surface, loop: bool) -> bool:
	var runtime = Engine.get_singleton("AndroidRuntime")
	if runtime == null:
		_bridge = null
		_fail("No AndroidRuntime; cannot reach the media3 bridge")
		return false
	_bridge.init(runtime.getActivity())
	if JavaClassWrapper.get_exception():
		_bridge = null
		_fail("media3 bridge failed to initialise")
		return false
	looping = loop
	_bridge_ready = false
	_bridge.open(source, surface, loop)
	return _check_bridge_open("media3 bridge could not open the source")


## Fails with `message` on a Java exception, else enters PREPARING.
func _check_bridge_open(message: String) -> bool:
	if JavaClassWrapper.get_exception():
		_bridge = null
		_fail(message)
		return false
	state = State.PREPARING
	return true


func _poll_bridge() -> void:
	var err := str(_bridge.getError())
	if not err.is_empty():
		_fail(err)
		return
	var exo_state := int(_bridge.getState())
	if not _bridge_ready and exo_state == EXO_READY:
		_bridge_ready = true
		state = State.READY
		prepared.emit(int(_bridge.getVideoWidth()), int(_bridge.getVideoHeight()),
			int(_bridge.getDurationMs()))
		if _bridge == null:
			return              # a prepared listener released this player
	if not _bridge_ready:
		return
	if exo_state == EXO_ENDED and not looping:
		if state != State.READY:
			state = State.READY
			completed.emit()
		return
	state = State.PLAYING if _bridge.isPlaying() else State.PAUSED


## media3 only.
func subtitle() -> String:
	if _bridge == null:
		return ""
	return str(_bridge.getSubtitle())


## Pixel aspect applied; 0.0 until known. media3 only.
func video_aspect() -> float:
	if _bridge == null:
		return 0.0
	var w := float(_bridge.getVideoWidth())
	var h := float(_bridge.getVideoHeight())
	if w <= 0.0 or h <= 0.0:
		return 0.0
	return w * float(_bridge.getVideoPixelRatio()) / h


## (0, 0) until known.
func video_size() -> Vector2i:
	if _bridge == null:
		return Vector2i.ZERO
	return Vector2i(int(_bridge.getVideoWidth()), int(_bridge.getVideoHeight()))


## "ffmpeg..." proves the extension is running.
func audio_decoder() -> String:
	if _bridge == null:
		return ""
	return str(_bridge.getAudioDecoder())
