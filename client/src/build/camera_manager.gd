extends Node
## Switches the Studio view between the player's camera and the FreeCamera (F).

enum CameraMode {
	PLAYER,
	FREE
}

var current_mode: CameraMode = CameraMode.PLAYER

var player_camera: Node3D = null
var free_camera: Node3D = null
var player_character: Node3D = null

var toggle_label: Label = null

func _ready():
	await get_tree().process_frame

	var workspace = get_tree().current_scene

	player_character = _find_local_player(workspace)
	if player_character:
		player_camera = player_character.get_node_or_null("CamOrigin")

	free_camera = workspace.get_node_or_null("FreeCamera")
	toggle_label = workspace.get_node_or_null("UI/CameraToggleUI/Panel/Label")

	set_camera_mode(CameraMode.PLAYER)
	update_ui()

func _find_local_player(workspace: Node) -> Node3D:
	var all_children = _get_all_children(workspace)
	for child in all_children:
		if child.get_node_or_null("LocalPlayer") != null:
			return child

	var player = workspace.find_child("humanoid", true, false)
	if player:
		return player
	player = workspace.find_child("countryball", true, false)
	if player:
		return player

	return null

func _get_all_children(node: Node) -> Array:
	var children = []
	for child in node.get_children():
		children.append(child)
		children.append_array(_get_all_children(child))
	return children

## Find the player again when the reference is lost (login replaces it).
func _process(_delta):
	if not is_instance_valid(player_character):
		var workspace = get_tree().current_scene
		player_character = _find_local_player(workspace)
		if player_character:
			player_camera = player_character.get_node_or_null("CamOrigin")
			if current_mode == CameraMode.PLAYER:
				set_camera_mode(CameraMode.PLAYER)

func _input(event):
	if event.is_action_pressed("ui_focus_next"):
		toggle_camera_mode()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F:
			toggle_camera_mode()

func toggle_camera_mode():
	if current_mode == CameraMode.PLAYER:
		set_camera_mode(CameraMode.FREE)
	else:
		set_camera_mode(CameraMode.PLAYER)

func _player_view_camera():
	var cam_origin = player_character.get_node_or_null("CamOrigin")
	if cam_origin:
		return cam_origin.get_node_or_null("CamLook/Camera3D")
	return null

func set_camera_mode(mode: CameraMode):
	current_mode = mode

	match mode:
		CameraMode.PLAYER:
			_enter_player_mode()
		CameraMode.FREE:
			_enter_free_mode()

	update_ui()

func _enter_player_mode():
	if free_camera and free_camera.has_method("deactivate"):
		free_camera.deactivate()

	if player_character:
		var cam = _player_view_camera()
		if cam:
			cam.current = true
		player_character.set_physics_process(true)
		if player_character.has_method("set_input_enabled"):
			player_character.set_input_enabled(true)

	print("Switched to Player Camera")

func _enter_free_mode():
	if player_character:
		var cam = _player_view_camera()
		if cam:
			cam.current = false
		player_character.set_physics_process(false)
		if player_character.has_method("set_input_enabled"):
			player_character.set_input_enabled(false)

	if free_camera and free_camera.has_method("activate"):
		if player_character:
			_place_free_camera_at_player()
		free_camera.activate()

	print("Switched to Free Camera")

func _place_free_camera_at_player():
	var cam_origin = player_character.get_node_or_null("CamOrigin")
	if not cam_origin:
		return
	var cam_look = cam_origin.get_node_or_null("CamLook")
	var player_cam = cam_look.get_node_or_null("Camera3D") if cam_look else null
	if player_cam:
		free_camera.global_position = player_cam.global_position
		free_camera.global_rotation = Vector3(cam_look.global_rotation.x, player_character.rotation.y, 0)

func update_ui():
	if toggle_label:
		match current_mode:
			CameraMode.PLAYER:
				toggle_label.text = "Camera: Player (F to toggle)"
			CameraMode.FREE:
				toggle_label.text = "Camera: Free (F to toggle)"

func get_active_camera() -> Camera3D:
	match current_mode:
		CameraMode.PLAYER:
			if player_character:
				return _player_view_camera()
		CameraMode.FREE:
			if free_camera:
				return free_camera.get_node_or_null("Camera3D")
	return null

func is_free_camera_active() -> bool:
	return current_mode == CameraMode.FREE
