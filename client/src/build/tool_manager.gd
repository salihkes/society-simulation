extends Node
## Switches between the build tools and owns the shared BuildHistory.

signal tool_changed(tool_type: ToolType)

enum ToolType {
	NONE,
	MOVE,
	RESIZE,
	ROTATE,
	MATERIAL,
	NEW_PART,
	COLOR,
	GROUP
}

const TOOL_KEYS := {
	KEY_1: ToolType.MOVE,
	KEY_2: ToolType.ROTATE,
	KEY_3: ToolType.RESIZE,
	KEY_4: ToolType.MATERIAL,
	KEY_5: ToolType.NEW_PART,
	KEY_6: ToolType.COLOR,
	KEY_7: ToolType.GROUP,
}

var current_tool: ToolType = ToolType.NONE
var selection_manager: Node = null

var move_tool_ui: Control = null
var resize_tool_ui: Control = null
var rotate_tool_ui: Control = null
var material_tool_ui: Control = null
var new_part_tool_ui: Control = null
var color_tool_ui: Control = null
var group_tool_ui: Control = null

var move_button: Button = null
var resize_button: Button = null
var rotate_button: Button = null
var material_button: Button = null
var new_part_button: Button = null
var color_button: Button = null
var group_button: Button = null

var clipboard_objects: Array[Dictionary] = []

var history: BuildHistory = null

func _ready():
	# Created before the first await: other managers look it up in their _ready.
	history = BuildHistory.new()
	history.name = "BuildHistory"
	add_child(history)

	await get_tree().process_frame

	var workspace = get_tree().current_scene

	move_tool_ui = workspace.get_node_or_null("UI/BuildUI/MoveTool")
	resize_tool_ui = workspace.get_node_or_null("UI/BuildUI/ResizeTool")
	rotate_tool_ui = workspace.get_node_or_null("UI/BuildUI/RotateTool")
	material_tool_ui = workspace.get_node_or_null("UI/BuildUI/MaterialTool")
	new_part_tool_ui = workspace.get_node_or_null("UI/BuildUI/NewPartTool")
	color_tool_ui = workspace.get_node_or_null("UI/BuildUI/ColorTool")
	group_tool_ui = workspace.get_node_or_null("UI/BuildUI/GroupTool")

	move_button = workspace.get_node_or_null("UI/BackpackUI/HBoxContainer/MoveUI/Button")
	resize_button = workspace.get_node_or_null("UI/BackpackUI/HBoxContainer/ResizeUI/Button")
	rotate_button = workspace.get_node_or_null("UI/BackpackUI/HBoxContainer/RotateUI/Button")
	material_button = workspace.get_node_or_null("UI/BackpackUI/HBoxContainer/MaterialUI/Button")
	new_part_button = workspace.get_node_or_null("UI/BackpackUI/HBoxContainer/NewPartUI/Button")
	color_button = workspace.get_node_or_null("UI/BackpackUI/HBoxContainer/ColorUI/Button")
	group_button = workspace.get_node_or_null("UI/BackpackUI/HBoxContainer/GroupUI/Button")

	selection_manager = workspace.get_node_or_null("SelectionManager")

	if move_button:
		move_button.pressed.connect(_toggle_tool.bind(ToolType.MOVE))
	if resize_button:
		resize_button.pressed.connect(_toggle_tool.bind(ToolType.RESIZE))
	if rotate_button:
		rotate_button.pressed.connect(_toggle_tool.bind(ToolType.ROTATE))
	if material_button:
		material_button.pressed.connect(_toggle_tool.bind(ToolType.MATERIAL))
	if new_part_button:
		new_part_button.pressed.connect(_toggle_tool.bind(ToolType.NEW_PART))
	if color_button:
		color_button.pressed.connect(_toggle_tool.bind(ToolType.COLOR))
	if group_button:
		group_button.pressed.connect(_toggle_tool.bind(ToolType.GROUP))

func _unhandled_input(event):
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var ctrl_pressed = event.ctrl_pressed
	var shift_pressed = event.shift_pressed

	var focused_control = get_viewport().gui_get_focus_owner()
	if focused_control is LineEdit or focused_control is TextEdit:
		return

	if not ctrl_pressed and not shift_pressed:
		if TOOL_KEYS.has(event.keycode):
			set_tool(TOOL_KEYS[event.keycode])
			get_viewport().set_input_as_handled()

	if ctrl_pressed and not shift_pressed:
		_ctrl_shortcut(event.keycode)

	if ctrl_pressed and shift_pressed:
		match event.keycode:
			KEY_Z:
				redo()
				get_viewport().set_input_as_handled()

func _ctrl_shortcut(keycode: Key):
	match keycode:
		KEY_D:
			duplicate_selected()
			get_viewport().set_input_as_handled()
		KEY_C:
			copy_selected()
			get_viewport().set_input_as_handled()
		KEY_X:
			cut_selected()
			get_viewport().set_input_as_handled()
		KEY_V:
			paste_clipboard()
			get_viewport().set_input_as_handled()
		KEY_Z:
			undo()
			get_viewport().set_input_as_handled()
		KEY_Y:
			redo()
			get_viewport().set_input_as_handled()
		KEY_A:
			select_all()
			get_viewport().set_input_as_handled()

func _toggle_tool(tool: ToolType):
	if current_tool == tool:
		set_tool(ToolType.NONE)
	else:
		set_tool(tool)

func set_tool(tool: ToolType):
	current_tool = tool

	if move_tool_ui:
		move_tool_ui.visible = (tool == ToolType.MOVE)
	if resize_tool_ui:
		resize_tool_ui.visible = (tool == ToolType.RESIZE)
	if rotate_tool_ui:
		rotate_tool_ui.visible = (tool == ToolType.ROTATE)
	if material_tool_ui:
		material_tool_ui.visible = (tool == ToolType.MATERIAL)
	if new_part_tool_ui:
		new_part_tool_ui.visible = (tool == ToolType.NEW_PART)
	if color_tool_ui:
		color_tool_ui.visible = (tool == ToolType.COLOR)
	if group_tool_ui:
		group_tool_ui.visible = (tool == ToolType.GROUP)

	if selection_manager:
		selection_manager.set_tool_mode(tool)

	tool_changed.emit(tool)

	if tool == ToolType.NONE:
		print("Tool deselected")
	else:
		print("Tool changed to: ", ToolType.keys()[tool])

func copy_selected():
	if not selection_manager:
		return

	var selected_objects = selection_manager.selected_objects
	if selected_objects.is_empty():
		print("No objects selected to copy")
		return

	clipboard_objects.clear()

	for obj in selected_objects:
		if obj is Node3D:
			clipboard_objects.append(_clipboard_entry(obj))

	print("Copied ", clipboard_objects.size(), " object(s) to clipboard (position, rotation, scale preserved)")

func _clipboard_entry(obj: Node3D) -> Dictionary:
	var obj_data = {
		"scene_path": obj.scene_file_path if obj.scene_file_path else "",
		"name": obj.name,
		"position": obj.global_position,
		"rotation": obj.global_rotation,
		"scale": obj.scale,
		"transform": obj.global_transform,
		"properties": {}
	}

	for property in obj.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var prop_name = property.name
			obj_data.properties[prop_name] = obj.get(prop_name)
	return obj_data

func cut_selected():
	if not selection_manager:
		return

	var selected_objects = selection_manager.selected_objects
	if selected_objects.is_empty():
		print("No objects selected to cut")
		return

	copy_selected()
	selection_manager.delete_selected_objects()

	print("Cut ", clipboard_objects.size(), " object(s)")

func paste_clipboard():
	if clipboard_objects.is_empty():
		print("Clipboard is empty")
		return

	var workspace = get_tree().current_scene
	if not workspace:
		return

	var pasted_objects: Array[Node3D] = []

	for obj_data in clipboard_objects:
		pasted_objects.append(_paste_one(workspace, obj_data))

	if history and not pasted_objects.is_empty():
		history.record_created(pasted_objects, "Paste objects")
	if selection_manager and not pasted_objects.is_empty():
		selection_manager.select_objects(pasted_objects)

	print("Pasted ", pasted_objects.size(), " object(s) at exact original positions")

func _paste_one(workspace: Node, obj_data: Dictionary) -> Node3D:
	var new_obj: Node3D = null
	if obj_data.scene_path and obj_data.scene_path != "":
		var scene = load(obj_data.scene_path)
		if scene:
			new_obj = scene.instantiate()
	if not new_obj:
		new_obj = Node3D.new()

	workspace.add_child(new_obj)
	new_obj.owner = workspace
	new_obj.name = obj_data.name + "_copy"
	new_obj.global_position = obj_data.position
	new_obj.global_rotation = obj_data.rotation
	new_obj.scale = obj_data.scale

	for prop_name in obj_data.properties:
		if prop_name in new_obj:
			new_obj.set(prop_name, obj_data.properties[prop_name])
	return new_obj

func duplicate_selected():
	if not selection_manager:
		return

	var selected_objects = selection_manager.selected_objects
	if selected_objects.is_empty():
		print("No objects selected to duplicate")
		return

	var workspace = get_tree().current_scene
	if not workspace:
		return

	var duplicated_objects: Array[Node3D] = []

	for obj in selected_objects:
		if obj is Node3D:
			var duplicate = obj.duplicate()
			var original_pos = obj.global_position
			var original_rot = obj.global_rotation
			var original_scale = obj.scale

			workspace.add_child(duplicate)
			duplicate.owner = workspace
			duplicate.global_position = original_pos
			duplicate.global_rotation = original_rot
			duplicate.scale = original_scale

			duplicated_objects.append(duplicate)

	if history and not duplicated_objects.is_empty():
		history.record_created(duplicated_objects, "Duplicate objects")
	if not duplicated_objects.is_empty():
		selection_manager.select_objects(duplicated_objects)

	print("Duplicated ", duplicated_objects.size(), " object(s) at exact original positions")

func select_all():
	if not selection_manager:
		return

	var all_objects = BuildSelectable.all_selectable(get_tree().current_scene)

	if not all_objects.is_empty():
		selection_manager.select_objects(all_objects)
		print("Selected all ", all_objects.size(), " object(s)")
	else:
		print("No objects to select")

func undo():
	if history:
		history.undo()

func redo():
	if history:
		history.redo()
