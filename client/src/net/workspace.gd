## Workspace: the scene the player is in; default character scenes, plots, places and the studio save.
class_name NetWorkspace
extends RefCounted

const STUDIO_SCENE_PATH := "user://studio_workspace.tscn"
const NetworkControllerScript := preload("res://src/net/network_controller.gd")

var humanoid_scene: PackedScene
var countryball_scene: PackedScene
var countryball_oneside_scene: PackedScene
var countryball_qwc_scene: PackedScene
## The server's plots_info list.
var all_plots = []

var _nc: NetworkControllerScript = null


func _init(controller: NetworkControllerScript):
	_nc = controller


func register_handlers() -> void:
	_nc.register_handler("plots_info", _msg_plots_info)
	_nc.register_handler("place_info", _on_place_info)
	_nc.register_handler("places_list", _on_places_list)


func load_default_scenes():
	if humanoid_scene == null:
		humanoid_scene = load("res://assets/entities/character/humanoid.tscn")
	if countryball_scene == null:
		countryball_scene = load("res://assets/entities/countryball/countryball.tscn")
	if countryball_oneside_scene == null:
		countryball_oneside_scene = load("res://assets/entities/countryball/countryballoneside.tscn")
	if countryball_qwc_scene == null:
		countryball_qwc_scene = load(CountryballTypes.scene_path(CountryballTypes.QWC))


func find_workspace():
	var workspace = _nc.get_tree().get_root().find_child("workspace", true, false)
	if not workspace:
		workspace = _nc.get_tree().get_root().find_child("localworkspace", true, false)
	return workspace


func _msg_plots_info(data) -> void:
	var plots = data.plots
	print("NetworkController: ===== RECEIVED PLOTS INFO =====")
	print("NetworkController: ", plots.size(), " plots received")
	print("NetworkController: Current username = ", _nc.local_username)
	all_plots = plots
	check_user_plot()


## From the server's plots_info.
func owned_plot_ids() -> Array:
	var ids := []
	if _nc.local_username == "" or _nc.local_username.begins_with("Guest"):
		return ids
	for plot_info in all_plots:
		if str(plot_info.get("owner", "")).to_lower() == _nc.local_username.to_lower():
			ids.append(str(plot_info.get("plot_id", "")))
	return ids


func check_user_plot():
	if all_plots.is_empty():
		print("NetworkController: No plots stored to check")
		return
	var ids := owned_plot_ids()
	if ids.is_empty():
		print("NetworkController: no plot owned by ", _nc.local_username, " (", all_plots.size(), " plots listed)")
	else:
		print("NetworkController: ", _nc.local_username, " owns plots ", ids)
	var workspace = _nc.get_tree().current_scene
	if not workspace:
		return
	var plot_ui_vis = workspace.get_node_or_null("PlotUIVisibility")
	if plot_ui_vis and plot_ui_vis.has_method("set_owned_plots"):
		plot_ui_vis.set_owned_plots(ids)
	else:
		print("NetworkController: ✗ PlotUIVisibility node not found or missing method")


func _on_places_list(data):
	var places = data.places
	print("Available places: ", places)

	var chat_ui = _nc.get_tree().root.find_child("ChatUI", true, false)
	if not chat_ui or not chat_ui.has_method("add_message"):
		return
	if places.size() == 0:
		chat_ui.add_message("System", "No places available", true)
		return
	chat_ui.add_message("System", "Available places:", true)
	for place_name in places:
		chat_ui.add_message("System", "  - " + place_name + " (use /join " + place_name + ")", true)


func request_places_list():
	if not _nc.connected:
		print("Not connected to server")
		return

	_nc.send_json({
		"type": "list_places"
	})


func join_place(place_name: String):
	if not _nc.connected:
		print("Not connected to server")
		return

	print("Requesting to join place: ", place_name)
	_nc.send_json({
		"type": "join_place",
		"place_name": place_name
	})


## Saves a place's scene under user://places and moves to its server.
func _on_place_info(data):
	var place_name = data.place_name
	var place_server_url = data.server_url
	var scene_data = data.scene_data

	print("Received place info for: ", place_name)
	print("Place server URL: ", place_server_url)

	var scene_path = "user://places/" + place_name + ".tscn"
	var dir = DirAccess.open("user://")
	if not dir.dir_exists("user://places"):
		dir.make_dir("user://places")

	var file = FileAccess.open(scene_path, FileAccess.WRITE)
	if file:
		file.store_string(scene_data)
		file.close()
		print("Saved place scene to: ", scene_path)

	_switch_to_place_server(place_server_url, scene_path)


## Also connects to the place server and sends this player's identity.
func _switch_to_place_server(new_server_url: String, scene_path: String):
	print("Switching to place server: ", new_server_url)
	print("Loading scene: ", scene_path)

	var username = _nc.local_username

	_nc.close_socket()
	_nc.players.remove_all()

	var workspace = _nc.get_tree().get_root().find_child("workspace", true, false)
	if workspace:
		await _enter_place_scene(workspace, scene_path)

	_nc.pin_server(new_server_url)

	await _nc.get_tree().create_timer(0.5).timeout
	_nc.connect_to_server()
	await _nc.get_tree().create_timer(0.5).timeout

	if not _nc.connected:
		return
	_nc.send_json({
		"type": "set_identity",
		"username": username,
		"texture": _nc.players.user_texture,
		"character_type": _nc.players.user_character_type,
		"accessories": _nc.players.user_accessories
	})
	print("Sent identity to place server: ", username, " (", _nc.players.user_character_type, ") with texture: ", _nc.players.user_texture, " and accessories: ", _nc.players.user_accessories)

	await _nc.get_tree().create_timer(0.1).timeout
	_nc.session.update_voice_username()


func _enter_place_scene(workspace: Node, scene_path: String):
	for child in workspace.get_children():
		if child.name not in ["NetworkController", "Players", "humanoid", "countryball", "countryball_oneside", "RainSystem", "UI"]:
			child.queue_free()

	await _nc.get_tree().process_frame

	var ui_node = workspace.get_node_or_null("UI")
	if ui_node:
		_free_ui_child(ui_node, "BuildUI", "  Removing BuildUI from lobby UI before entering place")
		_free_ui_child(ui_node, "BackpackUI", "  Removing BackpackUI from lobby UI")
		_free_ui_child(ui_node, "ModeToggleUI", "  Removing ModeToggleUI from lobby UI")
		_free_ui_child(ui_node, "NetworkUI", "  Removing ModeToggleUI from lobby UI")

	await _nc.get_tree().process_frame

	var place_scene = load(scene_path)
	if not place_scene:
		print("Failed to load place scene")
		return

	var place_root = place_scene.instantiate()
	print("Transferring place content to workspace...")
	for child in place_root.get_children():
		var child_name = child.name
		if child_name == "UI":
			print("  Skipping UI node from place (using lobby UI instead)")
			continue
		elif child_name == "BuildUI":
			print("  Skipping BuildUI from place")
			continue
		elif child_name == "ChatUI":
			print("  Skipping ChatUI from place")
			continue

		place_root.remove_child(child)
		workspace.add_child(child)
		print("  Added: ", child_name)

	place_root.queue_free()
	_apply_checkpoint_spawn(workspace)
	print("Loaded place scene successfully")


func _free_ui_child(ui_node: Node, child_name: String, log_line: String):
	var child = ui_node.get_node_or_null(child_name)
	if child:
		print(log_line)
		child.queue_free()


## After 0.2 s, to "Checkpoint" or (0, 10, 0); without a player yet it waits for the spawn.
func _apply_checkpoint_spawn(workspace: Node):
	var checkpoint = workspace.get_node_or_null("Checkpoint")
	var spawn_position = Vector3(0, 10, 0)

	if checkpoint:
		spawn_position = checkpoint.global_position
		print("Found Checkpoint at: ", spawn_position)
	else:
		print("No Checkpoint found, using default spawn position: ", spawn_position)

	await _nc.get_tree().create_timer(0.2).timeout

	if _nc.players.local_player:
		_nc.players.local_player.global_position = spawn_position
		print("Teleported local player to checkpoint")
	else:
		_nc.players.pending_spawn_position = spawn_position
		print("Player not ready yet, will apply spawn position when created")


## No system nodes, players or cameras.
func save_studio_workspace():
	var workspace = find_workspace()
	if not workspace:
		print("No workspace found to save")
		_nc.chat.chat_ui_notice("No workspace found to save")
		return false

	print("Saving studio workspace to user://...")
	print("Workspace children count: ", workspace.get_child_count())

	var clean_workspace = Node3D.new()
	clean_workspace.name = "workspace"
	clean_workspace.transform = Transform3D.IDENTITY
	print("  Created clean workspace node")

	var saved_count = _copy_studio_content(workspace, clean_workspace)
	print("Clean workspace now has ", clean_workspace.get_child_count(), " children")

	var packed_scene = PackedScene.new()
	var result = packed_scene.pack(clean_workspace)
	clean_workspace.queue_free()
	if result != OK:
		print("Failed to pack scene: ", result)
		_nc.chat.chat_ui_notice("Failed to save studio workspace")
		return false

	result = ResourceSaver.save(packed_scene, STUDIO_SCENE_PATH)
	if result != OK:
		print("Failed to save packed scene: ", result)
		_nc.chat.chat_ui_notice("Failed to save studio workspace to file")
		return false

	var file_check = FileAccess.open(STUDIO_SCENE_PATH, FileAccess.READ)
	var file_size = 0
	if file_check:
		file_size = file_check.get_length()
		file_check.close()

	print("Studio workspace saved to: ", STUDIO_SCENE_PATH)
	print("File size: ", file_size, " bytes (", file_size / 1024.0, " KB)")
	_nc.chat.chat_ui_notice("Studio workspace saved! (" + str(saved_count) + " objects, " + str(file_size / 1024.0).pad_decimals(1) + " KB)")
	return true


## Returns how many were copied.
func _copy_studio_content(workspace: Node, clean_workspace: Node) -> int:
	var saved_count = 0
	var skipped_count = 0
	for child in workspace.get_children():
		var child_name = child.name
		print("  Checking child: ", child_name, " (type: ", child.get_class(), ")")
		var skip_reason := _studio_skip_reason(child)
		if skip_reason != "":
			print(skip_reason, child_name)
			skipped_count += 1
			continue

		print("    -> Duplicating child: ", child_name)
		var child_duplicate = child.duplicate(Node.DUPLICATE_USE_INSTANTIATION)
		if child_duplicate:
			clean_workspace.add_child(child_duplicate)
			_set_owner_recursive(child_duplicate, clean_workspace)
			saved_count += 1
			print("       ✓ Added (children: ", child_duplicate.get_child_count(), ", owner: ", child_duplicate.owner, ")")
		else:
			print("       ✗ Failed to duplicate")

	print("Summary: Saved ", saved_count, " nodes, skipped ", skipped_count, " nodes")
	return saved_count


## "" when the child is saved.
func _studio_skip_reason(child: Node) -> String:
	var child_name = child.name
	if child_name in ["UI", "NetworkController", "Players", "humanoid", "countryball",
			"countryball_oneside", "LocalPlayer", "AuthManager", "TextureManager", "RainSystem",
			"SelectionManager", "ToolManager", "CameraManager", "OBJExporter", "FreeCamera",
			"AudioStreamPlayer"]:
		return "    -> Skipping system node: "
	if child == _nc.players.local_player:
		return "    -> Skipping local player: "
	if child_name.contains("Camera") or child_name.contains("XR") or child_name.contains("Cam"):
		return "    -> Skipping camera/XR node: "
	return ""


func _set_owner_recursive(node: Node, owner_node: Node):
	node.owner = owner_node
	for child in node.get_children():
		_set_owner_recursive(child, owner_node)


## Keeps (or finds, or spawns) the local player.
func load_studio_workspace():
	if not FileAccess.file_exists(STUDIO_SCENE_PATH):
		print("No saved studio workspace found")
		_nc.chat.chat_ui_notice("No saved studio workspace found")
		return false

	print("Loading studio workspace from: ", STUDIO_SCENE_PATH)

	var workspace = find_workspace()
	if not workspace:
		print("No workspace node found")
		return false

	_clear_studio_content(workspace)
	await _nc.get_tree().process_frame

	var place_scene = load(STUDIO_SCENE_PATH)
	if not place_scene:
		print("Failed to load studio workspace scene")
		_nc.chat.chat_ui_notice("Failed to load studio workspace")
		return false

	var place_root = place_scene.instantiate()
	print("Loaded workspace has ", place_root.get_child_count(), " children")
	var loaded_count = _move_studio_content(place_root, workspace)
	place_root.queue_free()

	await _nc.get_tree().process_frame

	_restore_local_player_after_load(workspace)
	_nc.refresh_rain_player()

	print("Studio workspace loaded successfully")
	if loaded_count > 0:
		_nc.chat.chat_ui_notice("Studio workspace loaded! (" + str(loaded_count) + " objects)")
	else:
		_nc.chat.chat_ui_notice("Studio workspace loaded (empty workspace)")
	return true


func _clear_studio_content(workspace: Node):
	for child in workspace.get_children():
		if child.name in ["NetworkController", "Players", "humanoid", "countryball",
				"countryball_oneside", "RainSystem", "UI", "SelectionManager", "ToolManager",
				"CameraManager", "OBJExporter", "FreeCamera", "Lightning", "AudioStreamPlayer"]:
			continue
		if child == _nc.players.local_player:
			print("  Keeping local player: ", child.name)
			continue
		child.queue_free()


func _move_studio_content(place_root: Node, workspace: Node) -> int:
	print("Loading studio workspace content...")
	var loaded_count = 0
	for child in place_root.get_children():
		var child_name = child.name
		print("  Found child: ", child_name, " (type: ", child.get_class(), ")")
		if child_name in ["UI", "BuildUI", "ChatUI", "NetworkController", "Players",
				"SelectionManager", "ToolManager", "CameraManager", "OBJExporter", "FreeCamera",
				"Lightning", "AudioStreamPlayer"]:
			print("    -> Skipping system node: ", child_name)
			continue

		place_root.remove_child(child)
		workspace.add_child(child)
		loaded_count += 1
		print("    -> ✓ Loaded: ", child_name)

	print("Loaded ", loaded_count, " objects into workspace")
	return loaded_count


## Keeps the local player above y = -10.
func _restore_local_player_after_load(workspace: Node):
	if is_instance_valid(_nc.players.local_player):
		print("Local player preserved: ", _nc.players.local_player.name, " at ", _nc.players.local_player.global_position)
		if _nc.players.local_player.global_position.y < -10:
			_nc.players.local_player.global_position = Vector3(_nc.players.local_player.global_position.x, 10, _nc.players.local_player.global_position.z)
			print("  Repositioned player to safe height")
		return

	print("Local player not found after load, finding or spawning...")
	var existing_player = workspace.find_child("humanoid", true, false)
	if not existing_player:
		existing_player = workspace.find_child("countryball", true, false)

	if existing_player:
		_nc.players.local_player = existing_player
		print("Found existing player after load: ", existing_player.name)
		_nc.players.ensure_local_player_node(_nc.players.local_player)
	else:
		print("No player found, spawning new local player")
		_nc.players.spawn_local_player()


func upload_place(scene_path: String = ""):
	if not _nc.connected:
		print("Not connected to server")
		_nc.chat.chat_ui_notice("Not connected to server. Please connect first.")
		return

	if not FileAccess.file_exists(STUDIO_SCENE_PATH):
		print("No saved studio workspace found. Save your work first.")
		_nc.chat.chat_ui_notice("No saved workspace found. Use /save first to save your work.")
		return

	print("Reading saved studio workspace for upload...")

	var file = FileAccess.open(STUDIO_SCENE_PATH, FileAccess.READ)
	if not file:
		print("Failed to open saved studio workspace")
		_nc.chat.chat_ui_notice("Failed to read saved workspace")
		return

	var scene_data = file.get_as_text()
	file.close()

	print("Scene data size: ", scene_data.length(), " bytes")

	_nc.send_json({
		"type": "upload_place",
		"scene_data": scene_data
	})

	print("Place upload request sent (from saved studio workspace)")
	_nc.chat.chat_ui_notice("Uploading saved workspace to server...")

