extends Node3D
## City coast sea whose swell and crest foam ease towards the WeatherController's sea state.

const JsonData := preload("res://src/core/json_data.gd")
const DATA_PATH := "res://assets/world/water/sea_state.json"

## Weather type -> wave scale.
static var SEA_STATE: Dictionary = JsonData.read(DATA_PATH)

@export var base_wave_scale := 1.0
## Seconds for the sea to settle into a new weather state.
@export var response_seconds := 25.0

var _mat: ShaderMaterial
var _weather: Node = null
var _target := 1.0
var _cur := 1.0
var _poll := 1.0


## Gives Near its own copy of the sea material.
func _ready() -> void:
	var ice := preload("res://src/world/water/freezable_water.gd").new()
	ice.name = "WaterIce"
	add_child(ice)
	var near := get_node_or_null("Near") as MeshInstance3D
	if near != null and near.material_override is ShaderMaterial:
		# Own copy so runtime tweaks never dirty the shared .tres.
		_mat = (near.material_override as ShaderMaterial).duplicate()
		near.material_override = _mat
		_mat.set_shader_parameter("wave_scale", base_wave_scale)


func _process(delta: float) -> void:
	if _mat == null:
		return
	_poll += delta
	if _poll >= 1.0:
		_poll = 0.0
		_target = SEA_STATE.get(_weather_type(), 1.0)
	var k := 1.0 - exp(-delta / maxf(response_seconds, 0.5))
	_cur = lerpf(_cur, _target, k)
	_mat.set_shader_parameter("wave_scale", base_wave_scale * _cur)
	_mat.set_shader_parameter("crest_foam", 0.6 * clampf(_cur, 0.5, 2.0))


## "clear" without a WeatherController.
func _weather_type() -> String:
	if _weather == null or not is_instance_valid(_weather):
		var root := get_tree().current_scene
		if root == null:
			return "clear"
		_weather = root.find_child("WeatherController", true, false)
	if _weather != null and _weather.has_method("current_type"):
		return str(_weather.current_type())
	return "clear"


## World space; waves ride +-~1 model unit around it.
func sea_level() -> float:
	return global_position.y
