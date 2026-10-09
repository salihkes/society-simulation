extends Node3D

## Studio fly camera, driven by CameraManager through activate()/deactivate().

@export var movement_speed := 20.0
@export var sprint_multiplier := 2.0
@export var mouse_sensitivity := 0.003
@export var rotation_smoothing := 15.0
@export var zoom_speed_multiplier := 1.2

var camera: Camera3D

var target_rotation := Vector2.ZERO
var current_rotation := Vector2.ZERO
var is_rotating := false
var velocity := Vector3.ZERO

func _ready():
	camera = $Camera3D

	target_rotation.x = rotation.y
	target_rotation.y = rotation.x
	current_rotation = target_rotation

	set_process(false)
	set_process_unhandled_input(false)

func _unhandled_input(event):
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		if is_rotating:
			target_rotation.x -= event.relative.x * mouse_sensitivity
			target_rotation.y -= event.relative.y * mouse_sensitivity
			target_rotation.y = clamp(target_rotation.y, -PI/2, PI/2)
			get_viewport().set_input_as_handled()

func _on_mouse_button(event: InputEventMouseButton):
	match event.button_index:
		MOUSE_BUTTON_RIGHT:
			is_rotating = event.pressed
			if is_rotating:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			get_viewport().set_input_as_handled()

		MOUSE_BUTTON_WHEEL_UP:
			movement_speed *= zoom_speed_multiplier
			movement_speed = min(movement_speed, 200.0)
			get_viewport().set_input_as_handled()

		MOUSE_BUTTON_WHEEL_DOWN:
			movement_speed /= zoom_speed_multiplier
			movement_speed = max(movement_speed, 1.0)
			get_viewport().set_input_as_handled()

func _process(delta):
	current_rotation = current_rotation.lerp(target_rotation, delta * rotation_smoothing)
	rotation.y = current_rotation.x
	rotation.x = current_rotation.y

	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir -= transform.basis.z
	if Input.is_key_pressed(KEY_S):
		input_dir += transform.basis.z
	if Input.is_key_pressed(KEY_A):
		input_dir -= transform.basis.x
	if Input.is_key_pressed(KEY_D):
		input_dir += transform.basis.x

	if Input.is_key_pressed(KEY_E):
		input_dir.y += 1.0
	if Input.is_key_pressed(KEY_Q):
		input_dir.y -= 1.0

	if input_dir.length() > 0:
		input_dir = input_dir.normalized()

	var current_speed = movement_speed
	if Input.is_key_pressed(KEY_SHIFT):
		current_speed *= sprint_multiplier

	velocity = input_dir * current_speed
	global_position += velocity * delta

func activate():
	set_process(true)
	set_process_unhandled_input(true)
	camera.current = true
	is_rotating = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func deactivate():
	set_process(false)
	set_process_unhandled_input(false)
	camera.current = false
	is_rotating = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

