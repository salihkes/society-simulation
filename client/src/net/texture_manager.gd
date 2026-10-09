extends Node
## Player skins and countryball flags: fetched from the server, cached in memory and on disk, applied to meshes.

signal texture_loaded(texture_name, texture, character_type)

## Saved PNGs let skins and flags survive restarts and work with no connection.
const DISK_CACHE_DIR := "user://texture_cache/"

## Cache key ("name_type" or "name_type_flag") -> Texture2D.
var texture_cache = {}

var default_texture: Texture2D


func _ready():
	default_texture = load(Identity.value("default_skin"))
	if not default_texture:
		default_texture = load("res://icon.png")

	var dir = DirAccess.open("user://")
	if dir and not dir.dir_exists("texture_cache"):
		dir.make_dir("texture_cache")


func _disk_path(cache_key: String) -> String:
	var safe := ""
	for ch in cache_key:
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") \
				or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			safe += ch
		else:
			safe += "%%%02X" % ch.unicode_at(0)
	return DISK_CACHE_DIR + safe + ".png"


## Also puts it in the memory cache; null if absent.
func _load_from_disk(cache_key: String) -> Texture2D:
	var path := _disk_path(cache_key)
	if not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	if image.load(path) != OK:
		print("Failed to read cached texture from disk: ", path)
		return null
	var texture := ImageTexture.create_from_image(image)
	texture_cache[cache_key] = texture
	print("Loaded texture from disk cache: ", cache_key)
	return texture


func _save_to_disk(cache_key: String, image: Image) -> void:
	var path := _disk_path(cache_key)
	if image.save_png(path) != OK:
		print("Failed to write texture to disk cache: ", path)


## Flag-wearing countryballs include the flag code, so one user can own several.
func _get_cache_key(texture_name: String, character_type: String = "humanoid",
		flag_code: String = "") -> String:
	if CountryballTypes.wears_flag(character_type) and flag_code != "":
		return texture_name + "_" + character_type + "_" + flag_code
	return texture_name + "_" + character_type


## Emits texture_loaded when cached; otherwise asks the server and returns the default for now.
func load_texture(texture_name: String, character_type: String = "humanoid",
		flag_code: String = ""):
	var cache_key = _get_cache_key(texture_name, character_type, flag_code)

	if texture_cache.has(cache_key):
		emit_signal("texture_loaded", texture_name, texture_cache[cache_key], character_type)
		return texture_cache[cache_key]

	var cached := _load_from_disk(cache_key)
	if cached:
		emit_signal("texture_loaded", texture_name, cached, character_type)
		return cached

	var network_controller = get_node("/root/NetworkController")
	network_controller.send_json({
		"type": "get_texture",
		"texture_name": texture_name
	})

	return default_texture


func has_texture(texture_name: String, character_type: String = "humanoid",
		flag_code: String = "") -> bool:
	var cache_key = _get_cache_key(texture_name, character_type, flag_code)
	return texture_cache.has(cache_key) or FileAccess.file_exists(_disk_path(cache_key))


## Emits texture_loaded; a texture already in memory wins over the new data.
func process_texture_data(texture_name: String, base64_data: String,
		character_type: String = "humanoid", flag_code: String = ""):
	print("Processing texture data for:", texture_name, "character type:", character_type,
		"flag_code:", flag_code)

	var cache_key = _get_cache_key(texture_name, character_type, flag_code)

	if texture_cache.has(cache_key):
		print("Using cached texture for:", texture_name, "character type:", character_type,
			"flag_code:", flag_code)
		emit_signal("texture_loaded", texture_name, texture_cache[cache_key], character_type)
		return texture_cache[cache_key]

	var bytes = Marshalls.base64_to_raw(base64_data)
	print("Decoded base64 data, size:", bytes.size())

	var image = Image.new()
	var error = image.load_png_from_buffer(bytes)
	if error != OK:
		push_error("Failed to create image from texture data: " + texture_name)
		emit_signal("texture_loaded", texture_name, default_texture, character_type)
		return default_texture

	print("Successfully created image from data")

	var texture = ImageTexture.create_from_image(image)
	print("Created texture from image")

	texture_cache[cache_key] = texture
	_save_to_disk(cache_key, image)

	emit_signal("texture_loaded", texture_name, texture, character_type)
	print("Emitted texture_loaded signal for:", texture_name, "character type:", character_type)

	return texture


## Countryballs get the texture on their Base mesh only; humanoids on every mesh.
func apply_texture_to_player(player: Node, texture: Texture2D):
	print("TEXTURE APPLICATION to player:", player.name)

	var character_type = _get_player_character_type(player)

	if CountryballTypes.is_countryball(character_type):
		var base_mesh = _get_countryball_base_mesh(player)
		if base_mesh and base_mesh is MeshInstance3D:
			print("Applying texture to", character_type, "Base mesh only")
			apply_texture_to_mesh(base_mesh, texture)
		else:
			print("Could not find Base mesh in", character_type)
	else:
		print("Applying texture to humanoid - finding all mesh instances")
		var mesh_instances = []
		find_all_mesh_instances(player, mesh_instances)

		print("Found", mesh_instances.size(), "mesh instances in humanoid")

		for mesh_instance in mesh_instances:
			apply_texture_to_mesh(mesh_instance, texture)


## Its own answer, else guessed from scene path, metadata and model; "humanoid" when unsure.
func _get_player_character_type(player: Node) -> String:
	if player.has_method("get_character_type"):
		return player.get_character_type()

	if player.has_method("get") and player.get("character_type") != null:
		return player.character_type

	# The QWC ball also carries flag_code, so test it before the metadata.
	if player.scene_file_path.contains("countryball_quincyform"):
		return CountryballTypes.QWC

	if player.has_meta("flag_code"):
		return CountryballTypes.ONESIDE

	if player.scene_file_path.contains("countryballoneside"):
		return CountryballTypes.ONESIDE

	var character_model = player.find_child("CharacterModel")
	if character_model:
		if character_model.has_node("Base") and character_model.has_node("Emotions"):
			return CountryballTypes.CLASSIC
		elif character_model.has_node("LeftArm") and character_model.has_node("RightArm"):
			return "humanoid"

	if player.has_method("get_base_mesh"):
		return "countryball"

	return "humanoid"


func _get_countryball_base_mesh(player: Node) -> MeshInstance3D:
	if player.has_method("get_base_mesh"):
		var base_mesh = player.get_base_mesh()
		if base_mesh and base_mesh is MeshInstance3D:
			return base_mesh

	if player.has_method("get") and player.get("current_animation") != null:
		var animation = player.current_animation
		if animation.has_method("get_base_mesh"):
			var base_mesh = animation.get_base_mesh()
			if base_mesh and base_mesh is MeshInstance3D:
				return base_mesh

	# owned=false: the QWC ball's Base sits inside an instanced scene.
	var character_model = player.find_child("CharacterModel")
	if character_model:
		var base_mesh = character_model.find_child("Base", true, false)
		if base_mesh and base_mesh is MeshInstance3D:
			return base_mesh

	return null


## Skips meshes tagged preserve_materials.
func apply_texture_to_mesh(mesh_instance: MeshInstance3D, texture: Texture2D):
	if not mesh_instance or not texture or mesh_instance.get_meta("preserve_materials", false):
		return

	print("Applying texture to mesh:", mesh_instance.name)

	var material = StandardMaterial3D.new()
	material.albedo_texture = texture

	if mesh_instance.mesh:
		for i in range(mesh_instance.mesh.get_surface_count()):
			mesh_instance.set_surface_override_material(i, material)
			print("Applied texture to surface", i, "of", mesh_instance.name)


func find_all_mesh_instances(node: Node, result: Array):
	if node is MeshInstance3D:
		result.append(node)

	for child in node.get_children():
		find_all_mesh_instances(child, result)


func apply_texture_by_username(username: String, character_type: String = "humanoid",
		flag_code: String = ""):
	print("Attempting to apply texture for username:", username, "character type:",
		character_type, "flag_code:", flag_code)

	var cache_key = _get_cache_key(username, character_type, flag_code)

	if not texture_cache.has(cache_key) and _load_from_disk(cache_key) == null:
		print("No texture found for username:", username, "character type:", character_type,
			"flag_code:", flag_code)
		return

	var texture = texture_cache[cache_key]
	var network_controller = get_node_or_null("/root/NetworkController")
	if not network_controller:
		print("NetworkController not found")
		return

	print("NetworkController found, username:", network_controller.local_username,
		"texture_name:", username)

	if network_controller.local_username == username:
		var local_player = network_controller.players.local_player
		if is_instance_valid(local_player) \
				and _get_player_character_type(local_player) == character_type:
			print("Local player is valid, applying texture directly")
			apply_texture_to_player(local_player, texture)
		return

	print("Username mismatch: local=", network_controller.local_username, "texture=", username)
	for player_id in network_controller.players.remote_players:
		var player = network_controller.players.remote_players[player_id]
		if player.name == username and _get_player_character_type(player) == character_type:
			print("Applying texture to remote player:", username)
			apply_texture_to_player(player, texture)
