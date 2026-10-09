extends RefCounted
## What the weather does to one citizen: umbrella and pace. Apart from held_prop so rain never empties a hand.

const UMBRELLA := "res://assets/art/models/props/black_umbrella.glb"
const WET := ["drizzle", "rain", "storm"]
const FELT := ["drizzle", "rain", "storm", "snow", "windy"]
const TWO_HANDED := ["pot", "broom", "bento"]
const SIZE_RATIO := 0.95

var body: CharacterBody3D
var weather_type := "clear"
var exposed := false
var umbrella_open := false
var speed_factor := 1.0
var _timer := 0.0
var _umbrella: Node3D
var _height := 6.0
var _top := 3.0
var _using_left := false


func setup(citizen: CharacterBody3D) -> void:
	body = citizen
	_timer = float(abs(hash(str(body.ped_id))) % 100) / 100.0
	var model: Node3D = body.character_model
	if model == null:
		return
	var bounds := AABB()
	var found := false
	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	if model is MeshInstance3D:
		meshes.append(model)
	for node in meshes:
		if node.mesh == null or not node.visible:
			continue
		var box: AABB = model.global_transform.affine_inverse() * node.global_transform * node.mesh.get_aabb()
		bounds = bounds.merge(box) if found else box
		found = true
	if found:
		_height = maxf(bounds.size.y, 1.0)
		_top = bounds.end.y


## Authority only, once a second.
func tick(delta: float) -> void:
	if not body.is_authority():
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 1.0
	weather_type = _local_weather()
	exposed = false
	if weather_type in FELT:
		exposed = _sky_above()
	var hands_free: bool = not (body.held_prop in TWO_HANDED)
	set_umbrella(exposed and weather_type in WET and hands_free and not body.sitting)
	speed_factor = 1.0
	if exposed:
		match weather_type:
			"rain": speed_factor = 1.12
			"storm": speed_factor = 1.22
			"snow": speed_factor = 0.82
	if exposed and weather_type in WET and body.errand_owner == null and not body.is_engaged():
		body.idle_timer = minf(body.idle_timer, 1.5)


## By region: the world process has no camera to take a viewpoint from.
func _local_weather() -> String:
	var manager = body.manager
	if manager != null and manager.has_method("weather_at"):
		return manager.weather_at(body.global_position)
	if manager != null and manager.has_method("current_weather"):
		return manager.current_weather()
	return "clear"


func _sky_above() -> bool:
	var model: Node3D = body.character_model
	var start: Vector3 = model.to_global(Vector3(0, _top + _height * 0.05, 0)) if model != null else body.global_position + Vector3.UP
	var ray := PhysicsRayQueryParameters3D.create(start, start + Vector3.UP * 60.0)
	ray.exclude = [body.get_rid()]
	return body.get_world_3d().direct_space_state.intersect_ray(ray).is_empty()


func set_umbrella(open: bool) -> void:
	if umbrella_open and not open:
		_release_arm()
	umbrella_open = open
	if not open:
		if is_instance_valid(_umbrella):
			_umbrella.visible = false
		return
	if not is_instance_valid(_umbrella) and not _spawn_umbrella():
		return
	_umbrella.visible = true
	pose()


## False when it cannot be loaded.
func _spawn_umbrella() -> bool:
	if body.character_model == null or not ResourceLoader.exists(UMBRELLA):
		return false
	var packed := load(UMBRELLA) as PackedScene
	if packed == null:
		return false
	_umbrella = packed.instantiate()
	_umbrella.name = "WeatherUmbrella"
	body.character_model.add_child(_umbrella)
	# The model is 1.0 wide; its shaft is tilted in Y/Z (corrected in pose()).
	_umbrella.scale = Vector3.ONE * (_height * SIZE_RATIO)
	for mesh in _umbrella.find_children("*", "MeshInstance3D", true, false):
		for surface in mesh.mesh.get_surface_count():
			_soften_surface(mesh, surface)
	return true


## The model marks the whole canopy as metal; make it fabric, keeping colour and normal maps.
func _soften_surface(mesh: MeshInstance3D, surface: int) -> void:
	var material = mesh.get_active_material(surface)
	if not (material is StandardMaterial3D):
		return
	material = material.duplicate()
	material.metallic = 0.0
	material.metallic_texture = null
	material.roughness = 0.85
	material.roughness_texture = null
	material.metallic_specular = 0.25
	mesh.set_surface_override_material(surface, material)


func pose() -> void:
	if not umbrella_open or not is_instance_valid(_umbrella):
		return
	var use_left: bool = body.calling or body.held_prop != ""
	if use_left != _using_left:
		_release_arm()
	_using_left = use_left
	var model: Node3D = body.character_model
	var size := _height * SIZE_RATIO
	var grip := Vector3((-0.22 if _using_left else 0.22) * _height, _top - _height * 0.68, -_height * 0.12)
	if body.has_limbs():
		var arm: Node3D = body.limb_rig().left_arm if _using_left else body.limb_rig().right_arm
		body.limb_rig().pitch(arm, 0.55)
		body.limb_rig().flex(arm, 1.4)
		var joint = body.limb_rig().joint_of(arm)
		if joint != null:
			var hand: Vector3 = joint.mesh_instance.mesh.get_aabb().get_center()
			hand.y = joint.mesh_instance.mesh.get_aabb().position.y + 0.12
			var u: float = joint.joint.y - hand.y
			var bend: Transform3D = joint.ring_transform(u, joint.joint, joint.half_width, joint.axis, joint.angle)
			grip = model.to_local(arm.to_global(bend * hand))
		else:
			grip = model.to_local(arm.to_global(Vector3(0, -1.6, 0)))
	# Fixed, so the canopy stays upright instead of swinging with the arm.
	_umbrella.rotation = Vector3(deg_to_rad(52.43), 0, 0)
	_umbrella.position = grip + Vector3(0, size * 0.43, -size * 0.007)


func _release_arm() -> void:
	if body.has_limbs():
		var arm: Node3D = body.limb_rig().left_arm if _using_left else body.limb_rig().right_arm
		body.limb_rig().flex(arm, 0.0)
		body.limb_rig().pitch(arm, 0.0)


func snapshot() -> Dictionary:
	return {"type": weather_type, "exposed": exposed, "umbrella": umbrella_open, "pace": speed_factor}


func apply_snapshot(data: Dictionary) -> void:
	weather_type = str(data.get("type", "clear"))
	exposed = bool(data.get("exposed", false))
	speed_factor = clampf(float(data.get("pace", 1.0)), 0.5, 1.5)
	set_umbrella(bool(data.get("umbrella", false)))
