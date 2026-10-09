extends SceneTree
## Isolated project, no real network connection required.
class Players extends RefCounted:
	var local_player = null
class Network extends Node:
	signal weather_update_received(data)
	var connected := true
	var players := Players.new()
	var latest_weather_update := {"type": "storm"}
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
	var nc := Network.new()
	nc.name = "NetworkController"
	root.add_child(nc)
	var world := Node3D.new()
	world.name = "localworkspace"
	world.scale = Vector3.ONE * 0.2
	root.add_child(world)
	current_scene = world
	var manager := Manager.new()
	manager.name = "AmbientManager"
	world.add_child(manager)
	var weather = load("res://src/world/environment/weather_controller.gd").new()
	weather.regional_weather = false # Explicit coverage of the legacy single-front protocol.
	weather.name = "WeatherController"
	world.add_child(weather)
	weather.set_process(false)
	await process_frame
	var rain = world.get_node("RainSystem")
	rain.set_process(false)
	check(weather.current_type() == "storm", "cached weather applied after scene creation")
	check(is_equal_approx(weather._cur.cloud, 1.0), "join atmosphere has no clear-to-storm fade")
	check(is_equal_approx(rain.current_intensity(), 1.0), "join rain is immediately full strength")
	weather._on_server_weather({"type": "clear"})
	weather._process(1.1)
	check(weather.current_type() == "clear" and weather._cur.cloud > 0.9, "new live weather still transitions")
	weather._on_server_weather({"type": "rain", "_initial": true})
	var state: Dictionary = weather.snapshot()
	state.atmosphere.cloud = 0.57
	state.rain = 0.3
	weather.apply_snapshot(state)
	weather._process(1.1)
	check(is_equal_approx(weather._cur.cloud, 0.57), "peer retains owner's current transition progress")
	check(is_equal_approx(rain.current_intensity(), 0.3), "peer receives current rain intensity")
	var stale := state.duplicate(true)
	stale.source = "storm"
	stale.atmosphere.cloud = 1.0
	weather.apply_snapshot(stale)
	check(is_equal_approx(weather._cur.cloud, 0.57), "stale snapshot cannot override newer command")
	manager._is_authority = true
	weather.apply_snapshot(stale)
	weather._process(1.1)
	check(weather._cur.cloud > 0.57 and weather._cur.cloud < 0.95, "new owner continues transition from inherited state")
	check(is_equal_approx(rain._target_intensity, 0.6), "new owner resumes rain toward profile intensity")
	weather._on_server_weather({"type": "snow", "_initial": true})
	check(weather._snow.visible and weather._snow.multimesh.instance_count == 6000, "joining snow starts with an already populated particle field")
	weather.set_weather("fog")
	check(weather.snapshot().is_empty(), "studio override stays local")
	world.queue_free()
	nc.queue_free()
	await process_frame
	print("WEATHER SYNC: %d failures" % failures)
	quit(1 if failures else 0)
