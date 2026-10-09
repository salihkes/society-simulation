extends Node
## Selection and gizmo dragging for the build tools; every drag is one undo step.

signal objects_selected(objects: Array)
signal objects_deselected()

## Same values as ToolManager.ToolType.
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

enum SelectionMode {
	PART,
	GROUP
}

## Gizmo face order: +X, -X, +Y, -Y, +Z, -Z.
const FACE_NAMES := ["PosX", "NegX", "PosY", "NegY", "PosZ", "NegZ"]
const RESIZE_GIZMO_COLOR := Color(0, 0.8, 1, 1)
const MOVE_GIZMO_COLORS := [Color(1, 0, 0, 1), Color(0, 1, 0, 1), Color(0, 0, 1, 1)]
const DRAG_GIZMO_COLOR := Color(1, 0.5, 0, 1)
## Screen pixels of mouse travel to one unit of drag.
const DRAG_SENSITIVITY := 0.002

var current_tool_mode: ToolType = ToolType.NONE
var selection_mode: SelectionMode = SelectionMode.PART
var selected_objects: Array[Node3D] = []

var _history: BuildHistory = null
var _drag_history_token: Array[Dictionary] = []

var is_box_selecting: bool = false
var box_select_start_pos: Vector2
var box_select_current_pos: Vector2
var box_select_canvas: Control = null

var is_dragging: bool = false
var dragged_sphere: MeshInstance3D = null
var drag_start_mouse_pos: Vector2
var drag_start_object_basis: Basis
var drag_axis: int = 0
var drag_direction: int = 1
var drag_start_gizmo_pos: Vector3
var drag_screen_axis_dir: Vector2

var rotate_ring_center: Vector3
var rotate_ring_normal: Vector3
var rotate_last_screen_angle: float
var rotate_total_angle: float

# Direct drag (Move mode) starts after drag_threshold_time or drag_threshold_distance px.
var is_object_dragging: bool = false
var object_drag_start_time: float = 0.0
var object_drag_start_mouse_pos: Vector2
var object_drag_initial_pos: Vector3
var object_drag_plane_point: Vector3
var object_drag_plane_normal: Vector3
var object_drag_offset: Vector3
var drag_threshold_time: float = 0.15
var drag_threshold_distance: float = 5.0
var is_waiting_for_drag: bool = false

## Per object at drag start: object, position, and for gizmo drags scale and basis.
var drag_initial_states: Array[Dictionary] = []

func _ready():
	await get_tree().process_frame
	create_selection_box_canvas()


## Looked up lazily because the managers' _ready order is not fixed.
func get_history() -> BuildHistory:
	if _history and is_instance_valid(_history):
		return _history
	var tool_manager = get_tree().current_scene.get_node_or_null("ToolManager")
	if tool_manager:
		_history = tool_manager.get("history")
		if _history:
			_history.changed.connect(_on_history_changed)
	return _history


func _on_history_changed():
	var pruned: Array[Node3D] = []
	for obj in selected_objects:
		if is_instance_valid(obj) and obj.is_inside_tree():
			pruned.append(obj)
	if pruned.size() != selected_objects.size():
		selected_objects = pruned
		if selected_objects.is_empty():
			remove_all_selection_outlines()
			objects_deselected.emit()
		else:
			update_selection_visuals()
			objects_selected.emit(selected_objects)

func _unhandled_input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_on_left_press(event.position)
			else:
				_on_left_release()

	elif event is InputEventMouseMotion:
		if is_dragging:
			update_gizmo_drag(event.position)
		elif is_waiting_for_drag:
			check_drag_threshold(event.position)
		elif is_object_dragging:
			update_object_drag(event.position)
		elif is_box_selecting:
			update_box_selection(event.position)

	elif event is InputEventKey:
		if event.keycode == KEY_DELETE and event.pressed and not event.echo:
			if selected_objects.size() > 0:
				delete_selected_objects()
				get_viewport().set_input_as_handled()

func _on_left_press(mouse_pos: Vector2):
	var shift_pressed = Input.is_key_pressed(KEY_SHIFT)

	if selected_objects.size() > 0:
		var gizmo = get_gizmo_at_mouse(mouse_pos)
		if gizmo:
			start_gizmo_drag(gizmo, mouse_pos)
			return
		if current_tool_mode == ToolType.MOVE and not shift_pressed:
			if _try_start_object_drag(mouse_pos):
				return

	var hit_result = raycast_from_mouse(mouse_pos)
	var clicked_object = null
	if hit_result and hit_result.collider:
		clicked_object = find_selectable_parent(hit_result.collider)

	if clicked_object:
		if shift_pressed:
			toggle_object_selection(clicked_object)
		else:
			select_objects([clicked_object])
	else:
		start_box_selection(mouse_pos)

func _try_start_object_drag(mouse_pos: Vector2) -> bool:
	var hit_result = raycast_from_mouse(mouse_pos)
	if not (hit_result and hit_result.collider):
		return false
	var target = find_selectable_parent(hit_result.collider)
	if target and target in selected_objects:
		start_waiting_for_drag(mouse_pos, hit_result.position)
		return true
	return false

func _on_left_release():
	if is_dragging:
		stop_gizmo_drag()
	elif is_object_dragging or is_waiting_for_drag:
		stop_object_drag()
	elif is_box_selecting:
		finish_box_selection(Input.is_key_pressed(KEY_SHIFT))

func _process(delta):
	if is_waiting_for_drag and not is_object_dragging:
		if Time.get_ticks_msec() / 1000.0 - object_drag_start_time >= drag_threshold_time:
			activate_object_drag()

func create_selection_box_canvas():
	box_select_canvas = Control.new()
	box_select_canvas.name = "SelectionBoxCanvas"
	box_select_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box_select_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	box_select_canvas.visible = false
	box_select_canvas.draw.connect(_draw_selection_box)
	add_child(box_select_canvas)

func _draw_selection_box():
	if not is_box_selecting:
		return

	var rect_min = Vector2(
		min(box_select_start_pos.x, box_select_current_pos.x),
		min(box_select_start_pos.y, box_select_current_pos.y)
	)
	var rect_max = Vector2(
		max(box_select_start_pos.x, box_select_current_pos.x),
		max(box_select_start_pos.y, box_select_current_pos.y)
	)
	var rect_size = rect_max - rect_min

	box_select_canvas.draw_rect(Rect2(rect_min, rect_size), Color(0.3, 0.6, 1.0, 0.2))
	box_select_canvas.draw_rect(Rect2(rect_min, rect_size), Color(0.3, 0.6, 1.0, 0.8), false, 2.0)

func start_box_selection(mouse_pos: Vector2):
	is_box_selecting = true
	box_select_start_pos = mouse_pos
	box_select_current_pos = mouse_pos
	box_select_canvas.visible = true
	box_select_canvas.queue_redraw()
	print("Started box selection")

func update_box_selection(mouse_pos: Vector2):
	box_select_current_pos = mouse_pos
	box_select_canvas.queue_redraw()

## A box under 5 pixels counts as a click on empty space and deselects.
func finish_box_selection(additive: bool):
	is_box_selecting = false
	box_select_canvas.visible = false
	box_select_canvas.queue_redraw()

	var min_x = min(box_select_start_pos.x, box_select_current_pos.x)
	var max_x = max(box_select_start_pos.x, box_select_current_pos.x)
	var min_y = min(box_select_start_pos.y, box_select_current_pos.y)
	var max_y = max(box_select_start_pos.y, box_select_current_pos.y)

	var box_size = Vector2(max_x - min_x, max_y - min_y)
	if box_size.length() < 5.0:
		if not additive:
			deselect_all_objects()
		print("Box too small, treating as click")
		return

	var rect = Rect2(Vector2(min_x, min_y), box_size)

	var objects_in_box: Array[Node3D] = []
	for obj in BuildSelectable.all_selectable(get_tree().current_scene):
		if is_object_in_screen_rect(obj, rect):
			objects_in_box.append(obj)

	if additive:
		for obj in objects_in_box:
			if obj not in selected_objects:
				selected_objects.append(obj)
		if objects_in_box.size() > 0:
			update_selection_visuals()
			objects_selected.emit(selected_objects)
	elif objects_in_box.size() > 0:
		select_objects(objects_in_box)
	else:
		deselect_all_objects()

	print("Box selection finished. Selected ", objects_in_box.size(), " objects")

func find_selectable_parent(node: Node) -> Node3D:
	return BuildSelectable.find_selectable_parent(node, get_tree().current_scene)

func is_object_in_screen_rect(obj: Node3D, rect: Rect2) -> bool:
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return false

	var aabb = get_object_aabb(obj)
	if not aabb:
		var screen_pos = camera.unproject_position(obj.global_position)
		return rect.has_point(screen_pos)

	var world_transform = obj.global_transform
	for i in 8:
		var screen_pos = camera.unproject_position(world_transform * aabb.get_endpoint(i))
		if rect.has_point(screen_pos):
			return true

	var center = world_transform * aabb.get_center()
	return rect.has_point(camera.unproject_position(center))

func select_objects(objects: Array[Node3D]):
	deselect_all_objects()

	selected_objects.clear()
	for obj in objects:
		if is_instance_valid(obj) and obj.is_inside_tree():
			selected_objects.append(obj)
	print("Selected ", selected_objects.size(), " object(s)")

	update_selection_visuals()

	if selected_objects.size() > 0:
		objects_selected.emit(selected_objects)

func toggle_object_selection(obj: Node3D):
	if obj in selected_objects:
		selected_objects.erase(obj)
		remove_selection_outline_for_object(obj)
		print("Removed from selection: ", obj.name)

		if selected_objects.size() == 0:
			objects_deselected.emit()
		else:
			objects_selected.emit(selected_objects)
	else:
		selected_objects.append(obj)
		print("Added to selection: ", obj.name)
		update_selection_visuals()
		objects_selected.emit(selected_objects)

func update_selection_visuals():
	remove_all_selection_outlines()
	if selected_objects.size() > 0:
		add_selection_outlines(selected_objects)

## Called by the ToolManager. Also sets the selection mode to GROUP.
func set_tool_mode(tool_mode: ToolType):
	current_tool_mode = tool_mode
	selection_mode = SelectionMode.GROUP
	print("Tool changed to: ", ToolType.keys()[tool_mode])

	if selected_objects.size() > 0:
		update_selection_visuals()

func deselect_all_objects():
	if selected_objects.size() > 0:
		print("Deselected ", selected_objects.size(), " object(s)")
		remove_all_selection_outlines()
		selected_objects.clear()
		objects_deselected.emit()

func add_selection_outlines(objects: Array[Node3D]):
	var workspace = get_tree().current_scene
	if workspace.has_node("SelectionMarkers"):
		return

	var markers_parent = Node3D.new()
	markers_parent.name = "SelectionMarkers"
	get_tree().current_scene.add_child(markers_parent)

	markers_parent.set_meta("target_objects", objects)
	markers_parent.set_meta("tool_mode", current_tool_mode)

	for obj in objects:
		var obj_markers = Node3D.new()
		obj_markers.name = "Markers_" + obj.name
		obj_markers.set_meta("target_object", obj)
		markers_parent.add_child(obj_markers)

		match current_tool_mode:
			ToolType.MOVE:
				create_move_gizmos(obj_markers, obj)
			ToolType.RESIZE:
				create_resize_gizmos(obj_markers, obj)
			ToolType.ROTATE:
				create_rotate_gizmos(obj_markers, obj)
			_:
				pass

	if not get_tree().process_frame.is_connected(update_selection_markers):
		get_tree().process_frame.connect(update_selection_markers)

func _face_offset(aabb: AABB, i: int, margin: float) -> Vector3:
	var axis_index = i / 2
	var local_offset = Vector3.ZERO
	local_offset[axis_index] = (1 if i % 2 == 0 else -1) * (aabb.size[axis_index] / 2.0 + margin)
	return local_offset

func _arrow_basis(i: int) -> Basis:
	var arrow_rotation = Basis()
	if i / 2 == 0:
		arrow_rotation = arrow_rotation.rotated(Vector3.FORWARD, -PI / 2 if i % 2 == 0 else PI / 2)
	elif i / 2 == 1:
		arrow_rotation = arrow_rotation.rotated(Vector3.RIGHT, PI if i % 2 == 1 else 0)
	else:
		arrow_rotation = arrow_rotation.rotated(Vector3.RIGHT, PI / 2 if i % 2 == 0 else -PI / 2)
	return arrow_rotation

func create_resize_gizmos(parent: Node3D, obj: Node3D):
	var aabb = get_object_aabb(obj)
	if not aabb:
		return

	var world_transform = obj.global_transform
	var center = world_transform * aabb.get_center()

	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 0.2
	sphere_mesh.height = 0.4
	var material = _gizmo_material(RESIZE_GIZMO_COLOR)

	for i in range(6):
		var sphere = MeshInstance3D.new()
		sphere.name = FACE_NAMES[i]
		sphere.mesh = sphere_mesh
		sphere.material_override = material
		sphere.set_meta("axis", i / 2)
		sphere.set_meta("direction", 1 if i % 2 == 0 else -1)
		sphere.set_meta("gizmo_type", "resize")
		sphere.global_position = center + world_transform.basis * _face_offset(aabb, i, 0.2)
		parent.add_child(sphere)

func create_move_gizmos(parent: Node3D, obj: Node3D):
	var aabb = get_object_aabb(obj)
	if not aabb:
		return

	var world_transform = obj.global_transform
	var center = world_transform * aabb.get_center()

	var cone_mesh = CylinderMesh.new()
	cone_mesh.top_radius = 0.0
	cone_mesh.bottom_radius = 0.15
	cone_mesh.height = 0.4

	for i in range(6):
		var arrow = MeshInstance3D.new()
		arrow.name = FACE_NAMES[i]
		arrow.mesh = cone_mesh
		arrow.material_override = _gizmo_material(MOVE_GIZMO_COLORS[i / 2])
		arrow.set_meta("axis", i / 2)
		arrow.set_meta("direction", 1 if i % 2 == 0 else -1)
		arrow.set_meta("gizmo_type", "move")
		arrow.global_position = center + world_transform.basis * _face_offset(aabb, i, 0.4)
		arrow.global_transform.basis = world_transform.basis * _arrow_basis(i)
		parent.add_child(arrow)

func _gizmo_material(color: Color) -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.render_priority = 10
	material.no_depth_test = true
	return material

func _rotate_ring_radius(obj: Node3D, aabb: AABB) -> float:
	var b = obj.global_transform.basis
	var hx = (b * Vector3(aabb.size.x / 2.0, 0, 0)).length()
	var hy = (b * Vector3(0, aabb.size.y / 2.0, 0)).length()
	var hz = (b * Vector3(0, 0, aabb.size.z / 2.0)).length()
	return max(hx, max(hy, hz)) + 0.6

func _rotate_ring_basis(obj_rot: Basis, axis: int, radius: float) -> Basis:
	var local := Basis()
	if axis == 0:
		local = Basis(Vector3.FORWARD, PI / 2)
	elif axis == 2:
		local = Basis(Vector3.RIGHT, PI / 2)
	return obj_rot * local

func create_rotate_gizmos(parent: Node3D, obj: Node3D):
	var aabb = get_object_aabb(obj)
	if not aabb:
		return

	var world_transform = obj.global_transform
	var center = world_transform * aabb.get_center()
	var obj_rot = world_transform.basis.orthonormalized()
	var ring_radius = _rotate_ring_radius(obj, aabb)

	var colors = [
		Color(1, 0.25, 0.25, 0.9),
		Color(0.25, 1, 0.25, 0.9),
		Color(0.35, 0.5, 1, 0.9)
	]
	var axis_names = ["X", "Y", "Z"]

	for i in range(3):
		var ring = MeshInstance3D.new()
		ring.name = "Ring" + axis_names[i]

		# Own torus per ring: update_rotate_gizmos changes its radius.
		var torus_mesh = TorusMesh.new()
		torus_mesh.inner_radius = ring_radius
		torus_mesh.outer_radius = ring_radius + 0.08
		torus_mesh.rings = 48
		torus_mesh.ring_segments = 10
		ring.mesh = torus_mesh

		var material = StandardMaterial3D.new()
		material.albedo_color = colors[i]
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.render_priority = 10
		material.no_depth_test = true
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		ring.material_override = material

		ring.set_meta("axis", i)
		ring.set_meta("gizmo_type", "rotate")
		ring.set_meta("ring_center", center)
		ring.set_meta("ring_normal", (obj_rot * _axis_unit(i)).normalized())
		ring.set_meta("ring_radius", ring_radius)

		ring.global_position = center
		ring.global_transform.basis = _rotate_ring_basis(obj_rot, i, ring_radius)

		parent.add_child(ring)

func _axis_unit(axis: int) -> Vector3:
	var v := Vector3.ZERO
	v[axis] = 1.0
	return v

## Detached at once so new gizmos can take the "SelectionMarkers" name this frame.
func remove_all_selection_outlines():
	var workspace = get_tree().current_scene
	if workspace.has_node("SelectionMarkers"):
		var markers = workspace.get_node("SelectionMarkers")
		workspace.remove_child(markers)
		markers.queue_free()

func remove_selection_outline_for_object(obj: Node3D):
	var workspace = get_tree().current_scene
	if workspace.has_node("SelectionMarkers"):
		var markers = workspace.get_node("SelectionMarkers")
		var marker_name = "Markers_" + obj.name
		if markers.has_node(marker_name):
			markers.get_node(marker_name).queue_free()

func update_selection_markers():
	if selected_objects.size() == 0:
		return

	var workspace = get_tree().current_scene
	if not workspace.has_node("SelectionMarkers"):
		return

	var markers = workspace.get_node("SelectionMarkers")
	if not markers.has_meta("target_objects"):
		return

	var tool_mode = markers.get_meta("tool_mode") if markers.has_meta("tool_mode") else ToolType.NONE

	for obj_marker in markers.get_children():
		if not obj_marker.has_meta("target_object"):
			continue

		var obj = obj_marker.get_meta("target_object")
		if not is_instance_valid(obj):
			obj_marker.queue_free()
			continue

		var aabb = get_object_aabb(obj)
		if not aabb:
			continue

		var center = obj.global_transform * aabb.get_center()
		match tool_mode:
			ToolType.MOVE:
				update_move_gizmos(obj_marker, center, obj, aabb)
			ToolType.RESIZE:
				update_resize_gizmos(obj_marker, center, obj, aabb)
			ToolType.ROTATE:
				update_rotate_gizmos(obj_marker, center, obj, aabb)
			_:
				pass

func update_resize_gizmos(markers: Node3D, center: Vector3, obj: Node3D, aabb: AABB):
	var world_transform = obj.global_transform
	for i in range(min(6, markers.get_child_count())):
		var gizmo = markers.get_child(i)
		gizmo.global_position = center + world_transform.basis * _face_offset(aabb, i, 0.2)

func update_move_gizmos(markers: Node3D, center: Vector3, obj: Node3D, aabb: AABB):
	var world_transform = obj.global_transform
	for i in range(min(6, markers.get_child_count())):
		var gizmo = markers.get_child(i)
		gizmo.global_position = center + world_transform.basis * _face_offset(aabb, i, 0.4)
		gizmo.global_transform.basis = world_transform.basis * _arrow_basis(i)

func update_rotate_gizmos(markers: Node3D, center: Vector3, obj: Node3D, aabb: AABB):
	var world_transform = obj.global_transform
	var obj_rot = world_transform.basis.orthonormalized()
	var ring_radius = _rotate_ring_radius(obj, aabb)

	for i in range(min(3, markers.get_child_count())):
		var ring = markers.get_child(i)
		ring.global_position = center
		ring.global_transform.basis = _rotate_ring_basis(obj_rot, i, ring_radius)

		if ring.mesh is TorusMesh:
			ring.mesh.inner_radius = ring_radius
			ring.mesh.outer_radius = ring_radius + 0.08
		ring.set_meta("ring_center", center)
		ring.set_meta("ring_normal", (obj_rot * _axis_unit(i)).normalized())
		ring.set_meta("ring_radius", ring_radius)


## Also used by the resize tool.
func get_object_aabb(obj: Node3D) -> AABB:
	return BuildSelectable.get_aabb(obj)

## Also called by the resize tool.
func _refresh_brick_uv(obj: Node) -> void:
	if obj.has_method("update_uv_scale"):
		obj.update_uv_scale()
	for child in obj.get_children():
		if child is Node3D:
			_refresh_brick_uv(child)

func get_selected_object() -> Node3D:
	if selected_objects.size() > 0:
		return selected_objects[0]
	return null

## In GROUP mode a part directly under a workspace child is replaced by that parent.
func set_selection_mode(mode: SelectionMode):
	selection_mode = mode
	print("Selection mode changed to: ", "GROUP" if mode == SelectionMode.GROUP else "PART")

	if selected_objects.size() == 0:
		return
	var current_selections = selected_objects.duplicate()
	deselect_all_objects()

	var new_selections: Array[Node3D] = []
	for current_selection in current_selections:
		var choice = current_selection
		if mode == SelectionMode.GROUP:
			var parent = current_selection.get_parent()
			if parent and parent.get_parent() and parent.get_parent().name == "workspace":
				choice = parent
		if choice not in new_selections:
			new_selections.append(choice)

	if new_selections.size() > 0:
		select_objects(new_selections)

func get_selection_mode() -> SelectionMode:
	return selection_mode

## Undoable through the history; freed directly when there is none.
func delete_selected_objects():
	if selected_objects.size() == 0:
		return

	var objects_to_delete = selected_objects.duplicate()
	var count = objects_to_delete.size()

	deselect_all_objects()

	var history = get_history()
	if history:
		history.delete_nodes(objects_to_delete, "Delete objects")
	else:
		for obj in objects_to_delete:
			if is_instance_valid(obj):
				obj.queue_free()

	print("Deleted ", count, " object(s)")

## Rings by screen distance to their rim, others within 0.5 of the ray or 30 px on screen.
func get_gizmo_at_mouse(mouse_pos: Vector2) -> MeshInstance3D:
	var camera = get_viewport().get_camera_3d()
	if selected_objects.size() == 0 or not camera:
		return null

	var workspace = get_tree().current_scene
	if not workspace.has_node("SelectionMarkers"):
		return null

	var markers = workspace.get_node("SelectionMarkers")
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000.0

	var closest_gizmo: MeshInstance3D = null
	var closest_distance = INF
	for obj_markers in markers.get_children():
		for gizmo in obj_markers.get_children():
			if not (gizmo is MeshInstance3D):
				continue
			var distance = _gizmo_pick_distance(gizmo, camera, mouse_pos, from, to)
			if distance < closest_distance:
				closest_gizmo = gizmo
				closest_distance = distance

	return closest_gizmo

func _gizmo_pick_distance(gizmo: MeshInstance3D, camera: Camera3D, mouse_pos: Vector2, from: Vector3, to: Vector3) -> float:
	var click_radius_3d = 0.5
	var click_radius_screen = 30.0
	var is_clickable := false
	var combined_distance := INF

	if gizmo.get_meta("gizmo_type", "") == "rotate":
		# Rings share a centre, so measure to the rim instead.
		var c = gizmo.get_meta("ring_center", gizmo.global_position)
		var n = gizmo.get_meta("ring_normal", Vector3.UP)
		var r = gizmo.get_meta("ring_radius", 1.0)
		var screen_distance = _ring_screen_distance(camera, mouse_pos, c, n, r)
		is_clickable = screen_distance < click_radius_screen
		combined_distance = screen_distance
	else:
		var gizmo_pos = gizmo.global_position
		var distance_to_ray = point_distance_to_ray(gizmo_pos, from, to - from)
		var screen_distance = mouse_pos.distance_to(camera.unproject_position(gizmo_pos))
		is_clickable = (distance_to_ray < click_radius_3d) or (screen_distance < click_radius_screen)
		combined_distance = screen_distance * 0.01 + distance_to_ray

	return combined_distance if is_clickable else INF

func _ring_screen_distance(camera: Camera3D, mouse_pos: Vector2, center: Vector3, normal: Vector3, radius: float) -> float:
	var n = normal.normalized()
	var u = n.cross(Vector3.RIGHT)
	if u.length() < 0.001:
		u = n.cross(Vector3.UP)
	u = u.normalized()
	var v = n.cross(u).normalized()

	var best := INF
	var samples := 48
	for i in range(samples):
		var ang = TAU * float(i) / float(samples)
		var world_pt = center + (u * cos(ang) + v * sin(ang)) * radius
		if camera.is_position_behind(world_pt):
			continue
		var screen_pt = camera.unproject_position(world_pt)
		var d = mouse_pos.distance_to(screen_pt)
		if d < best:
			best = d
	return best

func point_distance_to_ray(point: Vector3, ray_origin: Vector3, ray_direction: Vector3) -> float:
	var ray_dir_normalized = ray_direction.normalized()
	var to_point = point - ray_origin
	var projection = to_point.dot(ray_dir_normalized)
	if projection < 0:
		return INF

	var closest_point = ray_origin + ray_dir_normalized * projection
	return point.distance_to(closest_point)

func start_gizmo_drag(gizmo: MeshInstance3D, mouse_pos: Vector2):
	is_dragging = true
	dragged_sphere = gizmo
	drag_start_mouse_pos = mouse_pos

	var history = get_history()
	_drag_history_token = history.begin_transform(selected_objects) if history else []
	drag_axis = gizmo.get_meta("axis", 0)
	drag_direction = gizmo.get_meta("direction", 1)

	drag_initial_states.clear()
	for obj in selected_objects:
		drag_initial_states.append({
			"object": obj,
			"scale": obj.scale,
			"position": obj.global_position,
			"basis": obj.global_transform.basis
		})

	if selected_objects.size() > 0:
		drag_start_object_basis = selected_objects[0].global_transform.basis

	drag_start_gizmo_pos = gizmo.global_position

	var active_camera = get_viewport().get_camera_3d()
	if active_camera:
		drag_screen_axis_dir = _screen_axis_dir(active_camera)

	if gizmo.get_meta("gizmo_type", "") == "rotate" and active_camera:
		rotate_ring_center = gizmo.get_meta("ring_center", gizmo.global_position)
		rotate_ring_normal = gizmo.get_meta("ring_normal", Vector3.UP)
		rotate_total_angle = 0.0
		var center_screen = active_camera.unproject_position(rotate_ring_center)
		rotate_last_screen_angle = (mouse_pos - center_screen).angle()

	var material = gizmo.material_override.duplicate()
	material.albedo_color = DRAG_GIZMO_COLOR
	gizmo.material_override = material

	var gizmo_type = gizmo.get_meta("gizmo_type") if gizmo.has_meta("gizmo_type") else "resize"
	print("Started dragging ", gizmo_type, " gizmo on axis ", drag_axis, " direction ", drag_direction, " for ", selected_objects.size(), " object(s)")

func _screen_axis_dir(camera: Camera3D) -> Vector2:
	var gizmo_screen = camera.unproject_position(drag_start_gizmo_pos)
	var local_offset = Vector3.ZERO
	local_offset[drag_axis] = drag_direction * 1.0
	var test_world_pos = drag_start_gizmo_pos + drag_start_object_basis * local_offset
	return (camera.unproject_position(test_world_pos) - gizmo_screen).normalized()

func stop_gizmo_drag():
	if dragged_sphere and is_instance_valid(dragged_sphere):
		_restore_gizmo_color(dragged_sphere)

	var history = get_history()
	if history and not _drag_history_token.is_empty():
		var action = "Transform"
		if dragged_sphere and is_instance_valid(dragged_sphere):
			match dragged_sphere.get_meta("gizmo_type", ""):
				"move": action = "Move"
				"resize": action = "Resize"
				"rotate": action = "Rotate"
		history.commit_transform(_drag_history_token, action)
	_drag_history_token = []

	is_dragging = false
	dragged_sphere = null
	drag_initial_states.clear()

	if selected_objects.size() > 0:
		objects_selected.emit(selected_objects)

	print("Stopped dragging gizmo")

func _restore_gizmo_color(gizmo: MeshInstance3D):
	var gizmo_type = gizmo.get_meta("gizmo_type") if gizmo.has_meta("gizmo_type") else "resize"
	var material = gizmo.material_override.duplicate()

	match gizmo_type:
		"resize":
			material.albedo_color = RESIZE_GIZMO_COLOR
		"move":
			var axis = gizmo.get_meta("axis")
			material.albedo_color = MOVE_GIZMO_COLORS[axis]
		"rotate":
			var axis = gizmo.get_meta("axis")
			var colors = [Color(1, 0, 0, 0.8), Color(0, 1, 0, 0.8), Color(0, 0, 1, 0.8)]
			material.albedo_color = colors[axis]

	gizmo.material_override = material

func update_gizmo_drag(mouse_pos: Vector2):
	if not is_dragging or selected_objects.size() == 0 or not dragged_sphere:
		return

	var active_camera = get_viewport().get_camera_3d()
	if not active_camera:
		return

	var gizmo_type = dragged_sphere.get_meta("gizmo_type") if dragged_sphere.has_meta("gizmo_type") else "resize"

	match gizmo_type:
		"resize":
			update_resize_drag(mouse_pos)
		"move":
			update_move_drag(mouse_pos)
		"rotate":
			update_rotate_drag(mouse_pos)

func update_resize_drag(mouse_pos: Vector2):
	var increment = get_increment_value()
	var resize_both_directions = get_resize_both_directions()

	# The screen axis is fixed at drag start so moving gizmos cannot feed back into the drag.
	var mouse_delta = mouse_pos - drag_start_mouse_pos
	var movement_along_axis = mouse_delta.dot(drag_screen_axis_dir)
	var scale_delta_raw = movement_along_axis * DRAG_SENSITIVITY
	if resize_both_directions:
		scale_delta_raw *= 2.0

	var scale_delta = round(scale_delta_raw / increment) * increment

	for state in drag_initial_states:
		var obj = state.object
		if not is_instance_valid(obj):
			continue
		_resize_from_state(obj, state, scale_delta, resize_both_directions)

## Keeps the opposite face (or the centre, both directions) in place; min scale 0.05.
func _resize_from_state(obj: Node3D, state: Dictionary, scale_delta: float, both_directions: bool):
	var start_xform = Transform3D(state.basis, state.position)
	var aabb = get_object_aabb(obj)

	var anchor_local = aabb.get_center()
	if not both_directions:
		anchor_local[drag_axis] = aabb.get_center()[drag_axis] - drag_direction * (aabb.size[drag_axis] / 2.0)
	var anchor_world = start_xform * anchor_local

	var before_frame: Transform3D = obj.global_transform
	var new_scale = state.scale
	new_scale[drag_axis] = max(0.05, state.scale[drag_axis] + scale_delta)
	obj.scale = new_scale

	obj.global_position += anchor_world - obj.global_transform * anchor_local

	obj.global_transform = BuildPlots.constrain(get_tree().current_scene, obj, obj.global_transform, before_frame)

	# Not left to the brick's transform notification alone.
	_refresh_brick_uv(obj)

func update_move_drag(mouse_pos: Vector2):
	var increment = get_move_increment_value()

	var mouse_delta = mouse_pos - drag_start_mouse_pos
	var movement_along_axis = mouse_delta.dot(drag_screen_axis_dir)
	var move_delta_raw = movement_along_axis * DRAG_SENSITIVITY * drag_direction
	var move_delta = round(move_delta_raw / increment) * increment

	for state in drag_initial_states:
		var obj = state.object
		if not is_instance_valid(obj):
			continue

		var local_axis = Vector3.ZERO
		local_axis[drag_axis] = 1.0
		var world_axis = state.basis * local_axis
		var movement_vector = world_axis.normalized() * move_delta

		_settle(obj, Transform3D(obj.global_transform.basis, state.position + movement_vector), drag_axis != 1)

func update_rotate_drag(mouse_pos: Vector2):
	var increment_deg = get_rotate_increment_value()
	var increment_rad = deg_to_rad(increment_deg)

	var active_camera = get_viewport().get_camera_3d()
	if not active_camera:
		return

	var center_screen = active_camera.unproject_position(rotate_ring_center)
	var screen_angle = (mouse_pos - center_screen).angle()

	# Accumulate wrapped per-frame deltas so turns can pass 180 degrees.
	var delta = wrapf(screen_angle - rotate_last_screen_angle, -PI, PI)
	rotate_last_screen_angle = screen_angle
	rotate_total_angle += delta

	# Screen angles grow clockwise (Y down); flip when viewing the ring's back.
	var to_cam = (active_camera.global_position - rotate_ring_center).normalized()
	var facing = signf(rotate_ring_normal.dot(to_cam))
	if facing == 0.0:
		facing = 1.0
	var rotation_amount = -facing * rotate_total_angle

	var rotation_snapped = round(rotation_amount / increment_rad) * increment_rad

	for state in drag_initial_states:
		var obj = state.object
		if not is_instance_valid(obj):
			continue

		var this_world_axis = (state.basis.orthonormalized() * _axis_unit(drag_axis)).normalized()
		var rotation_delta = Basis(this_world_axis, rotation_snapped)
		BuildPlots.apply(get_tree().current_scene, obj, Transform3D(rotation_delta * state.basis, obj.global_position))

func _tool_value(panel: String, property: String, fallback):
	var workspace = get_tree().current_scene
	if not workspace:
		return fallback

	var tool = workspace.get_node_or_null("UI/BuildUI/" + panel)
	if not tool:
		return fallback

	if tool.has_method("get") and property in tool:
		return tool.get(property)

	return fallback

func get_increment_value() -> float:
	return _tool_value("ResizeTool", "increment_length", 0.1)

func get_move_increment_value() -> float:
	return _tool_value("MoveTool", "increment_length", 0.1)

func get_rotate_increment_value() -> float:
	return _tool_value("RotateTool", "increment_degrees", 15.0)

func get_resize_both_directions() -> bool:
	return _tool_value("ResizeTool", "resize_both_directions", false)

func raycast_from_mouse(mouse_pos: Vector2) -> Dictionary:
	return BuildTargeting.raycast(self, mouse_pos)

func start_waiting_for_drag(mouse_pos: Vector2, hit_position: Vector3):
	is_waiting_for_drag = true
	object_drag_start_time = Time.get_ticks_msec() / 1000.0
	object_drag_start_mouse_pos = mouse_pos

	drag_initial_states.clear()
	for obj in selected_objects:
		drag_initial_states.append({
			"object": obj,
			"position": obj.global_position
		})

	if selected_objects.size() > 0:
		object_drag_initial_pos = selected_objects[0].global_position

	object_drag_plane_point = hit_position

	if selected_objects.size() > 0:
		object_drag_offset = hit_position - selected_objects[0].global_position

	var active_camera = get_viewport().get_camera_3d()
	if active_camera:
		object_drag_plane_normal = -active_camera.global_transform.basis.z

	print("Waiting for drag threshold...")

func check_drag_threshold(mouse_pos: Vector2):
	var distance = mouse_pos.distance_to(object_drag_start_mouse_pos)
	if distance >= drag_threshold_distance:
		activate_object_drag()

func activate_object_drag():
	if is_object_dragging:
		return

	is_waiting_for_drag = false
	is_object_dragging = true

	var history = get_history()
	_drag_history_token = history.begin_transform(selected_objects) if history else []

	var workspace = get_tree().current_scene
	if workspace.has_node("SelectionMarkers"):
		var markers = workspace.get_node("SelectionMarkers")
		markers.visible = false

	print("Started natural object dragging")

func update_object_drag(mouse_pos: Vector2):
	var active_camera = get_viewport().get_camera_3d()
	if not is_object_dragging or selected_objects.size() == 0 or not active_camera:
		return

	var from = active_camera.project_ray_origin(mouse_pos)
	var ray_dir = active_camera.project_ray_normal(mouse_pos)
	var intersection = plane_ray_intersection(object_drag_plane_point, object_drag_plane_normal, from, ray_dir)
	if not intersection:
		return

	var target_pos = intersection - object_drag_offset

	var increment = get_move_increment_value()
	if increment > 0:
		target_pos.x = round(target_pos.x / increment) * increment
		target_pos.y = round(target_pos.y / increment) * increment
		target_pos.z = round(target_pos.z / increment) * increment

	var movement_delta = target_pos - object_drag_initial_pos

	for state in drag_initial_states:
		var obj = state.object
		if is_instance_valid(obj):
			_settle(obj, Transform3D(obj.global_transform.basis, state.position + movement_delta), true)

func stop_object_drag():
	if is_object_dragging:
		print("Stopped natural object dragging")

		var history = get_history()
		if history and not _drag_history_token.is_empty():
			history.commit_transform(_drag_history_token, "Move")
		_drag_history_token = []

		var workspace = get_tree().current_scene
		if workspace.has_node("SelectionMarkers"):
			var markers = workspace.get_node("SelectionMarkers")
			markers.visible = true

		if selected_objects.size() > 0:
			objects_selected.emit(selected_objects)

	is_object_dragging = false
	is_waiting_for_drag = false

## Clamped to its plot and, with floor snap on, dropped unless the drag is vertical.
func _settle(obj: Node3D, desired: Transform3D, allow_floor_snap: bool):
	var root = get_tree().current_scene
	var allowed: Transform3D = BuildPlots.constrain(root, obj, desired, obj.global_transform)
	if allow_floor_snap and floor_snap_enabled():
		var dropped: Transform3D = BuildPlots.drop_to_floor(root, obj, allowed)
		allowed = BuildPlots.constrain(root, obj, dropped, allowed)
	obj.global_transform = allowed

func floor_snap_enabled() -> bool:
	var workspace = get_tree().current_scene
	if workspace == null:
		return false
	var move_tool = workspace.get_node_or_null("UI/BuildUI/MoveTool")
	return move_tool != null and move_tool.get("floor_snap") == true

func plane_ray_intersection(plane_point: Vector3, plane_normal: Vector3, ray_origin: Vector3, ray_direction: Vector3) -> Variant:
	var denom = plane_normal.dot(ray_direction)
	if abs(denom) < 0.0001:
		return null

	var t = (plane_point - ray_origin).dot(plane_normal) / denom
	if t < 0:
		return null

	return ray_origin + ray_direction * t
