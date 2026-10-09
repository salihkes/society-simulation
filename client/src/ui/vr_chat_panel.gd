class_name VRChatPanel
extends "res://src/ui/vr_panel.gd"
## The chat window in VR; the primary panel keeps the controller's ChatUI alive across character swaps.

func _ready() -> void:
	if is_primary:
		return # The primary ChatUI attaches itself.
	var ui: Control = load(CHAT_UI_SCENE).instantiate()
	ui.vr_panel = self
	add_child(ui)
	ui.message_sent.connect(func(text):
		if is_instance_valid(primary) and is_instance_valid(primary.chat_ui):
			primary.chat_ui.message_sent.emit(text))
	attach_chat(ui)


func attach_chat(ui: Control) -> void:
	add_to_group("vr_chat_panel")
	ui.vr_panel = self
	super.attach_chat(ui)


func _in_headset() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized() and get_viewport().use_xr


## Remote characters have rigs too.
func _find_local_xr_camera() -> Camera3D:
	for body in get_tree().root.find_children("*", "CharacterBody3D", true, false):
		if not (body.get("is_remote_player") == false and body.get("is_vr_mode") == true):
			continue
		var origin = body.find_child("XROrigin3D", true, false)
		if not origin:
			continue
		var found = origin.find_child("XRCamera3D", true, false)
		if found:
			return found
	var cam := get_viewport().get_camera_3d()
	return cam if cam is XRCamera3D else null


## VRInteractions polls the menu button instead, so lift UI can close first.
func _poll_menu_button() -> void:
	pass


func set_panel_visible(value: bool, show_keyboard: bool = true) -> void:
	if not value and pointer != null:
		pointer.cancel_press()
	super.set_panel_visible(value, show_keyboard)


func _drop_input_focus() -> void:
	if sub_viewport != null:
		var focused := sub_viewport.gui_get_focus_owner()
		if focused != null:
			focused.release_focus()
	super._drop_input_focus()


func _exit_tree() -> void:
	video.close()
	close_browser()
	if is_primary:
		for window in windows:
			if is_instance_valid(window) and not window.is_queued_for_deletion():
				window.queue_free()
