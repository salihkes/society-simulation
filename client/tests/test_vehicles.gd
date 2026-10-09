extends SceneTree
## Vehicles: placement, fit, boarding, driving, doors, paint, body lean and
## the camera, exercised against the real workspace scene.
##
##   godot --headless --path client -s tests/test_vehicles.gd
##
## Exits non-zero on the first failing expectation. The lean and camera
## sections drive the model directly with controlled numbers rather than by
## driving around the city, because a vehicle that has run into a building
## has no speed to lean from and that says nothing about the lean.

## Where the definitions live, for the sweep that checks every cabin's eye.
const DEFS_DIR := "res://assets/entities/vehicles/definitions/"

var fails := 0

func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   " + what)
	else:
		fails += 1
		print("  FAIL " + what)

func key(k: int, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.physical_keycode = k
	ev.pressed = down
	Input.parse_input_event(ev)

func frames(n: int) -> void:
	for i in n:
		await physics_frame

## A seat empty's height in the model's own units, walking the transforms
## by hand so it works on a model that is only parked under the root.
func seat_height(model: Node3D, anchor: String) -> float:
	var n := model.find_child(anchor, true, false)
	if not (n is Node3D):
		return 0.0
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != model:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf.origin.y

## Bounds of every mesh under the nodes whose name `wanted` accepts.
func part_bounds(model: Node3D, wanted: Callable) -> AABB:
	var box := AABB()
	var first := true
	var stack: Array = [[model, Transform3D.IDENTITY, false]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		var inside: bool = item[2]
		if n is Node3D and n != model:
			xf = xf * (n as Node3D).transform
		if not inside and wanted.call(n.name):
			inside = true
		for c in n.get_children():
			stack.append([c, xf, inside])
		if inside and n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			for i in 8:
				var p: Vector3 = xf * (n as MeshInstance3D).get_aabb().get_endpoint(i)
				box = AABB(p, Vector3.ZERO) if first else box.expand(p)
				first = false
	return box

func _initialize() -> void:
	print("== vehicle test ==")
	var ws = load("res://assets/scenes/workspace_local.tscn").instantiate()
	root.add_child(ws)
	current_scene = ws
	await frames(10)
	var nc = root.get_node_or_null("NetworkController")
	var lp = ws.find_child("humanoid", true, false)
	var vm = ws.find_child("VehicleManager", true, false)
	var amb = ws.find_child("AmbientManager", true, false)
	check(nc != null and lp != null and vm != null and amb != null, "scene, player, vehicle and ambient managers")
	if nc == null or lp == null or vm == null:
		quit(1); return
	nc.players.local_player = lp
	nc._vehicle_manager = vm
	await frames(300)

	# ── Placement and fit ──────────────────────────────────────────
	var vehicles: Dictionary = vm.vehicles()
	var spots := get_nodes_in_group("vehicle_spot").filter(func(spot): return ws.is_ancestor_of(spot) and spot.definition != null)
	check(vehicles.size() == spots.size(), "each vehicle spot is populated (%d)" % vehicles.size())
	if vehicles.is_empty():
		quit(1); return
	var v = vehicles.get("wveh_Ambulance")
	var sedan = vehicles.get("wveh_LuxurySedan")
	check(v != null and v.is_ready(), "ambulance built")
	check(sedan != null and sedan.is_ready(), "sedan built")
	if v == null or not v.is_ready():
		quit(1); return
	var doors_ok := 0
	for d in v._vm.doors:
		if d != null: doors_ok += 1
	check(doors_ok == 4, "4 doors found (%d)" % doors_ok)
	check(v._vm.wheels.size() == 4, "4 wheels (%d)" % v._vm.wheels.size())
	check(v._vm.steer_pivots.size() == 2, "2 steer pivots (%d)" % v._vm.steer_pivots.size())
	check(v._seats.size() == 5, "5 seats (%d)" % v._seats.size())
	var shapes := 0
	for c in v.get_children():
		if c is CollisionShape3D: shapes += 1
	check(shapes == 5, "collision body + 4 wheels (%d)" % shapes)
	check(v.is_on_floor(), "resting on the ground")
	check(v._seats["DriverSeat"].position.x > 0.0, "driver seat on the right (RHD)")
	check(amb.traffic.ext_vehicles.size() == vehicles.size(), "all placed vehicles registered with traffic (%d)" % amb.traffic.ext_vehicles.size())

	# ── Traffic from definitions, with paint ───────────────────────
	var built := 0
	var kinds := {}
	var wheel0 := {}
	for id in amb.traffic.cars:
		var m = amb.traffic.cars[id].get_node_or_null("Model")
		if m != null and m.is_built:
			built += 1
			kinds[m.definition.display_name] = kinds.get(m.definition.display_name, 0) + 1
			if not m.wheels.is_empty():
				wheel0[id] = m.wheels[0].transform.basis
	await frames(90)
	var rolled := 0
	for id in wheel0:
		var c = amb.traffic.cars.get(id)
		if c != null and c.get_node("Model").wheels[0].transform.basis != wheel0[id]:
			rolled += 1
	print("  traffic: %d cars, %d built, kinds %s, %d rolled wheels" % [amb.traffic.cars.size(), built, kinds, rolled])
	check(built == amb.traffic.cars.size() and built > 0, "every traffic car built from a definition")
	check(kinds.size() >= 2, "several kinds in the pool")
	check(rolled > 0, "traffic wheels roll")
	var painted := 0
	var colors := {}
	var mats := {}
	var paint_id := ""
	for id in amb.traffic.cars:
		var m = amb.traffic.cars[id].get_node_or_null("Model")
		if m != null and m.has_paint():
			painted += 1
			colors[m.body_color] = true
			paint_id = id
			for mi in m.paint_meshes:
				mats[mi.get_surface_override_material(0)] = true
	print("  paint: %d of %d recolourable, %d colours, %d materials" % [painted, amb.traffic.cars.size(), colors.size(), mats.size()])
	check(painted > 0, "recolourable cars in traffic")
	check(colors.size() > 1, "traffic is not all one colour")
	check(mats.size() <= 2, "one shared material per kind (%d)" % mats.size())
	if paint_id != "":
		var m0 = amb.traffic.cars[paint_id].get_node("Model")
		var def0 = m0.definition
		check(def0.paint_for(paint_id).body == m0.body_color, "a car id always yields the same paint")
		var seen := {}
		for n in 200:
			seen[def0.paint_for("c%d" % n).body] = true
		print("  palette spread: %d of %d colours over 200 ids" % [seen.size(), def0.paint_colors.size()])
		check(seen.size() == def0.paint_colors.size(), "ids spread across the whole palette")

	# ── Boarding ───────────────────────────────────────────────────
	lp.global_position = v.to_global(v._vm.door_position_local(0)) + v.global_transform.basis.x.normalized() * 1.5 + Vector3.UP
	await frames(2)
	vm._toggle_ride(lp)
	await frames(2)
	check(vm.riding() == v, "boarded")
	check(v.mode == v.Mode.PLAYER and v.driver_id == 0, "driver state")
	check(lp.get("_in_vehicle") == true, "player marked in vehicle")
	check(v._camera != null and v._camera.current, "vehicle camera active")
	check(v.doors_mask() & 1, "driver door swung open on boarding")

	# ── Driving ────────────────────────────────────────────────────
	var p0: Vector3 = v.global_position
	var fwd0: Vector3 = v._forward()
	var wb0: Basis = v._vm.wheels[0].transform.basis
	key(KEY_W, true)
	await frames(120)
	print("  moved %.2f m forward, speed %.1f" % [(v.global_position - p0).dot(fwd0), v.speed()])
	check((v.global_position - p0).dot(fwd0) > 2.0, "drove forward")
	check(v.speed() > 10.0, "speed built up")
	check(v._vm.wheels[0].transform.basis != wb0, "wheels rolled")
	var yaw0: float = v.global_rotation.y
	key(KEY_A, true)
	await frames(60)
	check(v._steer > 0.1, "front wheels steered left")
	check(wrapf(v.global_rotation.y - yaw0, -PI, PI) > 0.05, "vehicle turned left")
	check(v._vm.steer_pivots[0].transform.basis != v._vm._steer_rest[0], "steer pivot turned")
	key(KEY_A, false)

	# ── Body lean ──────────────────────────────────────────────────
	# Driven directly rather than by driving round the city: a vehicle that
	# has run into a building has no speed to lean from, which says nothing
	# about the lean itself.
	var shapes_before: Array = []
	for c in v.get_children():
		if c is CollisionShape3D:
			shapes_before.append(c.transform)
	key(KEY_W, false)
	key(KEY_A, false)
	key(KEY_D, false)
	var lean_of := func(speed_seq: Array, steer_rad: float) -> Vector2:
		v._vm._lean = Vector2.ZERO
		v._vm._lean_vel = Vector2.ZERO
		v._vm._lean_prev_speed = speed_seq[0]
		for sp in speed_seq:
			v._vm.animate(1.0 / 60.0, sp, steer_rad)
		return v._vm.lean_angles()
	var hold := []
	for i in 120:
		hold.append(26.0)
	var straight: Vector2 = lean_of.call(hold, 0.0)
	var left: Vector2 = lean_of.call(hold, deg_to_rad(14.0))
	var right: Vector2 = lean_of.call(hold, deg_to_rad(-14.0))
	print("  lean roll at 26 u/s, 14 deg lock: straight %.2f deg, left %.2f, right %.2f (limit %.1f)" % [rad_to_deg(straight.x), rad_to_deg(left.x), rad_to_deg(right.x), v.definition.lean_roll_deg])
	check(absf(rad_to_deg(straight.x)) < 0.2, "body sits level in a straight line")
	check(rad_to_deg(left.x) < -1.0, "body rolls out of a left turn")
	check(rad_to_deg(right.x) > 1.0, "body rolls the other way in a right turn")
	check(absf(rad_to_deg(left.x)) <= v.definition.lean_roll_deg + 0.2, "roll stays inside the vehicle's limit")
	check(absf(absf(rad_to_deg(left.x)) - absf(rad_to_deg(right.x))) < 0.1, "left and right roll are symmetric")
	# Braking: speed falling hard should put the nose down, throttle lift it
	var slowing := []
	var sp := 26.0
	for i in 40:
		sp = maxf(sp - 0.55, 0.0)
		slowing.append(sp)
	var dive: Vector2 = lean_of.call(slowing, 0.0)
	var rising := []
	sp = 2.0
	for i in 40:
		sp = minf(sp + 0.45, 30.0)
		rising.append(sp)
	var squat: Vector2 = lean_of.call(rising, 0.0)
	print("  lean pitch: braking %.2f deg, accelerating %.2f deg (limit %.1f)" % [rad_to_deg(dive.y), rad_to_deg(squat.y), v.definition.lean_pitch_deg])
	check(rad_to_deg(dive.y) < -0.3, "nose dives under braking")
	check(rad_to_deg(squat.y) > 0.3, "nose lifts under acceleration")
	# Settling back to level, and overshooting on the way (the wobble)
	var settle := []
	for i in 240:
		settle.append(0.0)
	var crossings := 0
	var prev_sign := signf(v._vm.lean_angles().x)
	v._vm._lean = Vector2(deg_to_rad(4.0), 0.0)
	v._vm._lean_vel = Vector2.ZERO
	for i in 240:
		v._vm.animate(1.0 / 60.0, 0.0, 0.0)
		var sgn := signf(v._vm.lean_angles().x)
		if sgn != 0.0 and prev_sign != 0.0 and sgn != prev_sign:
			crossings += 1
		prev_sign = sgn
	print("  settle: %.3f deg after 4 s, crossed level %d time(s)" % [rad_to_deg(v._vm.lean_angles().x), crossings])
	check(absf(rad_to_deg(v._vm.lean_angles().x)) < 0.1, "body settles level")
	check(crossings >= 1, "spring overshoots on the way back (the wobble)")
	# Nothing but the visual moved
	var shapes_after: Array = []
	for c in v.get_children():
		if c is CollisionShape3D:
			shapes_after.append(c.transform)
	check(shapes_before == shapes_after, "collision never tilted")
	check(v._vm.lean_pivot != null and v._vm.model.get_parent() == v._vm.lean_pivot, "lean sits on its own node above the model")
	check(v._seats["DriverSeat"].get_parent() == v, "seats hang off the body, not the leaning model")

	# ── The rim in the cabin ───────────────────────────────────────
	# It is its own node in the fitted interiors, so it turns with the
	# road wheels instead of sitting in the dashboard like a moulding.
	var rim = v._vm.steering_wheel
	check(rim != null, "the ambulance has a steering wheel node")
	if rim != null:
		var rest: Basis = v._vm._rim_rest
		var lock := deg_to_rad(v.definition.max_steer_deg)
		v._vm.animate(1.0 / 60.0, 0.0, lock)
		var full: Basis = rim.transform.basis
		var turned: float = rest.x.signed_angle_to(full.x, rest * v.definition.steering_wheel_axis.normalized())
		v._vm.animate(1.0 / 60.0, 0.0, -lock)
		var other: float = rest.x.signed_angle_to(rim.transform.basis.x, rest * v.definition.steering_wheel_axis.normalized())
		print("  rim at full lock: %.0f deg left, %.0f deg right" % [rad_to_deg(turned), rad_to_deg(other)])
		check(absf(rad_to_deg(turned) - v.definition.steering_wheel_deg) < 1.0, "rim winds to its full turn")
		check(turned > 0.0 and other < 0.0, "rim turns the way the road wheels do")
		v._vm.animate(1.0 / 60.0, 0.0, 0.0)
		check(rim.transform.basis.is_equal_approx(rest), "rim comes back to straight")
	# The master switch takes it all back out
	VehicleModel.lean_enabled = false
	var off: Vector2 = lean_of.call(hold, deg_to_rad(14.0))
	print("  master switch off: roll %.4f deg" % rad_to_deg(off.x))
	check(absf(rad_to_deg(off.x)) < 0.05, "master switch off leaves the body upright")
	VehicleModel.lean_enabled = true
	# And it still happens while genuinely driving
	v._vm._lean = Vector2.ZERO
	v._vm._lean_vel = Vector2.ZERO
	key(KEY_W, true)
	key(KEY_A, true)
	var peak := 0.0
	for i in 150:
		await physics_frame
		peak = maxf(peak, absf(v._vm.lean_angles().x))
	key(KEY_W, false)
	key(KEY_A, false)
	print("  driving for real: peak roll %.2f deg" % rad_to_deg(peak))
	check(rad_to_deg(peak) > 0.5, "the body leans while actually being driven")
	key(KEY_SPACE, true)
	await frames(90)
	key(KEY_SPACE, false)
	check(absf(v.speed()) < 0.5, "braked to a stop (%.2f)" % v.speed())

	# ── Doors, paint, camera ───────────────────────────────────────
	vm._toggle_doors(lp)
	await frames(50)
	check(v.doors_mask() == v.all_doors_mask(), "all doors open")
	var hatch = v._vm.doors[3]
	check(hatch.transform != v._vm._door_closed[3], "rear hatch moved")
	vm._toggle_doors(lp)
	await frames(50)
	check(hatch.transform.is_equal_approx(v._vm._door_closed[3]), "rear hatch closed again")
	if v.paintable():
		var before: Color = v._vm.body_color
		var idx: Vector2i = v.next_paint()
		check(v._vm.body_color != before, "repaint changed the colour")
		var packet: Dictionary = v.get_sync_data()
		check(int(packet.get("pb", -1)) == idx.x, "paint rides in the sync packet")
		v.set_paint_indices(-1, -1)
		v.apply_sync_data(packet)
		check(v.paint_indices().x == idx.x, "a peer applying the packet repaints too")
	else:
		print("  ambulance carries a fixed livery, nothing to repaint")
	var seat_pos: Vector3 = v._seats["DriverSeat"].global_position
	var steps: Array = []
	var monotonic := true
	var gap := 0.0
	var prev := -1.0
	var z := 0.0
	while z <= 1.0001:
		v._cam_zoom = z
		v._cam_yaw = 0.0
		v._cam_pitch = 0.0
		v._update_camera(1.0, true)
		var dist: float = v._camera.global_position.distance_to(seat_pos)
		steps.append(snappedf(dist, 0.01))
		if prev >= 0.0:
			gap = maxf(gap, dist - prev)
			if dist < prev - 0.01:
				monotonic = false
		prev = dist
		z += 0.06
	print("  camera notches (m from the seat): %s" % [steps])
	check(steps.size() >= 15, "plenty of zoom levels (%d)" % steps.size())
	check(steps[0] < 0.6, "closest notch is at the driver's eyes (%.2f m)" % steps[0])
	check(monotonic, "zoom moves outward at every notch")
	check(gap < 2.0, "no jump between levels (biggest step %.2f m)" % gap)
	var near := 0
	for dd in steps:
		if dd < 4.0: near += 1
	check(near >= 5, "several levels under 4 m (%d)" % near)
	v.set_first_person(true)
	await frames(2)
	var eye: Vector3 = v._camera.global_position
	check(eye.distance_to(seat_pos) < 1.0 and eye.y > seat_pos.y, "first person at the driver's eyes")
	v.set_first_person(false)
	v._cam_zoom = 0.6

	# ── Every cabin's eye line ─────────────────────────────────────
	# An eye_height that only looks sensible as a seated person's height
	# can still land the camera on the dashboard: these cabins have high
	# sills and high-mounted wheels. So check the eye against the cabin it
	# is in — over the wheel, and in the upper half of the side window it
	# looks out of. `tools/world/probes/probe_vehicle_cabin.gd` prints the numbers.
	for f in DirAccess.get_files_at(DEFS_DIR):
		if not f.ends_with(".tres"):
			continue
		var d: VehicleDefinition = load(DEFS_DIR + f)
		if d == null or not ResourceLoader.exists(d.model_path):
			continue
		var model: Node3D = (load(d.model_path) as PackedScene).instantiate()
		root.add_child(model)
		var sit := seat_height(model, d.driver_seat)
		var window := part_bounds(model, func(n): return n.begins_with("FrontDoor") and n.ends_with("_Glass"))
		var ceiling := part_bounds(model, func(n): return n == "InteriorCeiling")
		var wheel := part_bounds(model, func(n): return n == "SteeringWheel")
		# The opening the driver looks through: the side window's sill up to
		# the glass, or to the headliner where that comes first.
		var sill: float = window.position.y
		var lid: float = window.end.y
		if ceiling.size.y > 0.0 and ceiling.position.y > sill:
			lid = minf(lid, ceiling.position.y)
		var at := sit + d.eye_height
		var up: float = (at - sill) / maxf(lid - sill, 0.001)
		print("  %s: eye %.0f%% up the cabin opening, %+.2f over the wheel" % [d.display_name, up * 100.0, at - wheel.end.y])
		check(up > 0.55 and up < 0.9, "%s looks out of its window" % d.display_name)
		check(wheel.size.y <= 0.0 or at - wheel.end.y > 0.05, "%s sees over its steering wheel" % d.display_name)
		model.free()

	# ── Leaving, and the NPC driver ────────────────────────────────
	vm._toggle_ride(lp)
	await frames(5)
	check(vm.riding() == null and lp.get("_in_vehicle") == false, "got out")
	check(v.mode == v.Mode.IDLE and v.driver_id == v.NO_ONE, "parked state after exit")
	var out_d: float = lp.global_position.distance_to(v.global_position)
	check(out_d > 1.0 and out_d < 8.0, "stepped out beside it (%.1f m)" % out_d)
	check(not v._camera.current, "vehicle camera released")
	print("  chat: " + vm.chat_command(PackedStringArray(["/vehicle", "npc", "ambulance"])))
	await frames(30)
	check(v.mode == v.Mode.NPC and v.is_sim_driven(), "NPC mode: lane sim drives it")
	check(v._npc_figure != null, "stand-in driver seated")
	var p1: Vector3 = v.global_position
	await frames(300)
	print("  npc moved %.2f m, speed %.1f" % [v.global_position.distance_to(p1), v.speed()])
	check(v.global_position.distance_to(p1) > 1.0, "NPC drove it somewhere")
	print("  chat: " + vm.chat_command(PackedStringArray(["/vehicle", "park", "ambulance"])))
	await frames(10)
	check(v.mode == v.Mode.IDLE and not v.is_sim_driven() and v._npc_figure == null, "parked again, figure gone")
	print("  chat: " + vm.chat_command(PackedStringArray(["/vehicle", "lean", "off"])))
	check(not VehicleModel.lean_enabled, "chat switch turns lean off")
	print("  chat: " + vm.chat_command(PackedStringArray(["/vehicle", "lean", "on"])))
	check(VehicleModel.lean_enabled, "chat switch turns lean back on")
	print("== done, %d failure(s) ==" % fails)
	quit(1 if fails > 0 else 0)
