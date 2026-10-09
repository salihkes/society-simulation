extends "res://src/character/rig/skinned_character_rig.gd"
## A skinned character in one pre-fitted outfit, with bone-driven corrective blend shapes.

const FITTED_OUTFIT := ["pants", "polo", "shoes"]

## JSON with "controls" (blend shape -> bone and response) and "rest_bones".
@export_file("*.json") var corrective_layout_path := ""

var _corrective_controls: Dictionary = {}
var _corrective_bindings: Array = []  # [mesh, blend shape index, control]
var _bone_alignment: Dictionary = {}


func _ready() -> void:
	var model := get_node("Model") as Node3D
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(corrective_layout_path))
	_corrective_controls = layout.controls
	_use_model_skeleton(model, "Fitted outfit requires one skeleton")
	var head_visuals := _make_head_visuals()
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		_prepare_mesh(mesh, head_visuals)
	_attach_face(model)
	# Expressions must never reset body/clothing corrections.
	for control in face.targets.keys():
		if _corrective_controls.has(control):
			face.targets.erase(control)
			face.values.erase(control)
	_align_corrective_bones(model, layout.rest_bones)
	_update_pose_correctives()
	if autoplay != "":
		play(autoplay)


func _process(delta: float) -> void:
	super._process(delta)
	_update_pose_correctives()


func _apply_clip(t: float) -> void:
	super._apply_clip(t)
	_update_pose_correctives()


func _prepare_mesh(mesh: MeshInstance3D, head_visuals: Node3D) -> void:
	mesh.set_meta("preserve_materials", true)
	mesh.custom_aabb = AABB(Vector3(-1, -0.5, -1), Vector3(2, 3, 2))
	var extras_flag = mesh.get_meta("extras", {}).get("first_person_head", false)
	if mesh.get_meta("first_person_head", extras_flag):
		mesh.reparent(head_visuals, true)
		mesh.skeleton = mesh.get_path_to(skeleton)
	for i in mesh.get_blend_shape_count():
		var control := String(mesh.mesh.get_blend_shape_name(i))
		if _corrective_controls.has(control):
			_corrective_bindings.append([mesh, i, control])


## rest_bones holds Blender rests as row-major rows.
func _align_corrective_bones(model: Node3D, rest_bones: Dictionary) -> void:
	var conversion := Basis(Vector3.RIGHT, Vector3(0, 0, -1), Vector3(0, 1, 0))
	var skeleton_in_model := (model.global_transform.affine_inverse() * skeleton.global_transform).basis.orthonormalized()
	for definition in _corrective_controls.values():
		var bone: String = definition.bone
		var i: int = _bone_index[bone]
		var rows: Array = rest_bones[bone]
		var blender_rest := Basis(
				Vector3(rows[0][0], rows[1][0], rows[2][0]),
				Vector3(rows[0][1], rows[1][1], rows[2][1]),
				Vector3(rows[0][2], rows[1][2], rows[2][2]))
		_bone_alignment[bone] = (skeleton.get_bone_global_rest(i).basis.inverse()
				* skeleton_in_model.inverse() * conversion * blender_rest)


func _update_pose_correctives() -> void:
	if skeleton == null or _corrective_controls.is_empty():
		return
	var values: Dictionary = {}
	for control in _corrective_controls:
		values[control] = _corrective_value(_corrective_controls[control])
	for binding in _corrective_bindings:
		(binding[0] as MeshInstance3D).set_blend_shape_value(binding[1], values.get(binding[2], 0.0))


## 0..1: "smoothstep_angle" or the default "squared_projection".
func _corrective_value(definition: Dictionary) -> float:
	var bone: String = definition.bone
	var i: int = _bone_index[bone]
	var local_motion := skeleton.get_bone_rest(i).basis.inverse() * skeleton.get_bone_pose(i).basis
	var alignment: Basis = _bone_alignment[bone]
	var q := (alignment.inverse() * local_motion * alignment).orthonormalized().get_rotation_quaternion()
	if q.w < 0:
		q = -q
	if definition.get("response", "squared_projection") == "smoothstep_angle":
		var a: Array = definition.axis
		var axis := Vector3(a[0], a[1], a[2]).normalized()
		var angle := 2.0 * atan2(Vector3(q.x, q.y, q.z).dot(axis), q.w)
		var amount := clampf(angle / float(definition.max_angle), 0.0, 1.0)
		return amount * amount * (3.0 - 2.0 * amount)
	var c: Array = definition.coefficients
	var amount := clampf(Vector3(q.x, q.y, q.z).dot(Vector3(c[0], c[1], c[2])), 0.0, 1.0)
	return amount * amount


func get_outfit() -> Array:
	return FITTED_OUTFIT.duplicate()


## Accepts only the fitted outfit; nothing can be removed from it.
func set_outfit(ids: Array) -> bool:
	var requested: Array = []
	for id in ids:
		if not id is String or id not in FITTED_OUTFIT:
			return false
		if id not in requested:
			requested.append(id)
	requested.sort()
	return requested == FITTED_OUTFIT
