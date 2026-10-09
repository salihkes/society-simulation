extends SceneTree
const StageShow := preload("res://src/theater/kabuki_performance.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var world := Node3D.new()
	world.name = "TestTheater"
	root.add_child(world)
	world.scale = Vector3.ONE * 0.2
	var theater: Node3D = load("res://assets/art/models/theater/theater.tscn").instantiate()
	world.add_child(theater)
	var show := StageShow.new()
	show.autoplay = false
	show.stage_path = NodePath("../theater/Stage")
	world.add_child(show)
	check(show.actors.size() == 2, "Both actors must spawn")
	check(show.global_position.is_equal_approx(show.stage.global_position), "Stage marker translation preserved")
	check(show.global_basis.get_scale().is_equal_approx(Vector3.ONE * 0.2), "Workspace scale preserved")
	check(show.audio.stream != null, "Score audio must load")
	check(absf(show.audio.stream.get_length() - float(show.score.duration)) < 0.05, "Audio and choreography durations match")
	for actor in show.actors:
		check(is_equal_approx(absf(actor.model.rotation.y), PI), "Source humanoid forward correction preserved")
		check(actor.find_children("*", "Camera3D", true, false).is_empty(), "Actors must not steal the camera")
		check(actor.rig.right_arm.is_ancestor_of(actor.fan), "Fan must follow the hand")
	# Exercise every authored moment and every interval, including end/reset.
	for second in range(85):
		show.seek(second)
		for actor in show.actors:
			check(actor.transform.is_finite(), "Finite actor transform")
			check(absf(actor.position.x) <= 8.01, "Actor stays within the authored stage width")
	show.seek(41)
	var held: Transform3D = show.actors[0].rig.right_arm.transform
	show.seek(69)
	show.seek(41)
	check(held.is_equal_approx(show.actors[0].rig.right_arm.transform), "Seeking must not accumulate joint rotations")
	show.seek(59)
	check(show.caption.text.begins_with("Together"), "Caption aligns with pose")
	show.pause()
	var paused := show.elapsed
	show._physics_process(1.0)
	check(is_equal_approx(show.elapsed, paused), "Pause freezes timeline")
	show.seek(83.9)
	show.playing = true
	show._physics_process(0.2)
	check(show.elapsed < 0.1, "Loop restarts")
	show.pause()
	show.loop = false
	show.seek(83.9)
	show.playing = true
	show._physics_process(0.2)
	check(not show.playing and show.elapsed == 84.0, "Nonlooping playback ends")
	await physics_frame
	await physics_frame
	show.seek(0)
	show._ground_actors()
	for actor in show.actors:
		var feet: Vector3 = actor.global_position
		var query := PhysicsRayQueryParameters3D.create(feet + Vector3.UP * 0.2, feet - Vector3.UP * 3)
		var hit := world.get_world_3d().direct_space_state.intersect_ray(query)
		check(not hit.is_empty(), "Stage floor under actor")
		if not hit.is_empty():
			check(absf(feet.y - hit.position.y) < 0.015, "Actor soles are on the stage floor")
	world.queue_free()
	await process_frame
	print("KABUKI TEST: ", "PASS" if failures == 0 else "FAIL", " (", failures, " failures)")
	quit(1 if failures else 0)
