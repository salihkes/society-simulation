extends Node
## Streams the microphone (the Record bus) to the voice chat server as base64 PCM16 chunks.

signal connected_to_voice_server
signal disconnected_from_voice_server

const AUDIO_CHANNELS = 2
const AUDIO_SAMPLE_RATE = 48000
const CHUNK_SIZE = 2048  # frames per chunk
## Seconds between dropping a stuck connection and reconnecting.
const RECONNECT_DELAY := 1.0

@export var websocket_url: String = Identity.value("voice_url")
@export var username: String = "Player1"
@export var room: String = "default"
## Off by default: VR connects on the first controller button press.
@export var auto_connect: bool = false

var _client = WebSocketPeer.new()
var _connected = false
var _registered = false

var _audio_effect_capture: AudioEffectCapture = null
var _recording = false

var _chunk_index = 0

var _send_timer = 0.0
var _send_interval = 0.05

var _ping_timer = 0.0
var _ping_interval = 10.0
var _last_pong_time = 0.0
var _connection_timeout = 30.0

## Reconnect when connected but not registered for this long.
var _registration_timer = 0.0
var _registration_timeout = 5.0

## Reconnect when stuck connecting for this long.
var _connection_timer = 0.0
var _connection_timeout_duration = 10.0
var _is_connecting = false


func _ready():
	print("========================================")
	print("MicrophoneSender initializing...")
	print("========================================")

	var network_controller = get_node_or_null("/root/NetworkController")
	if network_controller and network_controller.local_username != "":
		username = network_controller.local_username
		print("Got username from NetworkController: ", username)
	else:
		print("Using default username: ", username)

	_setup_audio_capture()
	_setup_websocket()
	_print_player_setup()

	if auto_connect:
		connect_to_voice_server()

	print("========================================")


## Diagnostics for the microphone setup.
func _print_player_setup() -> void:
	print("Checking microphone setup...")
	var workspace = get_parent()
	if not workspace:
		return
	var audio_player = workspace.get_node_or_null("AudioStreamPlayer")
	if audio_player:
		print("  - AudioStreamPlayer found: ", audio_player.name)
		print("  - Stream type: ", audio_player.stream)
		print("  - Bus: ", audio_player.bus)
		print("  - Playing: ", audio_player.playing)
	else:
		print("  - WARNING: AudioStreamPlayer not found!")


func _setup_audio_capture():
	print("Setting up audio capture from Record bus...")

	var bus_idx = AudioServer.get_bus_index("Record")
	if bus_idx == -1:
		printerr("ERROR: Record bus not found! Make sure default_bus_layout.tres has a Record bus")
		printerr("Available buses:")
		for i in range(AudioServer.get_bus_count()):
			printerr("  - Bus %d: %s" % [i, AudioServer.get_bus_name(i)])
		return

	print("  - Found Record bus at index: ", bus_idx)
	print("  - Number of effects on Record bus: ", AudioServer.get_bus_effect_count(bus_idx))

	for i in range(AudioServer.get_bus_effect_count(bus_idx)):
		var effect = AudioServer.get_bus_effect(bus_idx, i)
		print("    - Effect %d: %s" % [i, effect.get_class()])
		if effect is AudioEffectCapture:
			_audio_effect_capture = effect
			print("  ✓ Found AudioEffectCapture on Record bus!")
			break

	if not _audio_effect_capture:
		printerr("ERROR: AudioEffectCapture not found on Record bus!")
		printerr("Please add AudioEffectCapture to the Record bus in default_bus_layout.tres")
		return

	_audio_effect_capture.clear_buffer()
	print("  ✓ AudioEffectCapture ready")
	print("    - Buffer length: ", _audio_effect_capture.get_buffer_length_frames(), " frames")
	print("    - Can get buffer: ", _audio_effect_capture.can_get_buffer(_audio_effect_capture.get_buffer_length()))


func _setup_websocket():
	_client.encode_buffer_max_size = 16000000
	_client.outbound_buffer_size = 16000000
	_client.inbound_buffer_size = 16000000


func connect_to_voice_server():
	if _connected:
		return

	_is_connecting = false
	_connection_timer = 0.0

	# A reused WebSocketPeer goes straight to CLOSED; always start a new one.
	_client = WebSocketPeer.new()
	_setup_websocket()

	var nc = get_node_or_null("/root/NetworkController")
	if nc != null and nc.has_method("service_url"):
		websocket_url = nc.service_url("voice")
	var err = _client.connect_to_url(websocket_url)
	if err != OK:
		printerr("MicrophoneSender: Failed to connect - Error: %s" % err)


func disconnect_from_voice_server():
	_recording = false
	_connected = false
	_registered = false
	_is_connecting = false
	_connection_timer = 0.0
	_registration_timer = 0.0
	if _client.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_client.close()


func _process(delta):
	_client.poll()
	await _check_stuck_connecting(delta)
	_handle_connection_state()

	if _connected and _registered and _recording:
		_send_timer += delta
		if _send_timer >= _send_interval:
			_capture_and_send_audio()
			_send_timer = 0.0

	await _check_registration(delta)
	if _connected:
		_keep_alive(delta)


func _check_stuck_connecting(delta: float) -> void:
	if _client.get_ready_state() != WebSocketPeer.STATE_CONNECTING:
		_is_connecting = false
		_connection_timer = 0.0
		return
	if not _is_connecting:
		_is_connecting = true
		_connection_timer = 0.0
		return
	_connection_timer += delta
	if _connection_timer >= _connection_timeout_duration:
		print("MicrophoneSender: Connection timeout - reconnecting...")
		disconnect_from_voice_server()
		await get_tree().create_timer(RECONNECT_DELAY).timeout
		connect_to_voice_server()


func _check_registration(delta: float) -> void:
	if not _connected or _registered:
		return
	_registration_timer += delta
	if _registration_timer >= _registration_timeout:
		print("MicrophoneSender: Registration timeout - reconnecting...")
		disconnect_from_voice_server()
		await get_tree().create_timer(RECONNECT_DELAY).timeout
		connect_to_voice_server()
		_registration_timer = 0.0


func _keep_alive(delta: float) -> void:
	_ping_timer += delta
	if _ping_timer >= _ping_interval:
		_send_ping()
		_ping_timer = 0.0
	var time_since_pong = Time.get_ticks_msec() / 1000.0 - _last_pong_time
	if time_since_pong > _connection_timeout:
		print("MicrophoneSender: Connection timeout")
		_handle_connection_timeout()


func _handle_connection_state():
	var state = _client.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				_last_pong_time = Time.get_ticks_msec() / 1000.0
				_registration_timer = 0.0
				_register_with_server()
			while _client.get_available_packet_count() > 0:
				_handle_packet(_client.get_packet())

		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				_registered = false
				_recording = false
				disconnected_from_voice_server.emit()


func _handle_packet(packet):
	var msg_text = packet.get_string_from_utf8() if packet is PackedByteArray else packet

	var json = JSON.new()
	if json.parse(msg_text) != OK:
		return

	var data = json.get_data()
	if not data.has("type"):
		return

	match data.type:
		"registered":
			_registered = true
			_recording = true
			_last_pong_time = Time.get_ticks_msec() / 1000.0
			_registration_timer = 0.0
			connected_to_voice_server.emit()

		"error":
			printerr("MicrophoneSender: Server error - ", data.get("message", "Unknown error"))

		"ping":
			_client.send_text(JSON.stringify({"type": "pong"}))

		"pong":
			_last_pong_time = Time.get_ticks_msec() / 1000.0


func _register_with_server():
	var registration = {
		"type": "register",
		"username": username,
		"room": room,
		"user_type": "streamer",
	}
	_client.send_text(JSON.stringify(registration))


func _capture_and_send_audio():
	if not _audio_effect_capture:
		print("ERROR: No audio effect capture!")
		return

	if _audio_effect_capture.get_frames_available() < CHUNK_SIZE:
		return

	var audio_frames = _audio_effect_capture.get_buffer(CHUNK_SIZE)
	if audio_frames.size() == 0:
		print("WARNING: Got 0 audio frames from capture buffer")
		return

	var message = {
		"type": "audio_chunk",
		"audio_data": Marshalls.raw_to_base64(_to_pcm16(audio_frames)),
		"chunk_info": {
			"index": _chunk_index,
			"sample_rate": AUDIO_SAMPLE_RATE,
			"channels": AUDIO_CHANNELS,
			"format": "pcm_s16le"
		}
	}
	_client.send_text(JSON.stringify(message))
	_chunk_index += 1


## Interleaved little-endian 16-bit samples.
func _to_pcm16(audio_frames: PackedVector2Array) -> PackedByteArray:
	var pcm_data = PackedByteArray()
	pcm_data.resize(CHUNK_SIZE * 4)
	var byte_index = 0
	for frame in audio_frames:
		pcm_data.encode_s16(byte_index, int(clamp(frame.x * 32767.0, -32768.0, 32767.0)))
		byte_index += 2
		pcm_data.encode_s16(byte_index, int(clamp(frame.y * 32767.0, -32768.0, 32767.0)))
		byte_index += 2
	return pcm_data


func _send_ping():
	if _connected and _registered:
		_client.send_text(JSON.stringify({"type": "ping"}))


func _handle_connection_timeout():
	print("Voice server connection timed out")
	_connected = false
	_registered = false
	_recording = false
	_client.close()
	disconnected_from_voice_server.emit()


## Reconnects so the server registers it.
func set_voice_username(new_username: String):
	if new_username == username:
		return
	var old_username = username
	username = new_username
	print("Voice chat sender username updated from ", old_username, " to: ", username)
	if _connected:
		print("Disconnecting voice sender to reconnect with new username...")
		disconnect_from_voice_server()
		await get_tree().create_timer(2.0).timeout
		print("Reconnecting voice sender as: ", username)
		connect_to_voice_server()


func update_voice_username_from_network():
	var network_controller = get_node_or_null("/root/NetworkController")
	if not network_controller:
		print("WARNING: NetworkController not found for voice username update")
		return

	print("DEBUG: NetworkController username = '%s', current voice username = '%s'" % [network_controller.local_username, username])

	if network_controller.local_username == "":
		return
	var new_username = network_controller.local_username
	if new_username != username:
		print("VOICE SENDER: Updating username from '%s' to '%s'" % [username, new_username])
		set_voice_username(new_username)
	else:
		print("DEBUG: Voice sender username already matches: '%s'" % username)


func _exit_tree():
	disconnect_from_voice_server()
	print("MicrophoneSender cleaned up")
