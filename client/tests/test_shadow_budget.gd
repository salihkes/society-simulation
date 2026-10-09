extends SceneTree
## The headset shadow cap: it may only ever take shadows away, it must respect
## the count and the distance cutoff, and it must pick by reach over distance
## rather than by distance alone.
const BudgetScript = preload("res://src/world/environment/shadow_budget.gd")

var failures := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + label)

func _initialize() -> void:
	run.call_deferred()

func omni(world: Node3D, at: Vector3, reach: float, shadows: bool) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.omni_range = reach
	light.shadow_enabled = shadows
	world.add_child(light)
	light.global_position = at
	return light

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.global_position = Vector3.ZERO
	cam.current = true

	var budget := BudgetScript.new()
	budget.budget = 2
	budget.max_distance = 40.0
	world.add_child(budget)
	# start() by hand: _ready only self-starts on Android, so the desktop test
	# drives the same code path the headset runs.
	budget.start()

	# Authored before the cap exists, and authored after it — node_added has
	# to catch the second kind, which is how streamed interiors arrive.
	var near := omni(world, Vector3(1, 0, 0), 10.0, true)
	var mid := omni(world, Vector3(3, 0, 0), 10.0, true)
	var wide := omni(world, Vector3(5, 0, 0), 50.0, true)
	var far := omni(world, Vector3(0, 0, 100), 10.0, true)
	var authored_off := omni(world, Vector3(1, 0, 0), 10.0, false)
	await process_frame

	check(budget._lights.size() == 4, "tracks the four shadowed lights, not the fifth")
	check(not budget._lights.has(authored_off), "a light authored without shadows is not tracked")

	budget.apply_now()
	# near scores 100/1, wide 2500/25 = 100, mid 100/9. The two hundreds win.
	check(near.shadow_enabled, "the nearest light keeps its shadow")
	check(wide.shadow_enabled, "a wide light outranks a closer small one")
	check(not mid.shadow_enabled, "the light past the budget loses its shadow")
	check(not far.shadow_enabled, "a light beyond the cutoff never casts")
	check(not authored_off.shadow_enabled, "the cap never switches a shadow on")

	# Walking toward the loser brings its shadow back: the cap is a live
	# ranking, not a one-time cull.
	cam.global_position = Vector3(3, 0, 0)
	budget.apply_now()
	check(mid.shadow_enabled, "the ranking recovers a light the camera approaches")

	# Nothing within reach, so nothing should be paying.
	cam.global_position = Vector3(0, 0, 500)
	budget.apply_now()
	check(not near.shadow_enabled and not wide.shadow_enabled and not mid.shadow_enabled,
		"everything beyond the cutoff is switched off")

	# A light that goes away must be dropped without taking the pass with it.
	wide.queue_free()
	await process_frame
	cam.global_position = Vector3.ZERO
	budget.apply_now()
	check(budget._lights.size() == 3, "a freed light is pruned from the tracking list")
	check(near.shadow_enabled and mid.shadow_enabled, "the freed light's slot is reused")

	world.queue_free()
	await process_frame
	print("SHADOW BUDGET: %d failures" % failures)
	quit(1 if failures else 0)
