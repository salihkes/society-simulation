extends "res://src/character/rig/joint_rig.gd"
## A rig for an authored skinned character: one skeleton, an anime face and a wardrobe.

const FaceController := preload("res://src/character/face/anime_face.gd")
const Wardrobe := preload("res://src/character/clothing/skeletal_wardrobe.gd")
## Seconds a clip change takes to blend from the previous pose.
const BLEND_TIME := 0.18

@export var garment_catalog: Dictionary = {}
@export var default_outfit: Array[String] = []

var face: Node
var wardrobe: Node

var _blend_from: Dictionary = {}
var _blend_age := 1.0


func _ready() -> void:
	var model := get_node("Model") as Node3D
	_use_model_skeleton(model, "Authored character requires one body skeleton")
	var head_visuals := _make_head_visuals()
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if not String(mesh.name).begins_with("Body"):
			mesh.reparent(head_visuals, true)
			mesh.skeleton = mesh.get_path_to(skeleton)
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		mesh.set_meta("preserve_materials", true)
	_attach_face(model)
	wardrobe = Wardrobe.new()
	wardrobe.name = "Wardrobe"
	add_child(wardrobe)
	wardrobe.attach(model, skeleton, garment_catalog)
	assert(wardrobe.set_outfit(default_outfit), "Default outfit must bind to body skeleton")
	if autoplay != "":
		play(autoplay)


## A clip change blends from the current pose.
func play(clip, restart := true) -> void:
	var next := String(clip) if clip is String else ""
	if next != current_clip:
		_blend_from.clear()
		for i in skeleton.get_bone_count():
			_blend_from[i] = [skeleton.get_bone_pose_rotation(i), skeleton.get_bone_pose_position(i)]
		_blend_age = 0.0
	super.play(clip, restart)


func _process(delta: float) -> void:
	_blend_age += delta
	super._process(delta)


func _apply_clip(t: float) -> void:
	if skeleton == null:
		return
	var blend := smoothstep(0.0, BLEND_TIME, _blend_age)
	for bone in _clip.get("tracks", {}):
		if not _bone_index.has(bone):
			continue
		var i: int = _bone_index[bone]
		var keys: Array = _clip.tracks[bone]
		if keys.is_empty():
			continue
		var q := _authored_rotation(i, _sample(keys, t))
		if _blend_from.has(i):
			q = (_blend_from[i][0] as Quaternion).slerp(q, blend)
		skeleton.set_bone_pose_rotation(i, q)
	for bone in _clip.get("tracks", {}):
		if not _bone_index.has(bone):
			continue
		var i: int = _bone_index[bone]
		var position := skeleton.get_bone_rest(i).origin + _travel(i, bone, t)
		if _blend_from.has(i):
			position = (_blend_from[i][1] as Vector3).lerp(position, blend)
		skeleton.set_bone_pose_position(i, position)


## Clip rotations are in model axes; converts one to bone i's authored local rest.
func _authored_rotation(i: int, motion_q: Quaternion) -> Quaternion:
	var rest := skeleton.get_bone_global_rest(i).basis.orthonormalized()
	var local_rest := skeleton.get_bone_rest(i).basis.orthonormalized()
	var motion := Basis(motion_q)
	return (local_rest * rest.inverse() * motion * rest).get_rotation_quaternion()


## In the bone's parent rest space.
func _travel(i: int, bone: String, t: float) -> Vector3:
	var travel := Vector3.ZERO
	if _clip.get("positions", {}).has(bone):
		travel = _sample_vec(_clip.positions[bone], t)
	var parent := skeleton.get_bone_parent(i)
	if parent >= 0:
		travel = skeleton.get_bone_global_rest(parent).basis.inverse() * travel
	return travel


func _use_model_skeleton(model: Node3D, message: String) -> void:
	var skeletons := model.find_children("*", "Skeleton3D", true, false)
	assert(skeletons.size() == 1, message)
	skeleton = skeletons[0]
	for i in skeleton.get_bone_count():
		_bone_index[skeleton.get_bone_name(i)] = i
	bones_ready = true


func _make_head_visuals() -> Node3D:
	var head_visuals := Node3D.new()
	head_visuals.name = "FirstPersonHead"
	skeleton.add_child(head_visuals)
	return head_visuals


func _attach_face(model: Node3D) -> void:
	face = FaceController.new()
	face.name = "AnimeFace"
	add_child(face)
	face.attach(model)


func _rig_height() -> float:
	return 1.72


func set_emotion(value: String) -> bool:
	return face.set_emotion(value)


func get_emotion() -> String:
	return face.get_emotion()


func get_available_emotions() -> Array:
	return face.get_available_emotions()


func say(text: String) -> void:
	face.say(text)


func set_outfit(ids: Array) -> bool:
	return wardrobe.set_outfit(ids)


func get_outfit() -> Array:
	return wardrobe.get_outfit()


## Follows the head bone.
func get_eye_position() -> Vector3:
	var head := skeleton.find_bone("Head")
	var motion := skeleton.get_bone_global_pose(head) * skeleton.get_bone_global_rest(head).affine_inverse()
	return skeleton.to_global(motion * Vector3(0, 1.564, 0.05))
