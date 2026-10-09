extends SceneTree
## Exercise the real traffic snapshot writer/reader without city assets or sockets.
## godot --headless --path client -s tests/test_traffic_replication.gd

class Network extends Node:
	var connected := true
	var snapshot: Dictionary = {}
	func send_json(data: Dictionary) -> void:
		# Match the JSON transport, including its conversion of numeric types.
		snapshot = JSON.parse_string(JSON.stringify(data))

class Manager extends "res://src/life/ambient_manager.gd":
	func _ready() -> void:
		set_physics_process(false)
	func weather_controller():
		return null

class Car extends "res://src/life/ambient_car.gd":
	var honks := 0
	var yells := 0
	var last_line := -1
	func _ready() -> void:
		set_process(false)
	func honk(_double := false):
		honks += 1
	func yell(line: int):
		yells += 1
		last_line = line

var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var world := Node3D.new()
	world.scale = Vector3.ONE * 0.2
	root.add_child(world)
	var network := Network.new()
	world.add_child(network)
	var sender := Manager.new()
	var receiver := Manager.new()
	world.add_child(sender)
	world.add_child(receiver)
	sender._nc = network
	receiver._is_authority = false
	var source := Car.new()
	var replica := Car.new()
	world.add_child(source)
	world.add_child(replica)
	replica.set_authority(false)
	sender.traffic.cars["car"] = source
	receiver.traffic.cars["car"] = replica

	# A first snapshot establishes event counters without replaying old sounds.
	source.position = Vector3(12.25, 3.75, -18.5)
	sender.traffic.car_sim["car"] = {"hn": 0, "yc": 0}
	sender.replication.send_state()
	receiver.replication.apply_state(network.snapshot)
	check(replica.position.is_equal_approx(source.position), "initial traffic position")
	check(replica.honks == 0 and replica.yells == 0, "join does not replay sounds")

	# Many obstruction encounters used to replace height with the yell count.
	for count in [1, 2, 30, 120]:
		sender.traffic.car_sim["car"] = {"hn": count, "hd": 1, "yc": count, "yl": count % 3}
		sender.replication.send_state()
		var state: Dictionary = network.snapshot.cars.car
		check(is_equal_approx(float(state.y), source.position.y), "yells must not overwrite height")
		check(int(state.get("yc", -1)) == count, "snapshot carries a separate yell counter")
		var previous_yells := replica.yells
		var previous_honks := replica.honks
		receiver.replication.apply_state(network.snapshot)
		for frame in 60:
			replica._process(1.0 / 60.0)
		check(replica.position.is_equal_approx(source.position), "remote car stays on the road after yells")
		check(replica.yells == previous_yells + 1 and replica.last_line == count % 3, "new yell plays once")
		check(replica.honks == previous_honks + 1, "new horn plays once")
		receiver.replication.apply_state(network.snapshot)
		check(replica.yells == previous_yells + 1, "repeated snapshot does not replay yell")

	# A late join receives the true height even after many historical events.
	replica._got_remote = false
	replica._seen_honk = -1
	replica._seen_yell = -1
	var previous_yells := replica.yells
	receiver.replication.apply_state(network.snapshot)
	check(replica.position.is_equal_approx(source.position), "late join preserves height")
	check(replica.yells == previous_yells, "late join does not replay historical yells")

	# Road elevation alone is never a sound event, including optional fields absent.
	sender.traffic.car_sim["car"] = {"hn": 0, "yc": 0}
	source.position.y = 240.0
	sender.replication.send_state()
	receiver.replication.apply_state(network.snapshot)
	check(replica.yells == previous_yells, "height changes must not trigger yells")
	check(is_equal_approx(replica._remote_pos.y, 240.0), "road elevation still replicates")

	world.free()
	print("TRAFFIC REPLICATION: %d failures" % failures)
	quit(1 if failures else 0)
