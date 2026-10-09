extends Control

## Plot object tool panel: places furniture inside the player's plots; the server re-checks.

signal object_placed(object_type: String, position: Vector3, transform: Transform3D)

@onready var object_list_container = $ScrollContainer/ObjectList
@onready var place_btn = $ButtonContainer/PlaceButton
@onready var cancel_btn = $ButtonContainer/CancelButton
@onready var scroll_container = $ScrollContainer

var camera: Camera3D = null
var preview_instance: Node3D = null
var is_placing: bool = false
var current_object_type: String = ""
var available_objects: Dictionary = {}

## On web the folder is empty until OBJECTS_PACK mounts.
const OBJECTS_PATH := "res://assets/assets/Objects/"
const OBJECTS_PACK := "plot_objects"

var grid_size: float = 0.5

var _preview_valid: bool = false
var _preview_plot: Dictionary = {}
var _preview_tint: Color = Color.WHITE
var _preview_excludes: Array[RID] = []

var network_controller: Node = null
var selection_manager: Node = null

func _ready():
	if place_btn:
		place_btn.pressed.connect(_on_place_pressed)
	if cancel_btn:
		cancel_btn.pressed.connect(_on_cancel_pressed)

	await get_tree().process_frame
	camera = get_viewport().get_camera_3d()

	network_controller = get_node_or_null("/root/NetworkController")
	if not network_controller:
		network_controller = get_tree().root.find_child("NetworkController", true, false)

	var workspace = get_tree().current_scene
	selection_manager = workspace.get_node_or_null("SelectionManager")

	_load_available_objects()
	_populate_object_list()
	_watch_for_streamed_objects()

	if place_btn:
		place_btn.disabled = true
	if cancel_btn:
		cancel_btn.disabled = true

func _watch_for_streamed_objects():
	var pm = get_node_or_null("/root/PCKManager")
	if pm != null and pm.has_signal("content_mounted"):
		pm.content_mounted.connect(_on_content_mounted)


func _on_content_mounted(pack_name: String):
	if pack_name != OBJECTS_PACK:
		return
	var before := available_objects.size()
	_load_available_objects()
	if available_objects.size() != before:
		print("Plot objects: ", available_objects.size(), " available after '", pack_name, "' mounted")
		_populate_object_list()


func _load_available_objects():
	var objects_path = OBJECTS_PATH
	var dir = DirAccess.open(objects_path)
	available_objects.clear()

	if not dir:
		print("No Objects directory yet at: ", objects_path,
			" (waiting for the '", OBJECTS_PACK, "' pack)")
		return

	dir.list_dir_begin()
	var folder_name = dir.get_next()
	while folder_name != "":
		if dir.current_is_dir() and not folder_name.begins_with("."):
			_add_object_folder(objects_path, folder_name)
		folder_name = dir.get_next()
	dir.list_dir_end()
	print("Loaded ", available_objects.size(), " objects")

func _add_object_folder(objects_path: String, folder_name: String):
	var mesh_tscn_path = objects_path + folder_name + "/mesh.tscn"
	var mesh_glb_path = objects_path + folder_name + "/mesh.glb"

	if FileAccess.file_exists(mesh_tscn_path):
		available_objects[folder_name] = mesh_tscn_path
		print("Found object: ", folder_name, " at ", mesh_tscn_path)
	elif FileAccess.file_exists(mesh_glb_path):
		available_objects[folder_name] = mesh_glb_path
		print("Found object: ", folder_name, " at ", mesh_glb_path, " (fallback to .glb)")

func _populate_object_list():
	if not object_list_container:
		return

	for child in object_list_container.get_children():
		child.queue_free()

	for object_name in available_objects.keys():
		var preview_item = _create_preview_item(object_name)
		object_list_container.add_child(preview_item)

func _create_preview_item(object_name: String) -> Control:
	var container = PanelContainer.new()
	container.custom_minimum_size = Vector2(200, 220)

	var vbox = VBoxContainer.new()
	container.add_child(vbox)

	var viewport_container = SubViewportContainer.new()
	viewport_container.custom_minimum_size = Vector2(200, 180)
	viewport_container.stretch = true
	vbox.add_child(viewport_container)

	var viewport = _create_preview_viewport()
	viewport_container.add_child(viewport)

	var camera = Camera3D.new()
	camera.position = Vector3(0, 1, 3)
	camera.look_at(Vector3(0, 0.5, 0), Vector3.UP)
	viewport.add_child(camera)

	var mesh_path = available_objects.get(object_name, "")
	if mesh_path != "":
		_add_spinning_object(viewport, camera, object_name, mesh_path)

	var button = Button.new()
	button.custom_minimum_size = Vector2(200, 40)
	button.text = object_name
	button.pressed.connect(_on_object_selected.bind(object_name, container))
	vbox.add_child(button)

	return container

func _create_preview_viewport() -> SubViewport:
	var viewport = SubViewport.new()
	viewport.size = Vector2i(200, 180)
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true

	var world_env = WorldEnvironment.new()
	var environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.2, 0.2, 0.25, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.8, 0.8, 0.8, 1.0)
	world_env.environment = environment
	viewport.add_child(world_env)
	return viewport

func _add_spinning_object(viewport: SubViewport, camera: Camera3D, object_name: String, mesh_path: String):
	var loaded_scene = load(mesh_path)
	if not loaded_scene:
		return
	var object_instance = loaded_scene.instantiate()
	object_instance.name = object_name + "_preview"
	viewport.add_child(object_instance)

	call_deferred("_adjust_object_in_viewport", object_instance, camera)

	var rotation_timer = Timer.new()
	rotation_timer.wait_time = 0.016
	rotation_timer.autostart = true
	rotation_timer.timeout.connect(func():
		if is_instance_valid(object_instance):
			object_instance.rotate_y(0.01)
	)
	viewport.add_child(rotation_timer)

func _adjust_object_in_viewport(object_instance: Node3D, camera: Camera3D):
	await get_tree().process_frame
	await get_tree().process_frame

	var aabb = _get_world_aabb(object_instance, Transform3D.IDENTITY)

	if aabb.size.length() > 0:
		var center = aabb.get_center()
		object_instance.global_position = object_instance.global_position - center

		var max_size = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		var distance = max_size * 1.4
		camera.position = Vector3(distance * 0.7, max_size * 0.4, distance)
		camera.look_at(Vector3(0, 0, 0), Vector3.UP)
	else:
		camera.position = Vector3(2, 1, 3)
		camera.look_at(Vector3(0, 0, 0), Vector3.UP)

func _get_world_aabb(node: Node3D, parent_transform: Transform3D) -> AABB:
	var combined_aabb = AABB()
	var first = true
	var current_transform = parent_transform * node.transform

	if node is MeshInstance3D and node.mesh:
		combined_aabb = _transformed_aabb(node.mesh.get_aabb(), current_transform)
		first = false

	for child in node.get_children():
		if not (child is Node3D):
			continue
		var child_aabb = _get_world_aabb(child, current_transform)
		if child_aabb.size.length() > 0:
			if first:
				combined_aabb = child_aabb
				first = false
			else:
				combined_aabb = combined_aabb.merge(child_aabb)

	return combined_aabb

func _transformed_aabb(mesh_aabb: AABB, xform: Transform3D) -> AABB:
	var corners = [
		mesh_aabb.position,
		mesh_aabb.position + Vector3(mesh_aabb.size.x, 0, 0),
		mesh_aabb.position + Vector3(0, mesh_aabb.size.y, 0),
		mesh_aabb.position + Vector3(0, 0, mesh_aabb.size.z),
		mesh_aabb.position + Vector3(mesh_aabb.size.x, mesh_aabb.size.y, 0),
		mesh_aabb.position + Vector3(mesh_aabb.size.x, 0, mesh_aabb.size.z),
		mesh_aabb.position + Vector3(0, mesh_aabb.size.y, mesh_aabb.size.z),
		mesh_aabb.position + mesh_aabb.size
	]
	var result = AABB(xform * corners[0], Vector3.ZERO)
	for corner in corners:
		result = result.expand(xform * corner)
	return result

func _on_object_selected(object_name: String, selected_container: Control):
	current_object_type = object_name
	print("Selected object: ", object_name)
	print("Place button exists: ", place_btn != null)

	if place_btn:
		place_btn.disabled = false
		print("Place button enabled")
	else:
		print("ERROR: Place button not found!")

	for item in object_list_container.get_children():
		if item is PanelContainer:
			item.modulate = Color(1.5, 1.5, 1.0, 1.0) if item == selected_container else Color.WHITE

func _on_place_pressed():
	print("Place button pressed! is_placing: ", is_placing, " current_object_type: ", current_object_type)
	if not is_placing and current_object_type != "":
		start_placing_mode()
	else:
		finish_placing_mode()

	if place_btn:
		place_btn.release_focus()

func _on_cancel_pressed():
	cancel_placing_mode()

	if cancel_btn:
		cancel_btn.release_focus()

func start_placing_mode():
	if current_object_type == "":
		print("ERROR: No object selected")
		return

	is_placing = true
	print("Starting placement mode for: ", current_object_type)

	var mesh_path = available_objects.get(current_object_type, "")
	if mesh_path == "":
		print("ERROR: Object path not found for: ", current_object_type)
		is_placing = false
		return

	print("Loading mesh from: ", mesh_path)

	var loaded_scene = load(mesh_path)
	if loaded_scene:
		preview_instance = loaded_scene.instantiate()
		get_tree().current_scene.add_child(preview_instance)
		print("Preview instance created and added to scene")

		make_preview_transparent(preview_instance)
		disable_collision(preview_instance)
		set_collision_layer_recursive(preview_instance, 0)
		set_collision_mask_recursive(preview_instance, 0)
		_preview_excludes = BuildTargeting.collision_rids(preview_instance)
		_preview_valid = false
		_preview_plot = {}
		_preview_tint = Color.WHITE
	else:
		print("ERROR: Failed to load scene from: ", mesh_path)
		is_placing = false
		return

	if place_btn:
		place_btn.text = "Finish"
	if cancel_btn:
		cancel_btn.disabled = false

	print("Object placement mode activated for: ", current_object_type)

func finish_placing_mode():
	is_placing = false

	if preview_instance and is_instance_valid(preview_instance):
		preview_instance.queue_free()
		preview_instance = null

	if place_btn:
		place_btn.text = "Place"
	if cancel_btn:
		cancel_btn.disabled = true

	print("Object placement mode finished")

func cancel_placing_mode():
	finish_placing_mode()

func _process(_delta):
	if not visible or not is_placing:
		return
	update_preview_position()

func _unhandled_input(event):
	if not visible:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed and is_placing:
			place_object()
			get_viewport().set_input_as_handled()

	elif event is InputEventKey:
		if event.keycode == KEY_ESCAPE and event.pressed and is_placing:
			cancel_placing_mode()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_R and event.pressed and is_placing and preview_instance:
			preview_instance.rotate_y(deg_to_rad(15))
			get_viewport().set_input_as_handled()

func update_preview_position():
	if not preview_instance:
		return
	camera = BuildTargeting.active_camera(self)
	if not camera:
		return

	var mouse_pos = get_viewport().get_mouse_position()
	var hit = BuildTargeting.raycast(self, mouse_pos, _preview_excludes)
	var scene_root = get_tree().current_scene
	var aabb = BuildSelectable.get_aabb(preview_instance)
	var xform: Transform3D
	if hit:
		xform = BuildSnapping.place_on_face(hit.position, hit.normal, preview_instance.global_transform.basis, aabb, grid_size)
	else:
		var from = camera.project_ray_origin(mouse_pos)
		xform = Transform3D(preview_instance.global_transform.basis, snap_to_grid(from + camera.project_ray_normal(mouse_pos) * 10.0))
	preview_instance.global_transform = xform
	preview_instance.visible = true

	_update_preview_validity(scene_root, xform)
	_tint_preview(Color.WHITE if _preview_valid else Color(1.0, 0.35, 0.3))

## Valid in the offline sandbox, or when the whole box fits an owned plot.
func _update_preview_validity(scene_root: Node, xform: Transform3D):
	_preview_valid = false
	_preview_plot = {}
	if BuildPlots.sandbox(scene_root):
		_preview_valid = true
		return
	var owned = BuildPlots.owned_plot_ids(scene_root)
	var plot = BuildPlots.plot_at(scene_root, xform.origin, owned)
	if plot.is_empty():
		for candidate in BuildPlots.all_plots(scene_root):
			if str(candidate.id) in owned and BuildPlots.fits_object(scene_root, preview_instance, xform, candidate):
				plot = candidate
				break
	if not plot.is_empty() and BuildPlots.fits_object(scene_root, preview_instance, xform, plot):
		_preview_valid = true
		_preview_plot = plot

func place_object():
	if not preview_instance:
		return

	var mesh_path = available_objects.get(current_object_type, "")
	if mesh_path == "":
		return

	var workspace = get_tree().current_scene
	var global_pos = preview_instance.global_position
	var global_rot = preview_instance.global_rotation

	if not can_place_at_position(global_pos):
		print("Cannot place object here - not in your plot or not authenticated")
		return
	if not _preview_valid:
		print("Cannot place object here - it would stick out of your plot")
		_flash_help("That spot is outside your plot (or the piece would poke out of it).")
		return

	var loaded_scene = load(mesh_path)
	if not loaded_scene:
		print("Failed to load object scene")
		return

	var new_object = loaded_scene.instantiate()
	workspace.add_child(new_object)

	var local_pos = workspace.global_transform.affine_inverse() * global_pos
	new_object.position = local_pos
	new_object.rotation = global_rot

	var net_id = "plot_obj_" + str(Time.get_ticks_msec()) + "_" + str(randi())
	new_object.name = net_id

	new_object.set_meta("object_type", current_object_type)
	new_object.set_meta("is_plot_object", true)
	# Needed at once to keep the piece inside; plot_object_spawn confirms or corrects it.
	if not _preview_plot.is_empty():
		new_object.set_meta("plot_id", str(_preview_plot.id))

	if network_controller:
		network_controller.objects.track_object(net_id, new_object)

	print("Placed plot object: ", current_object_type, " at global: ", global_pos)

	send_place_object_to_server(net_id, new_object.global_transform, global_pos)

	object_placed.emit(current_object_type, global_pos, new_object.global_transform)

## Checks only the login; the plot fit is _preview_valid.
func can_place_at_position(position: Vector3) -> bool:
	if not network_controller:
		return false

	var username = network_controller.get("local_username")
	if not username or username == "" or username.begins_with("Guest"):
		print("Not authenticated - cannot place objects")
		return false

	return true

func send_place_object_to_server(net_id: String, xform: Transform3D, position: Vector3):
	if not network_controller:
		print("NetworkController not found, cannot send placement to server")
		return

	if not network_controller.has_method("send_json"):
		print("NetworkController doesn't have send_json method")
		return

	var payload = {}
	var placed = network_controller.objects.object_by_id(net_id) if network_controller.get("objects") != null else null
	if placed != null and is_instance_valid(placed):
		payload = BuildPlots.payload(get_tree().current_scene, placed, xform)

	var message = {
		"type": "place_plot_object",
		"net_id": net_id,
		"object_type": current_object_type,
		"plot_id": payload.get("plot_id", ""),
		"local": payload.get("local", {}),
		"footprint": payload.get("footprint", []),
		"position": {
			"x": position.x,
			"y": position.y,
			"z": position.z
		},
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

	network_controller.send_json(message)
	print("Sent plot object placement to server: ", net_id)

func snap_to_grid(pos: Vector3) -> Vector3:
	return BuildSnapping.snap_vec3(pos, grid_size)

## The overrides are already the preview's own copies.
func _tint_preview(color: Color):
	if color == _preview_tint or not preview_instance:
		return
	_preview_tint = color
	var stack: Array = [preview_instance]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			_tint_mesh(node, color)
		for child in node.get_children():
			stack.push_back(child)

func _tint_mesh(node: MeshInstance3D, color: Color):
	for i in range(node.get_surface_override_material_count()):
		var mat = node.get_surface_override_material(i)
		if mat is StandardMaterial3D:
			mat.albedo_color = Color(color.r, color.g, color.b, mat.albedo_color.a)

func _flash_help(text: String):
	var label = get_node_or_null("HelpLabel")
	if label == null:
		return
	var previous: String = label.text
	label.text = text
	label.modulate = Color(1.0, 0.6, 0.5)
	await get_tree().create_timer(2.5).timeout
	if is_instance_valid(label) and label.text == text:
		label.text = previous
		label.modulate = Color.WHITE

func make_preview_transparent(node: Node):
	if node is MeshInstance3D:
		for i in range(node.get_surface_override_material_count()):
			var mat = node.get_surface_override_material(i)
			if mat:
				node.set_surface_override_material(i, _translucent_copy(mat))

		if node.mesh:
			_translucent_mesh_materials(node)

	for child in node.get_children():
		make_preview_transparent(child)

func _translucent_mesh_materials(node: MeshInstance3D):
	for i in range(node.mesh.get_surface_count()):
		if node.get_surface_override_material(i) != null:
			continue
		var mat = node.mesh.surface_get_material(i)
		if mat:
			node.set_surface_override_material(i, _translucent_copy(mat))

func _translucent_copy(mat: Material) -> Material:
	mat = mat.duplicate()
	if mat is StandardMaterial3D:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.5
	return mat

func disable_collision(node: Node):
	if node is StaticBody3D or node is RigidBody3D or node is CharacterBody3D:
		for child in node.get_children():
			if child is CollisionShape3D or child is CollisionPolygon3D:
				child.disabled = true

	for child in node.get_children():
		disable_collision(child)

func set_collision_layer_recursive(node: Node, layer: int):
	if node is CollisionObject3D:
		node.collision_layer = layer

	for child in node.get_children():
		set_collision_layer_recursive(child, layer)

func set_collision_mask_recursive(node: Node, mask: int):
	if node is CollisionObject3D:
		node.collision_mask = mask

	for child in node.get_children():
		set_collision_mask_recursive(child, mask)

func _notification(what):
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if not visible and is_placing:
			cancel_placing_mode()
