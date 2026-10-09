extends Node3D
## World-space rain around the camera: drops, splashes, audio and a ray-traced ground height map.

const VOLUME := Vector3(36.0, 20.0, 36.0)
const MAX_DROPS := 10000
const SURFACE_SIZE := 32
const SURFACE_SPAN := 40.0
const RAYS_PER_TICK := 128

var _intensity := 0.0
var _target_intensity := 0.0
var _fall_distance := 0.0
var _wind_offset := Vector2.ZERO
var _elapsed := 0.0
var _surface_image: Image
var _surface_texture: ImageTexture
var _surface_index := 0
var _scan_origin := Vector3.ZERO
## Origin of the committed height map, not the scan in progress; WeatherController reads it.
var _surface_origin := Vector2.ZERO
var _surface_ready := false
var _surface_refresh := 0.0
var _drop_material: ShaderMaterial
var _splash_material: ShaderMaterial

var local_player: Node3D = null
var is_raining := false
## Keeps the height map updating for the snow flakes without rain.
var snow_active := false

@onready var drops: MultiMeshInstance3D = $RainDrops
@onready var splashes: MultiMeshInstance3D = $RainSplashes


func _ready() -> void:
	# Ignore the parents' scale.
	top_level = true
	global_transform = Transform3D.IDENTITY
	_drop_material = drops.material_override.duplicate()
	drops.material_override = _drop_material
	_splash_material = splashes.material_override.duplicate()
	splashes.material_override = _splash_material
	_build_instances(drops, MAX_DROPS)
	_build_instances(splashes, 600)
	_surface_image = Image.create(SURFACE_SIZE, SURFACE_SIZE, false, Image.FORMAT_RGF)
	_surface_image.fill(Color(-10000, 0, 0, 1))
	_surface_texture = ImageTexture.create_from_image(_surface_image)
	for material in [_drop_material, _splash_material]:
		material.set_shader_parameter("surface_map", _surface_texture)
	# Audio may arrive later in a pack, or never.
	_load_audio($RainAudio, "res://assets/world/environment/night-rain-with-distant-thunder-321446.mp3")
	_load_audio($WindAudio, "res://assets/world/environment/wind-blowing-sfx-12809_2.mp3")
	update_local_player_reference()
	set_rain_active(false)


## Loads a looping stream now, or once its pack is available.
func _load_audio(audio: AudioStreamPlayer3D, path: String) -> void:
	if ResourceLoader.exists(path):
		audio.stream = load(path).duplicate()
		if audio.stream is AudioStreamMP3:
			audio.stream.loop = true
		if is_raining:
			set_rain_active(true)
		return
	var packs := get_node_or_null("/root/PCKManager")
	if packs != null and packs.has_method("when_available"):
		packs.when_available(path, func():
			if is_instance_valid(audio):
				_load_audio(audio, path))


func update_local_player_reference() -> void:
	var network := get_node_or_null("/root/NetworkController")
	if network != null:
		local_player = network.get_indexed("players:local_player") as Node3D
	_follow_view()


## Centres the rain on the active camera, else on the local player.
func _follow_view() -> void:
	if not is_instance_valid(local_player):
		var network := get_node_or_null("/root/NetworkController")
		if network != null:
			local_player = network.get_indexed("players:local_player") as Node3D
	var target: Node3D = get_viewport().get_camera_3d()
	if target == null and is_instance_valid(local_player):
		target = local_player
	if target != null:
		global_position = target.global_position
		for material in [_drop_material, _splash_material]:
			material.set_shader_parameter("rain_center", global_position)


## count instances with seeded random custom data, hidden.
func _build_instances(node: MultiMeshInstance3D, count: int) -> void:
	var mesh := MultiMesh.new()
	mesh.transform_format = MultiMesh.TRANSFORM_3D
	mesh.use_custom_data = true
	mesh.mesh = load("res://assets/world/environment/rain_drop_mesh.tres")
	mesh.instance_count = count
	var rng := RandomNumberGenerator.new()
	rng.seed = 73019
	for i in count:
		mesh.set_instance_transform(i, Transform3D.IDENTITY)
		mesh.set_instance_custom_data(i, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
	mesh.custom_aabb = AABB(-VOLUME * 0.5 - Vector3.ONE, VOLUME + Vector3.ONE * 2.0)
	node.multimesh = mesh
	node.visible = false


## Sets the target intensity (0..1), at once if immediate.
func set_intensity(value: float, immediate := false) -> void:
	_target_intensity = clampf(value, 0.0, 1.0)
	set_rain_active(_target_intensity > 0.0)
	if immediate:
		_intensity = _target_intensity
		_process(0.0)


func current_intensity() -> float:
	return _intensity


func _process(delta: float) -> void:
	if snow_active:
		_follow_view()
	_intensity = move_toward(_intensity, _target_intensity, delta * 0.25)
	if _intensity <= 0.0:
		drops.visible = false
		splashes.visible = false
		return
	_follow_view()
	_elapsed += delta
	var fall_speed := lerpf(4.0, 10.0, _intensity)
	_fall_distance += fall_speed * delta
	var gust := 1.0 + 0.22 * sin(_elapsed * 0.63) + 0.12 * sin(_elapsed * 1.17)
	var wind := Vector2(1.0, 0.35) * lerpf(0.15, 2.8, _intensity * _intensity) * gust
	_wind_offset += wind * delta
	_drop_material.set_shader_parameter("fall_distance", _fall_distance)
	_drop_material.set_shader_parameter("wind_offset", _wind_offset)
	_drop_material.set_shader_parameter("fall_velocity", Vector3(wind.x, -fall_speed, wind.y))
	_drop_material.set_shader_parameter("intensity", _intensity)
	drops.multimesh.visible_instance_count = int(MAX_DROPS * _intensity)
	drops.visible = true
	_splash_material.set_shader_parameter("rain_time", _elapsed)
	_splash_material.set_shader_parameter("intensity", _intensity)
	splashes.multimesh.visible_instance_count = int(600 * _intensity)
	splashes.visible = _surface_ready


## Traces RAYS_PER_TICK cells from above the roofs; restarts after a cell of view travel or 0.4 s.
func _physics_process(delta: float) -> void:
	if _intensity <= 0.0 and not snow_active:
		return
	var space := get_world_3d().direct_space_state
	var cell := SURFACE_SPAN / SURFACE_SIZE
	_surface_refresh += delta
	if _surface_index == 0:
		var previous_center := _scan_origin + Vector3(SURFACE_SPAN * 0.5, 0, SURFACE_SPAN * 0.5)
		if _surface_ready and _surface_refresh < 0.4 and global_position.distance_to(previous_center) < cell:
			return
		_scan_origin = Vector3(floor(global_position.x / cell) * cell - SURFACE_SPAN * 0.5,
			global_position.y, floor(global_position.z / cell) * cell - SURFACE_SPAN * 0.5)
	var query := PhysicsRayQueryParameters3D.new()
	if is_instance_valid(local_player) and local_player is CollisionObject3D:
		query.exclude = [local_player.get_rid()]
	for i in RAYS_PER_TICK:
		var x := _surface_index % SURFACE_SIZE
		var z := _surface_index / SURFACE_SIZE
		var at := _scan_origin + Vector3((x + 0.5) * cell, 0, (z + 0.5) * cell)
		query.from = at + Vector3.UP * 60.0
		query.to = at - Vector3.UP * 30.0
		var hit := space.intersect_ray(query)
		var sample := Color(-10000, 0, 0, 1)
		if not hit.is_empty():
			sample = Color(hit.position.y, maxf(hit.normal.y, 0.0), 0, 1)
		_surface_image.set_pixel(x, z, sample)
		_surface_index += 1
		if _surface_index == SURFACE_SIZE * SURFACE_SIZE:
			_commit_surface()
			break


func _commit_surface() -> void:
	_surface_texture.update(_surface_image)
	_surface_origin = Vector2(_scan_origin.x, _scan_origin.z)
	for material in [_drop_material, _splash_material]:
		material.set_shader_parameter("surface_origin", Vector2(_scan_origin.x, _scan_origin.z))
		material.set_shader_parameter("surface_ready", true)
	_surface_ready = true
	_surface_refresh = 0.0
	_surface_index = 0


## Starts (at 0.6 unless a target is set) or stops the rain and its audio.
func set_rain_active(active: bool) -> void:
	is_raining = active
	if active:
		if _target_intensity == 0.0:
			_target_intensity = 0.6
		_follow_view()
	else:
		_target_intensity = 0.0
	for audio in [$RainAudio, $WindAudio]:
		if active and audio.stream != null and not audio.playing:
			audio.play()
		elif not active:
			audio.stop()
	# A WeatherController plays its own wind.
	var scene := get_tree().current_scene
	if scene != null and scene.find_child("WeatherController", true, false) != null:
		$WindAudio.stop()


## Ignored when a WeatherController drives the rain.
func handle_weather_update(weather_data: Dictionary) -> void:
	var scene := get_tree().current_scene
	if scene != null and scene.find_child("WeatherController", true, false) != null:
		return
	var weather_type := str(weather_data.get("type", "clear")).strip_edges().to_lower()
	set_rain_active(weather_type in ["raining", "rain", "drizzle", "storm"])
