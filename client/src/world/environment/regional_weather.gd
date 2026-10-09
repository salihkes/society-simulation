extends RefCounted
## Per-region weather simulation in the unscaled Builds frame; points between regions blend by distance.

const TYPES := ["clear", "partly", "overcast", "fog", "drizzle", "rain", "storm", "windy", "snow"]
const WorldGeo := preload("res://src/world/region/world_geo.gd")
const JsonData := preload("res://src/core/json_data.gd")
const DATA_PATH := "res://assets/world/environment/regional_weather.json"

static var _tables: Dictionary = JsonData.read(DATA_PATH)
## Per key: [freezing point, freeze rate, melt rate]; rates are fraction per degree per real hour.
static var ICE_RATES: Dictionary = _tables.get("ice_rates", {})
## lonlat, winter, summer and humidity for a region whose catalog entry lacks them.
static var STATION_DEFAULTS: Dictionary = _tables.get("station_defaults", {})

## {id, center: Vector2, lon, winter, summer, humidity} per region.
static var REGIONS: Array = _stations()

var config: Dictionary = {}
var states: Dictionary = {}
var elapsed := 0.0
var _received_elapsed := -1.0
var epoch := "%s-%s" % [Time.get_unix_time_from_system(), Time.get_ticks_usec()]
var _received_epoch := ""


static func _stations() -> Array:
	var d := STATION_DEFAULTS
	var out: Array = []
	for r in WorldGeo.regions():
		var c: Dictionary = r.get("climate", {})
		var ll: Array = r.get("lonlat", Identity.value("home_lonlat"))
		out.append({"id": str(r.id), "center": WorldGeo.center(r), "lon": float(ll[0]),
			"winter": float(c.get("winter", d.get("winter", 0.0))),
			"summer": float(c.get("summer", d.get("summer", 0.0))),
			"humidity": float(c.get("humidity", d.get("humidity", 0.0)))})
	return out


## Sets the weather config; a changed config accepts any packet time again.
func configure(data: Dictionary) -> void:
	var next := data.duplicate(true)
	next.erase("_initial")
	if next != config:
		_received_elapsed = -1.0
	config = next


## The config with region id's overrides merged in.
func settings(id: String) -> Dictionary:
	var result := config.duplicate(true)
	result.erase("regions")
	var regions = config.get("regions", {})
	if regions is Dictionary and regions.get(id) is Dictionary:
		result.merge(regions[id], true)
	return result


## data[key] clamped to low..high, or fallback when missing or not a number.
static func number(data: Dictionary, key: String, fallback: float, low: float, high: float) -> float:
	var value = data.get(key, fallback)
	if not (value is float or value is int) or not is_finite(float(value)):
		return fallback
	return clampf(float(value), low, high)


## Region settings may force the type, temperature_c and humidity_percent.
func climate(index: int, unix_time: float) -> Dictionary:
	var region: Dictionary = REGIONS[index]
	var options := settings(region.id)
	var date := Time.get_datetime_dict_from_unix_time(int(unix_time))
	var day := float(date.month - 1) * 30.4375 + float(date.day - 1)
	var summer := (1.0 - cos(TAU * (day - 15.0) / 365.25)) * 0.5
	var slot := floori(unix_time / 21600.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s:%d" % [region.id, slot])
	var anomaly := rng.randf_range(-6.0, 6.0)
	var temperature := lerpf(region.winter, region.summer, summer) + anomaly
	var solar_hour := fposmod(unix_time / 3600.0 + float(region.lon) / 15.0, 24.0)
	temperature += 2.5 * cos(TAU * (solar_hour - 13.5) / 24.0)
	var humidity := clampf(float(region.humidity) - summer * 12.0 + rng.randf_range(-15, 15), 15, 100)
	temperature = number(options, "temperature_c", temperature, -80.0, 60.0)
	var kind := _roll_type(rng.randf(), humidity, summer, temperature)
	var forced := str(options.get("type", "auto")).strip_edges().to_lower()
	if forced == "raining":
		forced = "rain"
	if TYPES.has(forced):
		kind = forced
	# Forced snow is cold too, unless temperature_c is set explicitly.
	if kind == "snow":
		temperature = minf(temperature, -1.0)
	if kind in ["rain", "storm", "drizzle", "snow", "fog"]:
		humidity = maxf(humidity, 85.0)
	temperature = number(options, "temperature_c", temperature, -80.0, 60.0)
	humidity = number(options, "humidity_percent", humidity, 0.0, 100.0)
	return {"type": kind, "temperature_c": temperature, "humidity_percent": humidity}


## Wetter types are likelier in winter.
static func _roll_type(roll: float, humidity: float, summer: float, temperature: float) -> String:
	if roll < 0.08:
		return "windy"
	elif roll < 0.12 and humidity > 65:
		return "fog"
	elif roll < 0.38 - summer * 0.15:
		return "snow" if temperature <= 1.0 else ("storm" if roll < 0.17 else "rain")
	elif roll < 0.45 - summer * 0.10:
		return "drizzle" if temperature > 1.0 else "snow"
	elif roll < 0.60:
		return "overcast"
	elif roll < 0.80:
		return "partly"
	return "clear"


## Integrates ice and snow depth over delta seconds.
func advance(delta: float, unix_time: float) -> void:
	if not is_finite(delta) or delta < 0.0:
		return
	elapsed += delta
	for i in REGIONS.size():
		var id: String = REGIONS[i].id
		var next := climate(i, unix_time)
		var previous: Dictionary = states.get(id, {})
		for key in ICE_RATES:
			var tune: Array = ICE_RATES[key]
			var difference := float(tune[0]) - float(next.temperature_c)
			var rate := float(tune[1]) if difference > 0.0 else float(tune[2])
			next[key] = clampf(float(previous.get(key, 0.0)) + difference * rate * delta / 3600.0, 0.0, 1.0)
		_advance_snow(id, next, previous, delta)
		states[id] = next


## Snow weather at or below 1 degree adds, above 0 melts; a new command may set the depth.
func _advance_snow(id: String, next: Dictionary, previous: Dictionary, delta: float) -> void:
	var snow = settings(id).get("snow", {})
	if not snow is Dictionary:
		snow = {}
	var depth := float(previous.get("snow_depth", 0.0))
	var command := str(snow.get("command", ""))
	if command != "" and command != str(previous.get("snow_command", "")):
		depth = number(snow, "depth", depth, 0.0, 0.3)
	var max_depth := number(snow, "max_depth", 0.18, 0, 0.3)
	if next.type == "snow" and next.temperature_c <= 1.0:
		depth = minf(maxf(max_depth, depth), depth + number(snow, "rate", 0.006, 0, 0.1) * delta / 60.0)
	elif next.temperature_c > 0.0:
		depth = maxf(0, depth - number(snow, "melt", 0.002, 0, 0.1) * delta / 60.0)
	next["snow_depth"] = depth
	next["snow_command"] = command


## Normalised inverse-distance weights at a Builds-frame point; regional_field.gdshaderinc matches it.
func weights(position: Vector2) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	var total := 0.0
	for region in REGIONS:
		var distance := position.distance_squared_to(region.center) / 100000000.0
		var weight := 1.0 / maxf(distance * distance, 0.000001)
		result.append(weight)
		total += weight
	for i in result.size():
		result[i] /= total
	return result


## Blended conditions at a Builds-frame point, with the nearest region's id and weather type.
func sample(position: Vector2) -> Dictionary:
	if states.is_empty():
		advance(0.0, Time.get_unix_time_from_system())
	var blend := weights(position)
	var nearest := 0
	var result := {"temperature_c": 0.0, "humidity_percent": 0.0, "sea_ice": 0.0, "freshwater_ice": 0.0, "snow_depth": 0.0}
	for i in REGIONS.size():
		if blend[i] > blend[nearest]:
			nearest = i
		var state: Dictionary = states[REGIONS[i].id]
		for key in result:
			result[key] += float(state[key]) * blend[i]
	result["region"] = REGIONS[nearest].id
	result["type"] = states[result.region].type
	return result


func packet() -> Dictionary:
	return {"version": 1, "epoch": epoch, "config": config.duplicate(true), "elapsed": elapsed, "states": states.duplicate(true)}


## Adopts a packet with the same config, a newer same-epoch time and valid regions; else false.
func apply_packet(data: Dictionary) -> bool:
	if data.get("version") != 1 or data.get("config") != config or not data.get("states") is Dictionary:
		return false
	var time = data.get("elapsed")
	var incoming_epoch = data.get("epoch")
	if not incoming_epoch is String or incoming_epoch.is_empty():
		return false
	var minimum := maxf(0.0, _received_elapsed) if incoming_epoch == _received_epoch else 0.0
	if not (time is float or time is int) or not is_finite(float(time)) or float(time) < minimum:
		return false
	if data.states.size() != REGIONS.size():
		return false
	for region in REGIONS:
		if not _valid_state(data.states.get(region.id)):
			return false
	states = data.states.duplicate(true)
	elapsed = float(time)
	_received_elapsed = elapsed
	epoch = incoming_epoch
	_received_epoch = incoming_epoch
	return true


static func _valid_state(state: Variant) -> bool:
	if not state is Dictionary or not TYPES.has(state.get("type")):
		return false
	for key in ["temperature_c", "humidity_percent", "sea_ice", "freshwater_ice", "snow_depth"]:
		var limits := [-80.0, 60.0] if key == "temperature_c" else ([0.0, 100.0] if key == "humidity_percent" else [0.0, 0.3 if key == "snow_depth" else 1.0])
		var value = state.get(key)
		if not (value is float or value is int) or not is_finite(float(value)):
			return false
		if float(value) < limits[0] or float(value) > limits[1]:
			return false
	return true


## Per-region (global x, global z, field value, 0) for regional_field.gdshaderinc.
func shader_values(frame: Node3D, field: String) -> PackedVector4Array:
	var result := PackedVector4Array()
	for region in REGIONS:
		var center := frame.to_global(Vector3(region.center.x, 0, region.center.y))
		result.append(Vector4(center.x, center.z, float(states.get(region.id, {}).get(field, 0.0)), 0))
	return result
