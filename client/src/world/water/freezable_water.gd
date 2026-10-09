extends Node3D
## Regional ice on the parent's water planes, with solid ice collision near the camera; parent origin is water level.

const SOLID_ICE := 0.98

@export_enum("sea_ice", "freshwater_ice") var ice_field := "sea_ice"
@export_range(1.0, 128.0, 1.0) var cell_size := 32.0
@export_range(1, 8) var collision_radius := 4

var weather: Node
var _surfaces: Array[MeshInstance3D] = []
var _body: StaticBody3D
var _shape: CollisionShape3D
var _timer := 0.0
var _last_faces := PackedVector3Array()


## Takes own material copies of the sibling water planes.
func _ready() -> void:
	for child in get_parent().get_children():
		if child is MeshInstance3D and child.mesh is PlaneMesh and child.material_override is ShaderMaterial:
			child.material_override = child.material_override.duplicate()
			_surfaces.append(child)
	_body = StaticBody3D.new()
	_body.name = "IceCollision"
	_body.collision_layer = 1
	_body.collision_mask = 0
	add_child(_body)
	_shape = CollisionShape3D.new()
	_body.add_child(_shape)


func _physics_process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 0.25
	refresh()


## Rebuilds the ice collider only when the set of solid cells changed.
func refresh() -> void:
	if not is_instance_valid(weather):
		var scene := get_tree().current_scene
		weather = scene.find_child("WeatherController", true, false) if scene != null else null
	if weather == null or not weather.regional_weather:
		_clear_collision()
		for surface in _surfaces:
			surface.material_override.set_shader_parameter("regional_enabled", false)
		return
	for surface in _surfaces:
		weather.set_regional_shader(surface.material_override, ice_field)
		# A plane set lower (to avoid z-fighting) still freezes at mean level.
		surface.material_override.set_shader_parameter("frozen_surface_offset", -surface.position.y)
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_clear_collision()
		return
	var point := to_local(camera.global_position)
	var center := Vector2i(floori(point.x / cell_size), floori(point.z / cell_size))
	var faces := _ice_faces(center)
	if faces == _last_faces:
		return
	_last_faces = faces
	if faces.is_empty():
		_shape.shape = null
	else:
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(faces)
		_shape.shape = shape


func _clear_collision() -> void:
	_shape.shape = null
	_last_faces.clear()


## Fully frozen cells within collision_radius of center.
func _ice_faces(center: Vector2i) -> PackedVector3Array:
	var faces := PackedVector3Array()
	for z in range(-collision_radius, collision_radius + 1):
		for x in range(-collision_radius, collision_radius + 1):
			var key := center + Vector2i(x, z)
			var a := Vector3(key.x * cell_size, 0, key.y * cell_size)
			var b := a + Vector3(cell_size, 0, 0)
			var c := a + Vector3(0, 0, cell_size)
			var d := a + Vector3(cell_size, 0, cell_size)
			if _is_solid([a, b, c, d, (a + d) * 0.5]):
				faces.append_array(PackedVector3Array([a, c, b, b, c, d]))
	return faces


func _is_solid(points: Array) -> bool:
	for vertex in points:
		if not _has_surface(vertex) or float(weather.conditions_at(to_global(vertex))[ice_field]) < SOLID_ICE:
			return false
	return true


func _has_surface(point: Vector3) -> bool:
	for surface in _surfaces:
		var local := surface.to_local(to_global(point))
		var plane := surface.mesh as PlaneMesh
		if absf(local.x) <= plane.size.x * 0.5 and absf(local.z) <= plane.size.y * 0.5:
			return true
	return false
