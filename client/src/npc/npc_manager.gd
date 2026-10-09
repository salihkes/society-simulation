extends Node
## Owns the NPCs under "NPCs"; the authority client runs their AI, the others apply its transforms and events.

## Network messages this module handles: type -> method (see protocol/messages.json).
const MESSAGES := {
	"npc_transform": "handle_npc_transform",
	"npc_initial_state": "handle_npc_initial_state",
	"npc_schedule": "handle_npc_schedule",
	"npc_vehicle": "handle_npc_vehicle",
	"npc_action_event": "handle_npc_action_event",
	"npc_audio_data": "handle_npc_audio_data",
	"npc_audio_sync": "handle_npc_audio_sync",
	"npc_chat_response": "handle_npc_chat_response",
}

var _npcs: Dictionary = {}         # npc_id -> NPC node
var _is_authority := true          # default true (offline)
var _network_controller = null
var _path_network = null           # NpcPathNetwork node (if present)
var _send_timer := 0.0
var _ready_done := false
var _pending_messages: Array = []  # messages received before discovery
const SEND_INTERVAL := 0.1        # seconds between network updates
const NPC_CHAT_RADIUS := 15.0      # global units; how close a player must be to talk


func _ready():
	_path_network = get_parent().get_node_or_null("NpcPathNetwork")
	_discover_npcs()

	_network_controller = get_node_or_null("/root/NetworkController")
	if _network_controller == null:
		print("[NpcManager] No NetworkController found – running in offline mode")
		_set_authority(true)
	else:
		_set_authority(not _network_controller.connected)

	_ready_done = true

	for msg in _pending_messages:
		_process_pending(msg)
	_pending_messages.clear()


## Keyed by npc_id, or the node name when empty.
func _discover_npcs():
	var container = get_parent().get_node_or_null("NPCs")
	if not container:
		print("[NpcManager] No 'NPCs' node found in workspace")
		return

	for child in container.get_children():
		if child.has_method("set_authority"):
			var npc_id = child.npc_id if child.npc_id != "" else child.name
			_npcs[npc_id] = child
			child.npc_id = npc_id
			if _path_network and child.has_method("set_path_network"):
				child.set_path_network(_path_network)
			if child.has_method("set_npc_manager"):
				child.set_npc_manager(self)
			print("[NpcManager] Registered NPC: ", npc_id)

	print("[NpcManager] Total NPCs: ", _npcs.size())


func _process(delta):
	if not _is_authority:
		return
	if _npcs.is_empty():
		return

	_send_timer += delta
	if _send_timer >= SEND_INTERVAL:
		_send_timer = 0.0
		_send_npc_transforms()


func _send_npc_transforms():
	if _network_controller == null or not _network_controller.connected:
		return

	var transforms = {}
	for npc_id in _npcs:
		var npc = _npcs[npc_id]
		if not is_instance_valid(npc):
			continue
		transforms[npc_id] = {
			"x": npc.position.x,
			"y": npc.position.y,
			"z": npc.position.z,
			"rot_y": npc.get_model_rotation_y()
		}

	if transforms.is_empty():
		return

	_network_controller.send_json({
		"type": "npc_transform",
		"transforms": transforms
	})


## Nearest NPC within NPC_CHAT_RADIUS of the local player, or "".
func find_nearest_npc_to_player() -> String:
	if not _network_controller or not is_instance_valid(_network_controller.players.local_player):
		return ""

	var player_pos: Vector3 = _network_controller.players.local_player.global_position
	var best_id := ""
	var best_dist := INF

	for npc_id in _npcs:
		var npc = _npcs[npc_id]
		if not is_instance_valid(npc):
			continue
		var dist: float = player_pos.distance_to(npc.global_position)
		if dist < best_dist:
			best_dist = dist
			best_id = npc_id

	if best_dist <= NPC_CHAT_RADIUS:
		return best_id
	return ""


## Also stops the NPC to face the player while the server answers.
func send_npc_chat(npc_id: String, message: String):
	if _network_controller and _network_controller.connected:
		var npc = _valid_npc(npc_id)
		if npc and _network_controller.players.local_player:
			npc.start_chatting(_network_controller.players.local_player)
		_network_controller.send_json({
			"type": "npc_chat",
			"npc_id": npc_id,
			"message": message
		})


func handle_npc_chat_response(data: Dictionary):
	var npc_id = str(data.get("npc_id", ""))
	var message = str(data.get("message", ""))

	var npc = _valid_npc(npc_id)
	if npc:
		_speak_response(npc, message, data)

	if _network_controller:
		var display_name = npc_id
		if npc_id in _npcs and is_instance_valid(_npcs[npc_id]):
			display_name = _npcs[npc_id].name
		_network_controller.emit_signal("chat_message_received", display_name, message)


func _speak_response(npc: Node, message: String, data: Dictionary) -> void:
	if _network_controller and is_instance_valid(_network_controller.players.local_player):
		npc.start_chatting(_network_controller.players.local_player)
	npc.show_chat_bubble(message)

	var audio_b64 = data.get("audio", "")
	var speak_dur := 0.0
	if typeof(audio_b64) == TYPE_STRING and audio_b64 != "":
		speak_dur = npc.play_inline_audio(audio_b64)
	else:
		speak_dur = max(3.0, message.length() * 0.05)
		npc.start_talk_animation(speak_dur)

	var dur = max(4.0, message.length() * 0.06, speak_dur + 0.5)
	if npc.has_method("_auto_hide_bubble"):
		npc._auto_hide_bubble(dur)


## Authority only.
func broadcast_npc_event(npc_id: String, event: String, data: Dictionary):
	if not _is_authority:
		return
	if _network_controller == null or not _network_controller.connected:
		return

	_network_controller.send_json({
		"type": "npc_action_event",
		"npc_id": npc_id,
		"event": event,
		"data": data
	})


# NetworkController handlers; early messages are queued, except transforms and action events.


func handle_npc_authority(data: Dictionary):
	if not _is_ready():
		_pending_messages.append({"handler": "authority", "data": data})
		return
	_do_handle_authority(data)


func handle_npc_transform(data: Dictionary):
	if not _is_ready():
		return
	_do_handle_transform(data)


func handle_npc_initial_state(data: Dictionary):
	if not _is_ready():
		_pending_messages.append({"handler": "initial_state", "data": data})
		return
	_do_handle_initial_state(data)


func handle_npc_schedule(data: Dictionary):
	if not _is_ready():
		_pending_messages.append({"handler": "schedule", "data": data})
		return
	_do_handle_schedule(data)


func handle_npc_vehicle(data: Dictionary):
	if not _is_ready():
		_pending_messages.append({"handler": "vehicle", "data": data})
		return
	_do_handle_vehicle(data)


func handle_npc_action_event(data: Dictionary):
	if not _is_ready():
		return
	_do_handle_action_event(data)


func _is_ready() -> bool:
	return _ready_done and not _npcs.is_empty()


func _do_handle_authority(data: Dictionary):
	var authority_id = int(data.get("authority_client_id", -1))
	if _network_controller:
		var is_me = authority_id == _network_controller.client_id
		print("[NpcManager] Authority update: client ", authority_id,
			  " (me: ", is_me, ")")
		_set_authority(is_me)
	else:
		_set_authority(true)


func _do_handle_transform(data: Dictionary):
	if _is_authority:
		return
	var transforms = data.get("transforms", {})
	for npc_id in transforms:
		var npc = _valid_npc(npc_id)
		if npc == null:
			continue
		var t = transforms[npc_id]
		npc.apply_remote_transform(
			Vector3(t.x, t.y, t.z),
			float(t.rot_y)
		)


## Server positions also become spawn points; forces a schedule re-check.
func _do_handle_initial_state(data: Dictionary):
	var transforms = data.get("transforms", {})
	for npc_id in transforms:
		var npc = _valid_npc(npc_id)
		if npc == null:
			continue
		var t = transforms[npc_id]
		var pos = Vector3(t.x, t.y, t.z)
		npc.position = pos
		npc.apply_remote_transform(pos, float(t.get("rot_y", 0.0)))
		npc._spawn_position = pos
		npc._active_schedule_idx = -1
		npc._schedule_check_timer = 0.0


func _do_handle_schedule(data: Dictionary):
	var npc_id = str(data.get("npc_id", ""))
	var entries = data.get("schedule", [])
	if npc_id in _npcs:
		var npc = _npcs[npc_id]
		if is_instance_valid(npc) and npc.has_method("apply_server_schedule"):
			npc.apply_server_schedule(entries)
	else:
		print("[NpcManager] Schedule received for unknown NPC: ", npc_id)


## Assigns (or clears with "") an NPC's vehicle scene, overriding its own.
func _do_handle_vehicle(data: Dictionary):
	var npc_id = str(data.get("npc_id", ""))
	var path = str(data.get("vehicle", ""))
	if npc_id in _npcs:
		var npc = _npcs[npc_id]
		if is_instance_valid(npc) and npc.has_method("set_vehicle"):
			npc.set_vehicle(path)
	else:
		print("[NpcManager] Vehicle assignment for unknown NPC: ", npc_id)


func _do_handle_action_event(data: Dictionary):
	if _is_authority:
		return
	var npc_id = str(data.get("npc_id", ""))
	var event = str(data.get("event", ""))
	var event_data = data.get("data", {})
	var npc = _valid_npc(npc_id)
	if npc and npc.has_method("handle_remote_event"):
		npc.handle_remote_event(event, event_data)


## Caches to user://npc_audio_cache/ and notifies every NPC.
func handle_npc_audio_data(data: Dictionary):
	var path = str(data.get("path", ""))
	var audio_b64 = str(data.get("data", ""))
	var fmt = str(data.get("format", "mp3"))
	if path == "" or audio_b64 == "":
		return

	var cache_path = "user://npc_audio_cache/" + path
	DirAccess.make_dir_recursive_absolute(cache_path.get_base_dir())

	var raw_bytes = Marshalls.base64_to_raw(audio_b64)
	var file = FileAccess.open(cache_path, FileAccess.WRITE)
	if not file:
		return
	file.store_buffer(raw_bytes)
	file.close()
	print("[NpcManager] Cached NPC audio: %s (%d bytes)" % [cache_path, raw_bytes.size()])

	for npc_id in _npcs:
		var npc = _npcs[npc_id]
		if is_instance_valid(npc) and npc.has_method("_on_audio_cached"):
			npc._on_audio_cached(path)


## Joins audio an NPC is already playing, at the server's offset.
func handle_npc_audio_sync(data: Dictionary):
	var npc_id = str(data.get("npc_id", ""))
	var path = str(data.get("path", ""))
	var offset = float(data.get("offset", 0.0))
	var duration = float(data.get("duration", 0.0))

	if npc_id in _npcs:
		var npc = _npcs[npc_id]
		if is_instance_valid(npc) and npc.has_method("play_audio_from_server"):
			npc.play_audio_from_server(path, offset, duration)
	else:
		print("[NpcManager] Audio sync for unknown NPC: ", npc_id)


func request_npc_audio(path: String):
	if _network_controller and _network_controller.connected:
		_network_controller.send_json({
			"type": "npc_audio_request",
			"path": path
		})
		print("[NpcManager] Requesting audio from server: ", path)


func _process_pending(msg: Dictionary):
	match msg.handler:
		"authority":
			_do_handle_authority(msg.data)
		"initial_state":
			_do_handle_initial_state(msg.data)
		"schedule":
			_do_handle_schedule(msg.data)
		"vehicle":
			_do_handle_vehicle(msg.data)


func _valid_npc(npc_id) -> Node:
	if not (npc_id in _npcs):
		return null
	var npc = _npcs[npc_id]
	return npc if is_instance_valid(npc) else null


func _set_authority(is_auth: bool):
	_is_authority = is_auth
	for npc_id in _npcs:
		var npc = _npcs[npc_id]
		if is_instance_valid(npc):
			npc.set_authority(is_auth)
	print("[NpcManager] Authority set to: ", is_auth)
