extends SceneTree
## The carved mask fits the head independently of source size and stays
## attached through head motion. Render checks still judge its appearance.
const Performer := preload("res://src/theater/performer.gd")
var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var actor := Performer.new()
	root.add_child(actor)
	actor.build({"mask_model": "ivory_noh_mask"})
	var head: MeshInstance3D = actor.rig.head
	var mask: Node3D = head.get_node("Mask")
	var carved: Node3D = mask.get_node("Carved")
	# Read only the head mesh: accessories must not inflate the target.
	var face: AABB = head.transform * head.mesh.get_aabb()
	var fitted: AABB = carved.transform * Performer._mesh_bounds(carved)
	check(absf(fitted.size.x - face.size.x * 0.96) < 0.001, "Mask spans the face width")
	check(absf(fitted.size.y - face.size.y * 0.98) < 0.001, "Mask height matches the face")
	check(absf(fitted.get_center().x - face.get_center().x) < 0.001, "Mask centred horizontally")
	check(absf(fitted.get_center().y - face.get_center().y) < 0.001, "Mask centred vertically")
	check(absf(fitted.end.z - (face.position.z - 0.012)) < 0.001, "Mask back rests against face")
	var attachment: Transform3D = head.global_transform.affine_inverse() * carved.global_transform
	for angles in [Vector2(-35, -20), Vector2(35, 15), Vector2.ZERO]:
		actor.apply_channels(StagePose.merge(StagePose.standing(), StagePose.from_degrees({"head_yaw": angles.x, "head_pitch": angles.y})))
		var posed: Transform3D = head.global_transform.affine_inverse() * carved.global_transform
		check(attachment.is_equal_approx(posed), "Mask stays attached during head turns and tilts")
	actor.queue_free()
	await process_frame
	print("MASK FIT TEST: ", "PASS" if failures == 0 else "FAIL", " (", failures, " failures)")
	quit(1 if failures else 0)
