extends Node3D
## Plays each speaker's voice chat audio from their character; only the local player's instance connects.

signal connected_to_microphone
signal disconnected_from_microphone
signal audio_chunk_received(chunk_index: int)

const AUDIO_CHANNELS = 2
const AUDIO_SAMPLE_RATE = 48000
const AUDIO_BITS_PER_SAMPLE = 16
## Bytes; allocated per peer when the socket opens.
const SOCKET_BUFFER_BYTES := 262144
## Seconds to wait for a forced close before replacing the socket.
const FORCE_CLOSE_WAIT := 2.0

@export var websocket_url: String = Identity.value("voice_url")
@export var username: String = "Player1"
@export var room: String = "default"
@export var auto_connect: bool = true

@export var max_distance: float = 30.0
@export var attenuation_model: int = 0  # ATTENUATION_INVERSE_DISTANCE
@export var volume_db: float = 0.0
@export var unit_size: float = 10.0
@export var emission_angle_degrees: float = 90.0
@export var emission_angle_filter_attenuation_db: float = -12.0

var _client = WebSocketPeer.new()
var _connected = false
var _registered = false

var _audio_player_3d = null
var _audio_generator = AudioStreamGenerator.new()
var _audio_playback = null
var _audio_buffer_size_ms = 500

var _connection_attempts = 0

var _player_audio_sources = {}  # username -> {player, generator, playback, target_node}

var _force_close_timer = 0.0
var _is_force_closing = false
var _ping_timer = 0.0
var _ping_interval = 10.0
var _last_pong_time = 0.0
## Seconds without a pong before the connection counts as dead.
var _connection_timeout = 30.0
var _cleanup_timer = 0.0
var _cleanup_interval = 5.0


## NPCs, mannequins and remote players share the scene and must not open their own sockets.
func _is_local_listener() -> bool:
	var character := get_parent()
	if character == null or not character.has_method("set_as_remote_player"):
		return false
	if character.get("is_remote_player") != false:
		return false
	var network := get_node_or_null("/root/NetworkController")
	return network == null or not (network.has_method("is_world_mode") and network.is_world_mode())


func _ready():
	if not _is_local_listener():
		set_process(false)
		return
	print("MicrophoneAudioPlayer initializing...")

	var network_controller = get_node_or_null("/root/NetworkController")
	if network_controller and network_controller.local_username != "":
		username = network_controller.local_username
		print("Got username from NetworkController: ", username)
	else:
		print("Using default username: ", username)

	_audio_player_3d = AudioStreamPlayer3D.new()
	add_child(_audio_player_3d)
	_setup_spatial_audio()
	_setup_audio_generator()
	_setup_websocket()

	if auto_connect:
		connect_to_voice_server()


func _setup_spatial_audio():
	_audio_player_3d.volume_db = volume_db
	_audio_player_3d.max_distance = max_distance
	_audio_player_3d.attenuation_model = attenuation_model
	_audio_player_3d.unit_size = unit_size
	_audio_player_3d.max_db = 3.0

	_audio_player_3d.emission_angle_enabled = true
	_audio_player_3d.emission_angle_degrees = emission_angle_degrees
	_audio_player_3d.emission_angle_filter_attenuation_db = emission_angle_filter_attenuation_db
	_audio_player_3d.attenuation_filter_cutoff_hz = 5000.0
	_audio_player_3d.attenuation_filter_db = -24.0
	_audio_player_3d.doppler_tracking = 0

	print("Spatial audio configured:")
	print("- Volume: %s dB" % volume_db)
	print("- Max distance: %s" % max_distance)
	print("- Attenuation model: %s" % attenuation_model)


func _setup_audio_generator():
	_audio_generator.mix_rate = AUDIO_SAMPLE_RATE
	_audio_generator.buffer_length = float(_audio_buffer_size_ms) / 1000.0

	_audio_player_3d.stream = _audio_generator
	_audio_player_3d.play()

	_audio_playback = _audio_player_3d.get_stream_playback()
	if _audio_playback == null:
		printerr("Failed to get AudioStreamGeneratorPlayback!")
	else:
		print("AudioStreamGenerator initialized:")
		print("- Sample Rate: %s Hz" % AUDIO_SAMPLE_RATE)
		print("- Buffer length: %s ms" % _audio_buffer_size_ms)
		print("- Channels: %s" % AUDIO_CHANNELS)


func _setup_websocket():
	_client.encode_buffer_max_size = SOCKET_BUFFER_BYTES
	_client.outbound_buffer_size = SOCKET_BUFFER_BYTES
	_client.inbound_buffer_size = SOCKET_BUFFER_BYTES


## A socket not closed yet is force-closed instead; call again once it is reset.
func connect_to_voice_server():
	if not _is_local_listener():
		return
	if _connected:
		print("Already connected to voice server")
		return

	var state = _client.get_ready_state()
	if state != WebSocketPeer.STATE_CLOSED:
		print("WebSocket not in closed state (%d), forcing close and waiting..." % state)
		_force_close_connection()
		return

	_connection_attempts += 1
	var nc = get_node_or_null("/root/NetworkController")
	if nc != null and nc.has_method("service_url"):
		websocket_url = nc.service_url("voice")
	print("Connecting to voice server: %s (attempt %d)" % [websocket_url, _connection_attempts])

	var err = _client.connect_to_url(websocket_url)
	if err != OK:
		printerr("Failed to connect to voice server: %s" % err)
		print("Connection failed. Manual retry required.")


func _force_close_connection():
	_is_force_closing = true
	_force_close_timer = 0.0
	_client.close()
	_connected = false
	_registered = false


func disconnect_from_microphone():
	if _client.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_client.close()
		print("Disconnected from microphone server")
	_connected = false
	_registered = false


## There is no automatic reconnection.
func _process(delta):
	if _connected:
		_tick_connected(delta)

	if _is_force_closing:
		_force_close_timer += delta
		if _force_close_timer > FORCE_CLOSE_WAIT or _client.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			print("WebSocket client reset - ready for manual reconnection")
			_client = WebSocketPeer.new()
			_setup_websocket()
			_is_force_closing = false
			_force_close_timer = 0.0
			return

	_client.poll()
	_handle_connection_state()


func _tick_connected(delta: float) -> void:
	_ping_timer += delta
	if _ping_timer >= _ping_interval:
		_send_ping()
		_ping_timer = 0.0

	var time_since_pong = Time.get_ticks_msec() / 1000.0 - _last_pong_time
	if time_since_pong > _connection_timeout:
		_handle_connection_timeout()

	_cleanup_timer += delta
	if _cleanup_timer >= _cleanup_interval:
		_cleanup_stale_audio_sources()
		_cleanup_timer = 0.0


func _handle_connection_state():
	var state = _client.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				print("Connected to voice server")
				_connected = true
				_connection_attempts = 0
				_last_pong_time = Time.get_ticks_msec() / 1000.0
				_register_with_server()
			while _client.get_available_packet_count() > 0:
				_handle_packet(_client.get_packet())

		WebSocketPeer.STATE_CLOSING:
			if _connected:
				_connected = false
				_registered = false
				print("Voice server connection closing...")

		WebSocketPeer.STATE_CLOSED:
			if _connected:
				var code = _client.get_close_code()
				var reason = _client.get_close_reason()
				print("Voice server connection closed: %d - %s" % [code, reason])
				_connected = false
				_registered = false
				disconnected_from_microphone.emit()
				print("Voice server disconnected. Manual reconnection required.")


func _handle_packet(packet):
	var msg_text: String
	if packet is String:
		msg_text = packet
	elif packet is PackedByteArray:
		msg_text = packet.get_string_from_utf8()
	else:
		printerr("Received unexpected packet type")
		return
	_parse_audio_message(msg_text)


func _parse_audio_message(msg_text: String):
	var json = JSON.new()
	var parse_result = json.parse(msg_text)

	if parse_result != OK:
		printerr("Failed to parse JSON: %s at line %d" % [json.get_error_message(), json.get_error_line()])
		return

	var data = json.get_data()
	if not data.has("type"):
		printerr("Message missing 'type' field")
		return

	match data.type:
		"registered":
			_registered = true
			_last_pong_time = Time.get_ticks_msec() / 1000.0
			connected_to_microphone.emit()

		"ping":
			_client.send_text(JSON.stringify({"type": "pong"}))

		"pong":
			_last_pong_time = Time.get_ticks_msec() / 1000.0

		"audio_chunk":
			_handle_player_audio_chunk(data)

		"user_joined":
			print("User joined: %s" % data.username)

		"user_left":
			print("User left: %s" % data.username)
			_remove_player_audio_source(data.username)

		_:
			print("Received unhandled message type: %s" % data.type)


## Including this player's own voice.
func _handle_player_audio_chunk(data):
	if not data.has("username") or not data.has("audio_data"):
		printerr("Audio chunk missing username or audio_data")
		return

	var audio_source = _get_or_create_player_audio_source(data.username)
	if not audio_source:
		return

	_process_pcm_audio_for_player(audio_source, Marshalls.base64_to_raw(data.audio_data))

	if data.has("chunk_info") and data.chunk_info.has("index"):
		audio_chunk_received.emit(data.chunk_info.index)


## Created on the speaker's character on first use; null when the character is not found.
func _get_or_create_player_audio_source(player_username: String):
	if player_username in _player_audio_sources:
		return _player_audio_sources[player_username]

	var target_node = _find_player_character_node(player_username)
	if not target_node:
		print("WARNING: Could not find character node for player '%s', audio will not be spatialized correctly" % player_username)
		return null

	var audio_player = AudioStreamPlayer3D.new()
	var audio_generator = AudioStreamGenerator.new()
	audio_generator.mix_rate = AUDIO_SAMPLE_RATE
	audio_generator.buffer_length = float(_audio_buffer_size_ms) / 1000.0

	audio_player.stream = audio_generator
	audio_player.volume_db = volume_db
	audio_player.max_distance = max_distance
	audio_player.attenuation_model = attenuation_model
	audio_player.unit_size = unit_size

	target_node.add_child(audio_player)
	audio_player.play()

	_player_audio_sources[player_username] = {
		"player": audio_player,
		"generator": audio_generator,
		"playback": audio_player.get_stream_playback(),
		"target_node": target_node
	}

	print("Created spatial audio source for player '%s' attached to: %s" % [player_username, target_node.get_path()])
	return _player_audio_sources[player_username]


## This player, or a node under "Players" named after them or whose get_username() matches.
func _find_player_character_node(player_username: String) -> Node3D:
	var workspace = get_tree().get_root().find_child("workspace", true, false)
	if not workspace:
		return null

	var my_character = get_parent()
	if my_character and _is_own_voice(my_character, player_username):
		return my_character

	var players_container = workspace.find_child("Players", true, false)
	if not players_container:
		return null
	var player_node = players_container.find_child(player_username, true, false)
	if player_node:
		return player_node
	for child in players_container.get_children():
		if child.has_method("get_username") and child.get_username() == player_username:
			return child
		elif child.name == player_username:
			return child
	return null


## Also matches a Guest name registered before logging in.
func _is_own_voice(my_character: Node, player_username: String) -> bool:
	var network_controller = get_node_or_null("/root/NetworkController")
	if not network_controller:
		return false
	if network_controller.local_username == player_username:
		return true
	return player_username.begins_with("Guest") and my_character.name == network_controller.local_username


## `audio_data` is interleaved 16-bit stereo PCM.
func _process_pcm_audio_for_player(audio_source, audio_data: PackedByteArray):
	if not is_instance_valid(audio_source.player):
		return
	if audio_source.has("target_node") and not is_instance_valid(audio_source.target_node):
		return

	var playback = audio_source.playback
	if not playback:
		return
	if audio_data.size() < 4:
		return

	var bytes_per_frame = AUDIO_CHANNELS * (AUDIO_BITS_PER_SAMPLE / 8)
	var frame_count = audio_data.size() / bytes_per_frame
	if frame_count == 0:
		return

	var byte_index = 0
	for i in range(frame_count):
		if byte_index + 3 >= audio_data.size():
			break
		var left_sample = audio_data.decode_s16(byte_index)
		var right_sample = audio_data.decode_s16(byte_index + 2)
		byte_index += 4
		playback.push_frame(Vector2(float(left_sample) / 32768.0, float(right_sample) / 32768.0))


func _remove_player_audio_source(player_username: String):
	if not player_username in _player_audio_sources:
		return
	var audio_source = _player_audio_sources[player_username]
	if is_instance_valid(audio_source.player):
		audio_source.player.queue_free()
	_player_audio_sources.erase(player_username)
	print("Removed audio source for player: %s" % player_username)


## Registers as a receiving "player".
func _register_with_server():
	var registration = {
		"type": "register",
		"username": username,
		"room": room,
		"user_type": "player"
	}
	_client.send_text(JSON.stringify(registration))
	print("Sent registration for user: %s in room: %s as PLAYER" % [username, room])


func _exit_tree():
	disconnect_from_microphone()
	print("MicrophoneAudioPlayer cleaned up")


## Reconnects so the server registers it.
func set_voice_username(new_username: String):
	if new_username == username:
		return
	var old_username = username
	username = new_username
	print("Voice chat username updated from ", old_username, " to: ", username)
	if _connected:
		print("Disconnecting voice chat to reconnect with new username...")
		disconnect_from_microphone()
		await get_tree().create_timer(2.0).timeout
		print("Reconnecting voice chat as: ", username)
		connect_to_voice_server()


func update_voice_username_from_network():
	var network_controller = get_node_or_null("/root/NetworkController")
	if network_controller and network_controller.local_username != "":
		var new_username = network_controller.local_username
		if new_username != username:
			print("Updating voice username from ", username, " to ", new_username)
			set_voice_username(new_username)


func _cleanup_stale_audio_sources():
	var players_to_remove = []
	for player_username in _player_audio_sources.keys():
		var audio_source = _player_audio_sources[player_username]
		if not is_instance_valid(audio_source.player):
			print("Voice audio player for '%s' is no longer valid, removing" % player_username)
			players_to_remove.append(player_username)
		elif audio_source.has("target_node") and not is_instance_valid(audio_source.target_node):
			print("Voice audio target node for '%s' is no longer valid, removing" % player_username)
			players_to_remove.append(player_username)
	for player_username in players_to_remove:
		_remove_player_audio_source(player_username)


func _send_ping():
	if _connected and _registered:
		_client.send_text(JSON.stringify({"type": "ping"}))


func _handle_connection_timeout():
	print("Voice server connection timed out")
	_connected = false
	_registered = false
	_client.close()
	disconnected_from_microphone.emit()
