extends Control
## The chat window: fading message list, input box and slash commands; in VR it moves onto a VRChatPanel.

signal message_sent(text)

const VRChatPanelScript = preload("res://src/ui/vr_chat_panel.gd")
const MediaCommands = preload("res://src/media/media_commands.gd")

@onready var chat_display = $VBoxContainer/ChatDisplay
@onready var input_field = $VBoxContainer/InputContainer/InputField
@onready var send_button = $VBoxContainer/InputContainer/SendButton

var max_messages = 50
## Seconds a message stays; it fades over the last two.
var message_timeout = 10.0
var messages = []
var vr_panel = null
var _mode_button: Button = null


func _ready():
	input_field.text_submitted.connect(_on_input_field_submitted)
	send_button.pressed.connect(_on_send_button_pressed)

	chat_display.text = ""
	# The movement keys are also GUI navigation keys; focus comes from T or a click only.
	input_field.focus_mode = Control.FOCUS_CLICK
	send_button.focus_mode = Control.FOCUS_NONE
	chat_display.focus_mode = Control.FOCUS_NONE
	input_field.release_focus()
	_add_mode_button()

	var timer = Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_on_fade_timer_timeout)
	add_child(timer)

	# OpenXR initialises after scene load, so keep checking.
	var vr_timer = Timer.new()
	vr_timer.wait_time = 2.0
	vr_timer.autostart = true
	vr_timer.timeout.connect(_check_vr_panel)
	add_child(vr_timer)

	var auth_manager = get_node_or_null("/root/AuthManager")
	if not auth_manager:
		await get_tree().process_frame
		auth_manager = get_node("/root/AuthManager")

	auth_manager.login_successful.connect(_on_login_successful)
	auth_manager.login_failed.connect(_on_login_failed)
	auth_manager.register_successful.connect(_on_register_successful)
	auth_manager.register_failed.connect(_on_register_failed)

	add_message("System", "Welcome! Type /connect to connect to server or /help for commands.", true)


## The switch showing whether keys type (入) or walk (歩).
func _add_mode_button() -> void:
	_mode_button = Button.new()
	_mode_button.focus_mode = Control.FOCUS_NONE
	_mode_button.custom_minimum_size = Vector2(44, 0)
	_mode_button.tooltip_text = \
			"Click or press T to type; Esc, Enter or a click in the world to walk again"
	_mode_button.pressed.connect(_toggle_typing)
	input_field.get_parent().add_child(_mode_button)
	input_field.get_parent().move_child(_mode_button, 0)
	input_field.focus_entered.connect(_refresh_mode)
	input_field.focus_exited.connect(_refresh_mode)
	input_field.placeholder_text = Labels.text("chat_hint", "T to type")
	_refresh_mode()


## The panel goes at the scene root because the character's scene is replaced at runtime.
func _check_vr_panel():
	if vr_panel:
		return
	var xr_interface = XRServer.find_interface("OpenXR")
	if not xr_interface or not xr_interface.is_initialized():
		return
	if not get_viewport().use_xr:
		return
	var host = get_tree().current_scene
	if host == null:
		host = get_tree().root
	vr_panel = VRChatPanelScript.new()
	host.add_child(vr_panel)
	# Reparenting this Control inside a signal callback is unsafe.
	vr_panel.call_deferred("attach_chat", self)
	print("ChatUI: VR chat panel created under ", host.name)


func vr_toggle_panel():
	if vr_panel:
		vr_panel.toggle()


func _toggle_typing():
	if input_field.has_focus():
		input_field.release_focus()
	else:
		input_field.grab_focus()


func _refresh_mode():
	if _mode_button == null:
		return
	var typing: bool = input_field.has_focus()
	_mode_button.text = Labels.text("typing", "Type") if typing else Labels.text("walking", "Walk")
	_mode_button.modulate = Color(1.0, 0.85, 0.35) if typing else Color(0.8, 0.8, 0.8)
	input_field.modulate = Color(1.0, 1.0, 1.0) if typing else Color(0.75, 0.75, 0.75)


func _unhandled_input(event):
	# A click in the world while typing goes back to walking.
	if event is InputEventMouseButton and event.pressed and input_field.has_focus():
		input_field.release_focus()


## T focuses the box (unless an in-game computer holds the keys); Esc leaves it.
func _input(event):
	if event is InputEventKey and event.pressed and event.keycode == KEY_T \
			and not input_field.has_focus() and not _keys_held_elsewhere():
		input_field.grab_focus()
		get_viewport().set_input_as_handled()

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE \
			and input_field.has_focus():
		input_field.release_focus()
		get_viewport().set_input_as_handled()


## Up from the current camera, else the local player's CamOrigin.
func _find_camera_controller() -> Node:
	var node: Node = get_viewport().get_camera_3d()
	while node != null:
		if node.has_method("toggle_first_person"):
			return node
		node = node.get_parent()
	var nc = get_node_or_null("/root/NetworkController")
	var me = nc.get_indexed("players:local_player") if nc else null
	if me != null and is_instance_valid(me):
		var rig = me.find_child("CamOrigin", true, false)
		if rig != null and rig.has_method("toggle_first_person"):
			return rig
	return null


func _keys_held_elsewhere() -> bool:
	var nc = get_node_or_null("/root/NetworkController")
	if nc == null:
		return false
	var me = nc.get_indexed("players:local_player")
	if me == null or not is_instance_valid(me):
		return false
	var h = me.get("key_holder")
	return h != null and is_instance_valid(h)


## Keeps at most max_messages.
func add_message(username, text, is_system = false):
	var timestamp = Time.get_unix_time_from_system()
	var message = {
		"username": username,
		"text": text,
		"timestamp": timestamp,
		"is_system": is_system
	}

	messages.append(message)

	if messages.size() > max_messages:
		messages.pop_front()

	_update_chat_display()


func _update_chat_display():
	chat_display.text = ""

	for message in messages:
		var prefix = "[System]: " if message.is_system else "[" + message.username + "]: "
		var color = "#AAAAFF" if message.is_system else "#FFFFFF"

		var age = Time.get_unix_time_from_system() - message.timestamp
		var opacity = 1.0
		if age > message_timeout - 2.0:
			opacity = max(0.0, (message_timeout - age) / 2.0)

		if opacity > 0.1:
			var opacity_hex = "%02X" % int(opacity * 255)
			chat_display.text += "[color=#" + color.substr(1) + opacity_hex + "]" + prefix \
					+ message.text + "[/color]\n"

	# The VR panel's viewport only renders on request.
	if vr_panel and is_instance_valid(vr_panel):
		vr_panel.request_redraw()


func _on_input_field_submitted(text):
	if text.strip_edges() == "":
		input_field.release_focus()
		return
	_dispatch(text)
	input_field.text = ""
	input_field.release_focus()


## Does not touch the input box (VR buttons).
func submit_text(text: String) -> void:
	text = text.strip_edges()
	if text == "":
		return
	_dispatch(text)


func _on_send_button_pressed():
	var text = input_field.text.strip_edges()
	if text != "":
		_dispatch(text)
		input_field.text = ""
	input_field.release_focus()


func _dispatch(text) -> void:
	if text.begins_with("/"):
		_handle_command(text)
	else:
		emit_signal("message_sent", text)


func _on_fade_timer_timeout():
	var current_time = Time.get_unix_time_from_system()
	var i = 0
	while i < messages.size():
		if current_time - messages[i].timestamp > message_timeout + 2.0:
			messages.remove_at(i)
		else:
			i += 1

	_update_chat_display()


## Local commands run here, the rest are forwarded as chat.
func _handle_command(command_text):
	var parts = command_text.split(" ")
	var command = parts[0].to_lower()

	match command:
		"/media":
			MediaCommands.handle(parts, self)
		"/browse":
			_browse(parts)
		"/window":
			_window(parts)
		"/drives":
			_list_drives()
		"/travel":
			_travel(parts)
		"/help":
			_show_help()
		"/register":
			_cmd_register(parts)
		"/login":
			_cmd_login(parts)
		"/logout":
			_cmd_logout()
		"/transform":
			_cmd_transform(parts, command_text)
		"/countryball":
			_cmd_countryball(parts, command_text)
		"/happy", "/sad", "/serious", "/neutral", "/angry", "/afraid", "/scarystare", "/shocked":
			# The server rejects faces the player's body does not have.
			emit_signal("message_sent", command_text)
			var emotion_name = command.substr(1)
			add_message("System", "Setting emotion to " + emotion_name + "...", true)
		"/firstperson", "/fp", "/thirdperson":
			_cmd_camera(command)
		"/vehicle", "/veh":
			var vm = get_tree().root.find_child("VehicleManager", true, false)
			if vm == null or not vm.has_method("chat_command"):
				add_message("System", "No vehicles in this workspace", true)
				return
			add_message("System", vm.chat_command(parts), true)
		"/scale":
			_cmd_scale(parts, command_text)
		"/teleport":
			if parts.size() < 2:
				add_message("System",
						"Usage: /teleport <destination> (a place or your plot name)", true)
				return
			emit_signal("message_sent", command_text)
			add_message("System", "Teleporting...", true)
		"/save":
			emit_signal("message_sent", "/save")
		"/load":
			emit_signal("message_sent", "/load")
		"/upload":
			emit_signal("message_sent", "/upload")
		"/places":
			_cmd_places()
		"/join":
			_cmd_join(parts)
		"/lobby":
			add_message("System", "Returning to lobby...", true)
			add_message("System",
					"Note: This will reload the scene. Your unsaved work will be lost!", true)
			get_tree().reload_current_scene()
		"/connect":
			_cmd_connect(parts)
		"/disconnect":
			_cmd_disconnect()
		"/talk", "/school", "/teach", "/leave", "/yard", "/seiza", "/agura", "/stand", \
		"/parliament", "/gallery", "/box", "/sitting", "/adjourn":
			emit_signal("message_sent", command_text)
		_:
			add_message("System", "Unknown command. Type /help for available commands.", true)


func _show_help() -> void:
	for line in [
		"Available commands:",
		"/register <username> <password> - Create account (lobby only)",
		"/login <username> <password> - Log in (lobby only)",
		"/logout - Log out from your account",
		"/transform <type> - Transform character (humanoid/countryball)",
		"/countryball <flag> [subtype] - Transform to countryball with flag (e.g. TUR, RUS_Republic)",
		"    subtype: " + ", ".join(CountryballTypes.subtype_names()) + " (default: classic)",
		"/happy /sad /serious /neutral - Set your face (countryballs and humanoids)",
		"/angry /afraid /scarystare /shocked - Extra faces (QWC ball and humanoids)",
		"/teleport <destination> - Teleport (a place or your plot name)",
		"/myplot - View your plot info",
		"/scale <value> - Set character scale (0.2 to 1.5)",
		"/firstperson (/fp) - Look out of your own eyes; Numpad 0 or zooming all the way in does the same",
		"/school - the classroom door; /yard - the school yard; /teach - the lectern; /leave - go back out",
		"/parliament - the chamber door; /gallery /box - where built; /sitting <matter> - put a matter to the house (sovereign); /adjourn; /leave - go back out",
		"/seiza /agura - sit on the floor right here (humanoid); /stand or any step gets up",
		"/connect [ip or url] - Connect to the server (a given one, even when offline)",
		"/disconnect - Disconnect from server",
		"/save - Save studio workspace to user:// (offline)",
		"/load - Load studio workspace from user:// (offline)",
		"/upload - Upload saved workspace as your place (requires login)",
		"/places - List available places to join",
		"/join <place_name> - Join a place (login first!)",
		"/lobby - Return to lobby",
		"/media list | play <path/url> | tracks | audio <n> | pause | resume | stop | volume <0-100>",
		"/drives · /browse <url or archive> · /window new | close | tidy | snap on/off",
		"/help - Show this help message",
		"Offline (no server): /transform, /countryball, emotions, /scale, /save and /load work locally; everything else needs a connection.",
	]:
		add_message("System", line, true)


func _cmd_register(parts) -> void:
	if parts.size() < 3:
		add_message("System", "Usage: /register <username> <password>", true)
		return
	var username = parts[1]
	var password = parts[2]
	if username.length() < 3:
		add_message("System", "Username must be at least 3 characters long", true)
		return
	if password.length() < 6:
		add_message("System", "Password must be at least 6 characters long", true)
		return
	var auth_manager = get_node("/root/AuthManager")
	auth_manager.current_username = username
	auth_manager.register(username, password)
	add_message("System", "Registering...", true)


func _cmd_login(parts) -> void:
	if parts.size() < 3:
		add_message("System", "Usage: /login <username> <password>", true)
		return
	var username = parts[1]
	var password = parts[2]
	var auth_manager = get_node("/root/AuthManager")
	auth_manager.current_username = username
	auth_manager.login(username, password, true)  # remember me
	add_message("System", "Logging in...", true)


func _cmd_logout() -> void:
	var auth_manager = get_node("/root/AuthManager")
	if auth_manager.is_logged_in():
		auth_manager.logout()
		add_message("System", "You have been logged out", true)
	else:
		add_message("System", "You are not logged in", true)


func _cmd_transform(parts, command_text) -> void:
	if parts.size() < 2:
		add_message("System", "Usage: /transform <type> (humanoid/countryball/custom)", true)
		return
	var character_type = parts[1].to_lower()
	if character_type in ["humanoid", "countryball", "custom"]:
		emit_signal("message_sent", command_text)
		add_message("System", "Transforming to " + character_type + "...", true)
	else:
		add_message("System",
				"Invalid character type. Use 'humanoid', 'countryball' or 'custom'", true)


func _cmd_countryball(parts, command_text) -> void:
	if parts.size() < 2:
		add_message("System",
				"Usage: /countryball <flag> [subtype] (e.g. TUR, RUS_Republic, NET_Monarchy qwc)",
				true)
		return
	var flag_code = parts[1]
	var subtype_arg = parts[2] if parts.size() >= 3 else ""
	var subtype_type = CountryballTypes.resolve_subtype(subtype_arg)
	if subtype_type == "":
		add_message("System", "Unknown countryball subtype '" + subtype_arg + "'. Available: "
				+ ", ".join(CountryballTypes.subtype_names()), true)
		return
	emit_signal("message_sent", command_text)
	add_message("System", "Transforming to countryball with " + flag_code + " flag...", true)


## Local only.
func _cmd_camera(command) -> void:
	var cam_origin = _find_camera_controller()
	if cam_origin == null:
		add_message("System", "No player camera to switch", true)
		return
	if command == "/thirdperson":
		cam_origin.set_first_person(false)
	else:
		cam_origin.toggle_first_person()
	var on_now: bool = cam_origin.is_first_person()
	add_message("System",
			"First person " + ("on — Escape frees the cursor" if on_now else "off"), true)


func _cmd_scale(parts, command_text) -> void:
	if parts.size() < 2:
		add_message("System", "Usage: /scale <value> (0.2 to 1.5)", true)
		return
	var scale_val = parts[1].to_float()
	if scale_val < 0.2 or scale_val > 1.5:
		add_message("System", "Scale must be between 0.2 and 1.5", true)
		return
	emit_signal("message_sent", command_text)
	add_message("System", "Setting scale to " + parts[1] + "...", true)


func _network_controller():
	var network_controller = get_node_or_null("/root/NetworkController")
	if not network_controller:
		network_controller = get_tree().root.find_child("NetworkController", true, false)
	return network_controller


func _cmd_places() -> void:
	var network_controller = _network_controller()
	if network_controller and network_controller.get("workspace") != null:
		network_controller.workspace.request_places_list()
		add_message("System", "Requesting places list...", true)
	else:
		add_message("System", "Network controller not found", true)


func _cmd_join(parts) -> void:
	if parts.size() < 2:
		add_message("System", "Usage: /join <place_name>", true)
		return
	var place_name = parts[1]
	var network_controller = _network_controller()
	if network_controller and network_controller.get("workspace") != null:
		network_controller.workspace.join_place(place_name)
		add_message("System", "Joining place '" + place_name + "'...", true)
	else:
		add_message("System", "Network controller not found", true)


## Without an address, connects to the launch's server.
func _cmd_connect(parts) -> void:
	var network_controller = _network_controller()
	if network_controller and parts.size() >= 2 \
			and network_controller.has_method("connect_to_address"):
		network_controller.connect_to_address(parts[1])
		add_message("System", "Connecting to " + parts[1] + "...", true)
	elif network_controller and network_controller.has_method("connect_to_server"):
		network_controller.connect_to_server()
		add_message("System", "Connecting to server...", true)
	else:
		add_message("System", "Network controller not found", true)


func _cmd_disconnect() -> void:
	var network_controller = _network_controller()
	if not (network_controller and network_controller.has_method("disconnect_from_server")):
		add_message("System", "Network controller not found", true)
		return
	var success = network_controller.disconnect_from_server()
	if success:
		add_message("System", "Disconnected from server. Use /connect to reconnect.", true)
	else:
		add_message("System", "Not connected to server", true)


func _on_login_successful(username):
	add_message("System", "Login successful. Welcome, " + username + "!", true)


func _on_login_failed(message):
	add_message("System", "Login failed: " + message, true)


func _on_register_successful(username):
	add_message("System", "Registration successful! You can now log in with /login "
			+ username + " <your-password>", true)


func _on_register_failed(message):
	add_message("System", "Registration failed: " + message, true)


func play_zim_media(archive_path: String, range_info: Dictionary, title: String,
		cues = null) -> void:
	if vr_panel == null or range_info.is_empty():
		add_message("System", "That item cannot be played in place.", true)
		return
	vr_panel.video.open_range(archive_path, int(range_info.offset), int(range_info.size),
			title, cues)
	add_message("System", "Playing %s from inside %s" % [title, archive_path.get_file()], true)


## /window new | close | tidy | snap on/off; anything else lists the windows.
func _window(parts: PackedStringArray) -> void:
	if vr_panel == null:
		add_message("System", "No panel.", true)
		return
	var what := String(parts[1]).to_lower() if parts.size() > 1 else "list"
	match what:
		"new":
			if vr_panel.spawn_window() != null:
				add_message("System",
						"Opened a window beside this one. Squeeze grip to move it.", true)
		"close":
			vr_panel.close_window()
		"snap":
			var on := true if parts.size() < 3 \
					else String(parts[2]).to_lower() in ["on", "true", "1"]
			vr_panel.set_snap(on)
			if vr_panel.shell:
				vr_panel.shell.set_snap(on)
			add_message("System", "Windows %s when you let go of them." % (
				"snap to the ring" if on else "stay where you put them"), true)
		"tidy":
			for w in vr_panel.all_windows():
				w.snap_to_ring()
			add_message("System", "Lined them up.", true)
		_:
			var all: Array = vr_panel.all_windows()
			add_message("System", "%d window%s open (limit %d)." % [all.size(),
				"" if all.size() == 1 else "s", vr_panel.MAX_WINDOWS], true)
			add_message("System", "/window new | close | tidy | snap on/off", true)


func _browse(parts: PackedStringArray) -> void:
	if vr_panel == null:
		add_message("System", "No panel.", true)
		return
	if parts.size() < 2:
		vr_panel.open_browser("")
		return
	var target := " ".join(Array(parts).slice(1))
	if target.get_extension().to_lower() == "zim":
		vr_panel.open_archive_in_browser(target)
	else:
		vr_panel.open_browser(target)


func _list_drives() -> void:
	var drives := get_node_or_null(^"/root/Drives")
	var found: Array = drives.drives() if drives else []
	if found.is_empty():
		add_message("System", "No drives mounted.", true)
	for d in found:
		add_message("System", "%s   %s" % [d.name, d.root], true)
	# A list can be non-empty and still miss the drive that was plugged in.
	if drives and drives.has_method("diagnosis"):
		var why: String = drives.diagnosis()
		if not why.is_empty():
			add_message("System", why, true)


## Moves the local player, or their ship, 1000 units above a planet of the in-world galaxy.
func _travel(parts: PackedStringArray) -> void:
	var scene := get_tree().current_scene
	var galaxy = scene.find_child("GalaxyInWorld", true, false) if scene else null
	var rid := String(parts[1]) if parts.size() > 1 else ""
	if galaxy == null or galaxy.map == null or not galaxy.map.planets.has(rid):
		add_message("System", "That planet is not available in this world.", true)
		return
	var network := get_node_or_null("/root/NetworkController")
	var body = network.get_indexed("players:local_player") if network else null
	if not is_instance_valid(body):
		add_message("System", "No local player to move.", true)
		return
	if body.get("_in_vehicle") == true or is_instance_valid(body.get("key_holder")):
		add_message("System",
				"Leave the vehicle or close the floor selector before travelling.", true)
		return
	var aboard = body.get("ship")
	var ship = aboard.boarded if aboard != null else null
	var mover: Node3D = ship if is_instance_valid(ship) else body
	galaxy.ensure_streamed(rid)
	var target: Vector3 = galaxy.to_global(galaxy.planet_local_position(rid) + Vector3(0, 1000, 0))
	var walker = mover.get("planet")
	if walker != null:
		walker.set_planet(null, "space")
	mover.global_position = target
	if "velocity" in mover:
		mover.velocity = Vector3.ZERO
	if walker != null:
		walker.update_nearest()
	add_message("System", "Travelled to " + rid, true)
