extends SceneTree
## GPU regression: rain must cover every viewing direction at the main scene's
## scale, and changing parent scale must not change its screen coverage.
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + label)

func shot() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func count_drops(img: Image, lower: bool) -> int:
	var count := 0
	var start := img.get_height() / 2 if lower else 0
	for y in range(start, start + img.get_height() / 2):
		for x in img.get_width():
			if img.get_pixel(x, y).get_luminance() > 0.035:
				count += 1
	return count

func run() -> void:
	root.size = Vector2i(640, 400)
	var world := Node3D.new()
	world.scale = Vector3.ONE * 0.2
	root.add_child(world)
	current_scene = world
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.BLACK
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	world.add_child(environment)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.global_position = Vector3(120, 2, -80)
	camera.current = true
	var rain = load("res://assets/world/environment/rain_system.tscn").instantiate()
	world.add_child(rain)
	rain.set_process(false)
	rain.set_physics_process(false)
	rain.set_intensity(0.6)
	rain._process(3.0)
	var first: Image
	for heading in [0, 90, 180, 270]:
		camera.global_rotation.y = deg_to_rad(heading)
		var img := await shot()
		var upper := count_drops(img, false)
		var lower := count_drops(img, true)
		print("RAIN RENDER heading=%d upper=%d lower=%d" % [heading, upper, lower])
		check(upper > 40 and lower > 40, "rain surrounds the viewer, including below eye level, at %d degrees" % heading)
		if heading == 0:
			first = img
	world.scale = Vector3.ONE
	camera.global_position = Vector3(120, 2, -80)
	camera.global_rotation = Vector3.ZERO
	rain._process(0.0)
	var unscaled := await shot()
	check(first.get_data() == unscaled.get_data(), "main scene's 0.2 scale has no effect on rain rendering")
	# A teleport must immediately have the same populated volume, no fall delay.
	camera.global_position += Vector3(720, 40, -360)
	rain._process(0.0)
	var teleported := await shot()
	check(count_drops(teleported, true) > 40, "rain reaches eye level immediately after teleport")
	print("RAIN RENDER: %d failures" % failures)
	quit(1 if failures else 0)
