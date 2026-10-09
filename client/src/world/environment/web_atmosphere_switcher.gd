extends Node
## On web, swaps the atmosphere and cloud shaders for ones that need no depth texture.

const _web_atmo_shader = preload("res://src/world/environment/atmosphere_web.gdshader")
const _web_cloud_shader = preload("res://src/world/environment/volumetric_clouds_web.gdshader")

@export var atmosphere_node: MeshInstance3D

@export var cloud_node: MeshInstance3D

## Cloud occlusion radius, at most the mesh radius so a surface camera stays outside; 0 detects it.
@export var planet_mesh_radius: float = 0.0

@export var web_cloud_march_steps: int = 12
@export var web_cloud_light_steps: int = 2


func _ready() -> void:
	if OS.has_feature("web"):
		print("[WebAtmosphereSwitcher] Web platform detected — switching to web-safe shaders.")
		_switch_to_web_shaders()
	else:
		print("[WebAtmosphereSwitcher] Native platform — keeping original shaders.")


func _switch_to_web_shaders() -> void:
	_switch_atmosphere()
	_switch_clouds()


## The web version keeps the same uniforms.
func _switch_atmosphere() -> void:
	if not atmosphere_node:
		push_warning("[WebAtmosphereSwitcher] No atmosphere_node assigned — skipping atmosphere shader swap.")
		return

	var mat := atmosphere_node.material_override as ShaderMaterial
	if not mat:
		push_warning("[WebAtmosphereSwitcher] Atmosphere has no ShaderMaterial — skipping.")
		return

	mat.shader = _web_atmo_shader
	print("[WebAtmosphereSwitcher] Atmosphere shader swapped to web version.")


func _switch_clouds() -> void:
	if not cloud_node:
		push_warning("[WebAtmosphereSwitcher] No cloud_node assigned — skipping cloud shader swap.")
		return

	var mat := cloud_node.material_override as ShaderMaterial
	if not mat:
		push_warning("[WebAtmosphereSwitcher] Clouds have no ShaderMaterial — skipping.")
		return

	mat.shader = _web_cloud_shader
	var radius := planet_mesh_radius
	if radius <= 0.0:
		radius = _detect_planet_radius(mat, radius)
	mat.set_shader_parameter("planet_surface_radius", radius)
	mat.set_shader_parameter("march_steps", web_cloud_march_steps)
	mat.set_shader_parameter("light_steps", web_cloud_light_steps)

	print("[WebAtmosphereSwitcher] Cloud shader swapped to web version (march=%d, light=%d)." % [web_cloud_march_steps, web_cloud_light_steps])


## ProvinceMap sphere radius, else planet_radius less 4 %, else inner radius less 14, else fallback.
func _detect_planet_radius(mat: ShaderMaterial, fallback: float) -> float:
	var radius := fallback
	var province_map = get_node_or_null("../Planet/Main/ProvinceMap")
	if province_map and province_map is MeshInstance3D:
		# A default SphereMesh has radius 0.5.
		radius = province_map.transform.basis.get_scale().x * 0.5
		print("[WebAtmosphereSwitcher] Auto-detected planet mesh radius: %.1f" % radius)
	elif "planet_radius" in cloud_node:
		radius = cloud_node.planet_radius * 0.96
		print("[WebAtmosphereSwitcher] Using planet_radius fallback: %.1f" % radius)
	else:
		var inner_r = mat.get_shader_parameter("cloud_inner_radius")
		if inner_r != null:
			radius = inner_r - 14.0
	return radius
