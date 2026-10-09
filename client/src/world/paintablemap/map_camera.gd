class_name MapCamera
extends Camera2D
## Pan/zoom camera for the province map.

@export var zoom_factor: float = 0.1
@export var min_zoom: float = 0.2
@export var max_zoom: float = 10.0

var _dragging: bool = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_towards_mouse(zoom_factor)
			get_viewport().set_input_as_handled()

		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_towards_mouse(-zoom_factor)
			get_viewport().set_input_as_handled()

		elif mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed

	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		position -= motion.relative / zoom
		get_viewport().set_input_as_handled()


## Zooms by factor, keeping the world point under the cursor in place.
func _zoom_towards_mouse(factor: float) -> void:
	var mouse_world_before := get_global_mouse_position()

	var new_val := clampf(zoom.x * (1.0 + factor), min_zoom, max_zoom)
	zoom = Vector2(new_val, new_val)

	var mouse_world_after := get_global_mouse_position()
	position += mouse_world_before - mouse_world_after
