class_name OrbitCamera
extends Camera3D
## Orbit camera around a pivot on the map.

@export var orbit_sensitivity: float = 0.3
@export var pan_sensitivity: float = 0.02
@export var zoom_speed: float = 0.1
@export var min_distance: float = 3.0
@export var max_distance: float = 60.0
@export var min_pitch: float = -89.0
@export var max_pitch: float = -10.0

var _yaw: float = 0.0
var _pitch: float = -55.0
var _distance: float = 20.0
var _target: Vector3 = Vector3.ZERO

var _orbiting: bool = false
var _panning: bool = false


func _ready() -> void:
	_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_orbiting = mb.pressed
			get_viewport().set_input_as_handled()

		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_panning = mb.pressed
			get_viewport().set_input_as_handled()

		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_distance = clampf(_distance * (1.0 - zoom_speed), min_distance, max_distance)
			_update_transform()
			get_viewport().set_input_as_handled()

		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_distance = clampf(_distance * (1.0 + zoom_speed), min_distance, max_distance)
			_update_transform()
			get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion

		if _orbiting:
			_yaw -= motion.relative.x * orbit_sensitivity
			_pitch = clampf(_pitch - motion.relative.y * orbit_sensitivity, min_pitch, max_pitch)
			_update_transform()
			get_viewport().set_input_as_handled()

		elif _panning:
			var right := Vector3(cos(deg_to_rad(_yaw)), 0, sin(deg_to_rad(_yaw)))
			var forward := Vector3(sin(deg_to_rad(_yaw)), 0, -cos(deg_to_rad(_yaw)))
			var pan_scale := _distance * pan_sensitivity
			_target -= right * motion.relative.x * pan_scale
			_target -= forward * motion.relative.y * pan_scale
			_update_transform()
			get_viewport().set_input_as_handled()


func _update_transform() -> void:
	var pitch_rad := deg_to_rad(_pitch)
	var yaw_rad := deg_to_rad(_yaw)

	var offset := Vector3(
		_distance * cos(pitch_rad) * sin(yaw_rad),
		-_distance * sin(pitch_rad),
		_distance * cos(pitch_rad) * cos(yaw_rad),
	)

	global_position = _target + offset
	look_at(_target, Vector3.UP)
