extends Button
## Saves plot object changes via PlotObjectSync; yellow while unsaved.

var plot_sync: Node = null

func _ready():
	await get_tree().process_frame
	var workspace = get_tree().current_scene
	plot_sync = workspace.get_node_or_null("PlotObjectSync")

	if not plot_sync:
		print("Warning: PlotObjectSync not found, save button won't work")

	pressed.connect(_on_save_pressed)

	if plot_sync:
		plot_sync.unsaved_changes_detected.connect(_on_unsaved_changes)
		plot_sync.all_changes_saved.connect(_on_all_saved)

func _on_unsaved_changes():
	modulate = Color(1.0, 0.8, 0.0)

func _on_all_saved():
	modulate = Color(0.0, 1.0, 0.0)
	await get_tree().create_timer(0.5).timeout
	modulate = Color.WHITE

func _on_save_pressed():
	if plot_sync and plot_sync.has_method("save_all_changes"):
		plot_sync.save_all_changes()
		print("Save button pressed - changes saved")
	else:
		print("Cannot save - PlotObjectSync not available")

	release_focus()
