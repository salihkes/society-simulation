extends SceneTree
var HOME: String = Identity.value("home_region")
const Climate = preload("res://src/world/environment/regional_weather.gd")
const Weather = preload("res://src/world/environment/weather_controller.gd")
const Ice = preload("res://src/world/water/freezable_water.gd")
class Players extends RefCounted:
	var local_player = null
class Network extends Node:
	signal weather_update_received(data)
	var connected := true
	var players := Players.new()
	var latest_weather_update := {}
class Manager extends Node:
	var _is_authority := true
	func is_authority(): return _is_authority
	func residents(): return null
	func peds(): return null
var failures := 0
func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + label)
func _initialize(): run.call_deferred()
func run():
	var winter := float(Time.get_unix_time_from_datetime_string("2026-01-15T00:00:00"))
	var sim := Climate.new()
	sim.configure({"type": "auto", "regions": {
		HOME: {"type": "clear", "temperature_c": 15.0, "humidity_percent": 30.0},
		"the_city": {"type": "snow", "temperature_c": -12.0, "humidity_percent": 90.0}}})
	sim.advance(600.0, winter)
	var warm: Dictionary = sim.sample(Climate.REGIONS[0].center)
	var cold: Dictionary = sim.sample(Climate.REGIONS[1].center)
	check(warm.type == "clear" and cold.type == "snow", "simultaneous distinct regional fronts")
	check(absf(warm.temperature_c - 15) < 0.01 and absf(cold.humidity_percent - 90) < 0.01, "Celsius and humidity at separate locations")
	check(cold.freshwater_ice > cold.sea_ice and cold.sea_ice > 0 and cold.sea_ice < 1, "cold gradually freezes fresh and salt water at different rates")
	check(warm.sea_ice < 0.001, "warm region remains unfrozen")
	var peer := Climate.new()
	peer.configure(sim.config)
	check(peer.apply_packet(sim.packet()), "joining replica restores every region without a camera")
	check(peer.states == sim.states, "late join restores ice and climate exactly")
	var old := sim.packet()
	sim.advance(3600.0, winter)
	check(peer.apply_packet(sim.packet()) and not peer.apply_packet(old), "out of order snapshot cannot rewind ice")
	var invalid := sim.packet()
	invalid.states.the_city.humidity_percent = NAN
	var before := peer.packet()
	check(not peer.apply_packet(invalid) and peer.packet() == before, "invalid snapshot rejected atomically")
	peer.advance(60, winter)
	check(peer.states.the_city.sea_ice >= sim.states.the_city.sea_ice, "promoted owner continues inherited freeze")
	var thaw := sim.config.duplicate(true)
	thaw.regions.the_city.temperature_c = 20
	thaw.regions.the_city.type = "clear"
	sim.configure(thaw)
	sim.advance(3600.0, winter)
	check(sim.states.the_city.sea_ice == 0.0 and sim.states.the_city.freshwater_ice == 0.0, "warming thaws both water types")
	check(not sim.apply_packet(peer.packet()), "old configuration cannot replace a new regional command")
	var fresh_world := Climate.new()
	fresh_world.configure(peer.config)
	fresh_world.advance(0, winter)
	check(peer.apply_packet(fresh_world.packet()) and peer.elapsed == 0, "new world epoch restores after a complete server restart")
	var marginal := Climate.new()
	marginal.configure({"type": "clear", "temperature_c": -1.0})
	marginal.advance(3600, winter)
	check(marginal.states.the_city.freshwater_ice > 0 and marginal.states.the_city.sea_ice == 0, "mild frost freezes fresh water but leaves sea liquid")
	var automatic := Climate.new()
	var twin := Climate.new()
	automatic.advance(0, winter)
	twin.advance(0, winter)
	check(automatic.states == twin.states, "seasonal schedule is deterministic per region and UTC slot")
	check(automatic.states.western_highlands.temperature_c < automatic.states.southern_coast.temperature_c, "regional seasonal temperature baseline")
	for i in 20:
		var month := float(Time.get_unix_time_from_datetime_string("2026-07-15T12:00:00")) + i * 21600
		automatic.advance(0, month)
		for state in automatic.states.values():
			check(state.humidity_percent >= 0 and state.humidity_percent <= 100 and is_finite(state.temperature_c), "finite bounded climate")

	var nc := Network.new()
	nc.name = "NetworkController"
	root.add_child(nc)
	var world := Node3D.new()
	world.scale = Vector3.ONE * 0.2
	world.position = Vector3(50, 3, -20)
	root.add_child(world)
	current_scene = world
	var builds := Node3D.new()
	builds.name = "Builds"
	world.add_child(builds)
	var manager := Manager.new()
	manager.name = "AmbientManager"
	world.add_child(manager)
	var weather := Weather.new()
	weather.name = "WeatherController"
	world.add_child(weather)
	weather.set_process(false)
	weather._snow_cover.render_enabled = false
	var config := {"type": "clear", "regions": {
		HOME: {"type": "clear", "temperature_c": 15.0},
		"the_city": {"type": "snow", "temperature_c": -12.0}}}
	weather._on_server_weather(config)
	weather._process(3600.0)
	check(weather.regional.states.the_city.sea_ice > 0.3, "headless owner advances distant ice without any camera")
	check(weather.current_type() == "clear", "headless view does not set distant weather")
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.current = true
	var city := Vector3(53324, 0, 93066)
	camera.global_position = builds.to_global(city + Vector3(0, 30, 0))
	check(weather.conditions_at(camera.global_position).region == "the_city", "global position queries respect scaled and translated Builds frame")
	weather._process(1.1)
	check(weather.current_type() == "snow", "travelling selects local precipitation")
	var snapshot: Dictionary = weather.snapshot()
	manager._is_authority = false
	camera.global_position = builds.to_global(Vector3(-232, 30, -238))
	weather.apply_snapshot(snapshot)
	check(weather.current_type() == "clear", "replicated owner view cannot overwrite observer region")
	var frozen_time: float = weather.regional.elapsed
	weather._process(10)
	check(weather.regional.elapsed == frozen_time, "graphical replica does not advance authoritative ice")
	manager._is_authority = true
	weather._process(1)
	check(weather.regional.elapsed > frozen_time, "authority handoff keeps shared regional simulation")

	# Exercise actual scaled water collision at a distant place, not just math.
	weather._on_server_weather({"type": "clear", "temperature_c": -20.0})
	weather.regional.advance(7200.0, winter)
	# This is the actual CitySea scene instanced by workspace_local.
	var sea: Node3D = load("res://assets/world/water/city_sea.tscn").instantiate()
	builds.add_child(sea)
	sea.position = city
	sea.set_process(false)
	var mesh := sea.get_node("Near") as MeshInstance3D
	var ice = sea.get_node("WaterIce")
	ice.weather = weather
	ice.set_physics_process(false)
	camera.global_position = sea.to_global(Vector3(10, 30, 10))
	ice.refresh()
	await physics_frame
	await physics_frame
	var query := PhysicsRayQueryParameters3D.create(sea.to_global(Vector3(10, 10, 10)), sea.to_global(Vector3(10, -10, 10)))
	var hit := world.get_world_3d().direct_space_state.intersect_ray(query)
	check(not hit.is_empty() and absf(hit.position.y - sea.global_position.y) < 0.001, "frozen water has collision at scaled mean surface")
	check(ice._last_faces.size() <= 9 * 9 * 6, "ice collision budget independent of country size")
	camera.clear_current()
	ice.refresh()
	check(ice._shape.shape == null, "no observer removes local physics patch")
	camera.make_current()
	ice.refresh()
	check(ice._shape.shape != null, "returning observer restores collision at the same location")
	check(mesh.material_override.get_shader_parameter("regional_enabled") == true, "workspace_local sea automatically receives regional field")
	check(is_equal_approx(float(sea.get_node("Far").material_override.get_shader_parameter("frozen_surface_offset")), 1.2), "frozen far skirt meets near water level")
	camera.global_position = sea.to_global(Vector3(10000, 30, 10000))
	ice.refresh()
	check(ice._shape.shape == null, "no ice collision beyond actual water mesh")
	camera.global_position = sea.to_global(Vector3(10, 30, 10))
	ice.refresh()
	weather._on_server_weather({"type": "clear", "temperature_c": 20.0})
	weather.regional.advance(7200.0, winter)
	ice.refresh()
	await physics_frame
	await physics_frame
	hit = world.get_world_3d().direct_space_state.intersect_ray(query)
	check(hit.is_empty() and ice._shape.shape == null, "thaw removes ice collision")
	world.queue_free()
	nc.queue_free()
	await process_frame
	print("REGIONAL WEATHER: %d failures" % failures)
	quit(1 if failures else 0)
