extends SceneTree
## Run in an isolated project with src/ linked in, without game autoloads.

var failures := 0


func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + label)


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var world := Node3D.new()
	world.name = "localworkspace"
	world.scale = Vector3.ONE * 0.2
	root.add_child(world)
	current_scene = world
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.global_position = Vector3(120, 3, -80)
	camera.current = true
	var weather = load("res://src/world/environment/weather_controller.gd").new()
	weather.name = "WeatherController"
	world.add_child(weather)
	weather.set_process(false)
	weather.set_weather("rain")
	weather._process(1.1)
	var rain = world.get_node_or_null("RainSystem")
	check(rain != null, "localworkspace creates rain without NetworkController")
	if rain == null:
		quit(1)
		return
	rain.set_process(false)
	rain.set_physics_process(false)
	rain._process(4.0)
	var drops: MultiMeshInstance3D = rain.get_node("RainDrops")
	check(drops.visible and drops.multimesh.visible_instance_count > 0, "rain weather displays drops")
	check(rain.global_basis.get_scale().is_equal_approx(Vector3.ONE), "rain does not inherit main scene's 0.2 scale")
	var rain_audio: AudioStreamPlayer3D = rain.get_node("RainAudio")
	if ResourceLoader.exists("res://assets/world/environment/night-rain-with-distant-thunder-321446.mp3"):
		check(rain_audio.stream != null and rain_audio.stream.loop and rain_audio.playing,
			"installed rain recording loops during rain")
	if ResourceLoader.exists(weather.WIND_STREAM):
		check(weather._wind_player.stream != null and weather._wind_player.stream.loop,
			"installed wind recording loops in the weather controller")
	check(rain.global_position.is_equal_approx(camera.global_position), "rain volume surrounds the local camera")
	camera.global_position += Vector3(12, 4, -10)
	rain._process(0.1)
	check(rain.global_position.is_equal_approx(camera.global_position), "rain follows the moving camera")
	check(drops.multimesh.custom_aabb.has_point(Vector3(0, -5, 0))
		and drops.multimesh.custom_aabb.has_point(Vector3(0, 5, 0)), "bounds extend above and below the viewer")
	# Rotate and rescale the parent: rain must stay upright and full size.
	world.rotation.y = 0.7
	world.scale = Vector3.ONE * 0.1
	rain._process(0.1)
	check(rain.global_basis.is_equal_approx(Basis.IDENTITY), "parent transforms do not distort rain")
	world.rotation = Vector3.ZERO
	world.scale = Vector3.ONE * 0.2
	camera.global_position = Vector3(0, 2, 0)
	rain._process(0.1)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 0.2, 60)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	floor_body.position.y = -0.1
	await physics_frame
	await physics_frame
	for i in 8:
		rain._physics_process(0.016)
	check(rain._surface_ready, "surface scan completes")
	check(absf(rain._surface_image.get_pixel(16, 16).r) < 0.02, "rain clips at ground")
	floor_body.position.y = 5.9
	await physics_frame
	await physics_frame
	rain._surface_refresh = 0.4
	for i in 8:
		rain._physics_process(0.016)
	check(is_equal_approx(rain._surface_image.get_pixel(16, 16).r, 6.0), "roof above viewer shelters the volume")
	floor_body.queue_free()
	for kind in ["drizzle", "storm", "clear", "rain"]:
		weather.set_weather(kind)
		weather._process(1.1)
		rain._process(5.0)
		check(drops.visible == (kind != "clear"), "visibility for " + kind)
		if kind == "clear":
			check(not rain_audio.playing, "clear weather stops the rain recording")
		check(is_equal_approx(rain._target_intensity, float(weather.PROFILES[kind].rain) / 20000.0),
			"intensity for " + kind)
	rain.handle_weather_update({"type": "clear"})
	check(rain.is_raining, "legacy callback cannot override active WeatherController")
	check(not rain.get_node("WindAudio").playing, "weather uses only one wind bed")
	world.remove_child(weather)
	weather.free()
	rain.handle_weather_update({"type": "clear"})
	check(not rain.is_raining, "standalone legacy clear stops rain")
	rain.handle_weather_update({"type": "raining"})
	check(rain.is_raining, "standalone legacy raining emits drops")
	world.queue_free()
	await process_frame
	print("RAIN: %d failures" % failures)
	quit(1 if failures else 0)
