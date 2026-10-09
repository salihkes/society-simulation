extends Node3D
## Workspace scene root: wires the chat window to the NetworkController.

var network_controller
@onready var chat_ui = $UI/ChatUI


func _ready():
	network_controller = get_node("/root/NetworkController")
	chat_ui.message_sent.connect(_on_chat_message_sent)
	network_controller.chat_message_received.connect(_on_chat_message_received)
	network_controller.system_message_received.connect(_on_system_message_received)

	chat_ui.add_message("System", "Welcome to the multiplayer chat! Press T to start typing.", true)

	var auth_manager = get_node_or_null("/root/AuthManager")
	if auth_manager:
		auth_manager.login_successful.connect(_on_login_successful)
	else:
		await get_tree().process_frame
		auth_manager = get_node("/root/AuthManager")
		if auth_manager:
			auth_manager.login_successful.connect(_on_login_successful)

	network_controller.texture_info_received.connect(_on_texture_info_received)


## Sends a chat line and shows it above the local player.
func _on_chat_message_sent(message):
	print("Sending chat message to server: ", message)
	network_controller.chat.send(message)

	var local_player = network_controller.players.local_player
	if is_instance_valid(local_player):
		local_player.show_chat_bubble(message)


func _on_chat_message_received(username, message):
	chat_ui.add_message(username, message)


## Shows a system line; on a rename, reapplies that player's texture twice.
func _on_system_message_received(message):
	chat_ui.add_message("System", message, true)

	if not message.contains(" is now known as "):
		return
	var parts = message.split(" is now known as ")
	if parts.size() != 2:
		return
	var new_username = parts[1]
	var texture_manager = get_node_or_null("/root/TextureManager")
	if texture_manager:
		await get_tree().create_timer(0.2).timeout
		texture_manager.apply_texture_by_username(new_username)
		await get_tree().create_timer(1.0).timeout
		texture_manager.apply_texture_by_username(new_username)


func _on_login_successful(_username):
	network_controller.chat.send("Hello everyone, I just logged in!")


## The network players object applies the texture itself; this only says so.
func _on_texture_info_received(_texture_name):
	chat_ui.add_message("System", "Applying your custom texture...", true)
