extends Node3D
## Free-fly camera for the junction preview: RMB look, WASD/QE move, Shift fast, Home/F views.

var speed := 45.0

@onready var camera: Camera3D = $Camera3D


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera.rotation.y -= event.relative.x * 0.002
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * 0.002, -1.5, 1.5)
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_HOME:
			camera.position = Vector3(1, 5.5, 125)
			camera.rotation_degrees = Vector3(2.5, 0, 0)
		if event.keycode == KEY_F:
			camera.position = Vector3(-180, 230, 110)
			camera.look_at(Vector3(-55, 0, -190))


func _process(delta: float) -> void:
	var move := Vector3(
		_axis(KEY_D, KEY_A),
		_axis(KEY_E, KEY_Q),
		_axis(KEY_S, KEY_W))
	var boost := 4 if Input.is_physical_key_pressed(KEY_SHIFT) else 1
	camera.position += camera.basis * move.normalized() * speed * delta * boost


func _axis(positive: Key, negative: Key) -> float:
	return float(Input.is_physical_key_pressed(positive)) - float(Input.is_physical_key_pressed(negative))
