extends Control

## New part tool panel: places grid-snapped bricks, double-click duplicates a part.

@onready var brick_btn = $SingleDirection

var delete_btn: Button = null
var brick_scene: PackedScene = null
var preview_instance: Node3D = null
var is_placing: bool = false
var has_valid_target: bool = false
var preview_yaw: float = 0.0

var grid_size: float = 0.2

var placement_excludes: Array[RID] = []

var last_click_time: float = 0.0
var last_clicked_object: Node3D = null
var double_click_threshold: float = 0.4

var tool_manager: Node = null
var selection_manager: Node = null


func _ready():
	brick_btn.pressed.connect(_on_brick_pressed)

	delete_btn = get_node_or_null("DeleteButton")
	if delete_btn:
		delete_btn.pressed.connect(_on_delete_pressed)

	brick_scene = load("res://assets/art/textures/brick.tscn")

	await get_tree().process_frame
	var workspace = get_tree().current_scene
	tool_manager = workspace.get_node_or_null("ToolManager")
	selection_manager = workspace.get_node_or_null("SelectionManager")

	brick_btn.release_focus()


func _on_brick_pressed():
	if not is_placing:
		start_placing_mode()
	else:
		cancel_placing_mode()
	brick_btn.release_focus()


func _on_delete_pressed():
	if selection_manager:
		selection_manager.delete_selected_objects()
	if delete_btn:
		delete_btn.release_focus()


func start_placing_mode():
	is_placing = true
	has_valid_target = false
	preview_yaw = 0.0

	if brick_scene:
		preview_instance = brick_scene.instantiate()
		get_tree().current_scene.add_child(preview_instance)
		preview_instance.visible = false

		make_preview_transparent(preview_instance)
		disable_collision(preview_instance)

	_collect_placement_excludes()

	print("Part placement mode: click to place, R to rotate, ESC to cancel.")


func cancel_placing_mode():
	is_placing = false
	has_valid_target = false

	if preview_instance and is_instance_valid(preview_instance):
		preview_instance.queue_free()
	preview_instance = null

	print("Part placement mode cancelled.")


func _collect_placement_excludes():
	placement_excludes.clear()
	if preview_instance:
		placement_excludes.append_array(BuildTargeting.collision_rids(preview_instance))
	var player = get_tree().current_scene.find_child("humanoid", true, false)
	if player:
		placement_excludes.append_array(BuildTargeting.collision_rids(player))


func _process(_delta):
	if not visible or not is_placing:
		return
	update_preview_position()


func _unhandled_input(event):
	if not visible:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_on_left_click(event.position)

	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE and is_placing:
			cancel_placing_mode()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_R and is_placing:
			preview_yaw = wrapf(preview_yaw + PI / 2.0, 0.0, TAU)
			get_viewport().set_input_as_handled()


## Placing consumes the click whether or not it places.
func _on_left_click(mouse_pos: Vector2):
	if is_placing:
		if has_valid_target:
			place_part()
		get_viewport().set_input_as_handled()
	elif check_for_duplicate_click(mouse_pos):
		get_viewport().set_input_as_handled()


func update_preview_position():
	if not preview_instance:
		return

	var mouse_pos = get_viewport().get_mouse_position()
	var hit = BuildTargeting.raycast(self, mouse_pos, placement_excludes)

	if hit.is_empty():
		has_valid_target = false
		preview_instance.visible = false
		return

	# The scene root is scaled; its basis keeps placed parts at the size of existing bricks.
	var workspace_basis: Basis = get_tree().current_scene.global_transform.basis
	var part_basis = workspace_basis * Basis(Vector3.UP, preview_yaw)
	var local_aabb = BuildSelectable.get_aabb(preview_instance)
	preview_instance.global_transform = BuildSnapping.place_on_face(
		hit.position, hit.normal, part_basis, local_aabb, grid_size
	)
	preview_instance.visible = true
	has_valid_target = true


func place_part():
	if not preview_instance or not brick_scene or not has_valid_target:
		return

	var new_part = brick_scene.instantiate()
	var workspace = get_tree().current_scene
	workspace.add_child(new_part)
	new_part.global_transform = preview_instance.global_transform

	_record_created([new_part], "Place part")
	print("Placed new part at: ", new_part.global_position)


## Returns true if a duplication was triggered.
func check_for_duplicate_click(mouse_pos: Vector2) -> bool:
	var hit = BuildTargeting.target(self, mouse_pos)
	var target: Node3D = hit.get("part") if not hit.is_empty() else null

	if not target:
		last_clicked_object = null
		last_click_time = 0.0
		return false

	var current_time = Time.get_ticks_msec() / 1000.0
	if target == last_clicked_object and (current_time - last_click_time) < double_click_threshold:
		duplicate_part(target)
		last_clicked_object = null
		last_click_time = 0.0
		return true

	last_clicked_object = target
	last_click_time = current_time
	return false


func duplicate_part(original: Node3D):
	var duplicate = original.duplicate()
	var workspace = get_tree().current_scene
	workspace.add_child(duplicate)
	duplicate.global_transform = original.global_transform

	_record_created([duplicate], "Duplicate part")
	print("Duplicated part: ", original.name)

	if tool_manager:
		tool_manager.set_tool(1)  # ToolType.MOVE

	if selection_manager:
		await get_tree().process_frame
		var objects: Array[Node3D] = [duplicate]
		selection_manager.select_objects(objects)


func _record_created(nodes: Array, action: String):
	if tool_manager and tool_manager.get("history") != null:
		tool_manager.history.record_created(nodes, action)


func make_preview_transparent(node: Node):
	if node is MeshInstance3D and node.mesh:
		for i in range(node.mesh.get_surface_count()):
			_make_surface_transparent(node, i)

	for child in node.get_children():
		make_preview_transparent(child)


func _make_surface_transparent(node: MeshInstance3D, i: int):
	var mat = node.get_surface_override_material(i)
	if mat == null:
		mat = node.mesh.surface_get_material(i)
	if not mat:
		return
	mat = mat.duplicate()
	if mat is BaseMaterial3D:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.5
	node.set_surface_override_material(i, mat)


## So the preview never catches the placement ray or pushes the player.
func disable_collision(node: Node):
	if node is CollisionObject3D:
		node.collision_layer = 0
		node.collision_mask = 0
		for child in node.get_children():
			if child is CollisionShape3D or child is CollisionPolygon3D:
				child.disabled = true

	for child in node.get_children():
		disable_collision(child)


func _notification(what):
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if not visible and is_placing:
			cancel_placing_mode()
