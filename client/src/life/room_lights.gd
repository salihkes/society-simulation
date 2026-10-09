@tool
extends Node3D

## Lights only the rooms somebody is in; Room* children are boxes scaled to half-extents.

@export var lights_when_empty := false
@export var npcs_light_rooms := true
## Editor-only initial visibility; disable for large interiors.
@export var editor_preview_lights := true:
	set(value):
		editor_preview_lights = value
		if Engine.is_editor_hint() and is_inside_tree():
			_apply_editor_light_preview()
const CHECK_INTERVAL := 0.25

var _rooms: Array = []
var _room_lights: Array = []  # per room: Array[Light3D]
var _room_on: Array = []  # per room: bool
var _nc = null
var _manager = null
var _poll := 0.0
var _preview: MeshInstance3D = null
var _mesh: ImmediateMesh = null


func _ready():
	if Engine.is_editor_hint():
		_mesh = ImmediateMesh.new()
		_preview = MeshInstance3D.new()
		_preview.mesh = _mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		_preview.material_override = mat
		add_child(_preview)
		_apply_editor_light_preview()
		return
	_collect_rooms()
	_nc = get_node_or_null("/root/NetworkController")
	var root := get_tree().current_scene
	if root:
		_manager = root.find_child("AmbientManager", true, false)
	_poll = randf_range(0.0, CHECK_INTERVAL)


func _apply_editor_light_preview() -> void:
	var lights: Array = []
	_gather_lights(_house_root(), lights)
	for light in lights:
		(light as Light3D).visible = editor_preview_lights


## A light inside no box stays on.
func _collect_rooms():
	_rooms = []
	_room_lights = []
	_room_on = []
	for child in get_children():
		if _is_room(child):
			_rooms.append(child)
			_room_lights.append([])
			_room_on.append(true)  # differs from the start state, so it applies
	var lights: Array = []
	_gather_lights(_house_root(), lights)
	for light in lights:
		var lp: Vector3 = (light as Light3D).global_position
		for i in _rooms.size():
			if _in_box(_room_inverse(i), lp):
				_room_lights[i].append(light)
				break
	for i in _rooms.size():
		_set_room(i, lights_when_empty)


func _is_room(node: Node) -> bool:
	return node is Node3D and str(node.name).to_lower().begins_with("room")


func _house_root() -> Node:
	return get_parent() if get_parent() != null else self


func _room_inverse(i: int) -> Transform3D:
	return (_rooms[i] as Node3D).global_transform.affine_inverse()


## `inv` is the inverse transform of a unit box.
static func _in_box(inv: Transform3D, p: Vector3) -> bool:
	var local: Vector3 = inv * p
	return absf(local.x) <= 1.0 and absf(local.y) <= 1.0 and absf(local.z) <= 1.0


func _gather_lights(node: Node, out: Array):
	for child in node.get_children():
		if child is Light3D:
			out.append(child)
		_gather_lights(child, out)


func _process(delta):
	if Engine.is_editor_hint():
		_draw_preview()
		return
	_poll += delta
	if _poll < CHECK_INTERVAL:
		return
	_poll = 0.0
	var occupants := _occupants()
	for i in _rooms.size():
		_set_room(i, lights_when_empty or _room_occupied(i, occupants))


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


func _room_occupied(i: int, occupants: Array) -> bool:
	var inv := _room_inverse(i)
	for p in occupants:
		if _in_box(inv, p):
			return true
	return false


func _set_room(i: int, on: bool):
	if _room_on[i] == on:
		return
	_room_on[i] = on
	for light in _room_lights[i]:
		if is_instance_valid(light):
			(light as Light3D).visible = on


const _BOX_EDGES := [
	[0, 1], [1, 3], [3, 2], [2, 0],
	[4, 5], [5, 7], [7, 6], [6, 4],
	[0, 4], [1, 5], [2, 6], [3, 7],
]


func _draw_preview():
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_mesh.surface_set_color(Color(0.2, 0.9, 1.0))
	var any := false
	for child in get_children():
		if _is_room(child):
			any = true
			var xf: Transform3D = to_local_transform(child)
			for edge in _BOX_EDGES:
				_mesh.surface_add_vertex(xf * _corner(edge[0]))
				_mesh.surface_add_vertex(xf * _corner(edge[1]))
	if not any:
		# An empty surface is an error.
		_mesh.surface_add_vertex(Vector3.ZERO)
		_mesh.surface_add_vertex(Vector3.ZERO)
	_mesh.surface_end()


func to_local_transform(child: Node3D) -> Transform3D:
	return global_transform.affine_inverse() * child.global_transform


static func _corner(i: int) -> Vector3:
	return Vector3(
		-1.0 if i & 1 == 0 else 1.0,
		-1.0 if i & 2 == 0 else 1.0,
		-1.0 if i & 4 == 0 else 1.0)
