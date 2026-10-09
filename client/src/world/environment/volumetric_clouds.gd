@tool
class_name VolumetricClouds
extends MeshInstance3D
## Volumetric cloud shell around a planet: sizes the box and feeds radii and sun to the shader.

@export var planet_radius: float = 62.0:
	set(value):
		planet_radius = value
		_update_clouds()

@export var cloud_floor_height: float = 4.0:
	set(value):
		cloud_floor_height = value
		_update_clouds()

@export var cloud_ceiling_height: float = 14.0:
	set(value):
		cloud_ceiling_height = value
		_update_clouds()

@export var sun_object: Node3D


func _init() -> void:
	if material_override:
		material_override = material_override.duplicate()
	if mesh:
		mesh = mesh.duplicate()


func _ready() -> void:
	_update_clouds()
	set_physics_process(sun_object != null)


func _update_clouds() -> void:
	if not material_override or not mesh:
		return
	var mat: ShaderMaterial = material_override
	var inner_r := planet_radius + cloud_floor_height
	var outer_r := planet_radius + cloud_ceiling_height
	var cube: BoxMesh = mesh
	cube.size = Vector3.ONE * 2.1 * outer_r

	mat.set_shader_parameter("cloud_inner_radius", inner_r)
	mat.set_shader_parameter("cloud_outer_radius", outer_r)


func _physics_process(_delta: float) -> void:
	if sun_object and material_override:
		var sun_dir := (sun_object.global_position - global_position).normalized()
		(material_override as ShaderMaterial).set_shader_parameter("sun_direction", sun_dir)
