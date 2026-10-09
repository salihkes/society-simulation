extends Node3D
class_name PlayerBlaster
## The player's blaster: follows a controller in VR, sits beside the camera on desktop.

@export var bolt_color := Color(0.1, 0.8, 0.3)
@export var bolt_speed := 25.0
@export var fire_cooldown := 0.35
@export var follow_speed := 20.0

@export var grip_offset := Transform3D(
	Basis(Vector3(1, 0, 0), deg_to_rad(-10)),
	Vector3(0, 0, 0)
)

## VR controller to follow; null on desktop.
var target_node: Node3D = null
var _cooldown_timer := 0.0
var _bolt_parent: Node3D = null
var combat_sync: CombatSync = null
var is_vr := false
var _character: CharacterBody3D = null

var _snd_fire: AudioStream = BlasterBolt.optional_audio(BlasterBolt.FIRE_SOUND)

var gun_mesh: MeshInstance3D
var muzzle_point: Node3D
var muzzle_flash: OmniLight3D
var _sfx_player: AudioStreamPlayer3D


func _ready():
	_build_gun()
	_build_muzzle()
	_sfx_player = AudioStreamPlayer3D.new()
	_sfx_player.name = "BlasterSFX"
	_sfx_player.max_distance = 30.0
	add_child(_sfx_player)


func _physics_process(delta: float):
	_cooldown_timer = maxf(0.0, _cooldown_timer - delta)

	if is_vr and target_node and is_instance_valid(target_node):
		_follow_controller(delta)
	elif not is_vr and _character and is_instance_valid(_character):
		_follow_camera(delta)

	if muzzle_flash and muzzle_flash.light_energy > 0.0:
		muzzle_flash.light_energy = maxf(0.0, muzzle_flash.light_energy - delta * 15.0)


func fire():
	if _cooldown_timer > 0.0:
		return
	_cooldown_timer = fire_cooldown

	var bolt := BlasterBolt.new()
	bolt.bolt_color = bolt_color
	bolt.speed = bolt_speed
	bolt.proximity_deflect_radius = 0.3

	var parent := _bolt_parent if _bolt_parent else get_parent()
	parent.add_child(bolt)

	var fire_pos: Vector3
	var fire_dir: Vector3

	if is_vr:
		fire_pos = muzzle_point.global_position
		fire_dir = -global_transform.basis.z
	else:
		var camera := _character.get_viewport().get_camera_3d()
		fire_pos = _character.global_position + Vector3(0, 1.2, 0)
		if camera:
			fire_dir = -camera.global_transform.basis.z
		else:
			fire_dir = -_character.global_transform.basis.z

	bolt.fire(fire_pos, fire_dir)

	if muzzle_flash:
		muzzle_flash.light_energy = 4.0
	if _sfx_player and _snd_fire:
		_sfx_player.stream = _snd_fire
		_sfx_player.play()

	if combat_sync:
		combat_sync.send_bolt_fired(fire_pos, fire_dir, bolt_color, bolt_speed)


func _follow_camera(delta: float):
	if _character == null:
		return
	var camera := _character.get_viewport().get_camera_3d()
	if camera == null:
		return
	var cam_xf := camera.global_transform
	var target_pos := cam_xf.origin + cam_xf.basis.x * 0.3 - cam_xf.basis.y * 0.2 - cam_xf.basis.z * 0.5
	var target_basis := cam_xf.basis
	var t := clampf(follow_speed * 1.5 * get_physics_process_delta_time(), 0.0, 1.0)
	_lerp_toward_global(Transform3D(target_basis, target_pos), t)


func _follow_controller(delta: float):
	var target_xf := target_node.global_transform * grip_offset
	var t := clampf(follow_speed * delta, 0.0, 1.0)
	_lerp_toward_global(target_xf, t)


## Scale removed, so a scaled parent does not scale the gun.
func _lerp_toward_global(target_global: Transform3D, t: float):
	var parent_node := get_parent() as Node3D
	var parent_inv: Transform3D = parent_node.global_transform.affine_inverse()
	var local_target: Transform3D = parent_inv * target_global
	local_target = Transform3D(Basis(local_target.basis.get_rotation_quaternion()), local_target.origin)
	transform = transform.interpolate_with(local_target, t)


func _build_gun():
	gun_mesh = MeshInstance3D.new()
	gun_mesh.name = "GunMesh"

	var barrel := CylinderMesh.new()
	barrel.top_radius = 0.03
	barrel.bottom_radius = 0.05
	barrel.height = 0.7
	barrel.radial_segments = 8
	gun_mesh.mesh = barrel
	gun_mesh.rotation.x = deg_to_rad(90)
	gun_mesh.position = Vector3(0, 0, -0.2)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.22, 0.25)
	mat.metallic = 0.9
	mat.roughness = 0.15
	gun_mesh.material_override = mat
	add_child(gun_mesh)

	var grip := MeshInstance3D.new()
	grip.name = "Grip"
	var grip_mesh := BoxMesh.new()
	grip_mesh.size = Vector3(0.08, 0.15, 0.1)
	grip.mesh = grip_mesh
	grip.position = Vector3(0, -0.08, 0.05)
	var grip_mat := StandardMaterial3D.new()
	grip_mat.albedo_color = Color(0.15, 0.15, 0.17)
	grip_mat.metallic = 0.7
	grip_mat.roughness = 0.4
	grip.material_override = grip_mat
	add_child(grip)

	var scope := MeshInstance3D.new()
	scope.name = "Scope"
	var scope_mesh := BoxMesh.new()
	scope_mesh.size = Vector3(0.04, 0.03, 0.25)
	scope.mesh = scope_mesh
	scope.position = Vector3(0, 0.05, -0.15)
	scope.material_override = mat
	add_child(scope)


func _build_muzzle():
	muzzle_point = Node3D.new()
	muzzle_point.name = "MuzzlePoint"
	muzzle_point.position = Vector3(0, 0, -0.55)
	add_child(muzzle_point)

	muzzle_flash = OmniLight3D.new()
	muzzle_flash.name = "MuzzleFlash"
	muzzle_flash.light_color = bolt_color
	muzzle_flash.light_energy = 0.0
	muzzle_flash.omni_range = 2.0
	muzzle_flash.omni_attenuation = 2.0
	muzzle_flash.shadow_enabled = false
	muzzle_point.add_child(muzzle_flash)
