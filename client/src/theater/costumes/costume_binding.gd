extends Node3D
## Poses a separately skinned garment from the body's limb rig; the fit is baked offline.

const Bender := preload("res://src/character/limb_bender.gd")
const COSTUMES := "res://assets/entities/theater/costumes/"
const ASSET := COSTUMES + "crimson_blossom/fitted.glb"
const LIMB_SLOTS := ["left_arm", "right_arm", "left_leg", "right_leg"]
var rig: RefCounted
var asset_path := ASSET
var skeleton: Skeleton3D
var meshes: Array[MeshInstance3D] = []
var _bind := {}
var _torso_rest: Transform3D
var _drape_floor := {}
var _shoulder_cap_y := 1.0
var _torso_shoulders := false
var _skirt_front_z = null
var _drape_skins := {}  # name -> instance-local [Skin, bind index] entries


## `costume` is a folder under costumes/ or a full res:// path to a fitted asset.
func build(body_rig: RefCounted, costume := "") -> bool:
	rig = body_rig
	if costume != "":
		asset_path = costume if costume.begins_with("res://") else COSTUMES + costume + "/fitted.glb"
	_read_fit(asset_path.get_basename() + ".fit.json")
	_compute_binds()
	var asset := _load_asset()
	if asset == null:
		return false
	add_child(asset)
	var skeletons := asset.find_children("*", "Skeleton3D", true, false)
	if skeletons.size() != 1:
		push_error("Expected one garment skeleton")
		return false
	skeleton = skeletons[0]
	for node in asset.find_children("*", "MeshInstance3D", true, false):
		_prepare_mesh(node as MeshInstance3D)
	update_pose()
	return true


func _read_fit(fit_path: String) -> void:
	if not FileAccess.file_exists(fit_path):
		return
	var fit = JSON.parse_string(FileAccess.get_file_as_string(fit_path))
	if fit is Dictionary:
		_drape_floor = fit.get("drape_floor", {})
		_shoulder_cap_y = float(fit.get("shoulder_cap_y", 1.0))
		_skirt_front_z = fit.get("skirt_front_z")
		_torso_shoulders = bool(fit.get("params", {}).get("torso_shoulders", false))


## Arms are bound as in a T-pose.
func _compute_binds() -> void:
	_torso_rest = rig.rest_of(rig.torso)
	for slot in LIMB_SLOTS:
		var limb: Node3D = rig.get(slot)
		var rest: Transform3D = rig.rest_of(limb)
		if slot.ends_with("arm"):
			var angle := -PI / 2 if slot == "left_arm" else PI / 2
			rest = Transform3D(Basis(Vector3.BACK, angle), rest.origin)
		_bind[slot] = rest.affine_inverse()


## Prefers the imported scene (exports carry no GLB bytes), else parses the GLB.
func _load_asset() -> Node3D:
	if ResourceLoader.exists(asset_path, "PackedScene"):
		var packed := load(asset_path) as PackedScene
		if packed != null:
			return packed.instantiate() as Node3D
		return null
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	state.create_animations = false
	var error := document.append_from_file(asset_path, state)
	if error != OK:
		push_error("Costume import failed: " + error_string(error))
		return null
	return document.generate_scene(state) as Node3D


## Materials are instance-local copies so set_inspection can edit them.
func _prepare_mesh(mesh: MeshInstance3D) -> void:
	meshes.append(mesh)
	if not _drape_floor.is_empty() and mesh.skin != null:
		_collect_drape_binds(mesh)
	mesh.custom_aabb = AABB(Vector3(-5, -5, -3), Vector3(10, 10, 6))
	for surface in mesh.mesh.get_surface_count():
		var material := mesh.get_active_material(surface)
		if material is BaseMaterial3D:
			var copy: BaseMaterial3D = material.duplicate()
			mesh.set_surface_override_material(surface, copy)


## Skeleton3D poses lose shear, so drape bones stay identity and their pose goes into copied skin binds.
func _collect_drape_binds(mesh: MeshInstance3D) -> void:
	mesh.skin = mesh.skin.duplicate()
	for i in mesh.skin.get_bind_count():
		var label := String(mesh.skin.get_bind_name(i))
		if label == "" and mesh.skin.get_bind_bone(i) >= 0:
			label = skeleton.get_bone_name(mesh.skin.get_bind_bone(i))
		if not ("_arm_drape_" in label):
			continue
		if not _drape_skins.has(label):
			_drape_skins[label] = []
		_drape_skins[label].append([mesh.skin, i])


func update_pose() -> void:
	if skeleton == null:
		return
	_set_bone("torso", rig.torso.transform * _torso_rest.affine_inverse())
	for slot in LIMB_SLOTS:
		_pose_limb(slot)
	if _skirt_front_z != null:
		_pose_skirt_front()
	skeleton.force_update_all_bone_transforms()


func _pose_limb(slot: String) -> void:
	var limb: Node3D = rig.get(slot)
	var bender = rig.joint_of(limb)
	if bender == null:
		return
	var shoulder_lift := Vector3.ZERO
	if _drape_floor.has(slot):
		shoulder_lift = _pose_shoulder_cap(slot, limb, bender)
	for i in bender.ring_u.size():
		var bend: Transform3D = Bender.ring_transform(bender.ring_u[i], bender.joint,
			bender.half_width, bender.axis, bender.angle)
		var pose: Transform3D = limb.transform * bend * _bind[slot]
		pose.origin += shoulder_lift
		_set_bone("%s_ring_%d" % [slot, i], pose)
		if _drape_floor.has(slot):
			_pose_drape(slot, i, pose)


## Returns the cap's lift; with torso_shoulders a bow carries the cap with the torso.
func _pose_shoulder_cap(slot: String, limb: Node3D, bender) -> Vector3:
	var box: AABB = bender.mesh_instance.mesh.get_aabb()
	var highest := _shoulder_cap_y
	var cap_pose: Transform3D = rig.torso.transform * _torso_rest.affine_inverse()
	var frame := cap_pose if _torso_shoulders else Transform3D.IDENTITY
	var arm_in_frame := frame.affine_inverse() * limb.transform
	for x in [box.position.x, box.end.x]:
		for z in [box.position.z, box.end.z]:
			highest = maxf(highest, (arm_in_frame * Vector3(x, box.end.y, z)).y)
	var shoulder_lift := frame.basis.y * (highest - _shoulder_cap_y)
	cap_pose.origin += shoulder_lift
	_set_bone(slot.trim_suffix("_arm") + "_shoulder_cap", cap_pose)
	return shoulder_lift


## Sleeve bags keep hanging down: shear about the tube's lower edge.
func _pose_drape(slot: String, i: int, pose: Transform3D) -> void:
	var drape := pose
	drape.origin += (pose.basis.y - Vector3.UP) * float(_drape_floor[slot])
	drape.basis.y = Vector3.UP
	for bind in _drape_skins.get("%s_drape_%d" % [slot, i], []):
		bind[0].set_bind_pose(bind[1], drape)


## Moves the hakama's shared front drape forward to enclose both folded legs.
func _pose_skirt_front() -> void:
	var front := float(_skirt_front_z)
	for limb in [rig.left_leg, rig.right_leg]:
		var bender = rig.joint_of(limb)
		if bender != null:
			front = _leg_front(limb, bender, front)
	var skirt_pose: Transform3D = rig.torso.transform * _torso_rest.affine_inverse()
	skirt_pose.origin.z += front - float(_skirt_front_z)
	_set_bone("skirt_front_drape", skirt_pose)


## Smallest of `front` and the leg box corners' z (minus a margin), at its ends and bend rings.
func _leg_front(limb: Node3D, bender, front: float) -> float:
	var box: AABB = bender.mesh_instance.mesh.get_aabb()
	var stations: Array = [box.position.y, box.end.y]
	for u in bender.ring_u:
		stations.append(bender.joint.y - u)
	for y in stations:
		var bend: Transform3D = Bender.ring_transform(bender.joint.y-y, bender.joint,
			bender.half_width, bender.axis, bender.angle)
		for x in [box.position.x, box.end.x]:
			for z in [box.position.z, box.end.z]:
				front = minf(front, (limb.transform * bend * Vector3(x, y, z)).z - 0.08)
	return front


func _set_bone(label: String, pose: Transform3D) -> void:
	var index := skeleton.find_bone(label)
	if index >= 0:
		skeleton.set_bone_global_pose(index, pose)


## See-through, unshadowed garment for checking the fit against the body.
func set_inspection(enabled: bool) -> void:
	for mesh in meshes:
		for surface in mesh.mesh.get_surface_count():
			var material := mesh.get_active_material(surface) as BaseMaterial3D
			if material != null:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if enabled else BaseMaterial3D.TRANSPARENCY_DISABLED
				material.albedo_color.a = 0.22 if enabled else 1.0
				material.cull_mode = BaseMaterial3D.CULL_BACK if enabled else BaseMaterial3D.CULL_DISABLED
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
