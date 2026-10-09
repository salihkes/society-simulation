extends Node

## Tracks plot objects' unsaved transforms and sends moved ones on save_all_changes().

signal unsaved_changes_detected()
signal all_changes_saved()

var network_controller: Node = null
var selection_manager: Node = null
## net_id -> object, for the current selection.
var tracked_objects: Dictionary = {}
## net_id -> last saved transform, for every plot object seen.
var all_plot_objects_initial: Dictionary = {}
var has_unsaved_changes: bool = false

func _ready():
	network_controller = get_node_or_null("/root/NetworkController")
	if not network_controller:
		network_controller = get_tree().root.find_child("NetworkController", true, false)

	var workspace = get_tree().current_scene
	selection_manager = workspace.get_node_or_null("SelectionManager")

	if selection_manager:
		selection_manager.objects_selected.connect(_on_objects_selected)
		selection_manager.objects_deselected.connect(_on_objects_deselected)

	# Give the server's plot objects time to load before the first scan.
	await get_tree().create_timer(2.0).timeout
	_initialize_plot_object_tracking()

	print("PlotObjectSync initialized")

func _initialize_plot_object_tracking():
	var workspace = get_tree().current_scene
	var plot_objects_found = 0

	var found_objects = []
	_find_plot_objects_recursive(workspace, found_objects)

	for obj in found_objects:
		var net_id = obj.name
		if not all_plot_objects_initial.has(net_id):
			all_plot_objects_initial[net_id] = obj.global_transform
			plot_objects_found += 1

	print("Initialized tracking for ", plot_objects_found, " existing plot objects")

func _find_plot_objects_recursive(node: Node, found_objects: Array):
	if node is Node3D and node.has_meta("is_plot_object"):
		found_objects.append(node)
	for child in node.get_children():
		_find_plot_objects_recursive(child, found_objects)

func _process(_delta):
	_check_for_unsaved_changes()

func _on_objects_selected(objects: Array):
	tracked_objects.clear()
	for obj in objects:
		if obj.has_meta("is_plot_object"):
			var net_id = obj.name
			tracked_objects[net_id] = obj
			if not all_plot_objects_initial.has(net_id):
				all_plot_objects_initial[net_id] = obj.global_transform
				print("Started tracking plot object: ", net_id)

func _on_objects_deselected():
	tracked_objects.clear()
	print("Objects deselected, but still tracking ", all_plot_objects_initial.size(), " plot objects for changes")

func _check_for_unsaved_changes():
	var changes_detected = false

	for net_id in all_plot_objects_initial.keys():
		var obj = _find_object_by_net_id(net_id)
		if not obj or not is_instance_valid(obj):
			all_plot_objects_initial.erase(net_id)
			continue
		if _has_moved(obj, all_plot_objects_initial[net_id]):
			changes_detected = true
			break

	if changes_detected != has_unsaved_changes:
		has_unsaved_changes = changes_detected
		if has_unsaved_changes:
			unsaved_changes_detected.emit()
		else:
			all_changes_saved.emit()

func _has_moved(obj: Node3D, saved: Transform3D) -> bool:
	var current_transform = obj.global_transform
	var pos_delta = current_transform.origin.distance_to(saved.origin)
	var rot_changed = not current_transform.basis.is_equal_approx(saved.basis)
	return pos_delta > 0.01 or rot_changed

func _find_object_by_net_id(net_id: String) -> Node3D:
	var scene = get_tree().current_scene

	var obj = scene.get_node_or_null(net_id)
	if obj:
		return obj

	var workspace = scene.get_node_or_null("workspace")
	if workspace:
		obj = workspace.get_node_or_null(net_id)
		if obj:
			return obj

	var interactive = scene.get_node_or_null("InteractiveObjects")
	if interactive:
		obj = interactive.get_node_or_null(net_id)
		if obj:
			return obj

	return null

func save_all_changes():
	print("Saving all plot object changes...")
	print("Checking ", all_plot_objects_initial.size(), " tracked objects for changes...")

	var saved_count = 0
	var unchanged_count = 0

	for net_id in all_plot_objects_initial.keys():
		var obj = _find_object_by_net_id(net_id)

		if not obj or not is_instance_valid(obj):
			print("Warning: Could not find object ", net_id, " to save")
			all_plot_objects_initial.erase(net_id)
			continue

		var initial_transform = all_plot_objects_initial[net_id]
		var current_transform = obj.global_transform
		var pos_delta = current_transform.origin.distance_to(initial_transform.origin)

		if _has_moved(obj, initial_transform):
			_send_plot_object_update(obj)
			all_plot_objects_initial[net_id] = current_transform
			saved_count += 1
			print("  - Saved ", net_id, " (moved ", pos_delta, "m or rotated)")
		else:
			unchanged_count += 1

	has_unsaved_changes = false
	all_changes_saved.emit()
	print("Save complete! ", saved_count, " objects updated, ", unchanged_count, " unchanged")

## Skipped until the server has assigned a plot_id, or when outside the plot.
func _send_plot_object_update(obj: Node3D):
	if not network_controller or not network_controller.has_method("send_json"):
		print("Warning: NetworkController not available")
		return

	if not obj.has_meta("is_plot_object"):
		print("Warning: Object ", obj.name, " is not a plot object")
		return

	var net_id = obj.name
	var plot_id = obj.get_meta("plot_id", "")

	if plot_id == "":
		print("Warning: Object ", net_id, " doesn't have plot_id set yet - waiting for server confirmation")
		return

	var xform = obj.global_transform
	var scene_root = get_tree().current_scene

	if BuildPlots.is_enforced(scene_root, obj):
		var plot = BuildPlots.plot_for_object(scene_root, obj)
		if not plot.is_empty() and not BuildPlots.fits_object(scene_root, obj, xform, plot):
			print("Warning: ", net_id, " sticks out of plot ", plot.id, " - not saved")
			return

	var message = {
		"type": "update_plot_object",
		"net_id": net_id,
		"plot_id": plot_id,
		"transform": {
			"origin": {
				"x": xform.origin.x,
				"y": xform.origin.y,
				"z": xform.origin.z
			},
			"basis_x": {"x": xform.basis.x.x, "y": xform.basis.x.y, "z": xform.basis.x.z},
			"basis_y": {"x": xform.basis.y.x, "y": xform.basis.y.y, "z": xform.basis.y.z},
			"basis_z": {"x": xform.basis.z.x, "y": xform.basis.z.y, "z": xform.basis.z.z}
		}
	}
	var payload = BuildPlots.payload(scene_root, obj, xform)
	message["local"] = payload.local
	message["footprint"] = payload.footprint

	network_controller.send_json(message)
	print("Sent plot object update: ", net_id, " (plot: ", plot_id, ")")
