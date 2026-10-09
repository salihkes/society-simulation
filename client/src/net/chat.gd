## Chat: chat and system messages, chat bubbles, and the commands typed into the chat line.
class_name NetChat
extends RefCounted

const BUBBLE_SECONDS := 3.0
const NetworkControllerScript := preload("res://src/net/network_controller.gd")

var _nc: NetworkControllerScript = null


func _init(controller: NetworkControllerScript):
	_nc = controller


func register_handlers() -> void:
	_nc.register_handler("chat_message", _on_chat_message)
	_nc.register_handler("system_message", _on_system_message)


## workspace.gd relays the signal to chat.
func system_notice(text: String):
	print(text)
	_nc.emit_signal("system_message_received", text)


## Straight into the ChatUI, if there is one.
func chat_ui_notice(text: String):
	var chat_ui = _nc.get_tree().root.find_child("ChatUI", true, false)
	if chat_ui and chat_ui.has_method("add_message"):
		chat_ui.add_message("System", text, true)


## Local commands first, offline chat without a server, else sends it.
func send(message):
	if _try_outfit_command(message):
		return

	if message.begins_with("/save"):
		_nc.workspace.save_studio_workspace()
		return

	if message.begins_with("/load"):
		_nc.workspace.load_studio_workspace()
		return

	if message.begins_with("/upload"):
		_nc.workspace.upload_place()
		return

	if _try_talk_command(message):
		return
	if _try_parliament_command(str(message).strip_edges()):
		return
	if _try_school_command(message):
		return
	if _try_pose_command(message):
		return

	# Words spoken beside a resident with a mind also go to it; the chat line itself is still sent.
	var ambient = _nc.ambient_manager()
	var routed_to_npc := false
	if not message.begins_with("/") and ambient and ambient.has_method("route_player_chat"):
		routed_to_npc = ambient.route_player_chat(message)

	if not _nc.connected:
		if routed_to_npc:
			# No server echo offline: show our own words locally.
			_nc.emit_signal("chat_message_received", _nc.local_username, message)
			return
		_handle_offline_chat(message)
		return

	var msg := {"type": "chat_message", "message": message}
	if not message.begins_with("/") and ambient and ambient.get("engagement") != null:
		var to: String = ambient.engagement.pick_addressee(message)
		if to != "":
			msg["to"] = to
	_nc.send_json(msg)


## Also lets residents in earshot hear it.
func _on_chat_message(data):
	var player_id = data.player_id
	var username = data.username
	var cmessage = data.message

	print("Chat message from %s: %s" % [username, cmessage])
	_nc.emit_signal("chat_message_received", username, cmessage)
	# The speaker is found by id: its node name may predate a later login.
	var ambient = _nc.ambient_manager()
	if ambient and ambient.get("engagement") != null:
		var speaker = _nc.players.remote_players.get(player_id, null)
		if speaker == null and player_id == _nc.client_id:
			speaker = _nc.players.local_player
		ambient.engagement.on_player_chat(str(username), str(cmessage), speaker,
			str(data.get("to", "")))

	_show_bubble(player_id, cmessage)


## "<old> is now known as <new>" renames a player.
func _on_system_message(data):
	var cmessage = data.message
	print("System message:", cmessage)
	_nc.emit_signal("system_message_received", cmessage)

	if not cmessage.contains(" is now known as "):
		return
	var parts = cmessage.split(" is now known as ")
	if parts.size() == 2:
		await _nc.players.rename(parts[0], parts[1])


func _show_bubble(player_id, message):
	var player = null
	if player_id == _nc.client_id and is_instance_valid(_nc.players.local_player):
		player = _nc.players.local_player
	elif player_id in _nc.players.remote_players:
		player = _nc.players.remote_players[player_id]

	if not player or not player.has_node("CharacterModel/ChatBubble"):
		return
	var chat_bubble = player.get_node("CharacterModel/ChatBubble")
	var sprite = chat_bubble.get_node("Sprite3D")
	var label = player.get_node("ChatBubbleViewport/Control/TextureRect/RichTextLabel")
	label.text = message
	sprite.visible = true

	await _nc.get_tree().create_timer(BUBBLE_SECONDS).timeout
	if is_instance_valid(sprite) and is_instance_valid(label):
		sprite.visible = false


## "/outfit [ids…|none]": the ids travel with transform updates.
func _try_outfit_command(message) -> bool:
	if String(message).strip_edges().get_slice(" ", 0).to_lower() != "/outfit":
		return false
	var parts := String(message).strip_edges().split(" ", false)
	var me = _nc.players.local_player
	if not is_instance_valid(me) or not me.has_method("get_outfit") \
			or not me.get_outfit() is Array:
		system_notice("This character has no fitted wardrobe.")
		return true
	if parts.size() == 1:
		system_notice("Outfit: " + ", ".join(me.get_outfit())
			+ ". Use /outfit polo pants shoes or /outfit none.")
		return true
	var ids: Array = []
	if parts.size() != 2 or parts[1] != "none":
		for i in range(1, parts.size()):
			ids.append(String(parts[i]).to_lower())
	if not me.set_outfit(ids):
		system_notice("Unknown or incompatible clothing selection.")
	return true


func _try_talk_command(message) -> bool:
	if not message.begins_with("/talk "):
		return false
	var npc_message = message.substr(6).strip_edges()
	if npc_message == "":
		return true
	var npcs = _nc.npc_manager()
	if not npcs:
		_nc.emit_signal("system_message_received", "NPC system not available.")
		return true
	var nearest = npcs.find_nearest_npc_to_player()
	if nearest != "":
		npcs.send_npc_chat(nearest, npc_message)
		_nc.emit_signal("chat_message_received", _nc.local_username,
			"[to " + nearest + "] " + npc_message)
	else:
		_nc.emit_signal("system_message_received", "No NPC nearby to talk to.")
	return true


## /sitting <matter> and /adjourn are checked by the server; /leave is passed on to the school too.
func _try_parliament_command(pm: String) -> bool:
	var ambient = _nc.ambient_manager()
	if not ambient or not ambient.has_method("player_parliament_request"):
		return false
	if pm in ["/parliament", "/gallery", "/box"]:
		ambient.player_parliament_request("enter" if pm == "/parliament" else pm.substr(1))
		return true
	if pm == "/adjourn":
		ambient.player_parliament_request("adjourn")
		return true
	if pm == "/sitting" or pm.begins_with("/sitting "):
		var matter: String = pm.substr(8).strip_edges()
		if matter == "":
			system_notice("Usage: /sitting <the matter before the house>")
		else:
			ambient.player_parliament_request("submit", matter)
		return true
	if pm == "/leave":
		ambient.player_parliament_request("leave")
	return false


## /school takes a desk, /teach the lectern, /yard the yard, /leave gets out.
func _try_school_command(message) -> bool:
	var cmd = message.strip_edges()
	var ambient = _nc.ambient_manager()
	if not cmd in ["/school", "/teach", "/leave", "/yard"] or not ambient \
			or not ambient.has_method("player_school_request"):
		return false
	ambient.player_school_request(cmd.substr(1) if cmd != "/school" else "enter")
	return true


## The pose reaches peers with the transform updates.
func _try_pose_command(message) -> bool:
	var cmd = message.strip_edges()
	if not cmd in ["/seiza", "/agura", "/stand"]:
		return false
	var me = _nc.players.local_player
	if me == null or not me.has_method("set_pose"):
		return true
	var wanted: String = "" if cmd == "/stand" else String(cmd).substr(1)
	me.set_pose(wanted)
	if wanted != "" and me.get("pose") != wanted:
		system_notice("Only the box humanoid can sit on the floor.")
	return true


## Appearance commands run the same local code the server's echo would.
func _handle_offline_chat(message: String):
	var parts = message.strip_edges().split(" ", false)
	if parts.is_empty():
		return

	var command = String(parts[0]).to_lower()
	if not command.begins_with("/"):
		system_notice("Offline — your message was not sent to anyone.")
		return

	match command:
		"/transform":
			if parts.size() < 2:
				system_notice("Usage: /transform <humanoid|countryball|custom>")
				return
			# "countryball" is the classic ball, which wears no flag.
			var character_type = String(parts[1]).to_lower()
			if not character_type in ["humanoid", CountryballTypes.CLASSIC, "custom"]:
				system_notice("Invalid character type. Use 'humanoid', 'countryball' or 'custom'.")
				return
			await _offline_transform(character_type, "")

		"/countryball":
			if parts.size() < 2:
				system_notice("Usage: /countryball <flag> [subtype]")
				return
			var flag_code = String(parts[1]).strip_edges()
			var subtype_arg = String(parts[2]) if parts.size() >= 3 else ""
			var subtype = CountryballTypes.resolve_subtype(subtype_arg)
			if subtype == "":
				system_notice("Unknown countryball subtype '" + subtype_arg + "'. Available: "
					+ ", ".join(CountryballTypes.subtype_names()))
				return
			await _offline_transform(subtype, flag_code)

		"/scale":
			_offline_scale(parts)

		_:
			# Emotions are single-word commands (/happy, /shocked, …).
			var emotion = command.substr(1)
			if CountryballTypes.all_emotions().has(emotion):
				_offline_emotion(emotion)
			else:
				system_notice("'" + command + "' needs a server connection.")


func _offline_scale(parts):
	if parts.size() < 2:
		system_notice("Usage: /scale <value> (0.2 to 1.5)")
		return
	var char_scale = String(parts[1]).to_float()
	if char_scale < 0.2 or char_scale > 1.5:
		system_notice("Scale must be between 0.2 and 1.5.")
		return
	if not is_instance_valid(_nc.players.local_player):
		system_notice("No character to scale yet.")
		return
	_nc.players.user_character_scale = char_scale
	_nc.players.apply_scale(_nc.players.local_player, char_scale)
	system_notice("Scale set to " + str(char_scale) + ".")


## A skin or flag is only available if cached on disk in an earlier online session.
func _offline_transform(character_type: String, flag_code: String):
	if not is_instance_valid(_nc.players.local_player):
		system_notice("No character to transform yet.")
		return

	_nc.players.user_character_type = character_type
	if flag_code != "":
		_nc.players.user_flag_code = flag_code

	await _nc.players.transform_local_player(character_type, flag_code)

	var username = _nc.local_username
	var texture_manager = _nc.get_node_or_null("/root/TextureManager")
	if texture_manager and texture_manager.has_method("has_texture"):
		if texture_manager.has_texture(username, character_type, flag_code):
			texture_manager.apply_texture_by_username(username, character_type, flag_code)
		elif flag_code != "":
			system_notice("Transformed, but the " + flag_code
				+ " flag has not been downloaded yet — connect once to fetch it.")
			return

	if flag_code != "":
		system_notice("Transformed to " + character_type + " with " + flag_code + " flag.")
	else:
		system_notice("Transformed to " + character_type + ".")


## Refuses faces the character type lacks, as the server would.
func _offline_emotion(emotion: String):
	if not is_instance_valid(_nc.players.local_player):
		system_notice("No character to emote with yet.")
		return

	var character_type = _nc.players.character_type_of(_nc.players.local_player)
	if CountryballTypes.emotions_for(character_type).is_empty():
		system_notice("Only countryballs and the humanoid have faces.")
		return
	if not CountryballTypes.supports_emotion(character_type, emotion):
		system_notice("'" + emotion + "' is not available on " + character_type + ".")
		return

	_nc.players.apply_emotion(_nc.players.local_player, emotion)
	system_notice("Emotion set to " + emotion + ".")
