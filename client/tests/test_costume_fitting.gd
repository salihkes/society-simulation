extends SceneTree
## The garment must never replace, hide or recolor the body. Its bind pose
## must reproduce the fitted mesh exactly; elbows must use the real bend map.
const HUMAN := "res://assets/entities/character/humanoid.tscn"
const Rig := preload("res://src/character/limb_rig.gd")
const Binding := preload("res://src/theater/costumes/costume_binding.gd")
var failures := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FITTING: " + message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var source := (load(HUMAN) as PackedScene).instantiate()
	var model: Node3D = source.get_node("CharacterModel")
	source.remove_child(model)
	source.free()
	root.add_child(model)
	var rig := Rig.new()
	rig.resolve(model)
	rig.enable_joints()
	var body := {}
	for node in model.find_children("*", "MeshInstance3D", true, false):
		body[node] = [node.mesh, node.material_override, node.visible]
	rig.pose_basis(rig.left_arm, Basis(Vector3.BACK, -PI / 2))
	rig.pose_basis(rig.right_arm, Basis(Vector3.BACK, PI / 2))
	var binding := Binding.new()
	model.add_child(binding)
	check(binding.build(rig, OS.get_environment("TEST_COSTUME")), "Fitted GLB loads")
	if binding.skeleton == null:
		quit(1)
		return
	check(binding.skeleton.get_bone_count() >= 37, "All garment deformation bones imported")
	for slot in ["torso", "left_arm_ring_8", "right_leg_ring_0"]:
		check(binding.skeleton.find_bone(slot) >= 0, "Bone name survived GLB import: " + slot)
	# Exported vertices are already in the T-pose; all bind-pose skin matrices
	# must be identity instead of deforming / rotating the costume a second time.
	for bone in binding.skeleton.get_bone_count():
		check(binding.skeleton.get_bone_global_pose(bone).is_equal_approx(Transform3D.IDENTITY), "Identity T-pose: " + binding.skeleton.get_bone_name(bone))
	for inspection in [true, false, true]:
		binding.set_inspection(inspection)
		for node in body:
			check(node.mesh == body[node][0] and node.material_override == body[node][1] and node.visible == body[node][2], "Body unchanged by garment: " + node.name)
	for frame in 120:
		var amount := float(frame) / 119
		rig.pose_basis(rig.left_arm, Basis(Vector3.BACK, -PI / 2 + amount * deg_to_rad(25)))
		rig.flex(rig.left_arm, amount * deg_to_rad(40))
		binding.update_pose()
		var bender = rig.joint_of(rig.left_arm)
		var bind := Transform3D(Basis(Vector3.BACK, -PI / 2), rig.rest_of(rig.left_arm).origin).affine_inverse()
		var expected: Transform3D = rig.left_arm.transform * bender.ring_transform(bender.ring_u[8], bender.joint,
			bender.half_width, bender.axis, bender.angle) * bind
		var cap_index := binding.skeleton.find_bone("left_shoulder_cap")
		if cap_index >= 0:
			expected.origin.y += binding.skeleton.get_bone_global_pose(cap_index).origin.y
		var actual := binding.skeleton.get_bone_global_pose(binding.skeleton.find_bone("left_arm_ring_8"))
		check(actual.is_finite() and actual.is_equal_approx(expected), "Sleeve uses the actual elbow transform")
		var drape_index := binding.skeleton.find_bone("left_arm_drape_8")
		if drape_index >= 0:
			var skin_bind: Array = binding._drape_skins.left_arm_drape_8[0]
			var drape: Transform3D = skin_bind[0].get_bind_pose(skin_bind[1])
			var edge := Vector3(-2, float(binding._drape_floor.left_arm), 0.2)
			check((drape * edge).is_equal_approx(actual * edge), "Drape joins the arm skin at the tube edge")
			check(drape.basis.y.is_equal_approx(Vector3.UP), "Sleeve excess stays vertical")
	if binding._torso_shoulders:
		# A common torso lean must carry shoulder clearance with it, rather
		# than losing the lift as the shoulder falls below model-space Y=1.
		var saved := {}
		for limb in [rig.torso, rig.left_arm, rig.right_arm]:
			saved[limb] = limb.transform
		var unbowed := {}
		for label in ["left_shoulder_cap", "right_shoulder_cap", "left_arm_ring_8", "right_arm_ring_8"]:
			unbowed[label] = binding.skeleton.get_bone_global_pose(binding.skeleton.find_bone(label))
		for angle in [-30.0, 15.0, 30.0]:
			var lean := Basis(Vector3.RIGHT, deg_to_rad(angle))
			var hips := Vector3(0, -1, 0)
			var bow := Transform3D(lean, hips - lean * hips)
			for limb in saved:
				limb.transform = bow * saved[limb]
			binding.update_pose()
			for label in unbowed:
				var actual := binding.skeleton.get_bone_global_pose(binding.skeleton.find_bone(label))
				check(actual.is_equal_approx(bow * unbowed[label]), "Shoulder clearance follows the bow: " + label)
		for limb in saved:
			limb.transform = saved[limb]
		binding.update_pose()
	# Verify the source body meshes still render; no stand-in hands or feet.
	for node in body:
		check(node.mesh == body[node][0] and node.visible == body[node][2], "Body preserved after motion")
	for mesh in binding.meshes:
		check(mesh.skin != null, "Imported garment has a bound skin")
		for surface in mesh.mesh.get_surface_count():
			var arrays := mesh.mesh.surface_get_arrays(surface)
			check(arrays[Mesh.ARRAY_VERTEX].size() > 0, "Garment retains source geometry")
	var skirt_index := binding.skeleton.find_bone("skirt_front_drape")
	if skirt_index >= 0:
		HumanoidPoses.apply(rig, "seiza", 1.0)
		binding.update_pose()
		var skirt: Transform3D = binding.skeleton.get_bone_global_pose(skirt_index)
		check(skirt.is_finite() and skirt.origin.z < -0.1, "Shared hakama front clears folded knees")
	model.queue_free()
	await process_frame
	print("COSTUME FITTING TEST: ", "PASS" if failures == 0 else "FAIL", " (", failures, " failures)")
	quit(1 if failures else 0)
