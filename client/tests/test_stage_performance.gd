extends SceneTree
## Headless check of the stage performance: performers spawn, face the house,
## follow the score deterministically, sit on the theater floor, and the
## soundtrack matches the score's duration.
##
##   Godot --headless --path client --script res://tests/test_stage_performance.gd

const StageShow := preload("res://src/theater/stage_performance.gd")
var failures := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var world := Node3D.new()
	world.name = "TestTheater"
	world.scale = Vector3.ONE * 0.2
	root.add_child(world)
	var theater: Node3D = load("res://assets/art/models/theater/theater.tscn").instantiate()
	world.add_child(theater)
	var show := StageShow.new()
	show.score_path = "res://assets/entities/theater/plays/between_the_acts.json"
	show.audio_path = "res://assets/art/sound/theater/between_the_acts.mp3"
	load("res://src/scenes/theater_rehearsal.gd").pick_play(show)
	show.autoplay = false
	show.stage_path = NodePath("../theater/Stage")
	world.add_child(show)

	check(not show.score.is_empty(), "Score loads")
	check(show.performers.size() == show.score.tracks.size(), "One performer per track")
	check(show.duration > 60.0, "Score is longer than a minute")
	check(show.global_position.is_equal_approx(show.stage.global_position), "Stage marker position preserved")
	check(show.global_basis.get_scale().is_equal_approx(Vector3.ONE * 0.2), "Workspace scale preserved")

	# Facing: the house lies along the theater's -X. A performer at yaw 0 must
	# look toward it, i.e. its +Z (model -Z after the PI flip) points at -X in theater space.
	show.seek(0.0)
	for performer in show.performers:
		performer.apply_pose({"x": 0, "z": 0, "yaw": 0.0, "head_yaw": 0.0, "torso": Vector3.UP,
			"left_arm": Vector3.DOWN, "right_arm": Vector3.DOWN, "left_leg": Vector3.DOWN, "right_leg": Vector3.DOWN})
		var look: Vector3 = theater.global_basis.inverse() * performer.global_basis.z
		check(look.normalized().dot(Vector3.LEFT) > 0.99, "Performer at yaw 0 faces the house (theater -X), got " + str(look.normalized()))
		var model_look: Vector3 = theater.global_basis.inverse() * (-performer.model.global_basis.z)
		check(model_look.normalized().dot(Vector3.LEFT) > 0.99, "Humanoid mesh front faces the house, got " + str(model_look.normalized()))
		check(is_equal_approx(absf(performer.model.rotation.y), PI), "Mesh keeps the PI forward correction")
		check(performer.find_children("*", "Camera3D", true, false).is_empty(), "No camera on performers")

	if show.audio.stream != null:
		check(absf(show.audio.stream.get_length() - show.duration) < 1.0, "Soundtrack length matches the score (%.1f vs %.1f)" % [show.audio.stream.get_length(), show.duration])
	else:
		check(false, "Soundtrack loads")

	# Walk the whole timeline; every pose must be finite and inside the stage.
	var step := 0.5
	var t := 0.0
	while t <= show.duration:
		show.seek(t)
		for performer in show.performers:
			check(performer.transform.is_finite(), "Finite performer transform at %.1f" % t)
			check(absf(performer.position.x) <= 10.0 and absf(performer.position.z) <= 6.0, "Performer inside the stage at %.1f" % t)
		t += step

	# Seeking must be deterministic: same time, same joints.
	show.seek(120.0)
	var held: Transform3D = show.performers[0].rig.right_arm.transform
	var held_pos: Vector3 = show.performers[0].position
	show.seek(300.0)
	show.seek(120.0)
	check(held.is_equal_approx(show.performers[0].rig.right_arm.transform), "Seeking does not accumulate joint rotation")
	check(held_pos.is_equal_approx(show.performers[0].position), "Seeking does not accumulate position")

	# Pause freezes; loop restarts; non-loop ends.
	show.pause()
	var paused := show.elapsed
	show._physics_process(1.0)
	check(is_equal_approx(show.elapsed, paused), "Pause freezes the timeline")
	show.seek(show.duration - 0.1)
	show.playing = true
	show._physics_process(0.2)
	check(show.elapsed < 0.5, "Loop restarts at the end")
	show.pause()
	show.loop = false
	show.seek(show.duration - 0.1)
	show.playing = true
	show._physics_process(0.2)
	check(not show.playing and show.elapsed == show.duration, "Non-looping playback ends")

	# Floor placement.
	await physics_frame
	await physics_frame
	show.seek(60.0)
	show._ground_performers()
	for performer in show.performers:
		var feet: Vector3 = performer.global_position
		var query := PhysicsRayQueryParameters3D.create(feet + Vector3.UP * 0.2, feet - Vector3.UP * 3.0)
		var hit := world.get_world_3d().direct_space_state.intersect_ray(query)
		check(not hit.is_empty(), "Stage floor under " + performer.name)
		if not hit.is_empty():
			check(absf(feet.y - hit.position.y) < 0.02, "%s soles on the floor (%.3f)" % [performer.name, feet.y - hit.position.y])

	world.queue_free()
	await process_frame
	print("STAGE TEST: ", "PASS" if failures == 0 else "FAIL", " (", failures, " failures)")
	quit(1 if failures else 0)
