extends Node
## The weather: picks the type, eases the atmosphere and drives sky, fog, rain, snow, wind and thunder.

const TYPES := ["clear", "partly", "overcast", "fog", "drizzle", "rain", "storm", "windy", "snow"]

const WIND_STREAM := "res://assets/world/environment/wind-blowing-sfx-12809_2.mp3"
const THUNDER_STREAM := "res://assets/art/sound/city/thunder_1.mp3"

const JsonData := preload("res://src/core/json_data.gd")
const DATA_PATH := "res://assets/world/environment/weather.json"

static var _tables: Dictionary = JsonData.read(DATA_PATH)
## Per type: cloud coverage, cspeed drift, vol/fogd fog density, dim, gloom, rain of 20000, rdb/wdb dB.
static var PROFILES: Dictionary = _profiles(_tables.get("profiles", {}))
## Storm targets the sky shader's day and dusk colours are greyed towards.
static var GLOOM_SKY: Dictionary = _vectors(_tables.get("gloom_sky", {}))
## [type, probability] per season: winter, spring, summer, autumn.
static var SEASONS: Dictionary = _tables.get("seasons", {})

## Forces a type locally; "" follows the server or the schedule.
@export var override_type := ""
@export var regional_weather := true
## Time constant, in seconds, of the easing between profiles.
@export var transition_seconds := 20.0

var regional = preload("res://src/world/environment/regional_weather.gd").new()

var _type := "clear"
var _server_type := "auto"
var _runtime_received := false
var _was_owner := false
var _nc = null
var _env_ctl = null
var _rain = null
var _snow_root: Node3D = null
var _snow: MultiMeshInstance3D = null
var _snow_material: ShaderMaterial
var _snow_time := 0.0
var _snow_cover = null
var _wind_player: AudioStreamPlayer = null
var _thunder_player: AudioStreamPlayer = null
var _flash: ColorRect = null
var _thunder_timer := 8.0
var _poll := 0.0
## The eased atmosphere, starting at "clear".
var _cur := {"cloud": 0.10, "cspeed": 0.010, "vol": 0.003, "fogd": 0.004, "dim": 1.0, "gloom": 0.0, "rdb": -80.0, "wdb": -80.0}
## The sky shader's colours as authored.
var _sky_orig: Dictionary = {}
## LEGACY sky: Environment -> its original fog.
var _fog_saved: Dictionary = {}
var _reported := false
var _warned_type := ""


## Also applies weather cached by the NetworkController if the connection came first.
func _ready():
	regional.advance(0.0, Time.get_unix_time_from_system())
	_nc = get_node_or_null("/root/NetworkController")
	if _nc != null and _nc.has_signal("weather_update_received"):
		_nc.weather_update_received.connect(_on_server_weather)
	_build_snow()
	_snow_cover = load("res://src/world/environment/snow_cover.gd").new()
	_snow_cover.name = "SnowCover"
	_snow_cover.weather = self
	add_child(_snow_cover)
	_build_audio()
	_build_flash()
	if _nc != null and _nc.get("latest_weather_update") is Dictionary:
		var cached: Dictionary = _nc.latest_weather_update.duplicate(true)
		if not cached.is_empty():
			cached["_initial"] = true
			_restore_cached_weather.call_deferred(cached)


## A cached weather command, then the cached runtime snapshot and snow state.
func _restore_cached_weather(config: Dictionary) -> void:
	_on_server_weather(config)
	if _nc != null and _nc.get("latest_weather_runtime") is Dictionary:
		var runtime: Dictionary = _nc.latest_weather_runtime.duplicate(true)
		var cache = _nc.get("snow_cache")
		if cache != null and cache.epoch != "":
			runtime["snow"] = cache.packet(true)
		runtime["_initial"] = true
		apply_snapshot(runtime)


## Temperature in Celsius, relative humidity in percent.
func conditions_at(global_point: Vector3) -> Dictionary:
	var frame := climate_frame()
	var point := frame.to_local(global_point) if frame != null else global_point
	return regional.sample(Vector2(point.x, point.z))


## The Builds node the climate is laid out in, else the scene root.
func climate_frame() -> Node3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var builds := scene.get_node_or_null("Builds") as Node3D
	return builds if builds != null else scene as Node3D


## The camera, else the local player, else the climate frame's origin.
func observer_position() -> Vector3:
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		return camera.global_position
	if _nc != null and is_instance_valid(_nc.players.local_player):
		return _nc.players.local_player.global_position
	var frame := climate_frame()
	return frame.global_position if frame != null else Vector3.ZERO


func current_conditions() -> Dictionary:
	return conditions_at(observer_position())


## Feeds a material using regional_field.gdshaderinc with one field.
func set_regional_shader(material: ShaderMaterial, field: String) -> void:
	var frame := climate_frame()
	if frame == null:
		return
	material.set_shader_parameter("regional_enabled", regional_weather)
	material.set_shader_parameter("regional_values", regional.shader_values(frame, field))
	material.set_shader_parameter("regional_scale", absf(frame.global_basis.get_scale().x))


func current_type() -> String:
	return _type


## The weather type at any place: the override, else its region's type.
func type_at(global_point: Vector3) -> String:
	if override_type != "":
		return _normalize(override_type)
	if regional_weather:
		return str(conditions_at(global_point).type)
	return _type


func is_precipitating() -> bool:
	return _type == "drizzle" or _type == "rain" or _type == "storm" or _type == "snow"


## Forces a type locally (debug, cinematics); "" resumes.
func set_weather(t: String):
	override_type = t


## The initial command (on joining) jumps straight to its weather instead of easing.
func _on_server_weather(data):
	if typeof(data) != TYPE_DICTIONARY:
		return
	_server_type = str(data.get("type", "auto"))
	regional.configure(data)
	regional.advance(0.0, Time.get_unix_time_from_system())
	if _snow_cover != null and data.get("snow", {}) is Dictionary:
		_snow_cover.configure(data.get("snow", {}))
		# A reconnect may reach a server with a fresh cache.
		if bool(data.get("_initial", false)):
			_snow_cover.request_full_snapshot()
	_runtime_received = false
	if bool(data.get("_initial", false)) and override_type == "":
		_type = _decide()
		_jump_to_profile()
		_on_type_changed(true)
		_apply_now()


func _jump_to_profile() -> void:
	for k in _cur:
		_cur[k] = float(PROFILES[_type][k])


func _apply_now() -> void:
	_apply_atmosphere()
	if _wind_player != null:
		_wind_player.volume_db = float(_cur.wdb)
	_apply_audio(0.0)


## True offline, or when this peer is the ambient authority.
func _owns_weather() -> bool:
	if _nc == null or not _nc.connected:
		return true
	var scene := get_tree().current_scene
	var manager = scene.find_child("AmbientManager", true, false) if scene != null else null
	return manager != null and bool(manager.is_authority())


## The authority's weather snapshot, so peers inherit the front's progress; {} while overridden.
func snapshot() -> Dictionary:
	if override_type != "":
		return {}
	var atmosphere := {}
	for k in _cur:
		atmosphere[k] = snappedf(float(_cur[k]), 0.0001)
	var rain = _rain_system()
	var result := {"type": _type, "source": _server_type, "atmosphere": atmosphere,
		"rain": rain.current_intensity() if rain != null else 0.0}
	if regional_weather:
		result["regional"] = regional.packet()
	if _snow_cover != null:
		var snow: Dictionary = _snow_cover.snapshot()
		if not snow.is_empty():
			result["snow"] = snow
	return result


## Ignored when this peer owns the weather (unless initial), overrides it, or it predates the command.
func apply_snapshot(data: Dictionary) -> void:
	var initial := bool(data.get("_initial", false))
	if data.is_empty() or override_type != "" or (_owns_weather() and not initial):
		return
	if str(data.get("source", "auto")) != _server_type:
		return
	if regional_weather:
		_apply_regional_snapshot(data, initial)
		return
	var kind := str(data.get("type", ""))
	if not TYPES.has(kind) or not (data.get("atmosphere") is Dictionary):
		return
	if not is_finite(float(data.get("rain", 0.0))):
		return
	for k in _cur:
		if not data.atmosphere.has(k) or not is_finite(float(data.atmosphere[k])):
			return
	var changed := kind != _type
	_type = kind
	for k in _cur:
		_cur[k] = float(data.atmosphere[k])
	_runtime_received = true
	if changed:
		_on_type_changed(true)
	var rain = _rain_system()
	if rain != null:
		rain.set_intensity(clampf(float(data.get("rain", 0.0)), 0.0, 1.0), true)
	_apply_now()
	if _snow_cover != null and data.get("snow") is Dictionary:
		_snow_cover.apply_snapshot(data.snow, initial)
	# Continue the inherited front as its new owner.
	if initial and _owns_weather():
		_on_type_changed()


## Adopts the regional state and the local type sampled from it.
func _apply_regional_snapshot(data: Dictionary, initial: bool) -> void:
	if not data.get("regional") is Dictionary or not regional.apply_packet(data.regional):
		return
	_runtime_received = true
	var local_type := _decide()
	var changed_region := local_type != _type
	_type = local_type
	if changed_region or initial:
		_on_type_changed(initial)
	if initial:
		_jump_to_profile()
		_apply_atmosphere()
	if _snow_cover != null and data.get("snow") is Dictionary:
		_snow_cover.apply_snapshot(data.snow, initial)


## Re-decides the type every second and eases the atmosphere, audio and snow.
func _process(delta):
	var owner := _owns_weather()
	if regional_weather and (owner or not _runtime_received):
		regional.advance(delta if owner else 0.0, Time.get_unix_time_from_system())
	# Promoted to owner: continue the received front rather than restarting.
	if owner and not _was_owner and _runtime_received:
		_on_type_changed()
	_was_owner = owner
	_snow_time += delta
	_follow_player()
	_thunder_tick(delta)

	_poll += delta
	if _poll >= 1.0:
		_poll = 0.0
		_report_wiring_once()
		var want := _decide()
		if want != _type:
			print("[Weather] ", _type, " -> ", want)
			_type = want
			_on_type_changed()

	var prof: Dictionary = PROFILES.get(_type, PROFILES["clear"])
	var w := 1.0 - exp(-delta / maxf(transition_seconds, 0.5))
	if regional_weather or not _runtime_received or owner or override_type != "":
		for k in _cur:
			_cur[k] = lerpf(float(_cur[k]), float(prof[k]), w)
	_apply_atmosphere()
	_apply_audio(delta)
	if _snow_cover != null:
		_snow_cover.advance(delta, _type == "snow")


## Logs once which of the controlled systems were found.
func _report_wiring_once():
	if _reported:
		return
	_reported = true
	var env_ctl = _environment_controller()
	var proc_ok := false
	if env_ctl != null:
		var pe = env_ctl.get("_proc_env")
		proc_ok = pe != null
	var rain_ok := _rain_system() != null
	print("[Weather] wired: env_ctl=%s proc_sky=%s rain_system=%s override='%s' server='%s'" % [
		"OK" if env_ctl != null else "MISSING",
		"OK" if proc_ok else "no (LEGACY/depth-fog path)",
		"OK" if rain_ok else "MISSING",
		override_type, _server_type])


## Override, else regional type at the camera, else a peer's received type, else server, else schedule.
func _decide() -> String:
	if override_type != "":
		return _normalize(override_type)
	if regional_weather:
		return str(current_conditions().type)
	if _runtime_received and not _owns_weather():
		return _type
	var server_type := _server_type.strip_edges().to_lower()
	if server_type == "raining":
		server_type = "rain"
	if _nc != null and _nc.connected and TYPES.has(server_type):
		return server_type
	if _server_type != "auto" and _server_type != "" and _server_type != _warned_type:
		_warned_type = _server_type
		push_warning("[Weather] Server says '%s', which is not a weather this build knows — following the %s schedule. Valid: %s" % [_server_type, Identity.value("climate_name"), ", ".join(TYPES)])
	return _scheduled()


## A known type for t ("raining" is "rain"), else "clear" with a warning.
func _normalize(t: String) -> String:
	t = t.strip_edges().to_lower()
	if t == "raining":
		return "rain"
	if TYPES.has(t):
		return t
	if t != "" and t != _warned_type:
		_warned_type = t
		push_warning("[Weather] Unknown type '%s' — using clear. Valid: %s" % [t, ", ".join(TYPES)])
	return "clear"


## Seasonal, the same for everyone in each six-hour UTC slot.
func _scheduled() -> String:
	var d := Time.get_datetime_dict_from_system(true)
	var slot := int(d.hour) / 6
	var r := float(hash("%04d-%02d-%02d-%d" % [d.year, d.month, d.day, slot]) % 100000) / 100000.0
	for entry in _season_table(int(d.month)):
		r -= float(entry[1])
		if r <= 0.0:
			return str(entry[0])
	return "clear"


func _season_table(month: int) -> Array:
	if month == 12 or month <= 2:
		return SEASONS.get("winter", [])
	if month <= 5:
		return SEASONS.get("spring", [])
	if month <= 8:
		return SEASONS.get("summer", [])
	return SEASONS.get("autumn", [])


static func _profiles(table: Dictionary) -> Dictionary:
	for kind in table:
		table[kind]["rain"] = int(table[kind]["rain"])
	return table


static func _vectors(table: Dictionary) -> Dictionary:
	for key in table:
		var v: Array = table[key]
		table[key] = Vector3(v[0], v[1], v[2])
	return table


func _on_type_changed(immediate := false):
	var prof: Dictionary = PROFILES.get(_type, PROFILES["clear"])
	_set_rain(int(prof.rain), immediate)
	if _snow != null:
		_snow.visible = _type == "snow"
	var rainfall = _rain_system()
	if rainfall != null:
		rainfall.snow_active = _type == "snow"
	if _type == "storm":
		_thunder_timer = randf_range(3.0, 10.0)


func _environment_controller():
	if _env_ctl == null or not is_instance_valid(_env_ctl):
		var root := get_tree().current_scene
		if root != null:
			_env_ctl = root.find_child("EnvironmentController", true, false)
	return _env_ctl


## The scene's RainSystem, instanced here when the scene has none.
func _rain_system():
	if _rain != null and is_instance_valid(_rain):
		return _rain
	var root := get_tree().current_scene
	if root == null:
		return null
	_rain = root.find_child("RainSystem", true, false)
	if _rain == null:
		var rain_scene = load("res://assets/world/environment/rain_system.tscn")
		if rain_scene != null:
			_rain = (rain_scene as PackedScene).instantiate()
			root.add_child(_rain)
			print("[Weather] RainSystem created")
	if _rain != null and _rain.has_method("update_local_player_reference"):
		_rain.update_local_player_reference()
	return _rain


func _set_rain(amount: int, immediate := false):
	var rs = _rain_system()
	if rs == null:
		return
	if rs.has_method("set_intensity"):
		rs.set_intensity(float(amount) / 20000.0, immediate)
	else:
		rs.set_rain_active(amount > 0)


## Feeds the eased atmosphere to the procedural sky, or depth fog on the active LEGACY environment.
func _apply_atmosphere():
	var env_ctl = _environment_controller()
	if env_ctl == null:
		return
	if "weather_dim" in env_ctl:
		env_ctl.weather_dim = float(_cur.dim)
	if "weather_gloom" in env_ctl:
		env_ctl.weather_gloom = float(_cur.gloom)
	var proc_env = env_ctl.get("_proc_env")
	if proc_env != null and proc_env is Environment:
		_apply_procedural(env_ctl, proc_env)
		return
	_apply_legacy_fog(env_ctl)


func _apply_procedural(env_ctl, proc_env: Environment) -> void:
	if proc_env.volumetric_fog_enabled:
		proc_env.volumetric_fog_density = float(_cur.vol)
	elif proc_env.fog_enabled:
		# Density only; the EnvironmentController sets the web haze's colour.
		proc_env.fog_density = float(_cur.fogd)
	var sky_mat = env_ctl.get("_sky_material")
	if sky_mat != null and sky_mat is ShaderMaterial:
		sky_mat.set_shader_parameter("cloud_coverage", float(_cur.cloud))
		sky_mat.set_shader_parameter("cloud_speed", float(_cur.cspeed))
		# Heavy weather merges the clouds into one deck.
		sky_mat.set_shader_parameter("cloud_softness", 0.22 + float(_cur.gloom) * 0.16)
		_grey_sky(sky_mat, float(_cur.gloom))


## Grey depth fog while hazier than clear; else the environment's own fog, saved on first touch.
func _apply_legacy_fog(env_ctl) -> void:
	var we = env_ctl.get("world_environment")
	if we == null or not is_instance_valid(we):
		return
	var env: Environment = we.environment
	if env == null:
		return
	if not _fog_saved.has(env):
		_fog_saved[env] = {"enabled": env.fog_enabled, "density": env.fog_density}
	var clear_prof: Dictionary = PROFILES["clear"]
	if float(_cur.fogd) > float(clear_prof.fogd) + 0.0015:
		env.fog_enabled = true
		env.fog_density = float(_cur.fogd)
		env.fog_light_color = Color(0.66, 0.68, 0.72)
	else:
		var saved: Dictionary = _fog_saved[env]
		env.fog_enabled = bool(saved.enabled)
		env.fog_density = float(saved.density)


## Eases the wind (with a slow gust) and sets the rain volume.
func _apply_audio(delta):
	if _wind_player != null:
		var gust := sin(Time.get_ticks_msec() / 1000.0 * 0.37) * 2.5
		_wind_player.volume_db = move_toward(_wind_player.volume_db, float(_cur.wdb) + gust, delta * 10.0)
	var rs = _rain_system()
	if rs != null:
		var audio = rs.get_node_or_null("RainAudio")
		if audio != null:
			audio.volume_db = float(_cur.rdb)


## Greys towards GLOOM_SKY from originals saved on first touch, so clearing restores them exactly.
func _grey_sky(sky_mat: ShaderMaterial, gloom: float):
	for pname in GLOOM_SKY:
		if not _sky_orig.has(pname):
			var v = sky_mat.get_shader_parameter(pname)
			if v == null:
				continue
			_sky_orig[pname] = v
		var orig = _sky_orig[pname]
		var target: Vector3 = GLOOM_SKY[pname]
		if orig is Vector3:
			sky_mat.set_shader_parameter(pname, (orig as Vector3).lerp(target, gloom))
		elif orig is Color:
			var oc: Color = orig
			var tc := Color(target.x, target.y, target.z, oc.a)
			sky_mat.set_shader_parameter(pname, oc.lerp(tc, gloom))


## 6000 snow flakes around the camera, hidden until it snows.
func _build_snow():
	_snow_root = Node3D.new()
	_snow_root.name = "WeatherSnow"
	add_child(_snow_root)
	_snow_root.top_level = true
	_snow_root.global_transform = Transform3D.IDENTITY
	_snow = MultiMeshInstance3D.new()
	_snow.name = "Flakes"
	_snow_material = ShaderMaterial.new()
	_snow_material.shader = load("res://src/world/environment/snow_flake.gdshader")
	_snow.material_override = _snow_material
	var mesh := MultiMesh.new()
	mesh.transform_format = MultiMesh.TRANSFORM_3D
	mesh.use_custom_data = true
	mesh.mesh = load("res://assets/world/environment/rain_drop_mesh.tres")
	mesh.instance_count = 6000
	var rng := RandomNumberGenerator.new()
	rng.seed = 91023
	for i in mesh.instance_count:
		mesh.set_instance_transform(i, Transform3D.IDENTITY)
		mesh.set_instance_custom_data(i, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
	mesh.custom_aabb = AABB(Vector3(-15,-9,-15), Vector3(30,18,30))
	_snow.multimesh = mesh
	_snow.visible = false
	_snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_snow_root.add_child(_snow)


## Keeps the flakes on the camera (else the local player) with the RainSystem's ground map.
func _follow_player():
	if _snow_root == null or not _snow.visible:
		return
	var target: Node3D = get_viewport().get_camera_3d()
	if target == null and _nc != null:
		target = _nc.players.local_player
	if is_instance_valid(target):
		_snow_root.global_position = target.global_position
		_snow_material.set_shader_parameter("rain_center", target.global_position)
	_snow_material.set_shader_parameter("snow_time", _snow_time)
	var rainfall = _rain_system()
	if rainfall != null:
		_snow_material.set_shader_parameter("surface_map", rainfall._surface_texture)
		_snow_material.set_shader_parameter("surface_origin", rainfall._surface_origin)
		_snow_material.set_shader_parameter("surface_ready", rainfall._surface_ready)


## The looping wind and the thunder (on web, once its pack arrives).
func _build_audio():
	_wind_player = AudioStreamPlayer.new()
	var wind_stream = load(WIND_STREAM) if ResourceLoader.exists(WIND_STREAM) else null
	if wind_stream != null:
		var s = wind_stream.duplicate()
		if "loop" in s:
			s.loop = true
		_wind_player.stream = s
	_wind_player.volume_db = -80.0
	_wind_player.autoplay = true
	add_child(_wind_player)
	_thunder_player = AudioStreamPlayer.new()
	add_child(_thunder_player)
	if ResourceLoader.exists(THUNDER_STREAM):
		_thunder_player.stream = load(THUNDER_STREAM)
		return
	var pm = get_node_or_null("/root/PCKManager")
	if pm != null and pm.has_method("when_available"):
		pm.when_available(THUNDER_STREAM, func():
			if is_instance_valid(_thunder_player):
				_thunder_player.stream = load(THUNDER_STREAM))


## A full-screen white rect for lightning.
func _build_flash():
	var layer := CanvasLayer.new()
	layer.layer = 55
	add_child(layer)
	_flash = ColorRect.new()
	_flash.color = Color(1, 1, 1, 0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_flash)


## In storms, flashes every 8 to 26 s with the thunder 0.4 to 1.6 s later.
func _thunder_tick(delta):
	if _flash != null and _flash.color.a > 0.0:
		_flash.color.a = maxf(_flash.color.a - delta * 3.0, 0.0)
	if _type != "storm":
		return
	_thunder_timer -= delta
	if _thunder_timer > 0.0:
		return
	_thunder_timer = randf_range(8.0, 26.0)
	if _flash != null:
		_flash.color.a = randf_range(0.2, 0.4)
	if _thunder_player != null and _thunder_player.stream != null:
		_thunder_player.volume_db = randf_range(-8.0, 0.0)
		get_tree().create_timer(randf_range(0.4, 1.6)).timeout.connect(_thunder_player.play)
