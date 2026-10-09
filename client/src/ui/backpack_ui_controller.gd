extends Control
## The BackpackUI buttons of the build screen: move, rotate and the new-object panel toggle.

## Values of ToolManager.ToolType.
const TOOL_MOVE := 1
const TOOL_ROTATE := 3

@onready var move_button = $HBoxContainer/MoveUI/Button
@onready var rotate_button = $HBoxContainer/RotateUI/Button
@onready var new_object_button = $HBoxContainer/NewObjectUI/Button

var plot_object_ui: Control = null
var tool_manager: Node = null


## Waits a frame for the siblings.
func _ready():
	await get_tree().process_frame
	var ui_layer = get_parent()
	if ui_layer:
		plot_object_ui = ui_layer.get_node_or_null("PlotObjectUI")

	var workspace = get_tree().current_scene
	tool_manager = workspace.get_node_or_null("ToolManager")

	if move_button:
		move_button.pressed.connect(_on_move_pressed)
	if rotate_button:
		rotate_button.pressed.connect(_on_rotate_pressed)
	if new_object_button:
		new_object_button.pressed.connect(_on_new_object_pressed)


func _on_move_pressed():
	_select_tool(TOOL_MOVE, move_button)


func _on_rotate_pressed():
	_select_tool(TOOL_ROTATE, rotate_button)


func _select_tool(tool: int, button) -> void:
	if tool_manager and tool_manager.has_method("set_tool"):
		tool_manager.set_tool(tool)
	if button:
		button.release_focus()


func _on_new_object_pressed():
	if plot_object_ui:
		plot_object_ui.visible = not plot_object_ui.visible
		print("Plot Object UI toggled: ", plot_object_ui.visible)

	if new_object_button:
		new_object_button.release_focus()
