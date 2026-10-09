extends SceneTree
const State = preload("res://src/world/environment/snow_state.gd")
const Cover = preload("res://src/world/environment/snow_cover.gd")
const Patch = preload("res://src/world/environment/snow_patch.gd")
class Owner extends Node:
	var authority := true
	func _owns_weather(): return authority
class Walker extends CharacterBody3D:
	var sitting := false
class Car extends Node3D:
	var _vm = null
var failures := 0
func check(ok: bool, label: String):
	if not ok:
		failures += 1
		push_error("FAIL: " + label)
func _initialize(): run.call_deferred()
func floor_at(parent: Node, pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = pos
	return body
func run():
	var sim = State.new()
	sim.advance(60.0, true)
	check(is_equal_approx(sim.depth, 0.006), "snow accumulates in metres per real minute")
	sim.configure({"command": "one", "depth": 0.12, "rate": 0.006})
	sim.stamp(Vector3(1, 0, 1), 0, 0.13, 0.25)
	sim.advance(30.0, true)
	sim.configure({"command": "one", "depth": 0.12, "rate": 0.012})
	check(is_equal_approx(sim.depth, 0.123) and sim.records.size() == 1, "rate update does not reset depth or tracks")
	var peer = State.new()
	check(peer.apply_packet(sim.packet(true)), "late join applies full cover and track history")
	check(is_equal_approx(peer.depth, sim.depth) and peer.records.size() == 1, "late join matches owner immediately")
	sim.packet() # advance its delta cursor
	sim.stamp(Vector3(2, 0, 1), 0, 0.13, 0.25)
	var delta: Dictionary = sim.packet()
	check(peer.apply_packet(delta) and peer.records.size() == 2, "new track delta appends")
	check(peer.apply_packet(delta) and peer.records.size() == 2, "duplicate delta never duplicates a track")
	var bad := delta.duplicate(true)
	bad.start = 100
	check(not peer.apply_packet(bad) and peer.records.size() == 2, "invalid packet preserves existing snow")
	bad = delta.duplicate(true)
	bad.depth = NAN
	check(not peer.apply_packet(bad), "non-finite depth is rejected")
	sim.configure({"command": "two", "depth": 0.0})
	check(peer.apply_packet(sim.packet()) and peer.records.is_empty() and peer.depth == 0, "explicit reset clears replicated tracks")
	sim.set_depth(0.18)
	sim.stamp(Vector3.ZERO, 0, 0.13, 0.25)
	sim.advance(901.0, true)
	check(sim.depth <= sim.max_depth and sim.records.is_empty(), "snow stays capped while fresh snowfall buries tracks")
	sim.advance(20000.0, false)
	check(sim.depth == 0, "warm weather eventually melts cover completely")
	sim.set_depth(0.12)
	for i in State.MAX_TRACKS + 10:
		sim.stamp(Vector3(i * 0.2, 0, 0), 0, 0.13, 0.25)
	check(sim.records.size() == State.MAX_TRACKS and sim.first == 11, "track history is bounded")
	check(peer.apply_packet(sim.packet(true)) and peer.first == 11, "late join restores bounded history")
	peer.advance(1.0, true)
	peer.stamp(Vector3.ZERO, 0, 0.2, 0.4)
	check(sim.apply_packet(peer.packet()), "promoted peer continues existing track sequence")

	var world := Node3D.new()
	world.scale = Vector3.ONE * 0.2
	root.add_child(world)
	current_scene = world
	var owner := Owner.new()
	world.add_child(owner)
	var cover = Cover.new()
	cover.weather = owner
	world.add_child(cover)
	cover.set_physics_process(false)
	cover.state.set_depth(0.12)
	check(cover.global_basis.is_equal_approx(Basis.IDENTITY), "snow ignores workspace's 0.2 scale")
	var ground := floor_at(root, Vector3(0, -0.1, 0), Vector3(40, 0.2, 40))
	var roof := floor_at(root, Vector3(4, 3, 4), Vector3(3, 0.2, 3))
	var wire := floor_at(root, Vector3(4, 2, 1), Vector3(8, 0.04, 0.04))
	var walker := Walker.new()
	world.add_child(walker)
	walker.global_position = Vector3(0, 0.6, 0)
	var collider := CollisionShape3D.new()
	collider.shape = BoxShape3D.new()
	walker.add_child(collider)
	await physics_frame
	await physics_frame
	var hit: Dictionary = cover.static_hit(Vector3(0, 10, 0), Vector3(0, -1, 0))
	check(not hit.is_empty() and absf(hit.position.y) < 0.01, "surface scan ignores moving character bodies")
	cover._walker_contacts(walker, walker.get_instance_id())
	walker.global_position.x = 0.8
	cover._walker_contacts(walker, walker.get_instance_id())
	check(cover.state.records.size() >= 2, "walking produces alternating footprints")
	var count: int = cover.state.records.size()
	walker.global_position = Vector3(4, 0.6, 4)
	cover._walker_contacts(walker, walker.get_instance_id())
	walker.global_position.x += 0.5
	cover._walker_contacts(walker, walker.get_instance_id())
	check(cover.state.records.size() == count, "sheltered walking leaves no outdoor snow marks")
	walker.global_position = Vector3(0, 3, 0)
	cover._walker_contacts(walker, walker.get_instance_id())
	walker.global_position.x += 0.5
	cover._walker_contacts(walker, walker.get_instance_id())
	check(cover.state.records.size() == count, "airborne feet do not stamp the ground")
	var car := Car.new()
	world.add_child(car)
	car.global_position = Vector3(-4, 0, -4)
	cover._vehicle_contacts(car, car.get_instance_id())
	car.global_position.x += 1.0
	cover._vehicle_contacts(car, car.get_instance_id())
	check(cover.state.records.size() > count and cover.state.records[-1][9] == 1.0, "passing vehicle wheels leave tire tracks")
	count = cover.state.records.size()
	owner.authority = false
	cover.advance(60.0, true)
	check(is_equal_approx(cover.state.depth, 0.12) and cover.state.records.size() == count, "remote client does not accumulate snow or invent tracks")

	var patch = Patch.new()
	patch.setup(Vector2i.ZERO, 32, cover)
	while not patch.complete():
		var at: Vector2 = patch.next_position()
		patch.sample(cover.static_hit(Vector3(at.x, 20, at.y), Vector3(at.x, -2, at.y)), -1000)
	check(patch.node.mesh != null, "exposed collision builds a snow surface mesh")
	var middle := 16 * 33 + 16
	check(is_equal_approx(patch.vertices[middle].y, 3.1), "snow accumulates on roof, not sheltered floor beneath")
	check(absf(patch.vertices[4 * 33 + 16].y) < 0.01, "thin overhead wires do not punch wide gaps into ground snow")
	var arrays: Array = patch.node.mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var bridges := false
	for i in range(0, indices.size(), 3):
		var ys := [patch.vertices[indices[i]].y, patch.vertices[indices[i+1]].y, patch.vertices[indices[i+2]].y]
		if ys.max() - ys.min() > 1.0:
			bridges = true
	check(not bridges, "mesh never stretches from a roof edge down to the road")
	patch.paint(PackedFloat32Array([1,0,1,0,0.3,0.5,0.08,0,0,0]), 1, 0, 0)
	check(patch.image.get_pixel(16,16).r > 0.05, "footstep changes displacement texture")
	var old_mesh: Mesh = patch.node.mesh
	var old_node: MeshInstance3D = patch.node
	var old_texture: ImageTexture = patch.texture
	var old_mark: Color = patch.image.get_pixel(16,16)
	cover._patches[Vector2i.ZERO] = patch
	cover.refresh_surfaces()
	check(patch.node.mesh == old_mesh and not patch.node.is_queued_for_deletion(), "refresh retains the visible mesh while sampling")
	patch.rebuild(16)
	for i in 10:
		var at: Vector2 = patch.next_position()
		patch.sample(cover.static_hit(Vector3(at.x,20,at.y),Vector3(at.x,-2,at.y)), -1000)
	check(patch.node.mesh == old_mesh and patch.image.get_pixel(16,16) == old_mark, "partial LOD rebuild preserves cover and track map")
	cover.refresh_surfaces()
	check(patch.node.mesh == old_mesh, "another refresh during sampling never clears the old mesh")
	while not patch.complete():
		var at: Vector2 = patch.next_position()
		patch.sample(cover.static_hit(Vector3(at.x,20,at.y),Vector3(at.x,-2,at.y)), -1000)
	check(patch.node == old_node and patch.node.mesh != old_mesh and patch.texture == old_texture, "completed rebuild swaps only the mesh, retaining node and tracks")
	patch.rebuild(128)
	while not patch.complete():
		var at: Vector2 = patch.next_position()
		patch.sample(cover.static_hit(Vector3(at.x,20,at.y),Vector3(at.x,-2,at.y)), -1000)
	check(patch.cursor == 33 * 33 and patch.vertices.size() == 129 * 129, "fine track geometry reuses coarse collision samples")
	patch.dispose()
	ground.queue_free()
	roof.queue_free()
	wire.queue_free()
	world.queue_free()
	await process_frame
	print("SNOW: %d failures" % failures)
	quit(1 if failures else 0)
