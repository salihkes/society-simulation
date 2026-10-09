extends Node3D
## A character skinned at load to hand-placed joints (joint_skinner.gd) and posed by bone rotations or clips.

const JointSkinnerScript := preload("res://src/character/rig/joint_skinner.gd")
const MixamoRetargetScript := preload("res://src/character/rig/mixamo_retarget.gd")
const CLIP_DIR := "res://assets/entities/character/rig/clips/"

## A found Mixamo file takes precedence over the JSON clip.
const MIXAMO_FILES := {
	"idle": "Idle.fbx", "walk": "Walking.fbx", "run": "Running.fbx",
	"jump": "Jump.fbx", "sit": "Sitting.fbx", "talk": "Talking.fbx",
}
const MIXAMO_ROOT_MOTION := {"walk": "vertical", "run": "vertical", "jump": "none"}

## Read at runtime when there is no Model child.
@export_file("*.glb") var model_path := ""
## "" for the rest pose.
@export var autoplay := ""
## Mixamo FBX clips to retarget, or "" for JSON clips only.
@export_dir var mixamo_dir := ""

var skeleton: Skeleton3D
var bones_ready := false
## 1 = authored speed.
var speed_scale := 1.0
## "" for none.
var current_clip := ""

var _clip := {}
var _clip_time := 0.0
var _playing := false
var _bone_index := {}  # name -> int

static var _clip_cache := {}


func _ready() -> void:
	var joints := get_node_or_null("Joints") as Node3D
	var model := get_node_or_null("Model") as Node3D
	if model == null and model_path != "":
		model = _load_glb(model_path)
		if model != null:
			model.name = "Model"
			add_child(model)
	if joints == null or model == null:
		push_warning("JointRig: needs a Joints tree and a model (%s)" % get_path())
		return
	var mi := _first_mesh(model)
	if mi == null:
		push_warning("JointRig: no MeshInstance3D under the model")
		return
	skeleton = JointSkinnerScript.build(self, joints, mi)
	if skeleton == null:
		return
	for i in skeleton.get_bone_count():
		_bone_index[skeleton.get_bone_name(i)] = i
	bones_ready = true
	if autoplay != "":
		play(autoplay)


func _process(delta: float) -> void:
	if not _playing:
		return
	_clip_time += delta * speed_scale
	var length: float = _clip.get("length", 1.0)
	if _clip_time >= length:
		if _clip.get("loop", true):
			_clip_time = fmod(_clip_time, length)
		else:
			_clip_time = length
			_playing = false
	_apply_clip(_clip_time)


func bone_names() -> Array:
	return _bone_index.keys()


func has_bone(bone: String) -> bool:
	return _bone_index.has(bone)


## Euler degrees about the rest axes (= the model's axes).
func rotate_bone(bone: String, euler_degrees: Vector3) -> void:
	set_bone_basis(bone, Basis.from_euler(euler_degrees * (PI / 180.0)))


func set_bone_basis(bone: String, basis: Basis) -> void:
	if not _bone_index.has(bone):
		return
	skeleton.set_bone_pose_rotation(_bone_index[bone], basis.get_rotation_quaternion())


## Back to the T-pose.
func reset_pose() -> void:
	if skeleton != null:
		skeleton.reset_bone_poses()


## Rig space, for attaching things.
func bone_position(bone: String) -> Vector3:
	if not _bone_index.has(bone):
		return Vector3.ZERO
	return skeleton.get_bone_global_pose(_bone_index[bone]).origin


## Clip JSON: {"length", "loop", "tracks": {bone: [[t, [x, y, z] deg]]}, "positions"}; restart false keeps the phase.
func play(clip, restart := true) -> void:
	var clip_name := String(clip) if clip is String else ""
	if not restart and _playing and clip_name != "" and clip_name == current_clip:
		return
	var data := {}
	if clip is Dictionary:
		data = clip
	else:
		data = resolve_clip(clip_name)
	if data.is_empty():
		return
	if restart or data != _clip:
		_clip_time = 0.0
	_clip = data
	current_clip = clip_name
	_playing = true
	_apply_clip(_clip_time)


func stop(keep_pose := false) -> void:
	_playing = false
	current_clip = ""
	if not keep_pose:
		reset_pose()


func is_playing() -> bool:
	return _playing


func has_clip(clip_name: String) -> bool:
	return not resolve_clip(clip_name).is_empty()


func clip_source(clip_name: String) -> String:
	var data := resolve_clip(clip_name)
	return String(data.get("source", "json")) if not data.is_empty() else ""


## The Mixamo file in mixamo_dir (retargeted and cached), else clips/<name>.json.
func resolve_clip(clip_name: String) -> Dictionary:
	if skeleton != null and mixamo_dir != "" and MIXAMO_FILES.has(clip_name):
		var path: String = mixamo_dir.path_join(MIXAMO_FILES[clip_name])
		if ResourceLoader.exists(path):
			var options := {
				"loop": clip_name != "jump",
				"root_motion": MIXAMO_ROOT_MOTION.get(clip_name, "keep"),
				"our_height": _rig_height(),
			}
			var baked: Dictionary = MixamoRetargetScript.bake(path, skeleton, options)
			if not baked.is_empty():
				return baked
	return load_clip(clip_name)


## Rig units, for scaling hip travel.
func _rig_height() -> float:
	var top: int = _bone_index.get("HeadTop", _bone_index.get("Head", -1))
	var toe: int = _bone_index.get("L_Toe", _bone_index.get("L_Ankle", -1))
	if top < 0 or toe < 0:
		return 1.9
	var top_y := skeleton.get_bone_global_rest(top).origin.y
	return top_y - skeleton.get_bone_global_rest(toe).origin.y


## Name or res:// path, cached; {} when missing.
static func load_clip(clip_name: String) -> Dictionary:
	if _clip_cache.has(clip_name):
		return _clip_cache[clip_name]
	var path := clip_name if clip_name.begins_with("res://") else CLIP_DIR + clip_name + ".json"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("JointRig: no clip at " + path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	var data: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	_clip_cache[clip_name] = data
	return data


func _apply_clip(t: float) -> void:
	if skeleton == null:
		return
	var tracks: Dictionary = _clip.get("tracks", {})
	for bone in tracks:
		if not _bone_index.has(bone):
			continue
		var keys: Array = tracks[bone]
		if keys.is_empty():
			continue
		skeleton.set_bone_pose_rotation(_bone_index[bone], _sample(keys, t))
	var positions: Dictionary = _clip.get("positions", {})
	for bone in positions:
		if not _bone_index.has(bone):
			continue
		var keys: Array = positions[bone]
		if keys.is_empty():
			continue
		var idx: int = _bone_index[bone]
		var origin := skeleton.get_bone_rest(idx).origin
		skeleton.set_bone_pose_position(idx, origin + _sample_vec(keys, t))


## Keys [[time, value], ...] time-ordered; holds the ends.
static func _sample(keys: Array, t: float) -> Quaternion:
	var seg := _segment(keys, t)
	if seg[1] == null:
		return _key_quat(seg[0])
	return _key_quat(seg[0]).slerp(_key_quat(seg[1]), seg[2])


## Keys [[time, [x, y, z]], ...] time-ordered; holds the ends.
static func _sample_vec(keys: Array, t: float) -> Vector3:
	var seg := _segment(keys, t)
	if seg[1] == null:
		return _key_vec(seg[0])
	return _key_vec(seg[0]).lerp(_key_vec(seg[1]), seg[2])


## Returns [key before t, key after t or null to hold, blend factor].
static func _segment(keys: Array, t: float) -> Array:
	var prev: Array = keys[0]
	if t <= float(prev[0]):
		return [prev, null, 0.0]
	for i in range(1, keys.size()):
		var next: Array = keys[i]
		var t1 := float(next[0])
		if t < t1:
			var t0 := float(prev[0])
			var f := 0.0 if t1 <= t0 else (t - t0) / (t1 - t0)
			return [prev, next, f]
		prev = next
	return [prev, null, 0.0]


## [x, y, z] euler degrees or an [x, y, z, w] quaternion.
static func _key_quat(key: Array) -> Quaternion:
	var e: Array = key[1]
	if e.size() == 4:
		return Quaternion(float(e[0]), float(e[1]), float(e[2]), float(e[3])).normalized()
	var euler := Vector3(float(e[0]), float(e[1]), float(e[2])) * (PI / 180.0)
	return Basis.from_euler(euler).get_rotation_quaternion()


static func _key_vec(key: Array) -> Vector3:
	var v: Array = key[1]
	return Vector3(float(v[0]), float(v[1]), float(v[2]))


static func _load_glb(path: String) -> Node3D:
	if not FileAccess.file_exists(path):
		push_warning("JointRig: no model at " + path)
		return null
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	state.create_animations = false
	if document.append_from_file(path, state) != OK:
		push_warning("JointRig: could not read " + path)
		return null
	return document.generate_scene(state) as Node3D


static func _first_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return node
	for child in node.get_children():
		var found := _first_mesh(child)
		if found != null:
			return found
	return null
