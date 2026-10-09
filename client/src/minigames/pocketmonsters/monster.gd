extends CharacterBody3D
class_name PocketMonster
## A pocket monster: local ones follow their owner, remote ones take replicated transforms.

var monster_name: String = "Unknown"
var monster_type: String = "normal"
var base_speed: float = 3.0
var interaction_range: float = 2.0
var description: String = ""
var color: Color = Color.WHITE

var owner_node: Node3D = null
var follow_distance: float = 1.8
var follow_speed_multiplier: float = 1.5

var net_id: String = ""
var is_local_monster: bool = false

var _gravity: float = 20.0
## Beyond this distance from the owner the monster teleports to them.
var _max_follow_distance: float = 6.0
var _teleport_cooldown: float = 0.0

var bounce_amount: float = 0.3
var bounce_speed: float = 8.0
var squash_amount: float = 0.2
var bounce_timer: float = 0.0
var original_scale: Vector3 = Vector3.ONE
## Countryball only: the first Node3D child other than the area, label and shape.
var character_model: Node3D = null

@onready var model: Node3D = $Model
@onready var interaction_area: Area3D = $InteractionArea
@onready var name_label: Label3D = $NameLabel

func _ready():
	_load_monster_data()

	if interaction_area:
		interaction_area.body_entered.connect(_on_body_entered_interaction)
		interaction_area.body_exited.connect(_on_body_exited_interaction)

	if name_label:
		name_label.text = monster_name
		name_label.modulate = color

	if _is_countryball_monster():
		_find_character_model()
	elif model and model is MeshInstance3D:
		var material = StandardMaterial3D.new()
		material.albedo_color = color
		material.metallic = 0.2
		material.roughness = 0.8
		model.material_override = material

	add_to_group("monsters")

func _find_character_model():
	for child in get_children():
		if child is Node3D and child.name != "InteractionArea" and child.name != "NameLabel" and child.name != "CollisionShape3D":
			character_model = child
			original_scale = character_model.scale
			break

func _is_countryball_monster() -> bool:
	return name.to_lower().begins_with("countryball")

## Reads data/<species>.yaml, or uses defaults when the file is missing.
func _load_monster_data():
	var species = "countryball"
	if name != "":
		species = name.to_lower()

	var yaml_path = "res://assets/minigames/pocketmonsters/data/" + species + ".yaml"

	if not FileAccess.file_exists(yaml_path):
		print("Warning: YAML file not found for ", species, " at ", yaml_path)
		_set_default_properties(species)
		return

	var file = FileAccess.open(yaml_path, FileAccess.READ)
	if not file:
		print("Error: Could not open YAML file: ", yaml_path)
		_set_default_properties(species)
		return

	var yaml_content = file.get_as_text()
	file.close()

	_parse_yaml(yaml_content)

## Minimal YAML: flat `key: value` lines, optional quotes, # comments.
func _parse_yaml(content: String):
	var lines = content.split("\n")

	for line in lines:
		line = line.strip_edges()
		if line.begins_with("#") or line == "":
			continue
		if not (":" in line):
			continue
		var parts = line.split(":", true, 1)
		if parts.size() != 2:
			continue
		_apply_property(parts[0].strip_edges(), _unquote(parts[1].strip_edges()))

func _unquote(value: String) -> String:
	if value.begins_with('"') and value.ends_with('"'):
		return value.substr(1, value.length() - 2)
	elif value.begins_with("'") and value.ends_with("'"):
		return value.substr(1, value.length() - 2)
	return value

func _apply_property(key: String, value: String):
	match key:
		"name":
			monster_name = value
		"type":
			monster_type = value
		"speed":
			base_speed = float(value)
		"interaction_range":
			interaction_range = float(value)
		"description":
			description = value
		"color":
			color = _parse_color(value)

func _parse_color(color_str: String) -> Color:
	if color_str.begins_with("#"):
		return Color(color_str)
	match color_str.to_lower():
		"red": return Color.RED
		"green": return Color.GREEN
		"blue": return Color.BLUE
		"yellow": return Color.YELLOW
		"white": return Color.WHITE
		"black": return Color.BLACK
		_: return Color.WHITE

func _set_default_properties(species: String):
	monster_name = species.capitalize()
	monster_type = "normal"
	base_speed = 3.0
	interaction_range = 2.0
	description = "A mysterious creature."
	color = Color.WHITE

func _physics_process(delta):
	if not is_local_monster:
		return

	if _teleport_cooldown > 0:
		_teleport_cooldown -= delta

	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0

	if owner_node and is_instance_valid(owner_node):
		_follow_owner(delta)
	else:
		_idle_behavior(delta)

	move_and_slide()

	if _is_countryball_monster() and character_model:
		_animate_countryball(delta)

func _follow_owner(delta):
	var owner_pos = owner_node.global_position
	var distance = global_position.distance_to(owner_pos)

	if distance > _max_follow_distance and _teleport_cooldown <= 0:
		var spawn_offset = Vector3(randf_range(-0.8, 0.8), 0, randf_range(-0.5, 0.5))
		global_position = owner_pos + spawn_offset
		velocity = Vector3.ZERO
		_teleport_cooldown = 2.0
		return

	if distance <= follow_distance:
		velocity.x = lerp(velocity.x, 0.0, delta * 5.0)
		velocity.z = lerp(velocity.z, 0.0, delta * 5.0)
		return

	var direction = (owner_pos - global_position).normalized()
	direction.y = 0

	var speed = base_speed
	if distance > follow_distance * 2.0:
		speed *= follow_speed_multiplier * 1.5
	elif distance > follow_distance * 1.5:
		speed *= follow_speed_multiplier

	velocity.x = direction.x * speed
	velocity.z = direction.z * speed

	if direction.length() > 0.1:
		_face(atan2(direction.x, direction.z), delta)

## The PI: countryball models are rotated 180 degrees in the scene.
func _face(target_rotation: float, delta: float):
	if _is_countryball_monster() and character_model:
		character_model.rotation.y = lerp_angle(character_model.rotation.y, target_rotation + PI, delta * 10.0)
	else:
		rotation.y = lerp_angle(rotation.y, target_rotation, delta * 10.0)

func _idle_behavior(delta):
	velocity.x = lerp(velocity.x, 0.0, delta * 5.0)
	velocity.z = lerp(velocity.z, 0.0, delta * 5.0)

func _animate_countryball(delta):
	if not character_model:
		return

	var speed = Vector2(velocity.x, velocity.z).length()
	var is_moving = speed > 0.1
	var is_running = speed > base_speed * 0.8

	if is_moving and is_on_floor():
		bounce_timer += delta * bounce_speed * (2.0 if is_running else 1.0)
		var bounce_offset = sin(bounce_timer) * bounce_amount
		var squash_factor = 1.0 - (speed / (base_speed * 2.0)) * squash_amount
		character_model.scale = Vector3(
			original_scale.x * (1.0 + squash_amount * 0.5),
			original_scale.y * squash_factor,
			original_scale.z * (1.0 + squash_amount * 0.5)
		)
		character_model.position.y = bounce_offset
	else:
		character_model.scale = character_model.scale.lerp(original_scale, delta * 5.0)
		character_model.position.y = lerp(character_model.position.y, 0.0, delta * 5.0)
		bounce_timer = 0.0

	if not is_on_floor():
		var fall_squash = 1.0 + abs(velocity.y) * 0.05
		character_model.scale = Vector3(
			original_scale.x * fall_squash,
			original_scale.y / fall_squash,
			original_scale.z * fall_squash
		)

func set_owner_player(new_owner: Node3D):
	owner_node = new_owner
	is_local_monster = true

func get_monster_data() -> Dictionary:
	var rot_to_send = rotation
	if _is_countryball_monster() and character_model:
		rot_to_send = character_model.rotation

	var data = {
		"net_id": net_id,
		"species": name,
		"position": {
			"x": global_position.x,
			"y": global_position.y,
			"z": global_position.z
		},
		"rotation": {
			"x": rot_to_send.x,
			"y": rot_to_send.y,
			"z": rot_to_send.z
		}
	}

	if has_meta("custom_texture"):
		data["texture"] = get_meta("custom_texture")

	return data

## Remote monsters only.
func apply_network_transform(pos: Vector3, rot: Vector3):
	if is_local_monster:
		return

	global_position = pos
	if _is_countryball_monster() and character_model:
		character_model.rotation = rot
	else:
		rotation = rot

func _on_body_entered_interaction(body: Node3D):
	print(monster_name, " detected: ", body.name)

func _on_body_exited_interaction(body: Node3D):
	pass

func apply_countryball_texture(texture: Texture2D):
	if not _is_countryball_monster():
		return

	var model_node = character_model if character_model else model
	var base_mesh = model_node.find_child("Base", true, false)
	if base_mesh and base_mesh is MeshInstance3D:
		var material = StandardMaterial3D.new()
		material.albedo_texture = texture
		material.metallic = 0.0
		material.roughness = 1.0
		base_mesh.set_surface_override_material(0, material)
