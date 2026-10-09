extends Control

## Resize tool panel: grows or shrinks the selection's scale, keeping the opposite face.

@onready var single_direction_btn = $SingleDirection
@onready var both_directions_btn = $BothDirections
@onready var increment_input = $IncrementLen
@onready var size_x_input = $SizeX
@onready var size_y_input = $SizeY
@onready var size_z_input = $SizeZ

const MIN_SCALE := 0.05

const RESIZE_KEYS := {
	KEY_LEFT: [0, -1],
	KEY_RIGHT: [0, 1],
	KEY_UP: [2, 1],
	KEY_DOWN: [2, -1],
	KEY_PAGEUP: [1, 1],
	KEY_PAGEDOWN: [1, -1],
}

var selection_manager: Node = null
var selected_objects: Array[Node3D] = []
var selected_object: Node3D = null
var resize_both_directions: bool = false
var increment_length: float = 0.1

func _ready():
	single_direction_btn.pressed.connect(_on_single_direction_pressed)
	both_directions_btn.pressed.connect(_on_both_directions_pressed)

	increment_input.text_submitted.connect(_on_increment_changed)
	size_x_input.text_submitted.connect(_on_size_axis_changed.bind(0, size_x_input))
	size_y_input.text_submitted.connect(_on_size_axis_changed.bind(1, size_y_input))
	size_z_input.text_submitted.connect(_on_size_axis_changed.bind(2, size_z_input))

	increment_input.focus_exited.connect(func(): increment_input.release_focus())
	size_x_input.focus_exited.connect(func(): size_x_input.release_focus())
	size_y_input.focus_exited.connect(func(): size_y_input.release_focus())
	size_z_input.focus_exited.connect(func(): size_z_input.release_focus())

	await get_tree().process_frame
	var workspace = get_tree().current_scene
	selection_manager = workspace.get_node_or_null("SelectionManager")

	if selection_manager:
		selection_manager.objects_selected.connect(_on_objects_selected)
		selection_manager.objects_deselected.connect(_on_objects_deselected)

	single_direction_btn.button_pressed = true

func _input(event):
	if not visible or not selected_object:
		return

	if event is InputEventKey and event.pressed and RESIZE_KEYS.has(event.keycode):
		var entry: Array = RESIZE_KEYS[event.keycode]
		resize_object_on_axis(entry[0], entry[1] * increment_length)
		update_size_display()

func _on_single_direction_pressed():
	resize_both_directions = false
	both_directions_btn.button_pressed = false
	single_direction_btn.release_focus()

func _on_both_directions_pressed():
	resize_both_directions = true
	single_direction_btn.button_pressed = false
	both_directions_btn.release_focus()

func _on_increment_changed(new_text: String):
	var value = new_text.to_float()
	if value > 0:
		increment_length = value
	else:
		increment_input.text = str(increment_length)
	increment_input.release_focus()

func _on_size_axis_changed(new_text: String, axis: int, input: LineEdit):
	if not selected_object:
		input.release_focus()
		return
	var value = new_text.to_float()
	if value > 0:
		set_object_size_axis(axis, value)
	input.release_focus()

func _on_objects_selected(objects: Array):
	selected_objects = objects.duplicate()
	selected_object = objects[0] if objects.size() > 0 else null
	update_size_display()

func _on_objects_deselected():
	selected_objects.clear()
	selected_object = null
	clear_size_display()

func update_size_display():
	if not selected_object:
		return

	var size = get_object_size(selected_object)
	size_x_input.text = "%.2f" % size.x
	size_y_input.text = "%.2f" % size.y
	size_z_input.text = "%.2f" % size.z

func clear_size_display():
	size_x_input.text = ""
	size_y_input.text = ""
	size_z_input.text = ""

## A "Brick" MeshInstance3D child's scale for brick scenes, else the object's own.
func get_object_size(obj: Node3D) -> Vector3:
	if _uses_brick_child(obj):
		return obj.get_node("Brick").scale
	return obj.scale

func set_object_size(obj: Node3D, new_size: Vector3):
	if _uses_brick_child(obj):
		obj.get_node("Brick").scale = new_size
	else:
		obj.scale = new_size

func _uses_brick_child(obj: Node3D) -> bool:
	if obj is MeshInstance3D or obj is CSGShape3D:
		return false
	return obj.has_node("Brick") and obj.get_node("Brick") is MeshInstance3D

func set_object_size_axis(axis: int, value: float):
	if not selected_object:
		return

	var current_size = get_object_size(selected_object)
	var scale_factor = value / current_size[axis] if current_size[axis] != 0 else 1.0

	for obj in selected_objects:
		if is_instance_valid(obj):
			var before: Transform3D = obj.global_transform
			var obj_size = get_object_size(obj)
			obj_size[axis] *= scale_factor
			set_object_size(obj, obj_size)
			obj.global_transform = BuildPlots.constrain(get_tree().current_scene, obj, obj.global_transform, before)

	update_size_display()

func resize_object_on_axis(axis: int, amount: float):
	if selected_objects.size() == 0:
		return

	for obj in selected_objects:
		if not is_instance_valid(obj):
			continue

		var start_xform = obj.global_transform
		var aabb = _get_object_aabb(obj)
		var before: Transform3D = start_xform

		# Pivot: the centre in both-directions mode, else the face opposite the growth.
		var grow_dir = 1.0 if amount >= 0.0 else -1.0
		var anchor_local = aabb.get_center()
		if not resize_both_directions:
			anchor_local[axis] = aabb.get_center()[axis] - grow_dir * (aabb.size[axis] / 2.0)
		var anchor_world = start_xform * anchor_local

		var new_scale = obj.scale
		var delta = amount * 2.0 if resize_both_directions else amount
		new_scale[axis] = max(MIN_SCALE, new_scale[axis] + delta)
		obj.scale = new_scale

		obj.global_position += anchor_world - obj.global_transform * anchor_local

		obj.global_transform = BuildPlots.constrain(get_tree().current_scene, obj, obj.global_transform, before)

		if selection_manager and selection_manager.has_method("_refresh_brick_uv"):
			selection_manager._refresh_brick_uv(obj)

	update_size_display()

func _get_object_aabb(obj: Node3D) -> AABB:
	if selection_manager and selection_manager.has_method("get_object_aabb"):
		return selection_manager.get_object_aabb(obj)
	if obj is MeshInstance3D:
		return obj.get_aabb()
	for child in obj.get_children():
		if child is MeshInstance3D:
			return child.get_aabb()
	return AABB(Vector3.ZERO, Vector3.ONE)
