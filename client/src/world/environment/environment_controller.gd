extends Node
## Day and night: the world clock and the lighting for it, LEGACY environment swaps or a PROCEDURAL sky.

## PROCEDURAL drives realtime_sky.gdshader from the sun at the observer's longitude and latitude.
enum SkyMode { LEGACY, PROCEDURAL }
enum TimeMode { REAL_TIME, MANUAL, ACCELERATED }

const WorldGeo = preload("res://src/world/region/world_geo.gd")

# Normalised times of day (0 midnight, 0.5 noon).
## 5:00
const SUNRISE_START = 0.208
## 7:00
const DAY_START = 0.292
## 17:00
const SUNSET_START = 0.708
## 19:00
const NIGHT_START = 0.792

@export var day_environment: Environment
@export var sunset_environment: Environment
@export var night_environment: Environment

@export var sun_light: DirectionalLight3D
@export var moon_light: DirectionalLight3D

@export var sky_mode: SkyMode = SkyMode.LEGACY

## The PROCEDURAL environment; defaults to the bundled one.
@export var realtime_sky_environment: Environment

## Shown only after dark; found by the name "OutsideLights" when unset.
@export var outside_lights: Node3D

## True aims the sun by the map's real compass; false keeps -Z as north, as the city was tuned.
@export var geographic_compass := false

@export var time_mode: TimeMode = TimeMode.REAL_TIME

## Hour (0..24) in MANUAL mode.
@export_range(0.0, 24.0, 0.1) var manual_time_hours: float = 12.0

## Game seconds per real second in ACCELERATED mode.
@export var time_speed_multiplier: float = 60.0
## Hour ACCELERATED mode starts at.
@export var start_time_hours: float = 8.0

## Unix day of the home region's date that current_time belongs to.
var current_day_unix: int = 0
## Time of day in the home region, 0..1.
var current_time: float = 0.0
var accelerated_time_offset: float = 0.0

var world_environment: WorldEnvironment

## Set by WeatherController: 1 clear, lower dims the sun and moon.
var weather_dim: float = 1.0
## Set by WeatherController: 0 blue sky, 1 full storm (darker haze and exposure).
var weather_gloom: float = 0.0

var _observer_lonlat := Vector2(INF, INF)
var _geo_timer := 0.0

## This scene's copy of the PROCEDURAL environment and its sky material.
var _proc_env: Environment
var _sky_material: ShaderMaterial
## Web build or the Compatibility renderer.
var _is_web: bool = false
var _mobile_rendering := false
## The environments as authored, before the tile-GPU profile.
var _authored_envs := {}
var _authored_shadow_mode := -1
# The inputs the environment was last applied for.
var _applied_time := -1.0
var _applied_dim := -1.0
var _applied_gloom := -1.0
var _applied_sky_mode := -1


func _ready():
	world_environment = get_parent().get_node_or_null("WorldEnvironment")
	if not world_environment:
		push_error("WorldEnvironment not found in parent!")
		return

	if not outside_lights:
		var scene_root: Node = owner if owner else get_tree().current_scene
		if scene_root:
			outside_lights = scene_root.find_child("OutsideLights", true, false) as Node3D

	if not day_environment:
		day_environment = load("res://assets/world/environment/day_environment.tres")
	if not sunset_environment:
		sunset_environment = load("res://assets/world/environment/sunriseset_environment.tres")
	if not night_environment:
		night_environment = load("res://assets/world/environment/night_environment.tres")

	_tune_for_renderer()

	# Only the Quest starts on the tile-GPU profile; set_mobile_rendering() switches others live.
	set_mobile_rendering(OS.has_feature("android"))

	if sky_mode == SkyMode.PROCEDURAL:
		_setup_procedural_sky()

	current_day_unix = WorldGeo.local_day(Time.get_unix_time_from_system(), WorldGeo.home_id())
	match time_mode:
		TimeMode.REAL_TIME:
			update_time_from_os()
		TimeMode.MANUAL:
			current_time = manual_time_hours / 24.0
		TimeMode.ACCELERATED:
			accelerated_time_offset = start_time_hours / 24.0
			current_time = accelerated_time_offset

	update_environment()


## On Compatibility, swaps in tuned copies; the renderer is queried, as forced GL may lack the feature.
func _tune_for_renderer() -> void:
	var web := OS.has_feature("web")
	var compat := RenderingServer.get_current_rendering_method() == "gl_compatibility"
	print("[EnvironmentController] web=%s compatibility_renderer=%s" % [web, compat])
	_is_web = web or compat
	if _is_web:
		print("[EnvironmentController] Applying web-safe environment tuning.")
		day_environment = _compat_tune(day_environment, 0.78, 0.65,
			Color(0.68, 0.73, 0.80))
		sunset_environment = _compat_tune(sunset_environment, 0.62, 0.58,
			Color(0.82, 0.60, 0.44))
		night_environment = _compat_tune(night_environment, 0.40, 0.50,
			Color(0.10, 0.12, 0.19))


## Re-aims the sun after about 1 km (0.01 degrees) of observer travel; reapplies only on changes.
func _process(delta):
	match time_mode:
		TimeMode.REAL_TIME:
			update_time_from_os()
		TimeMode.MANUAL:
			current_time = manual_time_hours / 24.0
		TimeMode.ACCELERATED:
			accelerated_time_offset += (delta * time_speed_multiplier) / 86400.0
			if accelerated_time_offset >= 1.0:
				accelerated_time_offset -= 1.0
				current_day_unix += 1
			current_time = accelerated_time_offset

	_geo_timer -= delta
	if _geo_timer <= 0.0 and sky_mode == SkyMode.PROCEDURAL:
		_geo_timer = 1.0
		var ll := observer_lonlat()
		if absf(ll.x - _observer_lonlat.x) > 0.01 or absf(ll.y - _observer_lonlat.y) > 0.01:
			_observer_lonlat = ll
			_applied_time = -1.0

	if current_time != _applied_time or weather_dim != _applied_dim \
			or weather_gloom != _applied_gloom or int(sky_mode) != _applied_sky_mode:
		update_environment()


## Sets the clock to the home region's hour now (not this machine's zone).
func update_time_from_os():
	set_world_instant(Time.get_unix_time_from_system())


## The world's single instant in unix seconds (UTC).
func world_utc() -> float:
	return (float(current_day_unix) + current_time) * 86400.0 - WorldGeo.home_offset() * 3600.0


## Sets current_time and current_day_unix for the home region at utc.
func set_world_instant(utc: float) -> void:
	var local := utc + WorldGeo.home_offset() * 3600.0
	current_day_unix = floori(local / 86400.0)
	current_time = fposmod(local, 86400.0) / 86400.0


## Where the sky is seen from: the camera, else the map origin.
func observer_global() -> Vector3:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera != null:
		return camera.global_position
	var frame := WorldGeo.builds_frame(get_tree()) if is_inside_tree() else null
	return frame.global_position if frame != null else Vector3.ZERO


func observer_lonlat() -> Vector2:
	if not is_inside_tree():
		return WorldGeo.to_lonlat(Vector2.ZERO)
	return WorldGeo.to_lonlat(WorldGeo.to_builds(get_tree(), observer_global()))


func update_environment():
	if not world_environment:
		return
	_applied_time = current_time
	_applied_dim = weather_dim
	_applied_gloom = weather_gloom
	_applied_sky_mode = int(sky_mode)

	if sky_mode == SkyMode.PROCEDURAL:
		_update_procedural_sky()
		return

	if current_time >= DAY_START and current_time < SUNSET_START:
		world_environment.environment = day_environment
		set_light_levels(1.0, 0.0)
	elif current_time >= SUNSET_START and current_time < NIGHT_START:
		world_environment.environment = sunset_environment
		var blend = (current_time - SUNSET_START) / (NIGHT_START - SUNSET_START)
		set_light_levels(1.0 - blend * 0.7, blend * 0.5)
	elif current_time >= SUNRISE_START and current_time < DAY_START:
		world_environment.environment = sunset_environment
		var blend = (current_time - SUNRISE_START) / (DAY_START - SUNRISE_START)
		set_light_levels(0.3 + blend * 0.7, 0.5 - blend * 0.5)
	else:
		world_environment.environment = night_environment
		set_light_levels(0.0, 0.5)

	_update_outside_lights(current_time < DAY_START or current_time >= SUNSET_START)


## The moon at 30 %, both dimmed by the weather; a light below 0.01 is hidden.
func set_light_levels(sun_energy: float, moon_energy: float):
	sun_energy *= weather_dim
	moon_energy *= weather_dim
	if sun_light:
		sun_light.light_energy = sun_energy * 1.0
		sun_light.visible = sun_energy > 0.01
	if moon_light:
		moon_light.light_energy = moon_energy * 0.3
		moon_light.visible = moon_energy > 0.01


## Switches to MANUAL time at hours (0..24).
func set_time_of_day_hours(hours: float):
	time_mode = TimeMode.MANUAL
	manual_time_hours = clamp(hours, 0.0, 24.0)
	current_time = manual_time_hours / 24.0
	update_environment()


func set_to_day():
	set_time_of_day_hours(12.0)


## The time as "HH:MM".
func get_current_time_string() -> String:
	var hours = int(current_time * 24.0)
	var minutes = int((current_time * 24.0 - hours) * 60.0)
	return "%02d:%02d" % [hours, minutes]


func switch_to_accelerated_time():
	time_mode = TimeMode.ACCELERATED
	accelerated_time_offset = current_time


## Falls back to LEGACY without one; on Compatibility, lower exposure and depth fog.
func _setup_procedural_sky() -> void:
	if not realtime_sky_environment:
		realtime_sky_environment = load("res://assets/world/environment/realtime_sky_environment.tres")
	if not realtime_sky_environment:
		push_error("[EnvironmentController] realtime_sky_environment missing — PROCEDURAL sky disabled.")
		sky_mode = SkyMode.LEGACY
		return

	_proc_env = realtime_sky_environment.duplicate(true)
	if _mobile_rendering:
		_proc_env.glow_enabled = false
	var sky: Sky = _proc_env.sky
	if sky and sky.sky_material is ShaderMaterial:
		_sky_material = sky.sky_material
	else:
		push_error("[EnvironmentController] realtime sky env has no ShaderMaterial sky.")

	if _is_web:
		_proc_env.tonemap_exposure = 0.8
		_proc_env.volumetric_fog_enabled = false
		# Its colour follows the time of day in _update_procedural_sky().
		_proc_env.fog_enabled = true
		_proc_env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		_proc_env.fog_light_energy = 1.0
		_proc_env.fog_density = 0.006
		_proc_env.fog_sky_affect = 0.0

	world_environment.environment = _proc_env
	print("[EnvironmentController] PROCEDURAL sky active (sun at the observer's real position).")


## Also turns the exterior lights on when the sun is low.
func _update_procedural_sky() -> void:
	if not _proc_env:
		return

	var sun_dir := _compute_sun_direction()
	# sin(elevation): above the horizon when > 0.
	var elev := sun_dir.y

	if sun_light:
		_aim_light(sun_light, sun_dir)
	if moon_light:
		_aim_light(moon_light, -sun_dir)

	var sun_amt := clampf(smoothstep(-0.06, 0.12, elev), 0.0, 1.0)
	var warmth := clampf(smoothstep(0.0, 0.30, elev), 0.0, 1.0)
	if sun_light:
		sun_light.light_color = Color(1.0, 0.55, 0.30).lerp(Color(1.0, 0.96, 0.92), warmth)
		sun_light.light_energy = sun_amt * 1.1 * weather_dim
		sun_light.visible = sun_amt * weather_dim > 0.01

	var moon_amt := 1.0 - clampf(smoothstep(-0.16, -0.02, elev), 0.0, 1.0)
	if moon_light:
		moon_light.light_color = Color(0.70, 0.75, 0.95)
		moon_light.light_energy = moon_amt * 0.15 * clampf(weather_dim + 0.25, 0.0, 1.0)
		moon_light.visible = moon_amt > 0.01

	if _sky_material:
		_sky_material.set_shader_parameter("sun_direction", sun_dir)

	_update_outside_lights(elev < 0.08)
	_tune_procedural_env(clampf(smoothstep(-0.08, 0.14, elev), 0.0, 1.0))


## For day_amt (0..1) and the weather's gloom.
func _tune_procedural_env(day_amt: float) -> void:
	var exposure_day := 0.8 if _is_web else 1.1
	_proc_env.tonemap_exposure = lerpf(0.55, exposure_day, day_amt) * (1.0 - weather_gloom * 0.18)
	_proc_env.ambient_light_energy = lerpf(0.18, 1.0, day_amt) * (0.45 + 0.55 * weather_dim)
	_proc_env.background_energy_multiplier = lerpf(0.6, 1.0, day_amt)
	if _proc_env.volumetric_fog_enabled:
		_proc_env.volumetric_fog_albedo = Color(0.20, 0.24, 0.34).lerp(
			Color(0.62, 0.66, 0.72), day_amt).lerp(Color(0.30, 0.32, 0.36), weather_gloom)
	elif _proc_env.fog_enabled:
		# The web depth fog follows the same ramp as the volumetric haze.
		_proc_env.fog_light_color = Color(0.16, 0.19, 0.28).lerp(
			Color(0.68, 0.73, 0.80), day_amt).lerp(Color(0.34, 0.36, 0.40), weather_gloom)


func _update_outside_lights(dark: bool) -> void:
	if outside_lights and outside_lights.visible != dark:
		outside_lights.visible = dark


## Points a directional light's -Z (its rays) away from toward_sun.
func _aim_light(light: DirectionalLight3D, toward_sun: Vector3) -> void:
	var up := Vector3.UP
	if absf(toward_sun.y) > 0.999:
		up = Vector3(0, 0, -1)
	light.look_at(light.global_position - toward_sun, up)


## Unit vector towards the sun (+Y up) at the observer's longitude and latitude.
func _compute_sun_direction() -> Vector3:
	if not _observer_lonlat.is_finite():
		_observer_lonlat = observer_lonlat()
	var dir := WorldGeo.sun_direction(world_utc(), _observer_lonlat, geographic_compass)
	if geographic_compass and is_inside_tree():
		var frame := WorldGeo.builds_frame(get_tree())
		if frame != null:
			dir = (frame.global_basis.orthonormalized() * dir).normalized()
	return dir


## Tile-GPU profile: no glow, one directional shadow split; reversible for comparison.
func set_mobile_rendering(on: bool) -> void:
	if on == _mobile_rendering and not _authored_envs.is_empty():
		return
	if _authored_envs.is_empty():
		_authored_envs = {
			"day": day_environment, "sunset": sunset_environment,
			"night": night_environment, "realtime": realtime_sky_environment,
		}
		_authored_shadow_mode = sun_light.directional_shadow_mode if sun_light else -1
	_mobile_rendering = on
	if on:
		day_environment = _without_glow(_authored_envs.day)
		sunset_environment = _without_glow(_authored_envs.sunset)
		night_environment = _without_glow(_authored_envs.night)
		realtime_sky_environment = _without_glow(_authored_envs.realtime)
		if sun_light:
			sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	else:
		day_environment = _authored_envs.day
		sunset_environment = _authored_envs.sunset
		night_environment = _authored_envs.night
		realtime_sky_environment = _authored_envs.realtime
		if sun_light and _authored_shadow_mode >= 0:
			sun_light.directional_shadow_mode = _authored_shadow_mode
	# The live procedural environment is a separate copy.
	if sky_mode == SkyMode.PROCEDURAL and _proc_env != null:
		var authored_glow := true
		if _authored_envs.realtime != null:
			authored_glow = bool(_authored_envs.realtime.glow_enabled)
		_proc_env.glow_enabled = false if on else authored_glow
	_applied_time = -1.0
	if world_environment:
		update_environment()
	print("[EnvironmentController] %s profile on %s: glow %s, sun shadow %s" % [
		"Tile-GPU" if on else "Full", OS.get_name(),
		"off" if on else "authored", "1 split" if on else "authored"])


func _without_glow(src: Environment) -> Environment:
	if src == null:
		return null
	var env := src.duplicate(true) as Environment
	env.glow_enabled = false
	return env


## A copy of src for Compatibility, which has no GI: lower exposure, an ambient floor, depth fog.
func _compat_tune(src: Environment, exposure: float, sky_mul: float,
		haze_color: Color = Color(0.68, 0.73, 0.80)) -> Environment:
	if src == null:
		return null
	var env: Environment = src.duplicate(true)

	env.tonemap_exposure = exposure
	env.background_energy_multiplier = sky_mul

	# An explicit ambient colour keeps shadows from crushing if the sky contribution drops.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color(0.75, 0.78, 0.82, 1.0)
	env.ambient_light_energy = max(env.ambient_light_energy, 1.0)
	env.ambient_light_sky_contribution = 1.0

	# Bloom stays; only the unnormalised intensity is too bright here.
	if env.glow_enabled:
		env.glow_normalized = false
		env.glow_intensity = env.glow_intensity * 0.65

	if env.adjustment_enabled:
		env.adjustment_brightness = lerp(env.adjustment_brightness, 1.0, 0.7)
		env.adjustment_contrast = lerp(env.adjustment_contrast, 1.0, 0.85)

	env.volumetric_fog_enabled = false

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = haze_color
	env.fog_light_energy = 1.0
	env.fog_density = 0.006
	env.fog_sky_affect = 0.0

	return env
