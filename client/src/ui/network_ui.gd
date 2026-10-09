extends Control
## Connect/disconnect bar of the build workspace.

@onready var connect_disconnect_button = $ColorRect/HBoxContainer/ConnectDisconnect
@onready var save_place_button = $ColorRect/HBoxContainer/SavePlace
@onready var load_place_button = $ColorRect/HBoxContainer/LoadPlace
@onready var upload_place_button = $ColorRect/HBoxContainer/UploadPlace

var _network_controller = null
var _is_connected = false


func _ready():
	_network_controller = get_node_or_null("/root/NetworkController")
	if not _network_controller:
		_network_controller = get_tree().root.find_child("NetworkController", true, false)

	connect_disconnect_button.pressed.connect(_on_connect_disconnect_pressed)
	save_place_button.pressed.connect(_on_save_place_pressed)
	load_place_button.pressed.connect(_on_load_place_pressed)
	upload_place_button.pressed.connect(_on_upload_place_pressed)

	_update_ui_state(false)


func _process(_delta):
	if _network_controller:
		var connected = _network_controller.connected
		if connected != _is_connected:
			_is_connected = connected
			_update_ui_state(_is_connected)


func _update_ui_state(connected: bool):
	connect_disconnect_button.text = "Disconnect" if connected else "Connect"
	upload_place_button.visible = connected
	save_place_button.visible = not connected
	load_place_button.visible = not connected


func _on_connect_disconnect_pressed():
	if not _release_and_check(connect_disconnect_button):
		return
	if _is_connected:
		_network_controller.disconnect_from_server()
		_show_chat_message("Disconnected from server")
	else:
		_network_controller.connect_to_server()
		_show_chat_message("Connecting to server...")


func _on_save_place_pressed():
	if not _release_and_check(save_place_button):
		return
	_network_controller.workspace.save_studio_workspace()


func _on_load_place_pressed():
	if not _release_and_check(load_place_button):
		return
	_network_controller.workspace.load_studio_workspace()


func _on_upload_place_pressed():
	if not _release_and_check(upload_place_button):
		return
	if not _is_connected:
		_show_chat_message("Cannot upload: Not connected to server")
		return
	_network_controller.workspace.upload_place()


## Drops the button's focus highlight; false when there is no controller.
func _release_and_check(button: Button) -> bool:
	button.release_focus()
	if not _network_controller:
		print("Network controller not found")
		return false
	return true


func _show_chat_message(message: String):
	var chat_ui = get_tree().root.find_child("ChatUI", true, false)
	if chat_ui and chat_ui.has_method("add_message"):
		chat_ui.add_message("System", message, true)
