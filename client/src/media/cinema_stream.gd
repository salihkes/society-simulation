class_name CinemaStream
extends Node
## Video channel over a WebSocket as JPEG frames and WAV chunks (tv's cinema.py), for builds without a decoder.

signal connected
signal closed(reason: String)
signal resized(w: int, h: int)
signal frame

## Must match the Python side (cinema.py).
const WAV_HEADER_SIZE := 44
const AUDIO_CHANNELS := 2
const AUDIO_SAMPLE_RATE := 48000
const AUDIO_BITS_PER_SAMPLE := 16

## Most buffered audio, i.e. how far sound trails the picture; under the lip-sync threshold.
const AUDIO_TARGET_LATENCY_MS := 80
const AUDIO_TARGET_LATENCY_FRAMES := AUDIO_TARGET_LATENCY_MS * AUDIO_SAMPLE_RATE / 1000

const BUFFER_LENGTH_S := 0.25   ## generator capacity; the cap above sets latency

## Reconnect backoff; retries never stop, since the station may start later.
const RECONNECT_BASE_S := 2.0
const RECONNECT_MAX_S := 30.0

## Null until the first frame arrives.
var texture: ImageTexture
var width := 0
var height := 0
var is_open := false
## Set before open() to reuse a speaker; left null, a child player is made.
var audio_player: Node = null

## Only used when this node makes its own AudioStreamPlayer3D.
var volume_db := 0.0
var max_distance := 30.0
var attenuation_model := 0      # ATTENUATION_INVERSE_DISTANCE
var unit_size := 10.0

var _ws := WebSocketPeer.new()
var _img := Image.new()
var stream_url := ""
var _was_open := false
var _generator: AudioStreamGenerator
var _playback: AudioStreamGeneratorPlayback
var _owns_audio := false
var _retry_at := 0.0
var _retries := 0
var _frames := 0


## ws://host:3245 locally, wss://host/cinema for a remote world, "" without a NetworkController.
static func default_url(tree: SceneTree) -> String:
	var nc = tree.root.get_node_or_null("NetworkController")
	if nc != null and nc.has_method("service_url"):
		return nc.service_url("cinema")
	return ""


## default_url() when empty; replaces any channel.
func open(url := "") -> void:
	if url == "":
		url = default_url(get_tree())
	if url == "":
		push_warning("CinemaStream: no URL and no NetworkController to ask")
		return
	close("reopen")
	stream_url = url
	_setup_audio()
	_ws = WebSocketPeer.new()
	# A 720x480 JPEG is tens of kilobytes; leave room for a burst of them.
	_ws.inbound_buffer_size = 8 << 20
	_ws.max_queued_packets = 256
	_retries = 0
	_connect()
	set_process(true)


func close(reason := "closed") -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_ws.close()
	if _was_open:
		_was_open = false
		is_open = false
		closed.emit(reason)
	set_process(false)


func _connect() -> void:
	var err := _ws.connect_to_url(stream_url)
	if err != OK:
		_schedule_retry()


func _schedule_retry() -> void:
	_retries += 1
	var wait: float = minf(RECONNECT_BASE_S * pow(2.0, _retries - 1), RECONNECT_MAX_S)
	_retry_at = Time.get_ticks_msec() / 1000.0 + wait
	if _retries == 1:
		print("CinemaStream: %s unreachable; retrying" % stream_url)


func _setup_audio() -> void:
	if audio_player == null:
		_make_speaker()
	_generator = AudioStreamGenerator.new()
	_generator.mix_rate = AUDIO_SAMPLE_RATE
	_generator.buffer_length = BUFFER_LENGTH_S
	audio_player.stream = _generator
	audio_player.play()
	_playback = audio_player.get_stream_playback()
	if _playback == null:
		push_warning("CinemaStream: no AudioStreamGeneratorPlayback; the channel will be silent")


func _make_speaker() -> void:
	var p := AudioStreamPlayer3D.new()
	p.volume_db = volume_db
	p.max_distance = max_distance
	p.attenuation_model = attenuation_model
	p.unit_size = unit_size
	p.max_db = 3.0
	p.emission_angle_enabled = true
	p.emission_angle_degrees = 90.0
	p.emission_angle_filter_attenuation_db = -12.0
	p.attenuation_filter_cutoff_hz = 5000.0
	p.attenuation_filter_db = -24.0
	p.doppler_tracking = 0
	add_child(p)
	audio_player = p
	_owns_audio = true


func _process(_delta: float) -> void:
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			is_open = true
			_retries = 0
			connected.emit()
		_drain_packets()
	elif state == WebSocketPeer.STATE_CLOSED:
		if _was_open:
			_was_open = false
			is_open = false
			closed.emit("code %d %s" % [_ws.get_close_code(), _ws.get_close_reason()])
			_schedule_retry()
		if _retry_at > 0.0 and Time.get_ticks_msec() / 1000.0 >= _retry_at:
			_retry_at = 0.0
			_connect()


## Decodes only the newest picture; every message's sound is pushed.
func _drain_packets() -> void:
	var latest := ""
	while _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		var got := _read(pkt.get_string_from_utf8())
		if got != "":
			latest = got
	if latest != "":
		_show(latest)


## {"type": "media_chunk", "audio_data": b64 WAV, "video_data": b64 JPEG or "", "timestamp_ms": int}
func _read(text: String) -> String:
	var data = JSON.parse_string(text)
	if not (data is Dictionary) or data.get("type", "") != "media_chunk":
		return ""
	if data.has("audio_data"):
		_play_audio(data["audio_data"])
	var v = data.get("video_data", "")
	return v if v is String else ""


func _show(b64: String) -> void:
	var bytes := Marshalls.base64_to_raw(b64)
	if _img.load_jpg_from_buffer(bytes) != OK:
		return
	_frames += 1
	if texture == null or texture.get_width() != _img.get_width() \
			or texture.get_height() != _img.get_height():
		texture = ImageTexture.create_from_image(_img)
		width = _img.get_width()
		height = _img.get_height()
		resized.emit(width, height)
	else:
		texture.update(_img)
	frame.emit()


## Dropped while the buffer holds more than the target latency.
func _play_audio(b64: String) -> void:
	if _playback == null:
		if audio_player == null:
			return
		_playback = audio_player.get_stream_playback()
		if _playback == null:
			return
	var wav := Marshalls.base64_to_raw(b64)
	if wav.size() <= WAV_HEADER_SIZE:
		return
	var pcm := wav.slice(WAV_HEADER_SIZE)
	var bytes_per_frame := AUDIO_CHANNELS * (AUDIO_BITS_PER_SAMPLE / 8)
	var count := pcm.size() / bytes_per_frame
	if count == 0:
		return

	var available := _playback.get_frames_available()
	if available <= 0:
		return
	var capacity := int(_generator.buffer_length * AUDIO_SAMPLE_RATE)
	if capacity - available > AUDIO_TARGET_LATENCY_FRAMES:
		return
	count = mini(count, available)

	# One push_buffer per chunk; push_frame per sample would be far slower.
	var frames := PackedVector2Array()
	frames.resize(count)
	var at := 0
	for i in count:
		frames[i] = Vector2(pcm.decode_s16(at) / 32768.0, pcm.decode_s16(at + 2) / 32768.0)
		at += 4
	_playback.push_buffer(frames)


func _exit_tree() -> void:
	close("exit")
