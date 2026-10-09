@tool
extends Node3D

## Lights that fade on when somebody is within `radius_m`; a light at zero is hidden, so it costs nothing.

## Metres, because it compares global positions.
@export var radius_m := 6.0
@export var fade_seconds := 0.35
@export var lights_when_empty := false
@export var npcs_light_rooms := true

const CHECK_INTERVAL := 0.25

var _lights: Array = []
var _full: Array = []  # authored energy per light
var _target: Array = []  # 0.0 or 1.0
var _level: Array = []  # current 0..1
var _nc = null
var _manager = null
var _poll := 0.0
var _preview: MeshInstance3D = null
var _mesh: ImmediateMesh = null


func _ready():
	if Engine.is_editor_hint():
		_mesh = ImmediateMesh.new()
		_preview = MeshInstance3D.new()
		_preview.name = "_PreviewDoNotSave"
		_preview.mesh = _mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		_preview.material_override = mat
		add_child(_preview)
		return
	_collect_lights()
	_nc = get_node_or_null("/root/NetworkController")
	var root := get_tree().current_scene
	if root:
		_manager = root.find_child("AmbientManager", true, false)
	# Staggered so several houses do not all poll on one frame.
	_poll = randf_range(0.0, CHECK_INTERVAL)


func _collect_lights():
	_lights = []
	_full = []
	_target = []
	_level = []
	var found: Array = []
	_gather_lights(_house_root(), found)
	for light in found:
		var l := light as Light3D
		_lights.append(l)
		_full.append(l.light_energy)
		var start := 1.0 if lights_when_empty else 0.0
		_target.append(start)
		_level.append(start)
		l.light_energy = _full[_full.size() - 1] * start
		l.visible = start > 0.0


func _house_root() -> Node:
	return get_parent() if get_parent() != null else self


func _gather_lights(node: Node, out: Array):
	for child in node.get_children():
		if child is Light3D:
			out.append(child)
		_gather_lights(child, out)


func _process(delta: float):
	if Engine.is_editor_hint():
		_draw_preview()
		return
	if _lights.is_empty():
		return

	_poll += delta
	if _poll >= CHECK_INTERVAL:
		_poll = 0.0
		_retarget()

	var step: float = 1.0 if fade_seconds <= 0.0 else delta / fade_seconds
	for i in _lights.size():
		var light := _lights[i] as Light3D
		if not is_instance_valid(light):
			continue
		if is_equal_approx(_level[i], _target[i]):
			continue
		_level[i] = move_toward(_level[i], _target[i], step)
		if _level[i] > 0.0 and not light.visible:
			light.visible = true
		light.light_energy = _full[i] * _level[i]
		if _level[i] <= 0.0:
			light.visible = false


func _retarget():
	if lights_when_empty:
		for i in _target.size():
			_target[i] = 1.0
		return
	var occupants := _occupants()
	var reach := radius_m * radius_m
	for i in _lights.size():
		var light := _lights[i] as Light3D
		if not is_instance_valid(light):
			_target[i] = 0.0
			continue
		var lit := _anyone_within(light.global_position, occupants, reach)
		_target[i] = 1.0 if lit else 0.0


static func _anyone_within(at: Vector3, occupants: Array, reach_sq: float) -> bool:
	for p in occupants:
		if at.distance_squared_to(p) <= reach_sq:
			return true
	return false


func _occupants() -> Array:
	if npcs_light_rooms and _manager != null:
		return _manager.people_positions_global()
	var occupants: Array = []
	if _nc and is_instance_valid(_nc.players.local_player):
		occupants.append(_nc.players.local_player.global_position)
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return occupants
	var players := scene_root.find_child("Players", true, false)
	if players == null:
		return occupants
	for p in players.get_children():
		if p is Node3D:
			occupants.append((p as Node3D).global_position)
	return occupants


func _draw_preview():
	if _mesh == null:
		return
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_mesh.surface_set_color(Color(1.0, 0.85, 0.3))
	var found: Array = []
	_gather_lights(_house_root(), found)
	var scale := global_transform.basis.get_scale()
	var unit: float = maxf(0.0001, (absf(scale.x) + absf(scale.z)) * 0.5)
	var r := radius_m / unit
	for light in found:
		var c: Vector3 = to_local((light as Light3D).global_position)
		var steps := 24
		for i in steps:
			var a0 := TAU * float(i) / float(steps)
			var a1 := TAU * float(i + 1) / float(steps)
			_mesh.surface_add_vertex(c + Vector3(cos(a0), 0, sin(a0)) * r)
			_mesh.surface_add_vertex(c + Vector3(cos(a1), 0, sin(a1)) * r)
	if found.is_empty():
		# An empty surface is an error.
		_mesh.surface_add_vertex(Vector3.ZERO)
		_mesh.surface_add_vertex(Vector3.ZERO)
	_mesh.surface_end()
