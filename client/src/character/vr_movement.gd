extends MovementBase
class_name VRMovement
## VR input module: sticks move and snap-turn, A/X jumps, and the body follows the headset.

signal vr_mode_changed(is_active: bool)

## Distance range multiplier for talking to the NPC in VR.
const NPC_RANGE_SCALE := 30.0

@export var snap_turn_degrees := 30.0
@export var stick_deadzone := 0.25

var xr_origin: XROrigin3D
var xr_camera: XRCamera3D
var left_hand: XRController3D
var right_hand: XRController3D
var movement_input := Vector2.ZERO
var rotation_input := 0.0
## The model's front faces +Z, so it is turned half round (per character type).
var mesh_forward_is_backward := true
var is_vr_active := false
var jump_just_pressed := false
## The first press also connects to the servers.
var first_button_pressed := false
var current_npc: Node = null
var npc_in_range = false

var _snap_armed := true
var _prev_right_ax := false


func setup(char: CharacterBody3D, model: Node3D) -> void:
	super.setup(char, model)
	xr_origin = character.find_child("XROrigin3D")
	xr_camera = xr_origin.find_child("XRCamera3D") if xr_origin else null
	var mesh_backward = character.get("mesh_forward_is_backward")
	mesh_forward_is_backward = mesh_backward if mesh_backward != null else true
	walk_speed = 3.5
	run_speed = 8.0
	jump_velocity = 9.0
	_connect_vr_controllers()
	_find_npc()


func _connect_vr_controllers() -> void:
	if not xr_origin:
		return
	left_hand = xr_origin.find_child("LeftHand")
	right_hand = xr_origin.find_child("RightHand")
	if left_hand:
		_connect_hand(left_hand, _on_left_hand_button_pressed, _on_left_hand_button_released,
				_on_left_hand_input_vector_2_changed)
		print("Connected left hand controller")
	if right_hand:
		_connect_hand(right_hand, _on_right_hand_button_pressed, _on_right_hand_button_released,
				_on_right_hand_input_vector_2_changed)
		print("Connected right hand controller")


func _connect_hand(hand: XRController3D, pressed: Callable, released: Callable,
		vector_changed: Callable) -> void:
	if not hand.button_pressed.is_connected(pressed):
		hand.button_pressed.connect(pressed)
	if not hand.button_released.is_connected(released):
		hand.button_released.connect(released)
	if not hand.input_vector2_changed.is_connected(vector_changed):
		hand.input_vector2_changed.connect(vector_changed)


func _handle_first_button_press() -> void:
	if first_button_pressed or not is_vr_active:
		return
	first_button_pressed = true
	if not character:
		return
	var network_controller = character.get_tree().root.get_node_or_null("/root/NetworkController")
	if network_controller and network_controller.has_method("connect_to_server"):
		network_controller.connect_to_server()
	var workspace = character.get_tree().root.find_child("workspace", true, false)
	if workspace:
		var mic_sender = workspace.find_child("MicrophoneSender", true, false)
		if mic_sender and mic_sender.has_method("connect_to_voice_server"):
			mic_sender.connect_to_voice_server()


func update_input(_delta: float) -> void:
	if not is_vr_active:
		movement_direction = Vector3.ZERO
		is_running = false
		is_jumping = false
		jump_just_pressed = false
		rotation_input = 0.0
		return
	_poll_controllers()
	if character.has_method("_typing") and character._typing():
		movement_direction = Vector3.ZERO
		is_jumping = false
		jump_just_pressed = false
		return
	is_jumping = jump_just_pressed
	jump_just_pressed = false
	_snap_turn()
	if movement_input != Vector2.ZERO:
		movement_direction = _get_vr_movement_direction(movement_input)
	else:
		movement_direction = Vector3.ZERO
	_sync_body_to_camera()
	_update_vr_character_rotation()
	_update_npc_interaction()


## Polling is authoritative because the controller signals are unreliable on device.
func _poll_controllers() -> void:
	if left_hand:
		var tracked := left_hand.get_has_tracking_data()
		movement_input = left_hand.get_vector2("primary") if tracked else Vector2.ZERO
		if movement_input.length() < stick_deadzone:
			movement_input = Vector2.ZERO
		is_running = tracked and (left_hand.get_float("grip") > 0.7
				or left_hand.get_float("trigger") > 0.7)
	if right_hand:
		var tracked := right_hand.get_has_tracking_data()
		rotation_input = right_hand.get_vector2("primary").x if tracked else 0.0
		var ax := tracked and right_hand.is_button_pressed("ax_button")
		if ax and not _prev_right_ax:
			jump_just_pressed = true
			_handle_first_button_press()
		_prev_right_ax = ax


## Moves the XR origin back by the same amount, so the camera stays put.
func _sync_body_to_camera() -> void:
	if not xr_camera or not xr_origin:
		return
	var up: Vector3 = -gravity_direction if (planet_node and gravity_direction.length() > 0.01) else Vector3.UP
	var offset: Vector3 = xr_camera.global_position - character.global_position
	offset = offset - offset.project(up)
	if offset.length() < 0.01:
		return
	var before: Vector3 = character.global_position
	character.move_and_collide(offset)
	var moved: Vector3 = character.global_position - before
	xr_origin.global_position -= moved


## In the ground plane, relative to where the headset looks.
func _get_vr_movement_direction(input_dir: Vector2) -> Vector3:
	if not xr_camera:
		return Vector3.ZERO
	var up: Vector3 = -gravity_direction if planet_node else Vector3.UP
	var aim := xr_camera.global_transform.basis
	# OpenXR stick +Y is forward.
	var wish := aim.x * input_dir.x - aim.z * input_dir.y
	wish = wish - up * wish.dot(up)
	return wish.normalized() if wish.length_squared() > 0.0 else Vector3.ZERO


func _update_vr_character_rotation() -> void:
	if not xr_camera:
		return
	var camera_forward = -xr_camera.get_global_transform().basis.z
	if planet_node:
		var up = -gravity_direction
		camera_forward = camera_forward - camera_forward.project(up)
	else:
		camera_forward.y = 0
	if camera_forward.length() > 0.1:
		var flip := PI if mesh_forward_is_backward else 0.0
		character_model.rotation.y = atan2(camera_forward.x, camera_forward.z) + flip


func _toggle_chat_panel() -> void:
	var chat_ui = character.get_tree().root.find_child("ChatUI", true, false)
	if chat_ui and chat_ui.has_method("vr_toggle_panel"):
		chat_ui.vr_toggle_panel()


func _find_npc() -> void:
	current_npc = character.get_node_or_null("/root/workspace/NPC2/Skeleton3D")
	if current_npc:
		print("VR: Found NPC for interaction: " + current_npc.name)


func _update_npc_interaction() -> void:
	if not current_npc or not current_npc.get_parent():
		return
	var distance = current_npc.get_parent().global_position.distance_to(character.global_position)
	var interaction_distance = current_npc.get("interaction_distance")
	var base_range = interaction_distance if interaction_distance != null else 5.0
	npc_in_range = distance < base_range * NPC_RANGE_SCALE


func set_vr_active(active: bool) -> void:
	is_vr_active = active
	if xr_origin:
		xr_origin.visible = active
		xr_origin.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	vr_mode_changed.emit(active)
	print("VR movement " + ("enabled" if active else "disabled"))


func is_movement_active() -> bool:
	return movement_direction.length() > 0.1 and is_vr_active


func _on_left_hand_input_vector_2_changed(name: String, value: Vector2) -> void:
	if name == "primary":
		movement_input = value


func _on_right_hand_input_vector_2_changed(name: String, value: Vector2) -> void:
	if name == "primary":
		rotation_input = value.x


## X and Y are polled by VRInteractions; the left trigger talks to the NPC.
func _on_left_hand_button_pressed(name: String) -> void:
	_handle_first_button_press()
	if name == "trigger_click":
		_handle_npc_interaction_start()


func _on_left_hand_button_released(name: String) -> void:
	if name == "trigger_click":
		_handle_npc_interaction_stop()


## A jumps; the right trigger replays the NPC unless it is clicking the VR UI.
func _on_right_hand_button_pressed(name: String) -> void:
	_handle_first_button_press()
	if name == "ax_button":
		jump_just_pressed = true
	elif name == "trigger_click":
		if not _ui_pointer_busy():
			_handle_npc_audio_playback()


func _on_right_hand_button_released(_name: String) -> void:
	pass


## A held key or a hovered chat panel.
func _ui_pointer_busy() -> bool:
	if is_instance_valid(character.get("key_holder")):
		return true
	var chat_ui = character.get_tree().root.find_child("ChatUI", true, false)
	if chat_ui == null:
		return false
	var panel = chat_ui.get("vr_panel")
	if panel == null or not panel.get("panel_visible"):
		return false
	var ptr = panel.get("pointer")
	return ptr != null and ptr.has_method("is_hovering") and ptr.is_hovering()


func _handle_npc_interaction_start() -> void:
	if not npc_in_range or not current_npc:
		return
	print("VR: Starting NPC interaction")
	if not current_npc.has_method("vr_start_recording"):
		return
	var is_speaking = current_npc.get("is_speaking")
	var is_recording = current_npc.get("is_recording")
	if is_speaking == null:
		is_speaking = false
	if is_recording == null:
		is_recording = false
	if not is_speaking and not is_recording:
		current_npc.vr_start_recording()


func _handle_npc_interaction_stop() -> void:
	if not npc_in_range or not current_npc:
		return
	print("VR: Stopping NPC interaction")
	if current_npc.has_method("vr_stop_recording"):
		var is_recording = current_npc.get("is_recording")
		if is_recording if is_recording != null else false:
			current_npc.vr_stop_recording()


func _handle_npc_audio_playback() -> void:
	if not npc_in_range or not current_npc:
		return
	print("VR: Playing last NPC response")
	if current_npc.has_method("play_last_audio"):
		current_npc.play_last_audio()


func cleanup() -> void:
	movement_input = Vector2.ZERO
	rotation_input = 0.0
	_snap_armed = true
	is_running = false
	is_jumping = false


## About the tracked head; scrolling a VR panel disarms it until the stick re-centres.
func _snap_turn() -> void:
	for panel in character.get_tree().get_nodes_in_group("vr_chat_panel"):
		if panel.pointer != null and panel.pointer.is_scrolling():
			_snap_armed = false
			return
	var x: float = rotation_input
	if absf(x) < 0.6:
		_snap_armed = true
		return
	if not _snap_armed or xr_origin == null:
		return
	_snap_armed = false
	var cam_before := xr_camera.global_position if xr_camera else Vector3.ZERO
	xr_origin.rotate_y(-signf(x) * deg_to_rad(snap_turn_degrees))
	if xr_camera:
		xr_origin.global_position += cam_before - xr_camera.global_position
