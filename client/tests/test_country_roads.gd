extends SceneTree
## Real generated data, geometry and scaled physics. No full city assets.
const Roads = preload("res://src/world/region/streamed_roads.gd")
const Terrain = preload("res://src/world/region/streamed_terrain.gd")
const BakeLoader = preload("res://src/world/region/road_bake_loader.gd")
const Furniture = preload("res://src/world/region/road_furniture.gd")
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func run() -> void:
	# For travel along +Z, the left carriageway is +X. A direction board
	# must stand above that half and face the approaching driver (-Z).
	var furniture := Node3D.new()
	root.add_child(furniture)
	Furniture.install(furniture, [{"position": Vector3.ZERO, "lateral": Vector3.LEFT, "width": 52.0}])
	var forward_sign_found := false
	for node in furniture.find_children("*", "Label3D", true, false):
		if node.text == "The City":
			forward_sign_found = true
			check(node.global_position.x > 0, "Forward destination sign is on the wrong carriageway for left-hand traffic")
			check(node.global_basis.z.dot(Vector3.FORWARD) > 0.99, "Direction sign faces away from approaching traffic")
	check(forward_sign_found, "Missing forward direction sign")
	furniture.queue_free()
	var world := Node3D.new()
	world.scale = Vector3.ONE * 0.2
	var loader := BakeLoader.new()
	world.add_child(loader)
	var road := Roads.new()
	road.name = "CountryRoads"
	world.add_child(road)
	var terrain := Terrain.new()
	terrain.name = "CityTerrain"
	world.add_child(terrain)
	root.add_child(world)
	if road.manifest.is_empty():
		quit(1)
		return
	check(terrain.meta.get("road_preview_version", "") == road.manifest.version, "Workspace loader did not select road terrain before child ready")
	var preview := load("res://assets/world/region/road_preview.tscn") as PackedScene
	check(preview != null, "Road preview failed to load")
	var connections := load("res://assets/world/region/road_connections.tscn") as PackedScene
	check(connections != null, "Road marker editor failed to load")
	var samples: Array = road.manifest.inspection_stations
	var positions: Array = []
	for index in [2, samples.size() / 4, samples.size() / 2, samples.size() - 3]:
		positions.append(samples[index])
	var alignment_file := FileAccess.open(road.manifest_path.get_base_dir().path_join(str(road.manifest.version)).path_join("alignment.bin"), FileAccess.READ)
	var alignment := alignment_file.get_buffer(alignment_file.get_length()).to_float32_array()
	for kind in [1, 2]:
		for index in alignment.size() / 10:
			if int(alignment[index * 10 + 7]) == kind:
				positions.append([alignment[index * 10], alignment[index * 10 + 1], alignment[index * 10 + 2]])
				break
	# Shared chunk boundary must also have physical continuity.
	var boundary: Array = road.manifest.chunks[100].origin
	var boundary_file := FileAccess.open(road.manifest_path.get_base_dir().path_join(str(road.manifest.chunks[100].file)), FileAccess.READ)
	var first := boundary_file.get_buffer(40).to_float32_array()
	positions.append([boundary[0] + first[0], first[1], boundary[2] + first[2]])
	for index in positions.size():
		var sample: Array = positions[index]
		var local_point := Vector3(sample[0], sample[1], sample[2])
		var point := world.to_global(local_point)
		road.set_viewer(point)
		terrain.set_viewer(point)
		var deadline := Time.get_ticks_msec() + 30000
		while (road.get_streaming_stats().busy or terrain.get_streaming_stats().busy or not road.collision_ready(point)) and Time.get_ticks_msec() < deadline:
			await process_frame
		await physics_frame
		await physics_frame
		var stats: Dictionary = road.get_streaming_stats()
		check(not stats.busy and stats.failed == 0, "Road streaming did not finish")
		check(stats.chunks <= road.max_chunks and stats.colliders <= road.max_colliders, "Road streaming exceeded budgets")
		check(road.collision_ready(point), "Road collision missing after travel")
		var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 10, point - Vector3.UP * 20)
		var hit := world.get_world_3d().direct_space_state.intersect_ray(query)
		check(not hit.is_empty(), "Road raycast missed")
		if not hit.is_empty():
			check(absf(hit.position.y - point.y) < 0.06, "Road deck is missing or terrain protrudes above it at station %s: %s expected %s" % [index, hit.position.y, point.y])
		print("ROAD CHECK station=", index, " ", stats)
	# Shutdown with an active worker must not leave resources/tasks behind.
	road.set_viewer(world.to_global(Vector3.ZERO))
	world.queue_free()
	await process_frame
	print("COUNTRY ROADS failures=", failures)
	quit(0 if failures == 0 else 1)
