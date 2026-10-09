extends Node
## Spawns and replicates pocket monsters for the local and remote players.

## Network messages this module handles: type -> method (see protocol/messages.json).
const MESSAGES := {
	"monster_spawn": "handle_monster_spawn",
	"monster_update": "handle_monster_update",
	"monster_despawn": "handle_monster_despawn",
}

var local_monsters: Array = []
var remote_monsters: Dictionary = {}

var network_controller = null
var local_player = null

## Countryballs take the "<username>_countryball" texture.
var monster_scenes: Dictionary = {
	"countryball": "res://assets/minigames/pocketmonsters/monsters/countryball_base.tscn",
}

var _update_interval: float = 0.1
var _update_timer: float = 0.0

func _ready():
	network_controller = get_node_or_null("/root/NetworkController")
	if not network_controller:
		print("MonsterController: NetworkController not found")
	else:
		print("MonsterController: Connected to NetworkController")
		if network_controller.has_signal("login_response"):
			network_controller.login_response.connect(_on_login_success)
			print("MonsterController: Connected to login_response signal")

	_connect_texture_manager()

	await get_tree().create_timer(1.0).timeout
	_find_local_player_with_retries()

	if not local_player or not is_instance_valid(local_player):
		_start_periodic_player_check()

	print("MonsterController ready (server-based spawning enabled)")

func _connect_texture_manager():
	var texture_manager = get_node_or_null("/root/TextureManager")
	if not texture_manager:
		print("MonsterController: TextureManager not found!")
		return
	if texture_manager.has_signal("texture_loaded"):
		texture_manager.texture_loaded.connect(_on_texture_loaded)
		print("MonsterController: Connected to TextureManager.texture_loaded signal")
	else:
		print("MonsterController: TextureManager doesn't have texture_loaded signal!")
		print("MonsterController: TextureManager signals: ", texture_manager.get_signal_list())

func _exit_tree():
	for monster in local_monsters:
		if is_instance_valid(monster):
			_send_monster_despawn(monster)
			monster.queue_free()
	local_monsters.clear()

	for net_id in remote_monsters.keys():
		var monster = remote_monsters[net_id]
		if is_instance_valid(monster):
			monster.queue_free()
	remote_monsters.clear()

func _send_monster_despawn(monster: PocketMonster):
	if not network_controller or not network_controller.connected:
		return

	network_controller.send_json({
		"type": "monster_despawn",
		"net_id": monster.net_id
	})

func _on_login_success(success: bool, message: String):
	if success:
		print("MonsterController: Login successful, requesting monsters...")
		# Give NetworkController time to store the username.
		await get_tree().create_timer(0.5).timeout
		_request_player_monsters()

func _on_texture_loaded(texture_name: String, texture: Texture2D, character_type: String):
	if not texture_name.contains("_countryball"):
		return

	apply_texture_to_monsters(texture_name, texture)

func _start_periodic_player_check():
	while not local_player or not is_instance_valid(local_player):
		await get_tree().create_timer(2.0).timeout

		_find_local_player()

		if local_player and is_instance_valid(local_player):
			print("MonsterController: Local player found via periodic check!")
			await _request_if_authenticated()
			break

func _find_local_player_with_retries():
	var max_retries = 10
	var retry_interval = 0.5

	for attempt in range(max_retries):
		_find_local_player()

		if local_player and is_instance_valid(local_player):
			print("MonsterController: Local player found on attempt ", attempt + 1)
			await _request_if_authenticated()
			return

		if attempt < max_retries - 1:
			await get_tree().create_timer(retry_interval).timeout

	print("MonsterController: Failed to find local player after ", max_retries, " attempts")

## Guests skip: login requests them instead.
func _request_if_authenticated():
	var username = _get_current_username()
	if username != "" and not username.begins_with("Guest"):
		print("MonsterController: Player authenticated as ", username, ", requesting monsters")
		await get_tree().create_timer(0.5).timeout
		_request_player_monsters()
	else:
		print("MonsterController: Player is guest (", username, "), will wait for login")

func _get_current_username() -> String:
	if network_controller and "local_username" in network_controller:
		return network_controller.local_username
	return ""

func _request_player_monsters():
	if not network_controller or not network_controller.connected:
		print("MonsterController: Not connected to server, skipping monster request")
		return

	var username = _get_current_username()
	print("MonsterController: Requesting monsters for user: ", username)

	network_controller.send_json({
		"type": "get_player_monsters"
	})

## Tries NetworkController, the workspace, the "local_player" group, then the tree.
func _find_local_player():
	print("MonsterController: === Searching for local player ===")

	if not is_inside_tree():
		print("MonsterController: ERROR - Not in scene tree yet!")
		return

	var tree = get_tree()
	if not tree:
		print("MonsterController: ERROR - get_tree() returned null!")
		return

	var root = tree.get_root()
	if not root:
		print("MonsterController: ERROR - get_root() returned null!")
		return

	print("MonsterController: Root node children: ", root.get_child_count())
	for i in range(min(root.get_child_count(), 10)):
		var child = root.get_child(i)
		print("  - ", child.name, " (", child.get_class(), ")")

	if _player_from_network():
		return

	var workspace = _find_workspace()
	if workspace:
		if _player_in_workspace(workspace):
			return
	else:
		print("MonsterController: ✗ No workspace or current_scene found!")

	var local_player_group = get_tree().get_nodes_in_group("local_player")
	print("MonsterController: Checking 'local_player' group, found ", local_player_group.size(), " members")
	if local_player_group.size() > 0:
		local_player = local_player_group[0]
		print("MonsterController: ✓ Found local player from 'local_player' group: ", local_player.name)
		return

	print("MonsterController: Last resort - searching entire scene tree...")
	var all_nodes = _get_all_children_recursive(get_tree().get_root())
	for node in all_nodes:
		if node.has_node("LocalPlayer"):
			local_player = node
			print("MonsterController: ✓ Found local player in scene tree: ", local_player.name)
			return

	print("MonsterController: ✗ Could not find local player by any method")

func _player_from_network() -> bool:
	if not (network_controller and network_controller.get("players") != null):
		print("MonsterController: NetworkController not available or missing players")
		return false
	var nc_player = network_controller.players.local_player
	if nc_player and is_instance_valid(nc_player):
		local_player = nc_player
		print("MonsterController: ✓ Found local player from NetworkController: ", local_player.name)
		return true
	print("MonsterController: NetworkController.players.local_player is null or invalid")
	return false

func _find_workspace():
	var workspace = null
	for ws_name in ["workspace", "Workspace", "localworkspace", "LocalWorkspace"]:
		workspace = get_tree().get_root().find_child(ws_name, true, false)
		if workspace:
			print("MonsterController: Found workspace variant: ", ws_name)
			break

	if not workspace:
		workspace = get_tree().current_scene
		if workspace:
			print("MonsterController: Using current_scene as workspace: ", workspace.name)
	return workspace

func _player_in_workspace(workspace: Node) -> bool:
	print("MonsterController: Workspace found (", workspace.name, "), searching for player...")

	var direct_children = workspace.get_children()
	print("MonsterController: Direct children of workspace: ", direct_children.size())
	for i in range(min(direct_children.size(), 15)):
		var child = direct_children[i]
		var has_local_marker = "✓" if child.has_node("LocalPlayer") else " "
		print("  [", has_local_marker, "] ", child.name, " (", child.get_class(), ")")

	for child in direct_children:
		if child.has_node("LocalPlayer"):
			local_player = child
			print("MonsterController: ✓ Found local player by LocalPlayer marker: ", local_player.name)
			return true

	if workspace.name.to_lower().contains("local"):
		print("MonsterController: Offline mode detected, looking for humanoid/countryball...")
		var offline = _first_player_body(direct_children)
		if offline:
			local_player = offline
			print("MonsterController: ✓ Found local player in offline mode: ", local_player.name)
			return true

	print("MonsterController: No direct child player found, searching recursively...")
	var all_children = _get_all_children_recursive(workspace)
	print("MonsterController: Found ", all_children.size(), " children in workspace tree (recursive)")

	for child in all_children:
		if child.has_node("LocalPlayer"):
			local_player = child
			print("MonsterController: ✓ Found local player by LocalPlayer marker (recursive): ", local_player.name)
			return true

	var found = _first_player_body(all_children)
	if found:
		local_player = found
		print("MonsterController: ✓ Found local player in recursive search: ", local_player.name)
		return true

	print("MonsterController: No child with LocalPlayer marker or humanoid/countryball found")
	return false

func _first_player_body(nodes: Array):
	for child in nodes:
		var child_name_lower = child.name.to_lower()
		if (child_name_lower == "humanoid" or child_name_lower == "countryball") and child is CharacterBody3D:
			return child
	return null

func _get_all_children_recursive(node: Node) -> Array:
	var children = []
	for child in node.get_children():
		children.append(child)
		children.append_array(_get_all_children_recursive(child))
	return children

func _instantiate_species(species: String) -> PocketMonster:
	if not monster_scenes.has(species):
		print("MonsterController: Unknown species: ", species)
		return null

	var scene_path = monster_scenes[species]
	if not FileAccess.file_exists(scene_path):
		print("MonsterController: Monster scene not found: ", scene_path)
		return null

	var monster_scene = load(scene_path)
	if not monster_scene:
		print("MonsterController: Failed to load monster scene: ", scene_path)
		return null

	return monster_scene.instantiate()

## Frees the monster and returns false when this controller is not in the tree.
func _add_to_world(monster: PocketMonster, what: String) -> bool:
	if not is_inside_tree():
		print("MonsterController: ERROR - Not in scene tree, cannot add %s!" % what)
		monster.queue_free()
		return false

	var tree = get_tree()
	if not tree:
		print("MonsterController: ERROR - get_tree() returned null%s!" % ("" if what == "monster" else " for " + what))
		monster.queue_free()
		return false

	var workspace = tree.get_root().find_child("workspace", true, false)
	if not workspace:
		workspace = tree.get_root().find_child("localworkspace", true, false)

	if workspace:
		workspace.add_child(monster)
	else:
		tree.current_scene.add_child(monster)
	return true

## A local owner's monster is tracked as local and announced to the server.
func spawn_monster(species: String, position: Vector3, owner_player: Node3D = null, texture: String = "") -> PocketMonster:
	var monster: PocketMonster = _instantiate_species(species)
	if monster == null:
		return null
	monster.name = species

	var net_id = "monster_" + str(Time.get_ticks_msec()) + "_" + str(randi())
	monster.net_id = net_id
	monster.global_position = position

	# Set before entering the tree so the spawn message carries the texture.
	if texture != "":
		monster.set_meta("custom_texture", texture)
		monster.set_meta("pending_texture", texture)

	if owner_player:
		monster.set_owner_player(owner_player)
		if owner_player == local_player:
			local_monsters.append(monster)

	if not _add_to_world(monster, "monster"):
		return null

	if owner_player == local_player and network_controller:
		_send_monster_spawn(monster)

	return monster

func spawn_remote_monster(species: String, net_id: String, position: Vector3, rotation: Vector3, texture_name: String = "") -> PocketMonster:
	if remote_monsters.has(net_id):
		var existing = remote_monsters[net_id]
		existing.apply_network_transform(position, rotation)
		return existing

	var monster: PocketMonster = _instantiate_species(species)
	if monster == null:
		return null
	monster.name = species + "_remote"
	monster.net_id = net_id
	monster.is_local_monster = false

	if not _add_to_world(monster, "remote monster"):
		return null

	# After _ready(), so a countryball's character_model exists to rotate.
	monster.apply_network_transform(position, rotation)
	remote_monsters[net_id] = monster

	if texture_name != "" and species == "countryball":
		monster.set_meta("custom_texture", texture_name)
		monster.set_meta("pending_texture", texture_name)
		_apply_monster_texture(monster, texture_name, species)
	return monster

func despawn_remote_monster(net_id: String):
	if remote_monsters.has(net_id):
		var monster = remote_monsters[net_id]
		monster.queue_free()
		remote_monsters.erase(net_id)

func _process(delta):
	_update_timer += delta
	if _update_timer >= _update_interval:
		_update_timer = 0.0
		_send_monster_updates()

func _send_monster_updates():
	if not network_controller or not network_controller.connected:
		return

	for monster in local_monsters:
		if not is_instance_valid(monster):
			continue

		var data = monster.get_monster_data()
		network_controller.send_json({
			"type": "monster_update",
			"monster_data": data
		})

func _send_monster_spawn(monster: PocketMonster):
	if not network_controller or not network_controller.connected:
		return

	var data = monster.get_monster_data()
	network_controller.send_json({
		"type": "monster_spawn",
		"monster_data": data
	})

func handle_monster_spawn(data: Dictionary):
	var monster_data = data.monster_data
	var species = monster_data.species
	var net_id = monster_data.net_id
	var position = Vector3(monster_data.position.x, monster_data.position.y, monster_data.position.z)
	var rotation = Vector3(monster_data.rotation.x, monster_data.rotation.y, monster_data.rotation.z)
	var texture_name = monster_data.get("texture", "")

	spawn_remote_monster(species, net_id, position, rotation, texture_name)

func handle_monster_update(data: Dictionary):
	var monster_data = data.monster_data
	var net_id = monster_data.net_id

	if remote_monsters.has(net_id):
		var position = Vector3(monster_data.position.x, monster_data.position.y, monster_data.position.z)
		var rotation = Vector3(monster_data.rotation.x, monster_data.rotation.y, monster_data.rotation.z)
		remote_monsters[net_id].apply_network_transform(position, rotation)

func handle_monster_despawn(data: Dictionary):
	var net_id = data.net_id
	despawn_remote_monster(net_id)

func handle_player_monsters_list(data: Dictionary, player_ref = null):
	var monsters_data = data.get("monsters", [])

	print("MonsterController: ===== RECEIVED MONSTERS LIST =====")
	print("MonsterController: Received ", monsters_data.size(), " monster(s) from server")
	print("MonsterController: Data: ", monsters_data)
	print("MonsterController: Player passed: ", player_ref)

	if player_ref and is_instance_valid(player_ref):
		local_player = player_ref
		print("MonsterController: ✓ Using player passed from NetworkController: ", local_player.name)
	elif not local_player or not is_instance_valid(local_player):
		print("MonsterController: ✗ ERROR - No valid player reference!")
		return

	print("MonsterController: ✓ Local player valid: ", local_player.name, " at ", local_player.global_position)

	for i in range(monsters_data.size()):
		print("MonsterController: Processing monster ", i + 1, "/", monsters_data.size())
		_spawn_owned_monster(monsters_data[i])

	print("MonsterController: ===== MONSTER SPAWNING COMPLETE =====")

## A logged-in player's countryball always wears "<username>_countryball".
func _spawn_owned_monster(monster_data):
	print("  Species: ", monster_data.get("species", "countryball"))
	print("  Texture: ", monster_data.get("texture", ""))

	var species = monster_data.get("species", "countryball")
	var texture_name = monster_data.get("texture", "")
	var position_offset = Vector3(randf_range(-1, 1), 0.2, randf_range(-1, 1))
	var spawn_pos = local_player.global_position + position_offset

	if species == "countryball":
		var username = _get_current_username()
		if username != "" and not username.begins_with("Guest"):
			texture_name = username + "_countryball"
			print("  Countryball detected, using texture: ", texture_name)

	print("  Spawning at: ", spawn_pos)
	var monster = spawn_monster(species, spawn_pos, local_player, texture_name)
	if not monster:
		print("  ✗ ERROR - Monster spawn failed!")
		return

	print("  ✓ Monster spawned successfully: ", monster.net_id)
	if texture_name != "":
		print("  Applying texture: ", texture_name)
		_apply_monster_texture(monster, texture_name, species)

## Countryballs only: cached texture, else ask the server and wait.
func _apply_monster_texture(monster: PocketMonster, texture_name: String, species: String):
	if species != "countryball":
		return

	var texture_manager = get_node_or_null("/root/TextureManager")
	if texture_manager:
		var cache_key = texture_name + "_humanoid"
		if texture_manager.texture_cache.has(cache_key):
			var texture = texture_manager.texture_cache[cache_key]
			monster.apply_countryball_texture(texture)
			return

	if network_controller:
		network_controller.send_json({
			"type": "get_texture",
			"texture_name": texture_name
		})

	monster.set_meta("pending_texture", texture_name)

func apply_texture_to_monsters(texture_name: String, texture: Texture2D):
	for monster in local_monsters:
		_apply_if_pending(monster, texture_name, texture)

	for net_id in remote_monsters.keys():
		_apply_if_pending(remote_monsters[net_id], texture_name, texture)

func _apply_if_pending(monster, texture_name: String, texture: Texture2D):
	if not is_instance_valid(monster) or not monster.has_meta("pending_texture"):
		return
	if monster.get_meta("pending_texture") == texture_name:
		monster.apply_countryball_texture(texture)
		monster.remove_meta("pending_texture")
