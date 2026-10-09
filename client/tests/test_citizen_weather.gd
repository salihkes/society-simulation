extends SceneTree
## Real citizen, Meshy umbrella and collision shelter. Pass -- --preview to render.
class Manager extends Node:
	var weather := "rain"
	func current_weather(): return weather
var failures := 0
func check(ok: bool, label: String):
	if not ok:
		failures += 1
		push_error("FAIL: " + label)
func _initialize(): run.call_deferred()
func run():
	var world := Node3D.new()
	world.name = "WeatherTest"
	world.scale = Vector3.ONE * 0.2
	root.add_child(world)
	current_scene = world
	var manager := Manager.new()
	world.add_child(manager)
	var avatar = load("res://assets/entities/character/humanoid.tscn").instantiate()
	var model = avatar.get_node("CharacterModel")
	avatar.remove_child(model)
	avatar.free()
	var citizen = load("res://src/life/ambient_pedestrian.gd").new()
	citizen.add_child(model)
	citizen.manager = manager
	citizen.ped_id = "weather_test"
	world.add_child(citizen)
	citizen.set_process(false)
	citizen.set_physics_process(false)
	citizen.position.y = 3.0
	await physics_frame
	await physics_frame
	var wx = citizen.weather_reaction
	wx.tick(2.0)
	check(wx.exposed and wx.umbrella_open, "outdoor citizen opens umbrella in rain")
	check(wx._umbrella != null and wx._umbrella.visible, "user's umbrella asset loads")
	check(is_equal_approx(wx.speed_factor, 1.12), "rain increases walking pace")
	citizen._animate(0.1)
	check(citizen._rig.flex_of(citizen._rig.right_arm) > 1.0, "right hand holds umbrella")
	citizen.calling = true
	citizen._animate(0.1)
	check(wx._using_left and citizen._rig.flex_of(citizen._rig.left_arm) > 1.0, "phone call uses free hand")
	citizen.calling = false
	citizen.held_prop = "pot"
	wx.tick(2.0)
	check(not wx.umbrella_open and citizen.held_prop == "pot", "two-handed task keeps its prop")
	citizen.held_prop = ""
	var roof := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(10, 0.2, 10)
	collision.shape = shape
	roof.add_child(collision)
	root.add_child(roof)
	roof.position.y = 3.0
	await physics_frame
	await physics_frame
	wx.tick(2.0)
	check(not wx.exposed and not wx.umbrella_open, "roof shelters citizen and closes umbrella")
	check(is_equal_approx(wx.speed_factor, 1.0), "indoors retains normal pace")
	roof.queue_free()
	await physics_frame
	await physics_frame
	manager.weather = "snow"
	wx.tick(2.0)
	check(wx.exposed and not wx.umbrella_open and is_equal_approx(wx.speed_factor, 0.82), "snow slows outdoor walking")
	manager.weather = "storm"
	wx.tick(2.0)
	var state: Dictionary = wx.snapshot()
	citizen._is_authority = false
	manager.weather = "clear"
	wx.tick(2.0)
	check(wx.weather_type == "storm", "replica does not make local weather decisions")
	wx.apply_snapshot({"type": "clear", "exposed": false, "umbrella": false, "pace": 1.0})
	check(not wx._umbrella.visible, "replicated clear hides umbrella")
	wx.apply_snapshot(state)
	check(wx.umbrella_open and is_equal_approx(wx.speed_factor, 1.22), "replica restores owner umbrella and pace")
	if "--preview" in OS.get_cmdline_user_args():
		root.size = Vector2i(1000, 850)
		var env := WorldEnvironment.new()
		env.environment = Environment.new()
		env.environment.background_mode = Environment.BG_COLOR
		env.environment.background_color = Color(0.32, 0.36, 0.40)
		env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.environment.ambient_light_color = Color.WHITE
		env.environment.ambient_light_energy = 0.7
		root.add_child(env)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-45, -30, 0)
		sun.light_energy = 2.0
		root.add_child(sun)
		var camera := Camera3D.new()
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 2.4
		root.add_child(camera)
		camera.position = Vector3(2.4, 2.4, -4)
		camera.look_at(Vector3(0, 1.15, 0))
		camera.current = true
		citizen._animate(0.016)
		print("UMBRELLA height=", wx._height, " top=", wx._top, " position=", wx._umbrella.position)
		await create_timer(1.0).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/citizen-umbrella.png")
	world.queue_free()
	await process_frame
	print("CITIZEN WEATHER: %d failures" % failures)
	quit(1 if failures else 0)
