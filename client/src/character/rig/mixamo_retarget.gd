extends RefCounted
## Bakes a Mixamo FBX clip onto a JointRig skeleton as quaternion keys, matched in world space from the T-pose.

const FPS := 30.0

## Source bones with no entry are skipped.
const MAP := {
	"Hips": "Hips", "Spine": "Spine", "Chest": "Spine2", "Neck": "Neck", "Head": "Head",
	"L_Clavicle": "LeftShoulder", "R_Clavicle": "RightShoulder",
	"L_Shoulder": "LeftArm", "L_Elbow": "LeftForeArm", "L_Wrist": "LeftHand",
	"R_Shoulder": "RightArm", "R_Elbow": "RightForeArm", "R_Wrist": "RightHand",
	"L_Hip": "LeftUpLeg", "L_Knee": "LeftLeg", "L_Ankle": "LeftFoot",
	"R_Hip": "RightUpLeg", "R_Knee": "RightLeg", "R_Ankle": "RightFoot",
}

static var _cache := {}


## options: loop, root_motion ("keep" | "vertical" | "none"), our_height (rig units).
static func bake(fbx_path: String, skel: Skeleton3D, options: Dictionary = {}) -> Dictionary:
	var layout := []
	for i in skel.get_bone_count():
		layout.append([skel.get_bone_name(i), skel.get_bone_parent(i)])
	var key := [fbx_path, hash(layout), options]
	if _cache.has(key):
		return _cache[key]
	var clip := _bake(fbx_path, skel, options)
	_cache[key] = clip
	return clip


static func _bake(fbx_path: String, skel: Skeleton3D, options: Dictionary) -> Dictionary:
	if not ResourceLoader.exists(fbx_path):
		return {}
	var scene := load(fbx_path) as PackedScene
	if scene == null:
		return {}
	var inst := scene.instantiate()
	var src := _find(inst, "Skeleton3D") as Skeleton3D
	var anim := _first_animation(_find(inst, "AnimationPlayer") as AnimationPlayer)
	if src == null or anim == null:
		inst.queue_free()
		push_warning("MixamoRetarget: no skeleton or animation in " + fbx_path)
		return {}
	var src_index := {}
	for i in src.get_bone_count():
		src_index[_norm(src.get_bone_name(i))] = i
	var bones := _mapped_bones(skel, src_index)
	var clip := _bake_tracks(anim, src, src_index, skel, bones, options)
	inst.queue_free()
	print("MixamoRetarget: %s -> %d bones, %d keys, %.2f s" % [
			fbx_path.get_file(), bones.size(), int(ceil(anim.length * FPS)) + 1, anim.length])
	return clip


static func _first_animation(ap: AnimationPlayer) -> Animation:
	if ap == null:
		return null
	for lib_name in ap.get_animation_library_list():
		for n in ap.get_animation_library(lib_name).get_animation_list():
			if String(n) != "RESET":
				return ap.get_animation_library(lib_name).get_animation(n)
	return null


## -1 for no track.
static func _track_indices(anim: Animation, src_index: Dictionary, n: int) -> Array:
	var rot_track := PackedInt32Array()
	rot_track.resize(n)
	rot_track.fill(-1)
	var pos_track := PackedInt32Array()
	pos_track.resize(n)
	pos_track.fill(-1)
	for t in anim.get_track_count():
		var type := anim.track_get_type(t)
		if type != Animation.TYPE_ROTATION_3D and type != Animation.TYPE_POSITION_3D:
			continue
		var path := String(anim.track_get_path(t))
		var colon := path.find(":")
		if colon < 0:
			continue
		var bone_name := _norm(path.substr(colon + 1))
		if not src_index.has(bone_name):
			continue
		if type == Animation.TYPE_ROTATION_3D:
			rot_track[src_index[bone_name]] = t
		else:
			pos_track[src_index[bone_name]] = t
	return [rot_track, pos_track]


## [our index, source index, nearest mapped ancestor's source index or -1]
static func _mapped_bones(skel: Skeleton3D, src_index: Dictionary) -> Array:
	var bones: Array = []
	for i in skel.get_bone_count():
		var m: String = MAP.get(skel.get_bone_name(i), "")
		if m == "" or not src_index.has(_norm(m)):
			continue
		bones.append([i, src_index[_norm(m)], _mapped_ancestor(skel, i, src_index)])
	return bones


static func _mapped_ancestor(skel: Skeleton3D, bone: int, src_index: Dictionary) -> int:
	var p := skel.get_bone_parent(bone)
	while p >= 0:
		var pm: String = MAP.get(skel.get_bone_name(p), "")
		if pm != "" and src_index.has(_norm(pm)):
			return src_index[_norm(pm)]
		p = skel.get_bone_parent(p)
	return -1


## From options.our_height, or 1.
static func _height_scale(src: Skeleton3D, src_index: Dictionary, options: Dictionary) -> float:
	if not options.has("our_height"):
		return 1.0
	if not src_index.has("headtopend") or not src_index.has("lefttoeend"):
		return 1.0
	var top := src.get_bone_global_rest(src_index["headtopend"]).origin.y
	var their := top - src.get_bone_global_rest(src_index["lefttoeend"]).origin.y
	if their > 0.01:
		return float(options["our_height"]) / their
	return 1.0


static func _bake_tracks(anim: Animation, src: Skeleton3D, src_index: Dictionary,
		skel: Skeleton3D, bones: Array, options: Dictionary) -> Dictionary:
	var n := src.get_bone_count()
	var indices := _track_indices(anim, src_index, n)
	var rot_track: PackedInt32Array = indices[0]
	var pos_track: PackedInt32Array = indices[1]
	var grest_inv: Array = []
	for i in n:
		grest_inv.append(src.get_bone_global_rest(i).basis.inverse())
	var tracks := {}
	for b in bones:
		tracks[skel.get_bone_name(b[0])] = []
	var hips_src: int = src_index.get("hips", -1)
	var hips_ours := -1
	for b in bones:
		if b[1] == hips_src:
			hips_ours = b[0]
	var root_motion: String = options.get("root_motion", "keep")
	var hips_keys = null
	if hips_ours >= 0 and hips_src >= 0 and pos_track[hips_src] >= 0 and root_motion != "none":
		hips_keys = []
	# Mixamo positions sit in the exporter's frame, so hip travel is measured from the first frame.
	var hips_base := Vector3.ZERO
	if hips_keys != null:
		hips_base = anim.position_track_interpolate(pos_track[hips_src], 0.0)
	var height_scale := _height_scale(src, src_index, options)
	var length := anim.length
	var steps := int(ceil(length * FPS))
	var delta: Array = []
	delta.resize(n)
	for s in steps + 1:
		var t := minf(s / FPS, length)
		_pose_deltas(anim, src, rot_track, grest_inv, t, delta)
		for b in bones:
			var d: Basis = delta[b[1]]
			if b[2] >= 0:
				d = (delta[b[2]] as Basis).inverse() * d
			var q := d.get_rotation_quaternion()
			tracks[skel.get_bone_name(b[0])].append([t, [q.x, q.y, q.z, q.w]])
		if hips_keys != null:
			var v := anim.position_track_interpolate(pos_track[hips_src], t) - hips_base
			v *= height_scale
			if root_motion == "vertical":
				v = Vector3(0.0, v.y, 0.0)
			hips_keys.append([t, [v.x, v.y, v.z]])
	var positions := {}
	if hips_keys != null:
		positions[skel.get_bone_name(hips_ours)] = hips_keys
	return {"length": length, "loop": options.get("loop", true), "tracks": tracks,
			"positions": positions, "source": "mixamo"}


## Relative to each bone's rest.
static func _pose_deltas(anim: Animation, src: Skeleton3D, rot_track: PackedInt32Array,
		grest_inv: Array, t: float, delta: Array) -> void:
	var gpose: Array = []
	gpose.resize(src.get_bone_count())
	for i in src.get_bone_count():
		var local: Basis
		if rot_track[i] >= 0:
			local = Basis(anim.rotation_track_interpolate(rot_track[i], t))
		else:
			local = src.get_bone_rest(i).basis
		var p := src.get_bone_parent(i)
		gpose[i] = (gpose[p] * local) if p >= 0 else local
		delta[i] = gpose[i] * grest_inv[i]


## Lower case, without the mixamorig prefix and separators.
static func _norm(bone_name: String) -> String:
	var lower := bone_name.to_lower().replace("mixamorig", "")
	return lower.replace(":", "").replace("_", "").replace(" ", "")


static func _find(node: Node, type_name: String) -> Node:
	if node.is_class(type_name):
		return node
	for child in node.get_children():
		var found := _find(child, type_name)
		if found != null:
			return found
	return null
