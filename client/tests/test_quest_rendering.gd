extends SceneTree
## Regression coverage for redundant lighting updates and the exported Quest
## profile. The profile must not mutate shared resources or shadow flags.

class ObservedEnvironment extends "res://src/world/environment/environment_controller.gd":
	var updates := 0
	func update_environment():
		updates += 1
		super.update_environment()

var failures := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + label)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var environment := WorldEnvironment.new()
	environment.name = "WorldEnvironment"
	world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	world.add_child(sun)
	var lamp := OmniLight3D.new()
	lamp.shadow_enabled = true
	world.add_child(lamp)
	var authored := Environment.new()
	authored.glow_enabled = true
	var controller := ObservedEnvironment.new()
	controller.time_mode = controller.TimeMode.MANUAL
	controller.manual_time_hours = 12.0
	controller.day_environment = authored
	controller.sunset_environment = authored
	controller.night_environment = authored
	controller.sun_light = sun
	world.add_child(controller)
	controller.set_process(false)
	var initial_updates := controller.updates
	for i in 120:
		controller._process(1.0 / 72.0)
	check(controller.updates == initial_updates, "unchanged time does not rewrite lighting for 120 frames")
	controller.weather_dim = 0.5
	controller._process(1.0 / 72.0)
	check(controller.updates == initial_updates + 1 and is_equal_approx(sun.light_energy, 0.5),
		"weather dimming applies immediately even when time is unchanged")
	controller.manual_time_hours = 0.0
	controller._process(1.0 / 72.0)
	check(not sun.visible, "manual time changes still switch day to night")
	controller.switch_to_accelerated_time()
	initial_updates = controller.updates
	for i in 3:
		controller._process(1.0 / 72.0)
	check(controller.updates == initial_updates + 3, "accelerated time remains continuous")
	controller._apply_quest_rendering()
	check(authored.glow_enabled, "Quest profile preserves the shared authored environment")
	check(not controller.day_environment.glow_enabled and not controller.night_environment.glow_enabled,
		"Quest disables glow on its runtime copies")
	check(sun.shadow_enabled and lamp.shadow_enabled, "Quest profile does not disable authored shadows")
	check(sun.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL,
		"Quest sun uses one shadow split")
	controller.realtime_sky_environment = null
	controller.sky_mode = controller.SkyMode.PROCEDURAL
	controller._setup_procedural_sky()
	check(controller._proc_env != null and not controller._proc_env.glow_enabled,
		"lazily loaded procedural sky also gets Quest profile")
	var config := ConfigFile.new()
	check(config.load("res://project.godot") == OK, "main project config loads")
	check(config.get_value("rendering", "lights_and_shadows/directional_shadow/size.mobile", 0) == 2048,
		"normal exports include the Quest directional shadow size")
	world.queue_free()
	await process_frame
	print("QUEST RENDERING: %d failures" % failures)
	quit(1 if failures else 0)
