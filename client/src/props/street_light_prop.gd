@tool
extends Node3D

## Street light lit between on_hour and off_hour by the game clock.

@export var on_hour := 18.5
@export var off_hour := 6.5
@export var light_energy := 2.2
@export var light_color := Color(1.0, 0.88, 0.66)   # warm sodium-ish

var _light: OmniLight3D = null
var _env = null
var _poll := 0.0
var _lit := false


func _ready():
	_light = get_node_or_null("OmniLight3D")
	if _light:
		_light.shadow_enabled = true
		_light.distance_fade_enabled = true
		_light.distance_fade_begin = 50.0
		_light.distance_fade_length = 15.0
		_light.distance_fade_shadow = 30.0
		_light.light_energy = light_energy
		_light.light_color = light_color
		# Editor: keep the lamp glowing so its throw is visible while placing.
		_light.visible = Engine.is_editor_hint()
	if Engine.is_editor_hint():
		set_process(false)
		return
	_poll = randf_range(0.0, 1.0)
	call_deferred("_find_env")


func _find_env():
	var root := get_tree().current_scene
	if root:
		_env = root.find_child("EnvironmentController", true, false)


func _process(delta):
	_poll += delta
	if _poll < 1.0:
		return
	_poll = 0.0
	var hour := 12.0
	if _env != null and is_instance_valid(_env):
		hour = float(_env.current_time) * 24.0
	var want: bool = hour >= on_hour or hour < off_hour
	if want != _lit:
		_lit = want
		if _light:
			_light.visible = want
