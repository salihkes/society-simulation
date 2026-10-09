@tool
extends Marker3D
class_name VehicleSpot

## Where a borrowable vehicle stands when the world loads (-Z forward); the name is its network id.

@export var definition: VehicleDefinition:
	set(value):
		definition = value
		if Engine.is_editor_hint():
			_refresh_preview()
## Doors locked.
@export var npc_driven := false

var _preview: Node3D = null


func _ready() -> void:
	if Engine.is_editor_hint():
		_refresh_preview()
	else:
		add_to_group("vehicle_spot")


func _refresh_preview() -> void:
	if _preview != null and is_instance_valid(_preview):
		_preview.queue_free()
		_preview = null
	if definition == null or definition.model_path == "" \
			or not ResourceLoader.exists(definition.model_path):
		return
	var scene = load(definition.model_path)
	if scene == null or not (scene is PackedScene):
		return
	var model: Node3D = (scene as PackedScene).instantiate() as Node3D
	if model == null:
		return
	model.name = "EditorPreview"
	definition.fit_model(model)
	# Internal and without an owner, so it is neither saved nor selectable.
	add_child(model, false, Node.INTERNAL_MODE_BACK)
