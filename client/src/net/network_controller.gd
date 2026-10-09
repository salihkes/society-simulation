extends Node
## The client's connection to the server: the socket, the message table and the signals.

signal player_connected(player_id, username)
signal player_disconnected(player_id)
signal chat_message_received(username, message)
signal system_message_received(message)
signal login_response(success, message)
signal register_response(success, message)
signal texture_info_received(texture_name)
signal weather_update_received(weather_data)
signal object_spawned(net_id)
signal object_updated(net_id, transform: Transform3D)
signal object_despawned(net_id)
signal map_state_received(state: Dictionary)
signal studio_message(data: Dictionary)

## Set by /connect; devices without a command line (iPad) can only reach a LAN server this way.
const SERVER_PREF_PATH := "user://server.url"
## Used when the server in use is local or on the LAN.
const LOCAL_SERVICE_PORTS := {"voice": 3246, "cinema": 3245}
const DEFAULT_PORT := 2053
const CONNECT_TIMEOUT_MS = 8000
## Matches PCK_HTTP_SERVER_PORT in server/constants.py.
const LOCAL_PCK_HTTP_PORT := 8099

## Without --server / GAME_SERVER the client walks SERVER_CANDIDATES and goes offline only when none answers.
@export var server_url = "ws://127.0.0.1:2053"
@export var reconnect_delay = 3.0

## Message type -> handler(data); see protocol/messages.json.
var _handlers: Dictionary = {}
var _module_types: Array = []
var latest_weather_update: Dictionary = {}
var latest_weather_runtime: Dictionary = {}
var snow_cache = preload("res://src/world/environment/snow_state.gd").new()
var chat := NetChat.new(self)
var session := NetSession.new(self)
var workspace := NetWorkspace.new(self)
var objects := NetObjects.new(self)
var players := NetPlayers.new(self)

var _client = WebSocketPeer.new()
var connected = false
var client_id = -1
var local_username = ""
var _manual_disconnect = true
var _handshake_sent = false

var SERVER_CANDIDATES: Array = Identity.value("servers")
var _candidate_index := 0
var _server_pinned := false

## A fallback only: it runs the local code paths the server messages would; a connect ends it.
var _offline_mode = false
## -1 when idle.
var _connect_attempt_ms = -1

## `--world`: the headless city authority; never spawns a player or goes offline.
var _world_mode := false
## `--studio`: like the world it never plays offline.
var _studio_mode := false
var _rain_system = null
var _monster_controller = null
var _npc_manager = null
var _ambient_manager = null
var _vehicle_manager = null
var _combat_sync = null

var _CK: String = Identity.value("client_key")


func _init() -> void:
	_handlers = {
		"connected": _on_connected,
		"weather_update": _msg_weather_update,
		"pck_manifest": _msg_pck_manifest,
		"map_state": _msg_map_state,
		"map_full_update": _msg_map_state,
		"map_player_owner": _msg_map_player_owner,
		"map_online_owners": _msg_map_online_owners,
		"treaty_incoming": _msg_treaty_incoming,
		"treaty_pending": _msg_treaty_pending,
		"treaty_resolved": _msg_treaty_resolved,
		"npc_authority": _msg_npc_authority,
		"amb_state": _msg_amb_state,
		"pc_session": _msg_pc_session,
		"elevator_req": _msg_elevator_req,
		"parliament_ack": _msg_parliament_ack,
		"mind_reply": _msg_mind_reply,
		"world_cmd": _msg_world_cmd,
		"player_monsters_list": _on_player_monsters_list,
	}
	chat.register_handlers()
	session.register_handlers()
	workspace.register_handlers()
	objects.register_handlers()
	players.register_handlers()


## Routes messages of `type` to `handler(data)`; replaces any earlier handler.
func register_handler(type: String, handler: Callable) -> void:
	_handlers[type] = handler


func ambient_manager():
	return _ambient_manager


func npc_manager():
	return _npc_manager


func is_world_mode() -> bool:
	return _world_mode


func vehicle_manager():
	return _vehicle_manager


func combat_sync():
	return _combat_sync


func handled_types() -> PackedStringArray:
	return PackedStringArray(_handlers.keys())


func _ready():
	_client.inbound_buffer_size = 10000000
	_client.outbound_buffer_size = 10000000
	workspace.load_default_scenes()
	_parse_launch_args()

	var ws = workspace.find_workspace()
	_find_managers(ws)
	session.load_credentials()

	var should_auto_connect = false
	if ws:
		should_auto_connect = _wants_auto_connect(ws)
		players.make_container(ws)
		players.adopt_scene_player(ws)
	else:
		players.make_container(self)

	session.ensure_auth_manager()
	_setup_rain_system()

	if should_auto_connect:
		print("Auto-connecting to server...")
		connect_to_server()
	else:
		print("Network controller ready. Use /connect to connect to server.")


## A MonsterController is created if missing.
func _find_managers(ws):
	for type in _module_types:
		_handlers.erase(type)
	_module_types.clear()
	if not ws:
		print("Warning: No workspace found, creating MonsterController at root")
		_new_monster_controller(get_tree().root)
		_register_module(_monster_controller)
		return

	_monster_controller = ws.find_child("MonsterController", true, false)
	if _monster_controller:
		print("MonsterController found in workspace scene")
	else:
		print("MonsterController not found in workspace, creating new one")
		_new_monster_controller(ws)

	_npc_manager = ws.find_child("NpcManager", true, false)
	if _npc_manager:
		print("NpcManager found in workspace scene")
	else:
		print("NpcManager not found in workspace")

	_ambient_manager = ws.find_child("AmbientManager", true, false)
	if _ambient_manager:
		print("AmbientManager found in workspace scene")

	_vehicle_manager = ws.find_child("VehicleManager", true, false)
	if _vehicle_manager:
		print("VehicleManager found in workspace scene")

	_combat_sync = ws.find_child("CombatSync", true, false)
	if _combat_sync:
		print("CombatSync found in workspace scene")
	for module in [_monster_controller, _npc_manager, _ambient_manager, _vehicle_manager, _combat_sync]:
		_register_module(module)
	if _ambient_manager:
		_register_module(_ambient_manager.engagement)


## Routes each type in `module.MESSAGES` (type -> method name) to that module.
func _register_module(module: Object) -> void:
	if module == null or not "MESSAGES" in module:
		return
	for type in module.MESSAGES:
		register_handler(type, Callable(module, module.MESSAGES[type]))
		_module_types.append(type)


func _new_monster_controller(parent: Node):
	_monster_controller = load("res://src/minigames/pocketmonsters/monster_controller.gd").new()
	_monster_controller.name = "MonsterController"
	parent.add_child(_monster_controller)


## Lobby, local city, web, world and studio connect on start; anything else waits for /connect.
func _wants_auto_connect(ws) -> bool:
	var auto = false
	if ws.name == "workspace":
		auto = true
		print("Workspace named 'workspace' detected - will auto-connect")
	if ws.name == "localworkspace" and _is_local_host(_ws_host(server_url)):
		auto = true
	# Web streams the city itself from the server, so it always connects.
	if OS.has_feature("web"):
		auto = true
	if _world_mode or _studio_mode:
		auto = true
	return auto


## --world, --studio, --server <url> (after Godot's `--`), GAME_WORLD, GAME_SERVER, the remembered server.
func _parse_launch_args():
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a: String = args[i]
		if a == "--world":
			_world_mode = true
		elif a == "--studio":
			_studio_mode = true
		elif a.begins_with("--server="):
			server_url = a.substr(9)
			_server_pinned = true
		elif a == "--server" and i + 1 < args.size():
			i += 1
			server_url = args[i]
			_server_pinned = true
		i += 1
	if OS.get_environment("GAME_WORLD") == "1":
		_world_mode = true
	var env_url := OS.get_environment("GAME_SERVER")
	if env_url != "":
		server_url = env_url
		_server_pinned = true
	if not _server_pinned:
		var saved := _read_saved_server()
		if saved != "":
			server_url = saved
			_server_pinned = true
			print("[Network] Remembered server: ", server_url, "  (/connect auto to forget)")
	if not _server_pinned:
		server_url = SERVER_CANDIDATES[0]
	if _world_mode:
		print("[World] World mode — headless city authority, server: ", server_url)


## Instances one if the scene has none.
func _setup_rain_system():
	var ws = get_tree().get_root().find_child("workspace", true, false)
	if not ws:
		return

	_rain_system = ws.find_child("RainSystem", true, false)
	if not _rain_system:
		var rain_scene = load("res://assets/world/environment/rain_system.tscn")
		if rain_scene:
			_rain_system = rain_scene.instantiate()
			ws.add_child(_rain_system)
			print("Rain system added to workspace")
		else:
			print("Failed to load rain system scene")
	else:
		print("Rain system already exists in workspace")

	refresh_rain_player()


func refresh_rain_player():
	if _rain_system and _rain_system.has_method("update_local_player_reference"):
		_rain_system.update_local_player_reference()


func _process(delta):
	_client.poll()
	var state = _client.get_ready_state()

	# STATE_CLOSED is also the idle state, hence the _connect_attempt_ms guard.
	if _connect_attempt_ms >= 0 and not connected:
		if state == WebSocketPeer.STATE_CLOSED:
			_handle_connect_failure("server unreachable")
		elif Time.get_ticks_msec() - _connect_attempt_ms > CONNECT_TIMEOUT_MS:
			_client.close()
			_handle_connect_failure("connection timed out")

	if state == WebSocketPeer.STATE_OPEN:
		if not _handshake_sent:
			_send_handshake()
		while _client.get_available_packet_count():
			_handle_message(_client.get_packet().get_string_from_utf8())
	elif state == WebSocketPeer.STATE_CLOSED and connected:
		await _on_connection_lost()

	objects.sync_owned(delta)
	objects.claim_nearby()


## The server admits a client only after a handshake carrying the client key.
func _send_handshake():
	_handshake_sent = true
	var handshake = {"type": "handshake", "ck": _CK}
	if _world_mode:
		handshake["role"] = "world"
	_client.send_text(JSON.stringify(handshake))
	print("Sent handshake with client key")


## Drops into offline play (not the world or studio) and reconnects unless the disconnect was manual.
func _on_connection_lost():
	_drop_session()
	_handshake_sent = false
	players.remove_all()

	if _monster_controller:
		var remote_monster_ids = _monster_controller.remote_monsters.keys()
		for net_id in remote_monster_ids:
			_monster_controller.despawn_remote_monster(net_id)

	if not _world_mode and not _studio_mode:
		_enter_offline_mode()

	if not _manual_disconnect:
		await get_tree().create_timer(reconnect_delay).timeout
		connect_to_server()


func _drop_session():
	connected = false
	latest_weather_update.clear()
	latest_weather_runtime.clear()
	snow_cache = preload("res://src/world/environment/snow_state.gd").new()
	client_id = -1


## A bare host gets ws:// and DEFAULT_PORT; "auto" or "forget" drops the remembered one.
func connect_to_address(address: String):
	var url := address.strip_edges()
	if url == "":
		connect_to_server()
		return
	if url == "auto" or url == "forget":
		_forget_saved_server()
		_server_pinned = false
		_candidate_index = 0
		chat.system_notice("Forgot the remembered server; trying the usual ones again.")
		connect_to_server()
		return
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		url = "ws://" + url
	var rest := url.substr(url.find("://") + 3)
	if rest.find(":") < 0 and rest.find("/") < 0:
		url += ":" + str(DEFAULT_PORT)
	server_url = url
	_server_pinned = true
	_candidate_index = 0
	_save_server(url)
	if _offline_mode:
		chat.system_notice("Leaving offline play to connect to " + url)
	connect_to_server()


## "" when there is none or it cannot be read.
func _read_saved_server() -> String:
	if not FileAccess.file_exists(SERVER_PREF_PATH):
		return ""
	var f := FileAccess.open(SERVER_PREF_PATH, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text().strip_edges()


func _save_server(url: String) -> void:
	var f := FileAccess.open(SERVER_PREF_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[Network] Could not remember the server (" + SERVER_PREF_PATH + ")")
		return
	f.store_string(url)


func _forget_saved_server() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(SERVER_PREF_PATH.get_file()):
		dir.remove(SERVER_PREF_PATH.get_file())


func connect_to_server():
	if not _server_pinned:
		if _candidate_index >= SERVER_CANDIDATES.size():
			_candidate_index = 0
		server_url = SERVER_CANDIDATES[_candidate_index]
	print("Connecting to server: ", server_url)
	_manual_disconnect = false
	_handshake_sent = false
	_connect_attempt_ms = Time.get_ticks_msec()
	var err = _client.connect_to_url(server_url)
	if err != OK:
		_handle_connect_failure("error " + str(err))


## Closes the socket without the lost-connection handling; players are left to the caller.
func close_socket():
	_client.close()
	connected = false


## Uses this server from now on instead of walking the candidates.
func pin_server(url: String):
	server_url = url
	_server_pinned = true


## When all failed, the world and studio retry forever and players drop into offline play.
func _handle_connect_failure(reason: String):
	_connect_attempt_ms = -1
	_handshake_sent = false
	print("Connection attempt failed: ", reason)
	if not _server_pinned:
		if _candidate_index + 1 < SERVER_CANDIDATES.size():
			_candidate_index += 1
			print("Trying the next server: ", SERVER_CANDIDATES[_candidate_index])
			connect_to_server()
			return
		_candidate_index = 0
	if _world_mode or _studio_mode:
		if _studio_mode:
			print("[Studio] waiting for the server at ", server_url, " (", reason, ")")
		await get_tree().create_timer(reconnect_delay).timeout
		connect_to_server()
		return
	if _offline_mode:
		chat.system_notice("Still offline (" + reason + "). Type /connect to retry.")
		return
	chat.system_notice("Could not reach the server (" + reason + ").")
	_enter_offline_mode()


## Continues in offline play.
func disconnect_from_server():
	if not connected:
		print("Not connected to server")
		return false

	print("Manually disconnecting from server...")
	_manual_disconnect = true
	_handshake_sent = false
	_connect_attempt_ms = -1
	_client.close()
	_drop_session()
	players.remove_all()
	_enter_offline_mode()

	print("Disconnected from server")
	return true


func _handle_message(message):
	var data = JSON.parse_string(message)
	if data == null:
		print("Invalid JSON received")
		return

	var handler: Callable = _handlers.get(data.type, Callable())
	if handler.is_valid():
		await handler.call(data)


func _msg_weather_update(data) -> void:
	var weather_data: Dictionary = data.weather.duplicate(true)
	weather_data["_initial"] = bool(data.get("initial", false))
	latest_weather_update = weather_data
	print("Received weather update: ", weather_data)
	emit_signal("weather_update_received", weather_data)
	if _rain_system and _rain_system.has_method("handle_weather_update"):
		_rain_system.handle_weather_update(weather_data)


func _msg_pck_manifest(data) -> void:
	print("Received PCK manifest from server")
	var pck_manager = get_node_or_null("/root/PCKManager")
	if pck_manager:
		pck_manager.handle_server_manifest(_localize_pck_manifest(data.manifest))
	else:
		print("WARNING: PCKManager autoload not found, skipping PCK check")


func _msg_map_state(data) -> void:
	var state_data = data.get("state", {})
	print("Received map state from server (%s)" % data.type)
	map_state_received.emit(state_data)
	_route_map_state(state_data)


func _msg_map_player_owner(data) -> void:
	print("Received map_player_owner: %s" % str(data))
	_route_to_map_network("handle_player_owner", data)


func _msg_map_online_owners(data) -> void:
	_route_to_map_network("handle_online_owners", data)


func _msg_treaty_incoming(data) -> void:
	print("Received treaty_incoming: %s" % str(data))
	_route_to_map_network("handle_treaty_incoming", data)


func _msg_treaty_pending(data) -> void:
	print("Received treaty_pending: %s" % str(data))
	_route_to_map_network("handle_treaty_pending", data)


func _msg_treaty_resolved(data) -> void:
	print("Received treaty_resolved: %s" % str(data))
	_route_to_map_network("handle_treaty_resolved", data)


func _msg_npc_authority(data) -> void:
	if _npc_manager:
		_npc_manager.handle_npc_authority(data)
	# The same election makes one client simulate all ambient life.
	if _ambient_manager:
		_ambient_manager.handle_npc_authority(data)


func _msg_amb_state(data) -> void:
	if data.get("weather") is Dictionary:
		latest_weather_runtime = data.weather.duplicate(true)
		if data.weather.get("snow") is Dictionary:
			snow_cache.apply_packet(data.weather.snow)
	if _ambient_manager:
		_ambient_manager.replication.apply_state(data)


func _msg_pc_session(data) -> void:
	# The server opened (or refused) a computer; the prop with that id shows it.
	for c in get_tree().get_nodes_in_group("computers"):
		if str(c.get("computer_id")) == str(data.get("id", "")) and c.has_method("on_session"):
			c.on_session(data)


func _msg_elevator_req(data) -> void:
	for elevator in get_tree().get_nodes_in_group("elevators"):
		elevator.handle_request(data)


func _msg_parliament_ack(data) -> void:
	chat.system_notice(str(data.get("text", "")))


func _msg_mind_reply(data) -> void:
	studio_message.emit(data)


func _msg_world_cmd(data) -> void:
	if _world_mode:
		_to_ambient("handle_world_cmd", data)


func _to_ambient(method: String, data):
	if _ambient_manager and _ambient_manager.has_method(method):
		_ambient_manager.call(method, data)


## Leaves offline play, sets up the local body and, as a guest, tries to log in automatically.
func _on_connected(data):
	connected = true
	client_id = data.client_id
	_connect_attempt_ms = -1
	_exit_offline_mode()

	var is_place_server = data.has("place_name")
	var current_is_guest = local_username == "" or local_username.begins_with("Guest")
	var new_is_guest = data.username.begins_with("Guest")

	if (not is_place_server) or (current_is_guest and not new_is_guest):
		local_username = data.username
		print("Connected to server with ID: ", client_id, " Username updated to: ", local_username)
	else:
		print("Connected to place server with ID: ", client_id, " Keeping username: ", local_username)

	if data.has("character_type"):
		players.user_character_type = data.character_type

	if not is_place_server and not _world_mode:
		session.update_voice_username()

	if _world_mode:
		print("[World] Connected as the world (client ", client_id, ") — no player body")
	elif players.local_player != null:
		await players.resume_local_player()
	else:
		players.spawn_local_player()

	send_json({
		"type": "get_players"
	})

	if local_username.begins_with("Guest"):
		await session.auto_login()


func _on_player_monsters_list(data):
	print("NetworkController: Received player_monsters_list message")
	print("NetworkController: Data: ", data)
	print("NetworkController: MonsterController reference: ", _monster_controller)
	print("NetworkController: Local player: ", players.local_player)
	if _monster_controller and is_instance_valid(_monster_controller):
		print("NetworkController: Calling handle_player_monsters_list...")
		_monster_controller.handle_player_monsters_list(data, players.local_player)
		print("NetworkController: handle_player_monsters_list completed")
	else:
		print("NetworkController: ERROR - MonsterController reference is null or invalid")


## Mounts the cached world packs and opens the build tools as a local sandbox.
func _enter_offline_mode():
	if _offline_mode:
		return
	_offline_mode = true
	print("=== ENTERING OFFLINE MODE ===")

	# Adopt the last logged-in name; a "Guest" prefix would lock plots and building.
	if local_username == "" or local_username.begins_with("Guest"):
		local_username = session.saved_username if session.saved_username != "" else "Player"
	print("Offline username: ", local_username)

	var mounted = 0
	var pck_manager = get_node_or_null("/root/PCKManager")
	if pck_manager and pck_manager.has_method("mount_cached_packs"):
		mounted = pck_manager.mount_cached_packs()

	# Only the player body carries a camera.
	if is_instance_valid(players.local_player):
		players.ensure_local_player_node(players.local_player)
	else:
		await players.spawn_local_player()
		if is_instance_valid(players.local_player) and local_username != "":
			players.local_player.name = local_username

	_set_offline_sandbox(true)
	refresh_rain_player()

	if mounted > 0:
		chat.system_notice("Offline mode — playing the downloaded world. Type /connect to go online.")
	else:
		chat.system_notice("Offline mode — no cached world to show. Connect once so it can be downloaded and remembered.")


func _exit_offline_mode():
	if not _offline_mode:
		return
	_offline_mode = false
	_set_offline_sandbox(false)
	print("=== LEFT OFFLINE MODE (server connected) ===")


func _set_offline_sandbox(enabled: bool):
	var ws = get_tree().current_scene
	if not ws:
		return
	var plot_ui_vis = ws.get_node_or_null("PlotUIVisibility")
	if plot_ui_vis and plot_ui_vis.has_method("set_offline_sandbox"):
		plot_ui_vis.set_offline_sandbox(enabled)


## Against a local or LAN server, packs come from that host's PCK HTTP server.
func _localize_pck_manifest(manifest):
	if typeof(manifest) != TYPE_DICTIONARY:
		return manifest
	var host := _ws_host(server_url)
	if _is_local_host(host):
		var localized = manifest.duplicate(true)
		localized["download_base_url"] = "http://%s:%d/pck/" % [host, LOCAL_PCK_HTTP_PORT]
		print("Local dev: PCK downloads redirected to ", localized["download_base_url"])
		return localized
	return manifest


## Its local port for a local or LAN server, else wss://<host>/<name>.
func service_url(name: String) -> String:
	var host := _ws_host(server_url)
	if _is_local_host(host) and LOCAL_SERVICE_PORTS.has(name):
		return "ws://%s:%d" % [host, int(LOCAL_SERVICE_PORTS[name])]
	return "wss://%s/%s" % [host, name]


func _ws_host(url: String) -> String:
	var s := url
	var scheme_end := s.find("://")
	if scheme_end != -1:
		s = s.substr(scheme_end + 3)
	var slash := s.find("/")
	if slash != -1:
		s = s.substr(0, slash)
	var colon := s.rfind(":")
	if colon != -1:
		s = s.substr(0, colon)
	return s


## Loopback, private network ranges and .local names.
func _is_local_host(host: String) -> bool:
	if host in ["127.0.0.1", "localhost", "::1"]:
		return true
	var parts := host.split(".")
	if parts.size() >= 2:
		if parts[0] == "10" or (parts[0] == "192" and parts[1] == "168"):
			return true
		if parts[0] == "172":
			# 172.16.0.0 – 172.31.255.255
			return parts[1].is_valid_int() and int(parts[1]) >= 16 and int(parts[1]) <= 31
	return host.ends_with(".local")


func _route_map_state(state_data: Dictionary) -> void:
	var map_net := _find_map_network_controller()
	if map_net and map_net.has_method("apply_remote_state"):
		map_net.apply_remote_state(state_data)
	else:
		print("MapNetworkController not found — map state not applied")


func _route_to_map_network(method_name: String, data: Dictionary) -> void:
	var map_net := _find_map_network_controller()
	if map_net and map_net.has_method(method_name):
		map_net.call(method_name, data)
	else:
		print("MapNetworkController.%s not available — message dropped" % method_name)


## By name or by class, two levels deep.
func _find_map_network_controller() -> Node:
	var ws = get_tree().get_root().find_child("workspace", true, false)
	if not ws:
		return null
	var mnc = ws.find_child("MapNetworkController", true, false)
	if mnc:
		return mnc
	for child in ws.get_children():
		if child is MapNetworkController:
			return child
		for grandchild in child.get_children():
			if grandchild is MapNetworkController:
				return grandchild
	return null


## Dropped while not connected.
func send_json(data):
	if connected:
		data["ck"] = _CK
		var json_string = JSON.stringify(data)
		_client.send_text(json_string)

