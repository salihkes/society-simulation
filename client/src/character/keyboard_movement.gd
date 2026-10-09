extends MovementBase
class_name KeyboardMovement
## Keyboard walking, sprint and jump, turning the model toward the motion or camera.

var _input_enabled := true
var target_rotation := 0.0
var rotation_speed := 5.0
var mesh_forward_is_backward := true

func setup(char: CharacterBody3D, model: Node3D) -> void:
	super.setup(char, model)
	if character.get("walk_speed") != null:
		walk_speed = character.walk_speed
		run_speed = character.run_speed
		jump_velocity = character.jump_velocity
		acceleration = character.acceleration
		air_control = character.air_control
		var mesh_backward = character.get("mesh_forward_is_backward")
		mesh_forward_is_backward = mesh_backward if mesh_backward != null else true

func update_input(delta: float) -> void:
	# Keys go to the chat box while it has focus, not to the legs.
	var focus = character.get_viewport().gui_get_focus_owner() if character and character.get_viewport() else null
	if not _input_enabled or focus is LineEdit or focus is TextEdit:
		_stop()
		return
	var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if input_dir != Vector2.ZERO:
		var camera = character.get_viewport().get_camera_3d()
		movement_direction = get_camera_relative_direction(input_dir, camera)
		if movement_direction.length() > 0.1:
			_calculate_target_rotation()
	else:
		movement_direction = Vector3.ZERO
	is_running = Input.is_action_pressed("ui_sprint")
	is_jumping = Input.is_action_just_pressed("jump")
	_update_character_rotation(delta)

func _mesh_offset() -> float:
	return PI if mesh_forward_is_backward else 0.0

func _calculate_target_rotation():
	if not planet_node:
		target_rotation = atan2(movement_direction.x, movement_direction.z) + _mesh_offset()
		return
	# On a planet, measure the angle in the character's own surface frame.
	var local_forward = -character.transform.basis.z
	var local_right = character.transform.basis.x
	var local_movement = Vector3(
		movement_direction.dot(local_right),
		0,
		movement_direction.dot(-local_forward)
	).normalized()
	if local_movement.length() > 0.1:
		target_rotation = atan2(local_movement.x, local_movement.z) + _mesh_offset()

func _update_character_rotation(delta: float):
	# In first person the body faces the camera so strafing does not turn it sideways.
	if _is_first_person():
		_face_camera(delta)
		return
	var has_movement = false
	if planet_node:
		var surface_velocity = character.velocity - character.velocity.project(gravity_direction)
		has_movement = surface_velocity.length() > 0.2
	else:
		has_movement = abs(character.velocity.x) > 0.2 or abs(character.velocity.z) > 0.2
	if not has_movement:
		return
	var current_rotation = character_model.rotation.y
	var rotation_diff = wrapf(target_rotation - current_rotation, -PI, PI)
	# Ignore turns under about 6 degrees so small corrections do not jitter.
	if abs(rotation_diff) <= 0.1:
		return
	var rotation_speed_adjusted = rotation_speed
	if abs(rotation_diff) < 0.5:
		rotation_speed_adjusted *= 0.5
	character_model.rotation.y = lerp_angle(current_rotation, current_rotation + rotation_diff, delta * rotation_speed_adjusted)

func _face_camera(delta: float) -> void:
	var camera = character.get_viewport().get_camera_3d()
	if not camera:
		return
	var look = -camera.global_transform.basis.z
	look.y = 0
	if look.length() <= 0.01:
		return
	look = look.normalized()
	var look_angle = atan2(look.x, look.z) + _mesh_offset()
	character_model.rotation.y = lerp_angle(character_model.rotation.y, look_angle, delta * 12.0)

## Disabling also stops movement.
func set_input_enabled(enabled: bool):
	_input_enabled = enabled
	if not enabled:
		_stop()

func _stop() -> void:
	movement_direction = Vector3.ZERO
	is_running = false
	is_jumping = false

func is_movement_active() -> bool:
	return movement_direction.length() > 0.1 and _input_enabled

func _is_first_person() -> bool:
	if character == null or character_model == null:
		return false
	var cam_origin = character.get_node_or_null("CamOrigin")
	return cam_origin != null and cam_origin.has_method("is_first_person") and cam_origin.is_first_person()
