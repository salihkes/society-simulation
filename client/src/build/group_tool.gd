extends Control

## Group tool panel; a group is a "Group*" Node3D directly under "workspace".

var selection_manager: Node = null
var workspace: Node3D = null

var create_group_button: Button = null
var add_to_group_button: Button = null
var remove_from_group_button: Button = null
var delete_group_button: Button = null
var duplicate_and_group_button: Button = null
var group_name_edit: LineEdit = null
var target_group_dropdown: OptionButton = null
var current_group_label: Label = null

var group_counter: int = 0

func _ready():
	await get_tree().process_frame
	workspace = get_tree().current_scene
	selection_manager = workspace.get_node_or_null("SelectionManager")

	create_group_button = get_node_or_null("CreateGroup")
	add_to_group_button = get_node_or_null("AddToGroup")
	remove_from_group_button = get_node_or_null("RemoveFromGroup")
	delete_group_button = get_node_or_null("DeleteGroup")
	duplicate_and_group_button = get_node_or_null("DuplicateAndGroup")
	group_name_edit = get_node_or_null("GroupNameEdit")
	target_group_dropdown = get_node_or_null("TargetGroupDropdown")

	if create_group_button:
		create_group_button.pressed.connect(_on_create_group_pressed)
	if add_to_group_button:
		add_to_group_button.pressed.connect(_on_add_to_group_pressed)
	if remove_from_group_button:
		remove_from_group_button.pressed.connect(_on_remove_from_group_pressed)
	if delete_group_button:
		delete_group_button.pressed.connect(_on_delete_group_pressed)
	if duplicate_and_group_button:
		duplicate_and_group_button.pressed.connect(_on_duplicate_and_group_pressed)

	if selection_manager:
		selection_manager.objects_selected.connect(_on_objects_selected)
		selection_manager.objects_deselected.connect(_on_objects_deselected)

	update_groups_dropdown()
	update_button_states()

func _on_objects_selected(objects: Array):
	update_groups_dropdown()
	update_button_states()

func _on_objects_deselected():
	update_groups_dropdown()
	update_button_states()

func update_button_states():
	if not selection_manager:
		return

	var selected = selection_manager.get_selected_object()
	var has_selection = selection_manager.selected_objects.size() > 0

	if not selected:
		if create_group_button:
			create_group_button.disabled = true
		if add_to_group_button:
			add_to_group_button.disabled = true
		if remove_from_group_button:
			remove_from_group_button.disabled = true
		if delete_group_button:
			delete_group_button.disabled = true
		if duplicate_and_group_button:
			duplicate_and_group_button.disabled = true
	else:
		var is_group = is_node_a_group(selected)
		var parent = selected.get_parent()
		var parent_is_group = parent and is_node_a_group(parent)

		if create_group_button:
			create_group_button.disabled = is_group or parent_is_group
		if add_to_group_button:
			add_to_group_button.disabled = is_group or parent_is_group
		if remove_from_group_button:
			remove_from_group_button.disabled = not parent_is_group
		if delete_group_button:
			delete_group_button.disabled = not is_group
		if duplicate_and_group_button:
			duplicate_and_group_button.disabled = false

func update_groups_dropdown():
	if not target_group_dropdown:
		return

	target_group_dropdown.clear()

	var groups = []
	if workspace:
		for child in workspace.get_children():
			if is_node_a_group(child):
				groups.append(child)

	if groups.is_empty():
		target_group_dropdown.add_item("(No groups available)")
		target_group_dropdown.disabled = true
	else:
		target_group_dropdown.disabled = false
		for i in range(groups.size()):
			target_group_dropdown.add_item(groups[i].name)
			target_group_dropdown.set_item_metadata(i, groups[i])

func get_selected_target_group() -> Node3D:
	if not target_group_dropdown or target_group_dropdown.disabled:
		return null

	var selected_idx = target_group_dropdown.selected
	if selected_idx >= 0 and selected_idx < target_group_dropdown.item_count:
		return target_group_dropdown.get_item_metadata(selected_idx)

	return null

func is_node_a_group(node: Node) -> bool:
	if not node or not node is Node3D:
		return false

	var parent = node.get_parent()
	if not parent or parent.name != "workspace":
		return false

	return node.name.begins_with("Group")

func _on_create_group_pressed():
	if not selection_manager:
		return

	var selected = selection_manager.get_selected_object()
	if not selected:
		print("No object selected to create group from")
		return

	var parent = selected.get_parent()
	if parent and is_node_a_group(parent):
		print("Object is already in a group")
		return

	var group_name = "Group"
	if group_name_edit and not group_name_edit.text.is_empty():
		group_name = group_name_edit.text
	else:
		group_counter += 1
		group_name = "Group" + str(group_counter)

	var group = Node3D.new()
	group.name = group_name

	var obj_global_transform = selected.global_transform
	workspace.add_child(group)
	group.owner = workspace
	group.global_transform = obj_global_transform
	selected.reparent(group, true)

	print("Created group '", group_name, "' with object: ", selected.name)

	var objects: Array[Node3D] = [group]
	selection_manager.select_objects(objects)

	if group_name_edit:
		group_name_edit.text = ""

	update_groups_dropdown()
	update_button_states()

func _on_add_to_group_pressed():
	if not selection_manager:
		return

	var selected = selection_manager.get_selected_object()
	if not selected:
		print("No object selected to add to group")
		return

	var parent = selected.get_parent()
	if parent and is_node_a_group(parent):
		print("Object is already in a group")
		return

	var target_group = get_selected_target_group()

	if not target_group:
		print("No target group selected. Please select a group from the dropdown.")
		return

	selected.reparent(target_group, true)

	print("Added '", selected.name, "' to group '", target_group.name, "'")
	update_button_states()

func _on_remove_from_group_pressed():
	if not selection_manager:
		return

	var selected = selection_manager.get_selected_object()
	if not selected:
		print("No object selected to remove from group")
		return

	var parent = selected.get_parent()
	if not parent or not is_node_a_group(parent):
		print("Object is not in a group")
		return

	selected.reparent(workspace, true)

	print("Removed '", selected.name, "' from group '", parent.name, "'")
	update_button_states()

## Children go back to the workspace and the group is freed (not undoable).
func _on_delete_group_pressed():
	if not selection_manager:
		return

	var selected = selection_manager.get_selected_object()
	if not selected or not is_node_a_group(selected):
		print("No group selected to delete")
		return

	var children = selected.get_children().duplicate()
	for child in children:
		if child is Node3D:
			child.reparent(workspace, true)

	selection_manager.deselect_all_objects()

	var group_name = selected.name
	selected.queue_free()

	print("Deleted group '", group_name, "' and moved its children back to workspace")

	update_groups_dropdown()
	update_button_states()

func _on_duplicate_and_group_pressed():
	if not selection_manager or not workspace:
		return

	var selected_objects = selection_manager.selected_objects
	if selected_objects.is_empty():
		print("No objects selected to duplicate and group")
		return

	print("Duplicating ", selected_objects.size(), " objects and grouping them")

	var duplicates: Array[Node3D] = []
	for obj in selected_objects:
		if obj is Node3D:
			var duplicate = obj.duplicate()
			workspace.add_child(duplicate)
			duplicate.owner = workspace
			duplicate.global_transform = obj.global_transform
			duplicates.append(duplicate)

	if duplicates.is_empty():
		print("No valid objects to duplicate")
		return

	group_counter += 1
	var group_name = "DuplicatedGroup" + str(group_counter)

	var group = Node3D.new()
	group.name = group_name
	workspace.add_child(group)
	group.owner = workspace

	var center_pos = Vector3.ZERO
	for dup in duplicates:
		center_pos += dup.global_position
	center_pos /= duplicates.size()

	group.global_position = center_pos

	for dup in duplicates:
		dup.reparent(group, true)

	print("Created group '", group_name, "' with ", duplicates.size(), " duplicated objects")

	var objects_to_select: Array[Node3D] = [group]
	selection_manager.select_objects(objects_to_select)

	update_groups_dropdown()
	update_button_states()

