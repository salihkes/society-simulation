extends Control
## Buttons that switch the SelectionManager between Part and Group selection.

var selection_manager: Node = null
var part_mode_button: Button = null
var group_mode_button: Button = null

func _ready():
	await get_tree().process_frame

	var workspace = get_tree().current_scene
	selection_manager = workspace.get_node_or_null("SelectionManager")
	part_mode_button = get_node_or_null("Panel/PartModeButton")
	group_mode_button = get_node_or_null("Panel/GroupModeButton")

	if part_mode_button:
		part_mode_button.pressed.connect(_on_part_mode_pressed)
	if group_mode_button:
		group_mode_button.pressed.connect(_on_group_mode_pressed)

	update_button_states()

func _on_part_mode_pressed():
	_set_mode("PART")

func _on_group_mode_pressed():
	_set_mode("GROUP")

func _set_mode(mode_name: String):
	if selection_manager:
		var SelectionMode = selection_manager.get("SelectionMode")
		if SelectionMode:
			selection_manager.set_selection_mode(SelectionMode[mode_name])
			update_button_states()

func update_button_states():
	if not selection_manager:
		return

	var current_mode = selection_manager.get_selection_mode()
	var SelectionMode = selection_manager.get("SelectionMode")
	if not SelectionMode:
		return

	if part_mode_button:
		part_mode_button.disabled = current_mode == SelectionMode.PART
	if group_mode_button:
		group_mode_button.disabled = current_mode == SelectionMode.GROUP
