extends Control

## Move tool panel: moves the selection (undoably) in global, local or previous axes.

@onready var global_btn = $Global
@onready var local_btn = $Local
@onready var last_btn = $Last
@onready var increment_input = $IncrementLen
@onready var position_x_input = $PositionX
@onready var position_y_input = $PositionY
@onready var position_z_input = $PositionZ

var selection_manager: Node = null
var selected_objects: Array[Node3D] = []
var selected_object: Node3D = null
var increment_length: float = 0.1

## The SelectionManager reads it for drags too.
var floor_snap: bool = false
var floor_snap_btn: BaseButton = null
var drop_btn: Button = null

enum AxisMode {
	GLOBAL,
	LOCAL,
	LAST
}

var current_axis_mode: AxisMode = AxisMode.GLOBAL
var last_object_transform: Transform3D = Transform3D.IDENTITY

func _ready():
	global_btn.pressed.connect(_on_global_pressed)
	local_btn.pressed.connect(_on_local_pressed)
	last_btn.pressed.connect(_on_last_pressed)

	increment_input.text_submitted.connect(_on_increment_changed)
	position_x_input.text_submitted.connect(_on_position_axis_changed.bind(0, position_x_input))
	position_y_input.text_submitted.connect(_on_position_axis_changed.bind(1, position_y_input))
	position_z_input.text_submitted.connect(_on_position_axis_changed.bind(2, position_z_input))

	floor_snap_btn = get_node_or_null("FloorSnap")
	if floor_snap_btn:
		floor_snap_btn.toggled.connect(func(on: bool):
			floor_snap = on
			floor_snap_btn.release_focus()
			if on:
				drop_selected_to_floor())
	drop_btn = get_node_or_null("DropToFloor")
	if drop_btn:
		drop_btn.pressed.connect(func():
			drop_selected_to_floor()
			drop_btn.release_focus())

	increment_input.focus_exited.connect(func(): increment_input.release_focus())
	position_x_input.focus_exited.connect(func(): position_x_input.release_focus())
	position_y_input.focus_exited.connect(func(): position_y_input.release_focus())
	position_z_input.focus_exited.connect(func(): position_z_input.release_focus())

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
	if not (event is InputEventKey and event.pressed):
		return

	if event.keycode == KEY_F and not event.echo:
		var focused = get_viewport().gui_get_focus_owner()
		if not (focused is LineEdit or focused is TextEdit):
			drop_selected_to_floor()
			get_viewport().set_input_as_handled()
			return

	var move_vector = _key_move_vector(event.keycode)
	if move_vector != Vector3.ZERO:
		move_object(move_vector)
		update_position_display()

func _key_move_vector(keycode: Key) -> Vector3:
	var axes := _axes()
	var axis_x: Vector3 = axes[0]
	var axis_y: Vector3 = axes[1]
	var axis_z: Vector3 = axes[2]
	match keycode:
		KEY_LEFT:
			return -axis_x * increment_length
		KEY_RIGHT:
			return axis_x * increment_length
		KEY_UP:
			return axis_z * increment_length
		KEY_DOWN:
			return -axis_z * increment_length
		KEY_PAGEUP:
			return axis_y * increment_length
		KEY_PAGEDOWN:
			return -axis_y * increment_length
	return Vector3.ZERO

## GLOBAL uses -Z as forward; LOCAL and LAST use the basis z (+Z).
func _axes() -> Array:
	var axis_x = Vector3.RIGHT
	var axis_y = Vector3.UP
	var axis_z = Vector3.FORWARD

	match current_axis_mode:
		AxisMode.LOCAL:
			if selected_object:
				axis_x = selected_object.global_transform.basis.x.normalized()
				axis_y = selected_object.global_transform.basis.y.normalized()
				axis_z = selected_object.global_transform.basis.z.normalized()
		AxisMode.LAST:
			axis_x = last_object_transform.basis.x.normalized()
			axis_y = last_object_transform.basis.y.normalized()
			axis_z = last_object_transform.basis.z.normalized()
	return [axis_x, axis_y, axis_z]

func _on_global_pressed():
	current_axis_mode = AxisMode.GLOBAL
	local_btn.button_pressed = false
	last_btn.button_pressed = false
	global_btn.release_focus()
	print("Axis mode: Global")

func _on_local_pressed():
	current_axis_mode = AxisMode.LOCAL
	global_btn.button_pressed = false
	last_btn.button_pressed = false
	local_btn.release_focus()
	print("Axis mode: Local")

func _on_last_pressed():
	current_axis_mode = AxisMode.LAST
	global_btn.button_pressed = false
	local_btn.button_pressed = false
	last_btn.release_focus()
	print("Axis mode: Last")

func _on_increment_changed(new_text: String):
	var value = new_text.to_float()
	if value > 0:
		increment_length = value
	else:
		increment_input.text = str(increment_length)
	increment_input.release_focus()

func _on_position_axis_changed(new_text: String, axis: int, input: LineEdit):
	if not selected_object:
		input.release_focus()
		return
	set_object_position_axis(axis, new_text.to_float())
	input.release_focus()

func _on_objects_selected(objects: Array):
	if selected_object:
		last_object_transform = selected_object.global_transform

	selected_objects = objects.duplicate()
	selected_object = objects[0] if objects.size() > 0 else null
	update_position_display()

func _on_objects_deselected():
	if selected_object:
		last_object_transform = selected_object.global_transform

	selected_objects.clear()
	selected_object = null
	clear_position_display()

func update_position_display():
	if not selected_object:
		return

	var pos = selected_object.global_position
	position_x_input.text = "%.2f" % pos.x
	position_y_input.text = "%.2f" % pos.y
	position_z_input.text = "%.2f" % pos.z

func clear_position_display():
	position_x_input.text = ""
	position_y_input.text = ""
	position_z_input.text = ""

func move_object(offset: Vector3):
	if selected_objects.size() == 0:
		return

	var token = _begin_history()
	for obj in selected_objects:
		if is_instance_valid(obj):
			_move_to(obj, obj.global_position + offset, is_zero_approx(offset.y))
	_commit_history(token, "Move")
	update_position_display()

## Other selected objects move by the same amount, as one undo step.
func set_object_position_axis(axis: int, value: float):
	if not selected_object:
		return

	var pos = selected_object.global_position
	var delta = value - pos[axis]

	var token = _begin_history()
	for obj in selected_objects:
		if is_instance_valid(obj):
			var obj_pos = obj.global_position
			obj_pos[axis] += delta
			_move_to(obj, obj_pos, axis != 1)
	_commit_history(token, "Move")
	update_position_display()

## Clamped to its plot; floor-snapped only when the move was horizontal.
func _move_to(obj: Node3D, origin: Vector3, allow_floor_snap: bool):
	var root = get_tree().current_scene
	var allowed: Transform3D = BuildPlots.constrain(root, obj, Transform3D(obj.global_transform.basis, origin), obj.global_transform)
	if allow_floor_snap and floor_snap:
		var dropped: Transform3D = BuildPlots.drop_to_floor(root, obj, allowed)
		allowed = BuildPlots.constrain(root, obj, dropped, allowed)
	obj.global_transform = allowed

func drop_selected_to_floor():
	if selected_objects.is_empty():
		return
	var root = get_tree().current_scene
	var token = _begin_history()
	var moved := 0
	for obj in selected_objects:
		if not is_instance_valid(obj):
			continue
		var dropped: Transform3D = BuildPlots.drop_to_floor(root, obj, obj.global_transform)
		var allowed: Transform3D = BuildPlots.constrain(root, obj, dropped, obj.global_transform)
		if not allowed.is_equal_approx(obj.global_transform):
			obj.global_transform = allowed
			moved += 1
	_commit_history(token, "Drop to floor")
	if moved > 0 and selection_manager and selection_manager.has_method("update_selection_markers"):
		selection_manager.update_selection_markers()
	update_position_display()

func _begin_history():
	if selection_manager and selection_manager.has_method("get_history"):
		var history = selection_manager.get_history()
		if history:
			return history.begin_transform(selected_objects)
	return null

func _commit_history(token, action: String):
	if token == null or selection_manager == null:
		return
	var history = selection_manager.get_history()
	if history:
		history.commit_transform(token, action)
