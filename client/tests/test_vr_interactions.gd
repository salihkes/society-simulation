extends SceneTree
## No headset or server: exercise driving inputs, tracked seat transforms,
## closest-target dispatch, and the real lifts' spatial UI/network requests.
const Interactions := preload("res://src/character/vr_interactions.gd")
const Car := preload("res://src/vehicles/drivable_vehicle.gd")

class Controls extends RefCounted:
	var left_hand: XRController3D
	var right_hand: XRController3D

class Player extends "res://src/character/unified_character.gd":
	func _ready(): pass
	func _physics_process(_delta): pass

class Vehicle extends Node3D:
	var activations := 0
	func activate_camera(): activations += 1
	func deactivate_camera(): pass
	func vr_eye_position(seat): return seat.global_position + Vector3.UP * 0.5

class Target extends Node:
	var distance := INF
	var calls := 0
	func vr_interaction_distance(_body): return distance
	func vr_interact(_body): calls += 1

class Players extends RefCounted:
	var local_player: Node3D

class Network extends RefCounted:
	var connected := true
	var players := Players.new()
	var sent: Array = []
	func send_json(data): sent.append(data)

class Manager extends Node:
	var _is_authority := false
	func is_authority(): return _is_authority
	func residents(): return null
	func peds(): return null

var failures := 0
func check(ok: bool, label: String):
	if not ok:
		failures += 1
		push_error("FAIL: " + label)

func _initialize(): run.call_deferred()
func run():
	var controllers := XROrigin3D.new()
	root.add_child(controllers)
	var input := Controls.new()
	var trackers: Array[XRControllerTracker] = []
	for hand_name in ["vr_test_left", "vr_test_right"]:
		var tracker := XRControllerTracker.new()
		tracker.name = hand_name
		tracker.type = XRServer.TRACKER_CONTROLLER
		XRServer.add_tracker(tracker)
		trackers.append(tracker)
		var hand := XRController3D.new()
		hand.tracker = tracker.name
		hand.pose = &"aim"
		controllers.add_child(hand)
		tracker.set_pose(&"aim", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		if hand_name.ends_with("left"): input.left_hand = hand
		else: input.right_hand = hand
	await process_frame
	trackers[0].set_input(&"primary", Vector2(1, 1))
	check(Car.vr_controls(input) == Vector3(1, -1, 0), "forward/right maps to accelerator/right steering")
	trackers[0].set_input(&"primary", Vector2(-1, -1))
	trackers[1].set_input(&"grip_click", true)
	check(Car.vr_controls(input) == Vector3(-1, 1, 1), "reverse/left and independent brake")
	trackers[0].set_input(&"primary", Vector2(0.1, -0.1))
	trackers[1].set_input(&"grip_click", false)
	check(Car.vr_controls(input) == Vector3.ZERO, "released sticks do not creep")
	trackers[0].set_input(&"primary", Vector2.ONE)
	trackers[0].invalidate_pose(&"aim")
	check(Car.vr_controls(input) == Vector3.ZERO, "lost tracking does not retain throttle")
	trackers[0].set_pose(&"aim", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)

	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	world.scale = Vector3.ONE * 0.2
	var player := Player.new()
	player.is_vr_mode = true
	player.vr_movement = VRMovement.new()
	player.vr_movement.left_hand = input.left_hand
	player.vr_movement.right_hand = input.right_hand
	player.character_model = Node3D.new()
	player.add_child(player.character_model)
	var origin := XROrigin3D.new()
	origin.name = "XROrigin3D"
	origin.scale = Vector3.ONE * 3
	origin.position = Vector3(1, -2.9, -1)
	player.add_child(origin)
	player.xr_origin = origin
	var head := XRCamera3D.new()
	head.name = "XRCamera3D"
	head.position = Vector3(0.3, 1.7, 0.1)
	head.rotation.y = 0.4
	origin.add_child(head)
	world.add_child(player)
	var saved := origin.transform
	var perceived_scale := head.global_basis.x.length()
	var vehicle := Vehicle.new()
	world.add_child(vehicle)
	vehicle.position = Vector3(5, 0, 4)
	vehicle.rotation.y = 0.7
	var seat := Node3D.new()
	vehicle.add_child(seat)
	seat.position = Vector3(1, 2, 0)
	player.enter_vehicle(vehicle, seat, true)
	check(player.get_parent() == seat and player._in_vehicle, "VR driver rides the seat")
	check(vehicle.activations == 0 and head.current, "boarding preserves XR camera")
	check(head.global_position.distance_to(vehicle.vr_eye_position(seat)) < 0.001, "tracked eye offset centered at seat")
	check(is_equal_approx(head.global_basis.x.length(), perceived_scale), "VR scale preserved under scaled world")
	var seated := head.global_position
	head.position.x += 0.1
	check(head.global_position.distance_to(seated) > 0.05, "physical head movement remains available")
	player.exit_vehicle(Vector3(2, 1, 3))
	check(player.get_parent() == world and not player._in_vehicle, "exit restores parent")
	check(origin.transform.is_equal_approx(saved) and head.current, "exit restores walking rig and XR camera")
	check(player.global_position.is_equal_approx(Vector3(2, 1, 3)), "exit honors the ground-safe position")

	var actions := Interactions.new()
	player.add_child(actions)
	actions.set_process(false)
	var far := Target.new()
	var near := Target.new()
	world.add_child(far)
	world.add_child(near)
	far.add_to_group("vr_interactable")
	near.add_to_group("vr_interactable")
	far.distance = 2
	near.distance = 1
	trackers[0].set_input(&"ax_button", true)
	actions._process(0.016)
	actions._process(0.016)
	check(near.calls == 1 and far.calls == 0, "one press reaches only the nearest object")
	check(player.vr_movement.movement_input == Vector2.ZERO, "interaction did not require a locomotion tick")
	trackers[0].set_input(&"ax_button", false)
	actions._process(0.016)
	player.is_remote_player = true
	trackers[0].set_input(&"ax_button", true)
	actions._process(0.016)
	check(near.calls == 1, "remote bodies cannot dispatch local interactions")
	player.is_remote_player = false
	trackers[0].set_input(&"ax_button", false)
	far.queue_free()
	near.queue_free()
	await process_frame

	for path in _lift_scenes():
		var lift = load(path).instantiate()
		world.add_child(lift)
		lift.set_process(false)
		lift.set_physics_process(false)
		var network := Network.new()
		network.players.local_player = player
		lift._nc = network
		var manager := Manager.new()
		world.add_child(manager)
		lift._manager = manager
		var school: bool = path.contains("school")
		player.global_position = lift.to_global(Vector3(-4 if school else 8.2, lift.FLOORS[0] + 1, 0))
		lift.vr_interact(player)
		check(network.sent.size() == 1 and network.sent[0].floor == 0, path + " VR landing call uses network request")
		player.global_position = lift.to_global(Vector3(9 if school else 0, lift.FLOORS[0] + 1, 0))
		check(lift.in_cabin(player), path + " test passenger in cabin")
		lift.vr_interact(player)
		check(is_instance_valid(lift._vr_panel) and player.key_holder == lift, path + " VR selector owns input")
		check(lift._vr_panel.sub_viewport.size == Vector2i(480, 600), path + " selector has headset viewport")
		var panel = lift._vr_panel
		await process_frame
		await process_frame
		var buttons = panel.sub_viewport.find_children("*", "Button", true, false)
		check(buttons.size() == lift.FLOORS.size() + 1, path + " all floors and close button available")
		var pixel: Vector2 = buttons[0].get_global_rect().get_center()
		var uv := pixel / Vector2(panel.VIEWPORT_SIZE)
		var hit: Vector3 = panel.quad.to_global(Vector3((uv.x - 0.5) * panel.PANEL_SIZE.x, (0.5 - uv.y) * panel.PANEL_SIZE.y, 0))
		var normal: Vector3 = panel.quad.global_basis.z.normalized()
		input.right_hand.global_transform = Transform3D(panel.quad.global_basis.orthonormalized(), hit + normal * 0.4)
		panel.pointer._right_hand = input.right_hand
		trackers[1].set_input(&"trigger_click", false)
		panel.pointer.update_pointer(0.2)
		trackers[1].set_input(&"trigger_click", true)
		panel.pointer.update_pointer(0.2)
		# Move off the card while held: cancel, then require a fresh press.
		input.right_hand.global_position += Vector3.UP * 10
		panel.pointer.update_pointer(0.2)
		input.right_hand.global_position -= Vector3.UP * 10
		panel.pointer.update_pointer(0.2)
		trackers[1].set_input(&"trigger_click", false)
		panel.pointer.update_pointer(0.2)
		check(network.sent.size() == 1, path + " cancelled pointer drag does not select a floor")
		trackers[1].set_input(&"trigger_click", true)
		panel.pointer.update_pointer(0.2)
		trackers[1].set_input(&"trigger_click", false)
		panel.pointer.update_pointer(0.2)
		check(network.sent.size() == 2 and network.sent[-1].floor == lift.FLOORS.size() - 1, path + " floor selection preserves remote request")
		check(player.key_holder == null and lift._vr_panel == null, path + " selection releases input")
		await process_frame
		lift.vr_interact(player)
		lift.vr_close()
		check(player.key_holder == null and network.sent.size() == 2, path + " cancel does not request a trip")
		lift.queue_free()
		manager.queue_free()
		await process_frame
	for tracker in trackers:
		XRServer.remove_tracker(tracker)
	controllers.queue_free()
	world.queue_free()
	await process_frame
	print("VR INTERACTIONS: %d failures" % failures)
	quit(1 if failures else 0)


## The school elevator and every scenes/*_lift.tscn.
func _lift_scenes() -> Array:
	var out := ["res://assets/art/models/interiors/school/elevator.tscn"]
	for f in DirAccess.get_files_at("res://assets/scenes"):
		if f.ends_with("_lift.tscn"):
			out.append("res://assets/scenes/" + f)
	return out
