extends Node
## Records the studio SubViewport to .mp4 through ffmpeg (raw RGB on stdin, audio muxed after) and saves PNG snapshots.

signal started(path: String)
signal finished(path: String, ok: bool, message: String)
signal log_line(text: String)

var viewport: SubViewport
var fps := 30
var pace_wall_clock := true
var record_audio := true
var out_dir := ""
var ffmpeg_path := ""
var crf := 17

var recording := false
var final_path := ""
var frames := 0

var _pipe: FileAccess = null
var _pid := -1
var _mux_pid := -1
## "", "video", "flush" or "mux".
var _phase := ""
var _tmp_video := ""
var _tmp_wav := ""
var _log_path := ""
var _t0_usec := 0
var _effect: AudioEffectRecord = null
var _bus := 0
var _saved_max_fps := 0
var _wait_frames := 0
var _hooked := false


func _ready() -> void:
	set_process(false)


## 0 when not recording.
func elapsed_seconds() -> float:
	if not recording:
		return 0.0
	return (Time.get_ticks_usec() - _t0_usec) / 1e6


## ffmpeg_path, $FFMPEG, a usual install path or `which ffmpeg`; "" if none.
func find_ffmpeg() -> String:
	if ffmpeg_path != "" and FileAccess.file_exists(ffmpeg_path):
		return ffmpeg_path
	var env := OS.get_environment("FFMPEG")
	if env != "" and FileAccess.file_exists(env):
		return env
	for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]:
		if FileAccess.file_exists(p):
			return p
	var out := []
	if OS.execute("/usr/bin/which", ["ffmpeg"], out) == 0 and out.size() > 0:
		var p := str(out[0]).strip_edges()
		if p != "" and FileAccess.file_exists(p):
			return p
	return ""


func _stamp() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d_%02d%02d%02d" % [t.year, t.month, t.day, t.hour, t.minute, t.second]


## Default out_dir: Movies/<studio_dir>.
func _ensure_dirs() -> bool:
	if out_dir == "":
		out_dir = OS.get_system_dir(OS.SYSTEM_DIR_MOVIES).path_join(Identity.value("studio_dir"))
	var err := DirAccess.make_dir_recursive_absolute(out_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		return false
	DirAccess.make_dir_recursive_absolute(out_dir.path_join(".studio"))
	return true


## Stderr goes to a log so it can never fill a pipe and stall ffmpeg.
func _wrapped(ffmpeg: String, args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray(["-c", "exec \"$0\" \"$@\" 2>>\"%s\"" % _log_path, ffmpeg])
	out.append_array(args)
	return out


## Returns the path, or "" on failure.
func snapshot() -> String:
	if viewport == null or not _ensure_dirs():
		return ""
	var img := viewport.get_texture().get_image()
	if img == null:
		return ""
	var path := out_dir.path_join(Identity.value("capture_prefix") + "%s.png" % _stamp())
	if img.save_png(path) != OK:
		return ""
	return path


func start() -> bool:
	if recording or _phase != "":
		return false
	if viewport == null:
		_say("no viewport to record")
		return false
	var ffmpeg := find_ffmpeg()
	if ffmpeg == "":
		_say("ffmpeg not found (brew install ffmpeg, or set FFMPEG=/path)")
		return false
	if not _ensure_dirs():
		_say("cannot create " + out_dir)
		return false
	var stamp := _stamp()
	final_path = out_dir.path_join(Identity.value("capture_prefix") + "%s.mp4" % stamp)
	_log_path = out_dir.path_join(".studio/ffmpeg.log")
	_tmp_video = out_dir.path_join(".studio/%s_video.mp4" % stamp)
	_tmp_wav = out_dir.path_join(".studio/%s_audio.wav" % stamp)
	var target := _tmp_video if record_audio else final_path
	var r := OS.execute_with_pipe("/bin/sh", _wrapped(ffmpeg, _encode_args(target)), true)
	if r.is_empty() or not r.has("stdio") or int(r.get("pid", -1)) <= 0:
		_say("could not start ffmpeg")
		return false
	_pipe = r["stdio"]
	_pid = int(r["pid"])
	frames = 0
	_t0_usec = Time.get_ticks_usec()
	if record_audio:
		_bus = AudioServer.get_bus_index("Master")
		_effect = AudioEffectRecord.new()
		AudioServer.add_bus_effect(_bus, _effect)
		_effect.set_recording_active(true)
	if not pace_wall_clock:
		_saved_max_fps = Engine.max_fps
		Engine.max_fps = fps
	recording = true
	_phase = "video"
	if not _hooked:
		RenderingServer.frame_post_draw.connect(_on_frame)
		_hooked = true
	_say("recording → " + final_path)
	started.emit(final_path)
	return true


func _encode_args(target: String) -> PackedStringArray:
	var size := viewport.size
	return PackedStringArray([
		"-hide_banner", "-loglevel", "warning", "-nostats", "-y",
		"-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % [size.x, size.y],
		"-r", str(fps), "-i", "-", "-an",
		"-c:v", "libx264", "-preset", "veryfast", "-crf", str(crf),
		"-pix_fmt", "yuv420p", "-movflags", "+faststart", target])


## With pace_wall_clock, frames are repeated or skipped so the clip runs at real speed.
func _on_frame() -> void:
	if not recording or _pipe == null:
		return
	var due := 1
	if pace_wall_clock:
		var slot := int(floor((Time.get_ticks_usec() - _t0_usec) * fps / 1000000.0)) + 1
		due = mini(slot - frames, fps * 5)
		if due <= 0:
			return
	var img := viewport.get_texture().get_image()
	if img == null:
		return
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	var data := img.get_data()
	for i in due:
		_pipe.store_buffer(data)
	if _pipe.get_error() != OK:
		_say("ffmpeg stopped taking frames — see " + _log_path)
		stop()
		return
	frames += due


## _process then waits for ffmpeg and muxes the audio.
func stop() -> void:
	if not recording:
		return
	recording = false
	if _hooked:
		RenderingServer.frame_post_draw.disconnect(_on_frame)
		_hooked = false
	if not pace_wall_clock:
		Engine.max_fps = _saved_max_fps
	if _pipe != null:
		_pipe.close()
		_pipe = null
	if _effect != null:
		_effect.set_recording_active(false)
	_phase = "flush"
	_wait_frames = 0
	set_process(true)


func _process(_delta: float) -> void:
	match _phase:
		"flush":
			_process_flush()
		"mux":
			_process_mux()
		_:
			set_process(false)


## Without audio the silent video is kept as the result.
func _process_flush() -> void:
	if OS.is_process_running(_pid):
		_wait_frames += 1
		if _wait_frames > 60 * 60:
			OS.kill(_pid)
			_finish(false, "ffmpeg did not finish")
		return
	if not record_audio or _effect == null:
		_finish(FileAccess.file_exists(final_path), "")
		return
	var wav: AudioStreamWAV = _effect.get_recording()
	AudioServer.remove_bus_effect(_bus, AudioServer.get_bus_effect_count(_bus) - 1)
	_effect = null
	if wav == null or wav.save_to_wav(_tmp_wav) != OK:
		DirAccess.rename_absolute(_tmp_video, final_path)
		_finish(true, "no audio captured")
		return
	var ffmpeg := find_ffmpeg()
	var args := PackedStringArray([
		"-hide_banner", "-loglevel", "warning", "-nostats", "-y",
		"-i", _tmp_video, "-i", _tmp_wav,
		"-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest",
		"-movflags", "+faststart", final_path])
	_mux_pid = OS.create_process("/bin/sh", _wrapped(ffmpeg, args))
	if _mux_pid <= 0:
		DirAccess.rename_absolute(_tmp_video, final_path)
		_finish(true, "audio mux could not start; video kept without sound")
		return
	_phase = "mux"
	_wait_frames = 0


## On failure the silent video becomes the result.
func _process_mux() -> void:
	if OS.is_process_running(_mux_pid):
		_wait_frames += 1
		if _wait_frames > 60 * 120:
			OS.kill(_mux_pid)
			DirAccess.rename_absolute(_tmp_video, final_path)
			_finish(true, "audio mux timed out; video kept without sound")
		return
	var ok := FileAccess.file_exists(final_path)
	if ok:
		DirAccess.remove_absolute(_tmp_video)
		DirAccess.remove_absolute(_tmp_wav)
	else:
		DirAccess.rename_absolute(_tmp_video, final_path)
	_finish(true, "" if ok else "audio mux failed; video kept without sound")


func _finish(ok: bool, message: String) -> void:
	_phase = ""
	set_process(false)
	var secs := frames / float(maxi(fps, 1))
	var text := "saved %s (%d frames, %.1f s)" % [final_path.get_file(), frames, secs]
	if message != "":
		text += " — " + message
	_say(text if ok else "recording failed: " + message)
	finished.emit(final_path, ok, message)


func _say(text: String) -> void:
	print("[Studio/rec] " + text)
	log_line.emit(text)
