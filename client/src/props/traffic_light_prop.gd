@tool
extends Node3D

## Traffic light following the AmbientManager signal for the approach it faces.

## Rotates the reading when the model faces the wrong approach.
@export var facing_yaw_offset_deg := 0.0
@export var show_district_plate := true
@export var light_energy := 1.6

const GO_COLOR := Color(0.1, 0.65, 1.0)
const PREPARE_COLOR := Color(1.0, 0.55, 0.08)
const STOP_COLOR := Color(1.0, 0.1, 0.08)

static var _mats_lit: Array = []
static var _mats_off: Array = []

var _manager = null
var _sig := -1
var _group := 0
var _state := -2 # -2 forces the first apply
var _poll := 0.0
var _flash_on := false
var _lamps: Array = []    # [Go, Prepare, Stop]
var _light: OmniLight3D = null
var _label: Label3D = null


static func _ensure_materials():
	if not _mats_lit.is_empty():
		return
	for color in [GO_COLOR, PREPARE_COLOR, STOP_COLOR]:
		var lit := StandardMaterial3D.new()
		lit.albedo_color = color
		lit.emission_enabled = true
		lit.emission = color
		lit.emission_energy_multiplier = 3.0
		_mats_lit.append(lit)
		var off := StandardMaterial3D.new()
		off.albedo_color = Color(color.r * 0.18, color.g * 0.18, color.b * 0.18)
		_mats_off.append(off)


func _ready():
	_ensure_materials()
	for lamp_name in ["Go", "Prepare", "Stop"]:
		_lamps.append(get_node_or_null(lamp_name))
	if Engine.is_editor_hint():
		for i in 3:
			var lamp = _lamps[i]
			if lamp != null and lamp is MeshInstance3D:
				(lamp as MeshInstance3D).set_surface_override_material(0, _mats_lit[i])
		set_process(false)
		return
	_light = get_node_or_null("OmniLight3D")
	if _light:
		_light.distance_fade_enabled = true
		_light.distance_fade_begin = 60.0
		_light.light_energy = light_energy
	_poll = randf_range(0.0, 0.25)
	# The AmbientManager is built after scene entry.
	call_deferred("_connect_to_signals")


func _connect_to_signals():
	var root := get_tree().current_scene
	if root:
		_manager = root.find_child("AmbientManager", true, false)
	if _manager == null:
		return
	var local_pos: Vector3 = _manager.world().to_local(global_position)
	_sig = _manager.nearest_signal(local_pos)
	if _sig >= 0:
		var facing := -global_basis.z.rotated(Vector3.UP, deg_to_rad(facing_yaw_offset_deg))
		_group = _manager.group_for_facing(_sig, facing.normalized())
	if show_district_plate:
		_setup_plate(local_pos)


func _setup_plate(local_pos: Vector3):
	var plate := get_node_or_null("ChomeText") as Node3D
	if plate == null or _manager == null:
		return
	var names: Array = _manager.places.district_names_at(local_pos)
	if names.is_empty():
		return
	_label = Label3D.new()
	_label.text = str(names[0])
	_label.font_size = 96
	_label.pixel_size = 0.02
	_label.modulate = Color(1, 1, 1)
	_label.outline_size = 18
	_label.outline_modulate = Color(0.05, 0.2, 0.1)
	add_child(_label)
	# The plate's normal is its local +Y; lift the text off it against z-fighting.
	var normal: Vector3 = plate.global_basis.y.normalized()
	_label.global_transform = Transform3D(
		plate.global_basis * Basis(Vector3.RIGHT, -PI / 2.0),
		plate.global_position + normal * 0.06)


## Four times a second, apply the signal phase (0 go, 1 prepare, 2 stop).
func _process(delta):
	_poll += delta
	if _poll < 0.25:
		return
	_poll = 0.0
	var state: int
	if _manager == null or _sig < 0:
		# No signal: flash Prepare, toggling every poll.
		_flash_on = not _flash_on
		state = 1 if _flash_on else -1
	else:
		state = _manager.signal_phase_for_group(_sig, _group)
	if state == _state:
		return
	_state = state
	for i in 3:
		var lamp = _lamps[i]
		if lamp != null and lamp is MeshInstance3D:
			(lamp as MeshInstance3D).set_surface_override_material(
				0, _mats_lit[i] if state == i else _mats_off[i])
	if _light:
		if state >= 0 and state <= 2:
			_light.visible = true
			_light.light_color = [GO_COLOR, PREPARE_COLOR, STOP_COLOR][state]
		else:
			_light.visible = false
