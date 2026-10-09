extends Control

## Material tool panel; only the Slate textures exist on disk, others change transparency only.

const PAINT_ROOTS := ["workspace"]

@onready var material_dropdown = $MaterialDropdown
@onready var transparency_input = $IncrementLen
@onready var reflectance_input = $Reflectance

var selection_manager: Node = null
var paint_mode: bool = false

enum MaterialType {
	SLATE,
	WOOD,
	COBBLESTONE,
	ASPHALT,
	BRICK,
	CLAYROOFTILES,
	CONCRETE,
	CORRODEDMETAL,
	FABRIC,
	MARBLE,
	METAL,
	PAVEMENT,
	PEBBLE,
	ROCK,
	WOODPLANKS
}

var current_material: MaterialType = MaterialType.SLATE
var transparency: float = 0.0
var reflectance: float = 0.5

var texture_paths = {
	MaterialType.SLATE: {
		"albedo": "res://assets/assets/BrickMeshes/Slate/Brick_Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Slate/Brick_Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Slate/Brick_Part1_spec.png"
	},
	MaterialType.WOOD: {
		"albedo": "res://assets/assets/BrickMeshes/Wood/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Wood/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Wood/Part1_spec.png"
	},
	MaterialType.COBBLESTONE: {
		"albedo": "res://assets/assets/BrickMeshes/Cobblestone/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Cobblestone/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Cobblestone/Part1_spec.png"
	},
	MaterialType.ASPHALT: {
		"albedo": "res://assets/assets/BrickMeshes/Asphalt/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Asphalt/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Asphalt/Part1_spec.png"
	},
	MaterialType.BRICK: {
		"albedo": "res://assets/assets/BrickMeshes/Brick/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Brick/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Brick/Part1_spec.png"
	},
	MaterialType.CLAYROOFTILES: {
		"albedo": "res://assets/assets/BrickMeshes/ClayRoofTiles/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/ClayRoofTiles/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/ClayRoofTiles/Part1_spec.png"
	},
	MaterialType.CONCRETE: {
		"albedo": "res://assets/assets/BrickMeshes/Concrete/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Concrete/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Concrete/Part1_spec.png"
	},
	MaterialType.CORRODEDMETAL: {
		"albedo": "res://assets/assets/BrickMeshes/CorrodedMetal/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/CorrodedMetal/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/CorrodedMetal/Part1_spec.png"
	},
	MaterialType.FABRIC: {
		"albedo": "res://assets/assets/BrickMeshes/Fabric/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Fabric/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Fabric/Part1_spec.png"
	},
	MaterialType.MARBLE: {
		"albedo": "res://assets/assets/BrickMeshes/Marble/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Marble/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Marble/Part1_spec.png"
	},
	MaterialType.METAL: {
		"albedo": "res://assets/assets/BrickMeshes/Metal/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Metal/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Metal/Part1_spec.png"
	},
	MaterialType.PAVEMENT: {
		"albedo": "res://assets/assets/BrickMeshes/Pavement/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Pavement/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Pavement/Part1_spec.png"
	},
	MaterialType.PEBBLE: {
		"albedo": "res://assets/assets/BrickMeshes/Pebble/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Pebble/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Pebble/Part1_spec.png"
	},
	MaterialType.ROCK: {
		"albedo": "res://assets/assets/BrickMeshes/Rock/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/Rock/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/Rock/Part1_spec.png"
	},
	MaterialType.WOODPLANKS: {
		"albedo": "res://assets/assets/BrickMeshes/WoodPlanks/Part1_diff.png",
		"normal": "res://assets/assets/BrickMeshes/WoodPlanks/Part1_nmap.png",
		"specular": "res://assets/assets/BrickMeshes/WoodPlanks/Part1_spec.png"
	}
}

func _ready():
	material_dropdown.clear()
	material_dropdown.add_item("Slate", MaterialType.SLATE)
	material_dropdown.add_item("Wood", MaterialType.WOOD)
	material_dropdown.add_item("Cobblestone", MaterialType.COBBLESTONE)
	material_dropdown.add_item("Asphalt", MaterialType.ASPHALT)
	material_dropdown.add_item("Brick", MaterialType.BRICK)
	material_dropdown.add_item("Clay Roof Tiles", MaterialType.CLAYROOFTILES)
	material_dropdown.add_item("Concrete", MaterialType.CONCRETE)
	material_dropdown.add_item("Corroded Metal", MaterialType.CORRODEDMETAL)
	material_dropdown.add_item("Fabric", MaterialType.FABRIC)
	material_dropdown.add_item("Marble", MaterialType.MARBLE)
	material_dropdown.add_item("Metal", MaterialType.METAL)
	material_dropdown.add_item("Pavement", MaterialType.PAVEMENT)
	material_dropdown.add_item("Pebble", MaterialType.PEBBLE)
	material_dropdown.add_item("Rock", MaterialType.ROCK)
	material_dropdown.add_item("Wood Planks", MaterialType.WOODPLANKS)

	material_dropdown.select(0)
	material_dropdown.item_selected.connect(_on_material_selected)

	transparency_input.text_submitted.connect(_on_transparency_changed)
	reflectance_input.text_submitted.connect(_on_reflectance_changed)

	transparency_input.focus_exited.connect(func(): transparency_input.release_focus())
	reflectance_input.focus_exited.connect(func(): reflectance_input.release_focus())

	await get_tree().process_frame
	var workspace = get_tree().current_scene
	selection_manager = workspace.get_node_or_null("SelectionManager")

	paint_mode = visible
	visibility_changed.connect(_on_visibility_changed)

func _on_visibility_changed():
	paint_mode = visible
	if paint_mode:
		print("Material Paint Mode: ENABLED - Click on objects to apply material")
	else:
		print("Material Paint Mode: DISABLED")

## Consumes the click so it does not also select.
func _input(event):
	if not paint_mode:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var clicked_object = BuildTargeting.paint_target_at(self, event.position, PAINT_ROOTS)
			if clicked_object:
				apply_material_to_object(clicked_object)
				get_viewport().set_input_as_handled()

func _on_material_selected(index: int):
	current_material = material_dropdown.get_item_id(index) as MaterialType
	material_dropdown.release_focus()
	print("Material selected: ", MaterialType.keys()[current_material], " - Click on objects to apply")

func _on_transparency_changed(new_text: String):
	var value = new_text.to_float()
	transparency = clamp(value, 0.0, 1.0)
	transparency_input.text = str(transparency)
	transparency_input.release_focus()
	print("Transparency set to: ", transparency, " - Click on objects to apply")

func _on_reflectance_changed(new_text: String):
	var value = new_text.to_float()
	reflectance = clamp(value, 0.0, 1.0)
	reflectance_input.text = str(reflectance)
	reflectance_input.release_focus()
	print("Reflectance set to: ", reflectance, " - Click on objects to apply")

func apply_material_to_object(obj: Node3D):
	if not is_instance_valid(obj):
		return

	var textures = texture_paths[current_material]

	for mesh_instance in BuildSelectable.mesh_instances(obj):
		if not mesh_instance:
			continue

		for i in range(mesh_instance.mesh.get_surface_count()):
			var material = BuildSelectable.editable_surface_material(mesh_instance, i)
			if material is StandardMaterial3D:
				_apply_settings(material, textures)
				mesh_instance.set_surface_override_material(i, material)

	print("Applied material '", MaterialType.keys()[current_material],
		  "' (T:", transparency, ", R:", reflectance, ") to '", obj.name, "'")

func _apply_settings(material: StandardMaterial3D, textures: Dictionary):
	if ResourceLoader.exists(textures["albedo"]):
		material.albedo_texture = load(textures["albedo"])

	if ResourceLoader.exists(textures["normal"]):
		material.normal_enabled = true
		material.normal_texture = load(textures["normal"])

	if transparency > 0.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 1.0 - transparency
	else:
		material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		material.albedo_color.a = 1.0

	material.metallic = reflectance
	material.roughness = 1.0 - reflectance * 0.5
