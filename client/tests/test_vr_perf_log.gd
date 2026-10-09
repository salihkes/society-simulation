extends SceneTree
## Regression: headset diagnostics must not freeze or hide the current world.
## Run with --headless --xr-mode off --path client
##   --script res://tests/test_vr_perf_log.gd


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := Node3D.new()
	world.name = "DiagnosticTestWorld"
	root.add_child(world)
	current_scene = world
	var logger: Node = load("res://src/debug/vr_perf_log.gd").new()
	root.add_child(logger)
	logger.set_process(false)
	# Invoke explicitly on desktop too. Cross every former phase boundary,
	# checking each second so a later reset cannot conceal a broken interval.
	for second in range(1, 61):
		logger._process(1.0)
		if not world.visible or world.process_mode != Node.PROCESS_MODE_INHERIT:
			push_error("VR diagnostics changed the world at second %d" % second)
			quit(1)
			return
	logger.queue_free()
	world.queue_free()
	await process_frame
	print("PASS: VR diagnostics leave the world visible and processing for 60 simulated seconds")
	quit()
