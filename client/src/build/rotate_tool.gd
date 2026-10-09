extends Control
## Rotate tool panel: keys or fields turn the selection about the pivot mode's axes.

@onready var global_btn = $Global
@onready var local_btn = $Local
@onready var last_btn = $Last
@onready var increment_input = $IncrementLen
@onready var rotation_x_input = $RotationX
@onready var rotation_y_input = $RotationY
@onready var rotation_z_input = $RotationZ

const ROTATE_KEYS := {
	KEY_Q: [Vector3.RIGHT, -1.0],
	KEY_E: [Vector3.RIGHT, 1.0],
	KEY_R: [Vector3.UP, 1.0],
	KEY_F: [Vector3.UP, -1.0],
	KEY_T: [Vector3.FORWARD, 1.0],
	KEY_G: [Vector3.FORWARD, -1.0],
}

var selection_manager: Node = null
var selected_objects: Array[Node3D] = []
var selected_object: Node3D = null
var increment_degrees: float = 15.0

enum PivotMode {
	GLOBAL,
	LOCAL,
	LAST
}

var current_pivot_mode: PivotMode = PivotMode.GLOBAL
## Transform of the previously selected primary object, for PivotMode.LAST.
var last_object_transform: Transform3D = Transform3D.IDENTITY

func _ready():
	global_btn.pressed.connect(_on_global_pressed)
	local_btn.pressed.connect(_on_local_pressed)
	last_btn.pressed.connect(_on_last_pressed)

	increment_input.text_submitted.connect(_on_increment_changed)
	rotation_x_input.text_submitted.connect(_on_rotation_axis_changed.bind(0, rotation_x_input))
	rotation_y_input.text_submitted.connect(_on_rotation_axis_changed.bind(1, rotation_y_input))
	rotation_z_input.text_submitted.connect(_on_rotation_axis_changed.bind(2, rotation_z_input))

	increment_input.focus_exited.connect(func(): increment_input.release_focus())
	rotation_x_input.focus_exited.connect(func(): rotation_x_input.release_focus())
	rotation_y_input.focus_exited.connect(func(): rotation_y_input.release_focus())
	rotation_z_input.focus_exited.connect(func(): rotation_z_input.release_focus())

	await get_tree().process_frame
	var workspace = get_tree().current_scene
	selection_manager = workspace.get_node_or_null("SelectionManager")

	if selection_manager:
		selection_manager.objects_selected.connect(_on_objects_selected)
		selection_manager.objects_deselected.connect(_on_objects_deselected)

	global_btn.button_pressed = true

func _input(event):
	if not visible or not selected_object:
		return

	if event is InputEventKey and event.pressed and ROTATE_KEYS.has(event.keycode):
		var entry: Array = ROTATE_KEYS[event.keycode]
		rotate_object(entry[0], deg_to_rad(increment_degrees) * entry[1])
		update_rotation_display()

func _on_global_pressed():
	current_pivot_mode = PivotMode.GLOBAL
	local_btn.button_pressed = false
	last_btn.button_pressed = false
	global_btn.release_focus()
	print("Pivot mode: Global")

func _on_local_pressed():
	current_pivot_mode = PivotMode.LOCAL
	global_btn.button_pressed = false
	last_btn.button_pressed = false
	local_btn.release_focus()
	print("Pivot mode: Local")

func _on_last_pressed():
	current_pivot_mode = PivotMode.LAST
	global_btn.button_pressed = false
	local_btn.button_pressed = false
	last_btn.release_focus()
	print("Pivot mode: Last")

func _on_increment_changed(new_text: String):
	var value = new_text.to_float()
	if value > 0:
		increment_degrees = value
	else:
		increment_input.text = str(increment_degrees)
	increment_input.release_focus()

func _on_rotation_axis_changed(new_text: String, axis: int, input: LineEdit):
	if not selected_object:
		input.release_focus()
		return
	set_object_rotation_axis(axis, deg_to_rad(new_text.to_float()))
	input.release_focus()

func _on_objects_selected(objects: Array):
	if selected_object:
		last_object_transform = selected_object.global_transform

	selected_objects = objects.duplicate()
	selected_object = objects[0] if objects.size() > 0 else null
	update_rotation_display()

func _on_objects_deselected():
	if selected_object:
		last_object_transform = selected_object.global_transform

	selected_objects.clear()
	selected_object = null
	clear_rotation_display()

func update_rotation_display():
	if not selected_object:
		return

	var rot = selected_object.rotation_degrees
	rotation_x_input.text = "%.2f" % rot.x
	rotation_y_input.text = "%.2f" % rot.y
	rotation_z_input.text = "%.2f" % rot.z

func clear_rotation_display():
	rotation_x_input.text = ""
	rotation_y_input.text = ""
	rotation_z_input.text = ""

func rotate_object(axis: Vector3, angle_radians: float):
	if selected_objects.size() == 0:
		return

	for obj in selected_objects:
		if not is_instance_valid(obj):
			continue

		var before: Transform3D = obj.global_transform
		match current_pivot_mode:
			PivotMode.GLOBAL:
				var current_transform = obj.global_transform
				var rotation = Basis(axis, angle_radians)
				obj.global_transform.basis = rotation * current_transform.basis

			PivotMode.LOCAL:
				obj.rotate(axis, angle_radians)

			PivotMode.LAST:
				var last_axis = last_object_transform.basis * axis
				last_axis = last_axis.normalized()
				var current_transform = obj.global_transform
				var rotation = Basis(last_axis, angle_radians)
				obj.global_transform.basis = rotation * current_transform.basis
		obj.global_transform = BuildPlots.constrain(get_tree().current_scene, obj, obj.global_transform, before)

	update_rotation_display()

func set_object_rotation_axis(axis: int, value_radians: float):
	if not selected_object:
		return

	var rot = selected_object.rotation
	var delta = value_radians - rot[axis]

	for obj in selected_objects:
		if is_instance_valid(obj):
			var before: Transform3D = obj.global_transform
			var obj_rot = obj.rotation
			obj_rot[axis] += delta
			obj.rotation = obj_rot
			obj.global_transform = BuildPlots.constrain(get_tree().current_scene, obj, obj.global_transform, before)

	update_rotation_display()
