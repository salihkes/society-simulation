extends SceneTree
## Isolated terrain test: no workspace, network, residents or city models.
const Terrain = preload("res://src/world/region/streamed_terrain.gd")
const Job = preload("res://src/world/region/terrain_tile_job.gd")
var failures := 0
var terrain: Node3D

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("COUNTRY FAIL: " + label)

func settle(seconds := 30.0) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while terrain.get_streaming_stats().busy and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	await physics_frame
	check(not terrain.get_streaming_stats().busy, "streaming finishes within deadline")

## `exclude`: bodies to see through (a city standing on the terrain).
func ray_height(x: float, z: float, exclude: Array[RID] = []) -> float:
	var from: Vector3 = terrain.to_global(Vector3(x, 10000, z))
	var to: Vector3 = terrain.to_global(Vector3(x, -2000, z))
	var query := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, exclude)
	var hit: Dictionary = terrain.get_world_3d().direct_space_state.intersect_ray(query)
	return terrain.to_local(hit.position).y if not hit.is_empty() else NAN

func run() -> void:
	terrain = Terrain.new()
	terrain.scale = Vector3.ONE * 0.2 # Match workspace_local, including collision scaling.
	root.add_child(terrain)
	check(terrain.meta.get("synthetic", true) == false, "test actual geographic bake")
	terrain.set_viewer(Vector3.ZERO)
	await settle()
	var first: Dictionary = terrain.get_streaming_stats()
	print("COUNTRY initial: ", first)
	check(first.tiles == 289, "full default terrain window")
	check(first.colliders == 25, "default collision window")
	check(first.failed == 0, "all terrain reads succeed")
	# Grid vertices on either side of a tile boundary, negative coordinates,
	# and the original city's ground. Test real physics against baked heights.
	for p: Vector2 in [Vector2(-16, 16), Vector2(0, 16), Vector2(16, 16), Vector2(1024, 32), Vector2(-320, -400)]:
		var y: float = ray_height(p.x, p.y)
		check(is_finite(y), "ground ray hits at %s" % p)
		check(absf(y - terrain.height_at(p.x, p.y)) < 0.03, "collision matches terrain at %s" % p)
	# Cross tile/LOD boundaries repeatedly, then take long jumps. Tile count,
	# collision count and retained data must not accumulate with distance.
	for p: Vector3 in [Vector3(1100, 0, 400), Vector3(3300, 0, -2200), Vector3(32000, 0, -21000), Vector3(-22000, 0, 12000), Vector3.ZERO]:
		terrain.set_viewer(terrain.to_global(p))
		await settle()
		var stats: Dictionary = terrain.get_streaming_stats()
		print("COUNTRY travel ", p, ": ", stats)
		check(stats.tiles <= 289, "resident tiles bounded")
		check(stats.colliders <= 25, "collision bounded")
		check(stats.height_bytes <= 289 * 65 * 65 * 4, "height memory bounded")
		check(stats.triangles < 400000, "triangle budget bounded")
		check(stats.failed == 0, "no missing pages during travel")
		check(terrain.collision_ready(terrain.to_global(p)), "destination has nearby collision")
	var destination := terrain.to_global(Vector3(18000, 0, 12000))
	check(await terrain.prepare_position(destination), "teleport warm-up waits for physics")
	check(terrain.collision_ready(destination), "teleport destination ready on return")
	check(not await terrain.prepare_position(Vector3(1e8, 0, 1e8), 0.1), "out-of-coverage teleport rejected")
	var invalid: Dictionary = Job.build("res://missing-country-page.bin", 64, 1024, 0)
	check(invalid.has("error"), "missing data rejected")
	# Free with a worker in flight: exit must join cleanly.
	terrain.set_viewer(Vector3.ZERO)
	await process_frame
	terrain.queue_free()
	await process_frame
	print("COUNTRY STREAMING: %d failures" % failures)
	quit(1 if failures else 0)
