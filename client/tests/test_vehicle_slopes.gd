extends SceneTree
## Isolated collision regression; no city assets, networking or input needed.
## godot --headless --path client -s tests/test_vehicle_slopes.gd

class TestCar extends DrivableVehicle:
	func _ready() -> void:
		definition = VehicleDefinition.new()
		definition.drive_coast = 0.0
		_wheelbase_units = 8.0
		_wheel_radius_units = 1.0
		floor_max_angle = deg_to_rad(52.0)
		for x in [-2.0, 2.0]:
			for z in [-4.0, 4.0]:
				var at := Vector3(x, 1.0, z)
				_ground_probes.append(at)
				var shape := CollisionShape3D.new()
				var sphere := SphereShape3D.new()
				sphere.radius = 0.98
				shape.shape = sphere
				shape.position = at
				add_child(shape)
		var body := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4.0, 2.0, 9.0)
		body.shape = box
		body.position.y = 2.0
		add_child(body)
		_is_authority = true

var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func frames(count: int) -> void:
	for i in count:
		await physics_frame

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	for world_scale in [1.0, 0.2]:
		for slope in [Vector3.ZERO, Vector3(12, 0, 0), Vector3(-12, 0, 0), Vector3(8, 0, 7)]:
			await ramp(world_scale, slope)
		await hill_transition(world_scale)
	for model in ["mint_mini", "ambulance"]:
		await ramp(0.2, Vector3(12, 0, 0), model)
	print("VEHICLE SLOPES: %d failures" % failures)
	quit(1 if failures else 0)

func ramp(world_scale: float, angles: Vector3, model := "") -> void:
	var scene := Node3D.new()
	scene.scale = Vector3.ONE * world_scale
	root.add_child(scene)
	current_scene = scene
	var road := StaticBody3D.new()
	scene.add_child(road)
	road.rotation_degrees = angles
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 2, 200)
	floor_shape.shape = box
	floor_shape.position.y = -1.0
	road.add_child(floor_shape)
	var car: DrivableVehicle
	if model.is_empty():
		car = TestCar.new()
	else:
		car = DrivableVehicle.new()
		car.definition = load("res://assets/entities/vehicles/definitions/%s.tres" % model).duplicate()
		car.definition.drive_coast = 0.0
		car.definition.lean_pitch_deg = 0.0
		car.definition.lean_roll_deg = 0.0
		car._is_authority = true
	car.position.y = 3.0
	scene.add_child(car)
	await frames(120)
	var expected := road.global_basis.y.normalized()
	var label := "scale=%s slope=%s model=%s" % [world_scale, angles, model]
	check(car.is_on_floor(), "parked contact " + label)
	check(car.global_basis.y.normalized().angle_to(expected) < deg_to_rad(1.0), "parked alignment " + label)
	var parked := car.global_position
	await frames(120)
	check(car.global_position.distance_to(parked) < 0.05 * world_scale, "parked drift " + label)
	car._speed = 12.0
	await frames(120)
	check(car.is_on_floor(), "moving contact " + label)
	check(car.global_basis.y.normalized().angle_to(expected) < deg_to_rad(1.0), "moving alignment " + label)
	check(car.global_position.z < parked.z - 10.0 * world_scale, "forward travel " + label)
	check(absf(car._forward().x) < 0.001, "heading preserved " + label)
	check(absf(car.global_basis.get_scale().x - world_scale) < 0.0001, "scale preserved " + label)
	car.set_first_person(true)
	car.activate_camera()
	check(car._camera.global_basis.z.normalized().angle_to(car.global_basis.z.normalized()) < 0.001,
		"cabin follows chassis " + label)
	# All four wheel centres should be one radius above the plane.
	for wheel in car._ground_probes:
		var height := car.to_global(wheel).dot(expected) / world_scale
		check(absf(height - car._wheel_radius_units * 0.98) < 0.12, "wheel clearance %s: %s" % [label, height])
	# Removing the road must release the car; the probes cannot hold it up.
	road.queue_free()
	var before_fall := car.global_position.y
	await frames(30)
	check(not car.is_on_floor() and car.global_position.y < before_fall - 1.0, "ledge gravity " + label)
	print("Checked ", label)
	scene.queue_free()
	await frames(2)

func hill_transition(world_scale: float) -> void:
	var scene := Node3D.new()
	scene.scale = Vector3.ONE * world_scale
	root.add_child(scene)
	var road := StaticBody3D.new()
	scene.add_child(road)
	var vertices := PackedVector3Array()
	var profile := [Vector2(100, 0), Vector2(0, 0), Vector2(-30, 6), Vector2(-60, 0), Vector2(-100, 0)]
	for i in profile.size() - 1:
		var a := Vector3(-50, profile[i].y, profile[i].x)
		var b := Vector3(50, profile[i].y, profile[i].x)
		var c := Vector3(-50, profile[i + 1].y, profile[i + 1].x)
		var d := Vector3(50, profile[i + 1].y, profile[i + 1].x)
		# Godot front faces use clockwise winding when viewed from above.
		vertices.append_array(PackedVector3Array([a, c, b, b, c, d]))
	var shape := CollisionShape3D.new()
	var mesh := ConcavePolygonShape3D.new()
	mesh.set_faces(vertices)
	shape.shape = mesh
	road.add_child(shape)
	var car := TestCar.new()
	car.position = Vector3(0, 3, 20)
	scene.add_child(car)
	await frames(120)
	car._speed = 12.0
	var min_pitch := 0.0
	var max_pitch := 0.0
	var contacts := 0
	var previous := car.global_basis.y.normalized()
	var max_change := 0.0
	for i in 480:
		await physics_frame
		var up := car.global_basis.y.normalized()
		max_change = maxf(max_change, previous.angle_to(up))
		previous = up
		var pitch := asin(-car.global_basis.z.normalized().y)
		min_pitch = minf(min_pitch, pitch)
		max_pitch = maxf(max_pitch, pitch)
		if car.is_on_floor():
			contacts += 1
	check(min_pitch < deg_to_rad(-9) and max_pitch > deg_to_rad(9), "follows both sides of hill")
	check(contacts > 460, "keeps contact through crest and dips: %d/480" % contacts)
	check(max_change < deg_to_rad(4), "smooth pitch through transitions")
	check(car.position.z < -65 and absf(car.position.y) < 0.15, "returns to flat after hill")
	check(car.global_basis.y.normalized().angle_to(Vector3.UP) < deg_to_rad(1), "levels after hill")
	print("Checked hill transitions scale=", world_scale, " contacts=", contacts)
	scene.queue_free()
	await frames(2)
