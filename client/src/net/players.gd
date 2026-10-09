## Players: the local body and remote peers, their identity and looks, and the transform stream.
class_name NetPlayers
extends RefCounted

const CUSTOM_CHARACTER_DIR := "res://assets/entities/custom_character/"
const TRANSFORM_INTERVAL := 0.05
const NetworkControllerScript := preload("res://src/net/network_controller.gd")

var local_player = null
var remote_players = {}  # player_id -> body
## The local user's look, as the server last described it.
var user_texture = null
var user_character_type = "humanoid"
var user_flag_code = ""
var user_accessories = []
var user_character_scale = 1.0
## A place's checkpoint, applied when the body spawns.
var pending_spawn_position = null
## The "Players" node that holds remote bodies.
var container = null

var _nc: NetworkControllerScript = null
var _spawning_players = {}
## Once per session, so a reconnect does not teleport a player who is already standing somewhere.
var _spawn_applied := false


func _init(controller: NetworkControllerScript):
	_nc = controller


func register_handlers() -> void:
	_nc.register_handler("player_list", _msg_player_list)
	_nc.register_handler("player_joined", _msg_player_joined)
	_nc.register_handler("player_left", _msg_player_left)
	_nc.register_handler("player_identity_update", _on_player_identity_update)
	_nc.register_handler("player_transform", _on_player_transform)
	_nc.register_handler("teleport", _msg_teleport)
	_nc.register_handler("character_transform", _on_character_transform)
	_nc.register_handler("texture_info", _on_texture_info)
	_nc.register_handler("texture_data", _on_texture_data)
	_nc.register_handler("accessories_data", _on_accessories_data)
	_nc.register_handler("emotion_update", _on_emotion_update)
	_nc.register_handler("scale_update", _on_scale_update)


func make_container(parent: Node) -> void:
	container = Node3D.new()
	container.name = "Players"
	parent.add_child(container)


## The world process has no player, so there the body is removed.
func adopt_scene_player(ws):
	var existing_player = ws.find_child("humanoid", true, false)
	if not existing_player:
		existing_player = ws.find_child("countryball", true, false)

	if existing_player and _nc.is_world_mode():
		print("[World] Removing scene player body: ", existing_player.name)
		existing_player.get_parent().remove_child(existing_player)
		existing_player.queue_free()
	elif existing_player:
		local_player = existing_player
		print("Found existing local player in workspace:", existing_player.name)
		ensure_local_player_node(existing_player)


## Adds a "LocalPlayer" child node.
func ensure_local_player_node(player: Node):
	if not player:
		return
	var local_player_node = player.get_node_or_null("LocalPlayer")
	if not local_player_node:
		local_player_node = Node.new()
		local_player_node.name = "LocalPlayer"
		player.add_child(local_player_node)
		print("Added LocalPlayer node to:", player.name)


func _remove_local_player_node(player: Node):
	if not player:
		return
	var local_player_node = player.get_node_or_null("LocalPlayer")
	if local_player_node:
		local_player_node.queue_free()
		print("Removed LocalPlayer node from remote player:", player.name)


func remove_all():
	for player_id in remote_players.keys():
		_remove_player(player_id)
	remote_players.clear()


func _remove_player(player_id):
	if player_id in remote_players:
		var player = remote_players[player_id]
		player.queue_free()
	remote_players.erase(player_id)
	# Cancels any custom-pack wait for this peer.
	_spawning_players.erase(player_id)


func _msg_player_list(data) -> void:
	for player_data in data.players:
		_spawn_remote_from(player_data.id, player_data, false)


func _msg_player_joined(data) -> void:
	_spawn_remote_from(data.player_id, data, true)


func _msg_player_left(data) -> void:
	var player_id = data.player_id
	if player_id in remote_players:
		var username = remote_players[player_id].name
		print("Player left:", username, "with ID:", player_id)
		_remove_player(player_id)
		_nc.emit_signal("player_disconnected", player_id)


func _msg_teleport(data) -> void:
	if is_instance_valid(local_player):
		var position = Vector3(data.position.x, data.position.y, data.position.z)
		local_player.position = position
		print("Teleported to position: ", position)


func _is_local_target(player_id, username) -> bool:
	return (username == _nc.local_username or player_id == _nc.client_id) and is_instance_valid(local_player)


## The workspace's humanoid if there is one, else a new body at the spawn position.
func spawn_local_player():
	if local_player != null or _nc.is_world_mode():
		return
	if await _use_workspace_humanoid():
		return

	await _ensure_custom_pack_ready(user_character_type, _nc.local_username)
	var player_scene = _resolve_character_scene(user_character_type, _nc.local_username)

	local_player = player_scene.instantiate()
	local_player.name = "LocalPlayer"
	container.add_child(local_player)

	ensure_local_player_node(local_player)
	_nc.refresh_rain_player()

	if pending_spawn_position != null:
		await _nc.get_tree().process_frame
		local_player.global_position = pending_spawn_position
		print("Applied pending checkpoint spawn position to new player: ", pending_spawn_position)
		pending_spawn_position = null
	else:
		await _apply_spawn_point()

	_start_transform_updates()


func _use_workspace_humanoid() -> bool:
	var ws = _nc.get_tree().get_root().find_child("workspace", true, false)
	if not ws:
		return false
	var existing_player = ws.find_child("humanoid", true, false)
	if not existing_player:
		return false

	local_player = existing_player
	print("Using existing local player from workspace")
	ensure_local_player_node(local_player)
	_nc.refresh_rain_player()
	await _apply_spawn_point()
	_start_transform_updates()
	return true


## Renames, places at the spawn point and retypes it if the server's character type differs.
func resume_local_player():
	print("Using existing local player")
	if _nc.local_username != "" and _nc.local_username != "Guest" + str(_nc.client_id):
		print("Renaming local player from 'humanoid' to:", _nc.local_username)
		local_player.name = _nc.local_username

	ensure_local_player_node(local_player)
	_nc.refresh_rain_player()

	await _apply_spawn_point()

	var current_type = character_type_of(local_player)
	if current_type != user_character_type:
		print("Transforming existing player from ", current_type, " to server default: ", user_character_type)
		await transform_local_player(user_character_type, user_flag_code)
	else:
		_start_transform_updates()


## Once per session; a pending checkpoint spawn takes priority.
func _apply_spawn_point() -> void:
	if pending_spawn_position != null or _spawn_applied:
		return
	if not is_instance_valid(local_player):
		return

	var ws = _nc.workspace.find_workspace()
	if not ws:
		return

	var spawn_point = ws.find_child("SpawnPoint", true, false)
	if not spawn_point:
		print("SpawnPoint node not found in workspace; leaving local player at default position")
		return

	# global_position is only meaningful once the node is in the tree.
	if not local_player.is_inside_tree():
		await _nc.get_tree().process_frame

	local_player.global_position = spawn_point.global_position
	_spawn_applied = true
	print("Positioned local player at SpawnPoint: ", spawn_point.global_position)


func _spawn_remote_from(player_id, d, announce: bool):
	var username = d.username
	var position_data = d.position
	var rotation_data = d.rotation
	var texture_name = d.get("texture", null)
	var accessories = d.get("accessories", null)
	var character_type = d.get("character_type", "humanoid")
	var flag_code = d.get("flag_code", "")
	var emotion = d.get("emotion", "neutral")
	var char_scale = d.get("character_scale", 1.0)

	if announce:
		print("Player joined: ", username)
	_spawn_remote_player(player_id, username, position_data, rotation_data, texture_name,
		accessories, character_type, flag_code, emotion, char_scale)


## player_list and player_joined may name the same peer; the second is ignored.
func _spawn_remote_player(player_id, username, position_data, rotation_data, texture_name = null,
		accessories = null, character_type = "humanoid", flag_code = "", emotion = "neutral",
		char_scale = 1.0):
	if player_id in remote_players or _spawning_players.has(player_id):
		return
	_spawning_players[player_id] = true

	await _ensure_custom_pack_ready(character_type, username)
	# The peer may have been spawned or removed while the pack was awaited.
	if player_id in remote_players or not _nc.connected:
		_spawning_players.erase(player_id)
		return

	var player = _new_body(_resolve_character_scene(character_type, username), username,
		character_type, flag_code)
	player.set_meta("initial_emotion", emotion)
	print("Adding remote player:", username, "as", character_type, " flag:", flag_code, " emotion:", emotion)

	player.get_node("CamOrigin").queue_free()
	player.get_node("XROrigin3D").queue_free()
	# add_child runs _ready (voice receivers too): mark it remote first.
	player.is_remote_player = true
	container.add_child(player)
	_remove_local_player_node(player)
	player.set_as_remote_player()

	var position = Vector3(position_data.x, position_data.y, position_data.z)
	var rotation = Vector3(rotation_data.x, rotation_data.y, rotation_data.z)
	player.position = position
	player.rotation = rotation
	if player.has_node("CharacterModel"):
		player.get_node("CharacterModel").rotation.y = rotation.y

	remote_players[player_id] = player
	_spawning_players.erase(player_id)
	print("Spawned remote player: ", username)

	if texture_name:
		_apply_remote_texture(player, texture_name)
	if accessories:
		_apply_accessories(player, accessories)
	# Deferred so the character has finished setting up.
	if emotion != "neutral" and emotion != "":
		call_deferred("apply_emotion", player, emotion)
	if char_scale != 1.0:
		call_deferred("apply_scale", player, char_scale)


## Now, or when TextureManager has loaded it.
func _apply_remote_texture(player, texture_name):
	var texture_manager = _texture_manager(false)
	if texture_manager.texture_cache.has(texture_name):
		var texture = texture_manager.texture_cache[texture_name]
		texture_manager.apply_texture_to_player(player, texture)
		return

	var texture_loaded_handler = func(loaded_texture_name, texture):
		if loaded_texture_name == texture_name:
			texture_manager.apply_texture_to_player(player, texture)
	texture_manager.texture_loaded.connect(texture_loaded_handler)
	texture_manager.load_texture(texture_name)


## Flag-wearing countryballs get the flag as metadata.
func _new_body(scene: PackedScene, body_name, character_type, flag_code):
	var body = scene.instantiate()
	body.name = body_name
	if CountryballTypes.wears_flag(character_type) and flag_code != "":
		body.set_meta("flag_code", flag_code)
	return body


func _custom_scene_path(username) -> String:
	return CUSTOM_CHARACTER_DIR + username + "/humanoid.tscn"


## Custom characters live in a per-user folder; a missing one falls back to the humanoid.
func _resolve_character_scene(character_type: String, username: String) -> PackedScene:
	match character_type:
		CountryballTypes.CLASSIC:
			return _nc.workspace.countryball_scene
		CountryballTypes.ONESIDE:
			return _nc.workspace.countryball_oneside_scene
		CountryballTypes.QWC:
			return _nc.workspace.countryball_qwc_scene
		"custom":
			var path = _custom_scene_path(username)
			if username != "" and ResourceLoader.exists(path):
				return load(path) as PackedScene
			print("Custom character scene not found for '", username, "' (", path, "), falling back to humanoid")
			return _nc.workspace.humanoid_scene
		_:
			return _nc.workspace.humanoid_scene


## Waits for the per-user pack's scene up to 20 s, or 3 s with no download running.
func _ensure_custom_pack_ready(character_type: String, username: String) -> void:
	if character_type != "custom" or username == "":
		return
	var path = _custom_scene_path(username)
	if ResourceLoader.exists(path):
		return
	var pck_manager = _nc.get_node_or_null("/root/PCKManager")
	if not pck_manager:
		return
	if pck_manager.has_method("request"):
		pck_manager.request(username)
	print("Waiting for custom character pack to arrive for: ", username)
	var waited := 0.0
	var idle_grace := 0.0
	while waited < 20.0:
		if ResourceLoader.exists(path):
			print("Custom character pack ready for: ", username)
			return
		if _pck_busy(pck_manager):
			idle_grace = 0.0
		else:
			idle_grace += 0.25
			if idle_grace >= 3.0:
				print("Custom character pack did not arrive for '", username, "', falling back")
				return
		await _nc.get_tree().create_timer(0.25).timeout
		waited += 0.25
	print("Timed out waiting for custom character pack for '", username, "', falling back")


func _pck_busy(pck_manager) -> bool:
	if not pck_manager.has_method("is_downloading"):
		return false
	return pck_manager.is_downloading() or pck_manager.get_download_queue_size() > 0


func _on_player_identity_update(data):
	var player_id = data.player_id
	var username = data.username
	var texture = data.get("texture", null)
	var character_type = data.get("character_type", "humanoid")

	if not player_id in remote_players:
		return
	remote_players[player_id].name = username
	print("Updated player identity: ", username, " (", character_type, ")")
	if texture:
		_nc.send_json({
			"type": "get_texture",
			"texture_name": texture
		})


func rename(old_username, new_username):
	if old_username == _nc.local_username:
		_nc.local_username = new_username
		print("Updating local username to:", new_username)
		if not _nc.workspace.all_plots.is_empty():
			print("NetworkController: Username changed, re-checking plots...")
			_nc.workspace.check_user_plot()
		if is_instance_valid(local_player):
			print("Updating local player name from:", local_player.name, "to:", new_username)
			local_player.name = new_username
	else:
		for player_id in remote_players:
			var player = remote_players[player_id]
			if player.name == old_username:
				player.name = new_username
				print("Renamed remote player from", old_username, "to", new_username)

	var texture_manager = _nc.get_node_or_null("/root/TextureManager")
	if not texture_manager:
		return
	await _nc.get_tree().create_timer(0.2).timeout
	if not texture_manager.texture_cache.has(new_username):
		print("Requesting texture for", new_username)
		_nc.send_json({
			"type": "get_texture",
			"texture_name": new_username
		})
	else:
		print("Applying cached texture for", new_username)
		texture_manager.apply_texture_by_username(new_username)


func _on_player_transform(data):
	var player_id = data.player_id
	if player_id == _nc.client_id or not player_id in remote_players:
		return
	var player = remote_players[player_id]
	if not is_instance_valid(player):
		print("Player object is no longer valid, removing from remote_players: ", player_id)
		remote_players.erase(player_id)
		return

	var position = Vector3(data.position.x, data.position.y, data.position.z)
	var rotation = Vector3(data.rotation.x, data.rotation.y, data.rotation.z)
	var on_floor = data.get("on_floor", true)
	var prev_position: Vector3 = _place_remote_player(player, data, position, rotation)

	if player.has_node("CharacterModel"):
		if "model_rotation_y" in data:
			player.get_node("CharacterModel").rotation.y = data.model_rotation_y
		else:
			player.get_node("CharacterModel").rotation.y = rotation.y

	var movement = position - prev_position
	# Peers that do not send their locomotion speed get it from the delta.
	var speed: float
	if "speed" in data:
		speed = float(data.speed)
	else:
		speed = movement.length() / TRANSFORM_INTERVAL

	if data.get("outfit") is Array and player.has_method("set_outfit"):
		player.set_outfit(data.outfit)
	if player.has_method("set_pose"):
		player.set_pose(str(data.get("pose", "")))
	if player.has_method("animate_remote_movement"):
		player.animate_remote_movement(speed, movement.normalized(), on_floor)


## Global when aboard a ship (which also gives its gravity); returns the previous position.
func _place_remote_player(player, data, position: Vector3, rotation: Vector3) -> Vector3:
	var remote_on_ship = data.get("on_ship") if "on_ship" in data else false
	if not remote_on_ship:
		var prev_local: Vector3 = player.position
		player.position = position
		player.rotation = rotation
		return prev_local

	var prev_position: Vector3 = player.global_position
	player.global_position = position
	player.global_rotation = rotation
	var ship_id = data.get("ship_id") if "ship_id" in data else ""
	if ship_id != "":
		var ship = _nc.objects.find_ship(ship_id)
		if ship and player.get("planet") != null:
			var sname = ship.ship_name if "ship_name" in ship else "Ship"
			player.planet.set_planet(ship, sname)
	return prev_position


## Every TRANSFORM_INTERVAL while connected; a pilot also sends the ship's.
func _start_transform_updates():
	while _nc.connected and is_instance_valid(local_player):
		var aboard = local_player.get("ship")
		var on_ship: bool = aboard != null and aboard.is_aboard()
		_nc.send_json(_local_transform_message(on_ship))

		if on_ship and aboard.is_piloting():
			_nc.objects.send_ship_transform(aboard.boarded)

		await _nc.get_tree().create_timer(TRANSFORM_INTERVAL).timeout


## Aboard a ship the transform is global, since the local one is relative to the ship.
func _local_transform_message(on_ship: bool) -> Dictionary:
	var position: Vector3
	var rotation: Vector3
	if on_ship:
		position = local_player.global_position
		rotation = local_player.global_rotation
	else:
		position = local_player.position
		rotation = local_player.rotation

	var model_rotation_y = null
	if local_player.has_node("CharacterModel"):
		model_rotation_y = local_player.get_node("CharacterModel").rotation.y

	var on_floor = false
	if local_player.get("planet") != null:
		on_floor = local_player.planet.is_on_floor()
	elif local_player.has_method("is_on_floor"):
		on_floor = local_player.is_on_floor()

	var message = {
		"type": "transform_update",
		"position": {"x": position.x, "y": position.y, "z": position.z},
		"rotation": {"x": rotation.x, "y": rotation.y, "z": rotation.z},
		"on_floor": on_floor
	}

	# The mover's real locomotion state drives the peers' animation.
	var mover_speed = local_player.get("anim_speed")
	if mover_speed != null:
		message["speed"] = mover_speed
		message["running"] = local_player.get("anim_is_running") == true

	if local_player.has_method("get_outfit"):
		var outfit = local_player.get_outfit()
		if outfit is Array:
			message["outfit"] = outfit

	# A floor pose (seiza, agura) so peers sit the body the same way.
	var floor_pose = local_player.get("pose")
	if typeof(floor_pose) == TYPE_STRING and floor_pose != "":
		message["pose"] = floor_pose

	if on_ship:
		message["on_ship"] = true
		var boarded: Node3D = local_player.ship.boarded
		message["ship_id"] = boarded.get_net_id() if boarded.has_method("get_net_id") else ""

	if model_rotation_y != null:
		message["model_rotation_y"] = model_rotation_y
	return message


func _on_character_transform(data):
	var player_id = data.player_id
	var username = data.username
	var character_type = data.character_type
	var flag_code = data.get("flag_code", "")

	print("Character transform for player:", username, "to:", character_type, " flag:", flag_code)
	print("  player_id:", player_id, " client_id:", _nc.client_id, " username:", username, " local_username:", _nc.local_username)

	if username == _nc.local_username:
		user_character_type = character_type
		user_flag_code = flag_code
		print("Stored character type for local player: ", character_type, " flag: ", flag_code)

	if _is_local_target(player_id, username):
		print("Transforming local player to:", character_type, " flag:", flag_code)
		await transform_local_player(character_type, flag_code)
	elif player_id in remote_players:
		print("Transforming remote player", player_id, "to:", character_type, " flag:", flag_code)
		await _transform_remote_player(player_id, character_type, flag_code)
	else:
		return

	_nc.send_json({
		"type": "get_texture",
		"texture_name": username
	})


## Keeps place, name, accessories and scale.
func transform_local_player(character_type, flag_code = ""):
	if not is_instance_valid(local_player):
		return

	print("Transforming local player to:", character_type, " flag:", flag_code)
	var snap := _snapshot_body(local_player)
	local_player.queue_free()
	await _nc.get_tree().process_frame

	await _ensure_custom_pack_ready(character_type, snap.name)
	var new_scene = _resolve_character_scene(character_type, snap.name)
	local_player = _new_body(new_scene, snap.name, character_type, flag_code)

	var ws = _nc.get_tree().get_root().find_child("workspace", true, false)
	if ws:
		ws.add_child(local_player)
		print("Added new local player directly to workspace")
	else:
		container.add_child(local_player)
		print("Fallback: Added new local player to player container")

	ensure_local_player_node(local_player)
	_nc.refresh_rain_player()

	local_player.global_position = snap.position
	local_player.rotation = snap.rotation
	await _nc.get_tree().process_frame

	if pending_spawn_position != null:
		local_player.global_position = pending_spawn_position
		print("Applied pending checkpoint spawn position: ", pending_spawn_position)
		pending_spawn_position = null

	print("New character should automatically find planetary system")

	var accessories_to_apply = user_accessories if user_accessories.size() > 0 else snap.accessories
	if accessories_to_apply.size() > 0:
		print("Restoring accessories after transformation:", accessories_to_apply)
		_apply_accessories(local_player, accessories_to_apply)
	if user_character_scale != 1.0:
		call_deferred("apply_scale", local_player, user_character_scale)

	_start_transform_updates()


## Keeps place, name, planet and accessories.
func _transform_remote_player(player_id, character_type, flag_code = ""):
	if not player_id in remote_players:
		return

	var old_player = remote_players[player_id]
	print("Transforming remote player:", old_player.name, "to:", character_type, " flag:", flag_code)
	var snap := _snapshot_body(old_player)
	old_player.queue_free()
	await _nc.get_tree().process_frame

	await _ensure_custom_pack_ready(character_type, snap.name)
	var new_scene = _resolve_character_scene(character_type, snap.name)
	var new_player = _new_body(new_scene, snap.name, character_type, flag_code)

	if new_player.has_node("XROrigin3D"):
		new_player.get_node("XROrigin3D").queue_free()
	if new_player.has_node("CamOrigin"):
		new_player.get_node("CamOrigin").queue_free()

	new_player.is_remote_player = true
	container.add_child(new_player)
	_remove_local_player_node(new_player)
	new_player.set_as_remote_player()

	new_player.global_position = snap.position
	new_player.rotation = snap.rotation
	await _nc.get_tree().process_frame

	if snap.planet and new_player.get("planet") != null:
		print("Restoring planetary system to new remote character")
		new_player.planet.current = snap.planet
		new_player.planet.current_name = snap.planet_name
		new_player.planet.calc_gravity_direction()
		print("Restored planetary system without repositioning")

	if snap.accessories.size() > 0:
		print("Restoring accessories after transformation:", snap.accessories)
		_apply_accessories(new_player, snap.accessories)

	remote_players[player_id] = new_player


## What survives a body swap: transform, name, accessories and planet.
func _snapshot_body(body) -> Dictionary:
	var snap := {
		"position": body.global_position,
		"rotation": body.rotation,
		"name": body.name,
		"accessories": [],
		"planet": null,
		"planet_name": "Planet",
	}
	if body.has_node("CharacterModel/Accessories"):
		var accessories_node = body.get_node("CharacterModel/Accessories")
		for child in accessories_node.get_children():
			snap.accessories.append(child.name)
	var walker = body.get("planet")
	if walker != null:
		snap.planet = walker.current
		snap.planet_name = walker.current_name
	return snap


func character_type_of(player: Node) -> String:
	if not player:
		return "humanoid"

	# The specific flavours are tested before the generic "countryball".
	if player.scene_file_path.contains("custom_character"):
		return "custom"
	elif player.scene_file_path.contains("countryball_quincyform"):
		return CountryballTypes.QWC
	elif player.scene_file_path.contains("countryballoneside"):
		return CountryballTypes.ONESIDE
	elif player.scene_file_path.contains("countryball") or player.has_node("CountryballModel"):
		return CountryballTypes.CLASSIC
	else:
		return "humanoid"


func _on_texture_info(data):
	var texture_name = data.texture_name
	_nc.emit_signal("texture_info_received", texture_name)

	if not is_instance_valid(local_player):
		return
	var texture_manager = _nc.get_node("/root/TextureManager")
	var texture = texture_manager.load_texture(texture_name)
	if texture:
		var character_model = local_player.find_child("CharacterModel", true)
		if character_model:
			texture_manager.apply_texture_to_character(character_model, texture)


func _on_texture_data(data):
	var texture_name = data.texture_name
	var texture_data = data.data
	var character_type = data.get("character_type", "humanoid")
	var flag_code = data.get("flag_code", "")

	print("Received texture data for:", texture_name, "character type:", character_type, "flag_code:", flag_code)

	if texture_name == _nc.local_username:
		user_texture = texture_name
		if CountryballTypes.wears_flag(character_type) and flag_code != "":
			user_flag_code = flag_code
		print("Stored texture for local player")

	var texture_manager = _texture_manager(true)
	var texture = texture_manager.process_texture_data(texture_name, texture_data, character_type, flag_code)

	print("Applying texture to all players with name:", texture_name, "and character type:", character_type)

	if is_instance_valid(local_player) and _nc.local_username == texture_name \
			and character_type_of(local_player) == character_type:
		print("Applying texture to local player:", texture_name, " (username: ", _nc.local_username, ")")
		texture_manager.apply_texture_to_player(local_player, texture)

	for player_id in remote_players:
		var player = remote_players[player_id]
		if player.name == texture_name and character_type_of(player) == character_type:
			print("Applying texture to remote player:", texture_name)
			texture_manager.apply_texture_to_player(player, texture)

	_nc.emit_signal("texture_info_received", texture_name)


## Created if it is missing.
func _texture_manager(announce: bool):
	var texture_manager = _nc.get_node_or_null("/root/TextureManager")
	if texture_manager:
		return texture_manager
	if announce:
		print("Creating TextureManager")
	texture_manager = load("res://src/net/texture_manager.gd").new()
	texture_manager.name = "TextureManager"
	_nc.get_tree().root.add_child(texture_manager)
	return texture_manager


func _on_accessories_data(data):
	print("Received accessories data: ", data)
	var username = data.username
	var accessories = data.accessories
	var player_id = data.get("player_id", -1)

	print("Accessories for user: ", username, " - ", accessories)

	if username == _nc.local_username:
		user_accessories = accessories
		print("Stored accessories for local player: ", accessories)

	var found = false
	if is_instance_valid(local_player) and (username == _nc.local_username):
		print("Applying accessories to local player: ", username)
		_apply_accessories(local_player, accessories)
		found = true

	for pid in remote_players:
		var player = remote_players[pid]
		if player.name == username:
			print("Applying accessories to remote player: ", username)
			_apply_accessories(player, accessories)
			found = true

	if not found:
		print("WARNING: Could not find player with username: ", username, " to apply accessories")


func _apply_accessories(player, accessories):
	print("Applying accessories to player: ", player.name)

	if not player:
		print("ERROR: Player is null")
		return

	if not accessories:
		print("WARNING: No accessories to apply")
		return

	if not player.has_node("CharacterModel"):
		print("ERROR: Player doesn't have a CharacterModel node")
		return

	if not player.has_node("CharacterModel/Accessories"):
		print("ERROR: Player doesn't have a CharacterModel/Accessories node")
		return

	var accessories_node = player.get_node("CharacterModel/Accessories")
	print("Found Accessories node: ", accessories_node)

	for child in accessories_node.get_children():
		child.queue_free()
	print("Cleared existing accessories")

	print("Adding new accessories: ", accessories)
	for accessory_name in accessories:
		print("Attempting to add accessory: ", accessory_name)
		var success = _add_accessory(accessories_node, accessory_name)
		print("Accessory add result: ", success)


## Instances accessories/<name>/<name>.tscn; false if missing.
func _add_accessory(accessories_node, accessory_name):
	var accessory_path = "res://assets/entities/character/accessories/" + accessory_name + "/" + accessory_name + ".tscn"
	print("Looking for accessory at path: ", accessory_path)

	if not ResourceLoader.exists(accessory_path):
		print("Failed to find accessory: ", accessory_name)
		return false

	print("Accessory exists, loading: ", accessory_path)
	var accessory_scene = load(accessory_path)
	if not accessory_scene:
		print("Failed to load accessory scene despite it existing: ", accessory_path)
		return false

	var accessory_instance = accessory_scene.instantiate()
	accessory_instance.name = accessory_name
	accessories_node.add_child(accessory_instance)
	print("Successfully added accessory: ", accessory_name)
	return true


func _on_emotion_update(data):
	var player_id = data.player_id
	var username = data.username
	var emotion = data.emotion

	print("Received emotion update for:", username, "emotion:", emotion)

	if _is_local_target(player_id, username):
		apply_emotion(local_player, emotion)
	elif player_id in remote_players:
		apply_emotion(remote_players[player_id], emotion)


func apply_emotion(player: Node, emotion: String) -> void:
	if not is_instance_valid(player):
		return

	if player.has_method("set_emotion") and player.set_emotion(emotion):
		print("Applied emotion '", emotion, "' to player via set_emotion: ", player.name)
		return

	if player.has_method("get") and player.get("current_animation") != null:
		var animation = player.current_animation
		if animation and animation.has_method("set_emotion"):
			animation.set_emotion(emotion)
			print("Applied emotion '", emotion, "' to player via animation: ", player.name)
			return

	var character_model = player.find_child("CharacterModel", true, false)
	if not character_model:
		return
	var emotions_mesh = character_model.find_child("Emotions", true, false)
	if emotions_mesh and emotions_mesh is MeshInstance3D:
		var emotion_path = "res://assets/entities/countryball/Emotions/" + emotion.to_lower() + ".tres"
		var emotion_material = load(emotion_path)
		if emotion_material:
			emotions_mesh.set_surface_override_material(0, emotion_material)
			print("Applied emotion material '", emotion, "' directly to player: ", player.name)


func _on_scale_update(data):
	var player_id = data.player_id
	var username = data.username
	var char_scale = float(data.character_scale)

	print("Received scale update for:", username, "scale:", char_scale)

	if _is_local_target(player_id, username):
		user_character_scale = char_scale
		apply_scale(local_player, char_scale)
	elif player_id in remote_players:
		apply_scale(remote_players[player_id], char_scale)


## Countryball base scale is 1.25.
func apply_scale(player: Node, char_scale: float) -> void:
	if not is_instance_valid(player):
		return

	if player.has_method("set_character_scale"):
		player.set_character_scale(char_scale)
		print("Applied scale ", char_scale, " to player: ", player.name)
		return

	var character_model = player.find_child("CharacterModel", true, false)
	if character_model:
		var base_scale = Vector3(1.25, 1.25, 1.25)
		character_model.scale = base_scale * char_scale
		print("Applied scale ", char_scale, " directly to CharacterModel: ", player.name)
