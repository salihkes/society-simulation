extends Node3D
class_name Lightsaber
## A lightsaber: follows a VR controller, freezes on a clash, floats without one.

@export var blade_length := 5.0
@export var blade_radius := 0.035
@export var hilt_length := 1.0
@export var hilt_top_radius := 0.1
@export var hilt_bottom_radius := 0.08
@export var blade_color := Color(0.3, 0.6, 1.0)
@export var follow_speed := 18.0
@export var collision_pushback_speed := 10.0
@export var debounce_time := 0.15

## Tilts the blade (local +Y) 45 degrees toward the controller's pointing direction.
@export var grip_offset := Transform3D(
	Basis(Vector3(1, 0, 0), deg_to_rad(-45)),
	Vector3(0, 0, 0)
)

var target_node: Node3D = null
var _colliding_blades: Array[Area3D] = []
var _debounce_timer := 0.0
var _collision_active := false
var _idle_time := 0.0

var _is_frozen := false
var _frozen_transform := Transform3D()
## Mean position of the clashing blades at freeze time.
var _collision_center := Vector3.ZERO
## Our distance from _collision_center at freeze time.
var _frozen_dist := 0.0
var _unfreeze_grace := 0.0

## World units further from the clash than at freeze time needed to unfreeze.
@export var unfreeze_pull_threshold := 0.05
@export var unfreeze_grace_duration := 0.18

var _snd_hum: AudioStream = BlasterBolt.optional_audio("res://assets/art/sound/Energy_sword_idle_hu_#2-1775686964024.wav")
var _snd_swing_fast: AudioStream = BlasterBolt.optional_audio("res://assets/art/sound/Energy_sword_fast_sw_#4-1775687009795.wav")
var _snd_swing_slow: AudioStream = BlasterBolt.optional_audio("res://assets/art/sound/Energy_sword_slow_sw_#1-1775687037463.wav")
var _snd_clash: AudioStream = BlasterBolt.optional_audio("res://assets/art/sound/Two_energy_swords_cl_#2-1775687062014.wav")
var _snd_ignite: AudioStream = BlasterBolt.optional_audio("res://assets/art/sound/Energy_sword_activat_#1-1775687098167.wav")
var _snd_deactivate: AudioStream = BlasterBolt.optional_audio("res://assets/art/sound/Energy_sword_deactiv_#3-1775687118421.wav")
var _snd_deflect: AudioStream = BlasterBolt.optional_audio(BlasterBolt.DEFLECT_SOUND)

var blade_area: Area3D
var blade_mesh: MeshInstance3D
var hilt_mesh: MeshInstance3D
var blade_light: OmniLight3D
var clash_particles: GPUParticles3D

var _hum_player: AudioStreamPlayer3D
var _sfx_player: AudioStreamPlayer3D
var _swing_player: AudioStreamPlayer3D

var _prev_global_pos := Vector3.ZERO
var _swing_velocity := 0.0
var _swing_cooldown := 0.0
@export var swing_slow_threshold := 2.0
@export var swing_fast_threshold := 6.0


func _ready():
	_build_hilt()
	_build_blade()
	_build_collision()
	_build_light()
	_build_clash_particles()
	_build_audio()
	_prev_global_pos = global_position


## Scale removed, so the scaled workspace parent does not scale the saber.
func _set_global_xf(global_xf: Transform3D):
	var parent_node := get_parent() as Node3D
	var parent_inv: Transform3D = parent_node.global_transform.affine_inverse()
	var local_xf: Transform3D = parent_inv * global_xf
	transform = Transform3D(Basis(local_xf.basis.get_rotation_quaternion()), local_xf.origin)

func _lerp_toward_global(target_global: Transform3D, t: float):
	var parent_node := get_parent() as Node3D
	var parent_inv: Transform3D = parent_node.global_transform.affine_inverse()
	var local_target: Transform3D = parent_inv * target_global
	local_target = Transform3D(Basis(local_target.basis.get_rotation_quaternion()), local_target.origin)
	transform = transform.interpolate_with(local_target, t)


func _physics_process(delta: float):
	_debounce_timer = maxf(0.0, _debounce_timer - delta)
	_unfreeze_grace = maxf(0.0, _unfreeze_grace - delta)
	_swing_cooldown = maxf(0.0, _swing_cooldown - delta)

	_colliding_blades = _colliding_blades.filter(func(b): return is_instance_valid(b))
	_collision_active = _colliding_blades.size() > 0

	if _is_frozen and not _collision_active and _unfreeze_grace > 0.0:
		_is_frozen = false

	if target_node and is_instance_valid(target_node):
		_follow_target(delta)
		_update_swing_sound(delta)
	else:
		_float_idle(delta)


func _follow_target(delta: float):
	var target_xf := target_node.global_transform * grip_offset
	var t := clampf(follow_speed * delta, 0.0, 1.0)

	if _unfreeze_grace > 0.0 and not _is_frozen:
		_lerp_toward_global(target_xf, t)
		return

	if _is_frozen:
		_hold_frozen(target_xf)
		return

	if _collision_active:
		_freeze_at_collision()
		return

	_lerp_toward_global(target_xf, t)


## Unfreeze only when pulled back on the saber's own side, so it cannot pass through.
func _hold_frozen(target_xf: Transform3D):
	_set_global_xf(_frozen_transform)

	var target_dist := target_xf.origin.distance_to(_collision_center)
	var frozen_side := (_frozen_transform.origin - _collision_center).normalized()
	var target_side := (target_xf.origin - _collision_center).normalized()
	var same_side := frozen_side.dot(target_side) > 0.0

	if not _collision_active:
		_is_frozen = false
		_unfreeze_grace = unfreeze_grace_duration
	elif same_side and target_dist > _frozen_dist + unfreeze_pull_threshold:
		_is_frozen = false
		_unfreeze_grace = unfreeze_grace_duration


func _freeze_at_collision():
	_is_frozen = true
	_frozen_transform = global_transform

	_collision_center = Vector3.ZERO
	for blade in _colliding_blades:
		_collision_center += blade.global_position
	_collision_center /= float(_colliding_blades.size())
	_frozen_dist = global_position.distance_to(_collision_center)

	var away := (global_position - _collision_center).normalized()
	_frozen_transform.origin += away * blade_radius * 4.0
	_set_global_xf(_frozen_transform)


func _update_swing_sound(delta: float):
	var current_pos := global_position
	_swing_velocity = current_pos.distance_to(_prev_global_pos) / maxf(delta, 0.001)
	_prev_global_pos = current_pos

	if _swing_cooldown > 0.0 or _is_frozen:
		return

	if _swing_velocity > swing_fast_threshold:
		_play_sfx(_swing_player, _snd_swing_fast)
		_swing_cooldown = 0.3
	elif _swing_velocity > swing_slow_threshold:
		_play_sfx(_swing_player, _snd_swing_slow)
		_swing_cooldown = 0.4


func _float_idle(delta: float):
	_idle_time += delta
	position.y += sin(_idle_time * 1.5) * 0.002
	rotate_y(delta * 0.3)


func _on_blade_area_entered(other_area: Area3D):
	if other_area == blade_area:
		return

	if other_area.is_in_group("blaster_bolt"):
		if clash_particles:
			clash_particles.global_position = other_area.global_position
			clash_particles.emitting = true
		_play_sfx(_sfx_player, _snd_deflect)
		return

	if not other_area.is_in_group("lightsaber_blade"):
		return
	if not _colliding_blades.has(other_area):
		_colliding_blades.append(other_area)
	if _debounce_timer <= 0.0:
		_debounce_timer = debounce_time
		_on_clash(other_area)


func _on_blade_area_exited(other_area: Area3D):
	_colliding_blades.erase(other_area)


func _on_clash(other_area: Area3D):
	if clash_particles:
		var midpoint := (blade_area.global_position + other_area.global_position) * 0.5
		clash_particles.global_position = midpoint
		clash_particles.emitting = true
	_play_sfx(_sfx_player, _snd_clash)


func _build_hilt():
	hilt_mesh = MeshInstance3D.new()
	hilt_mesh.name = "HiltMesh"
	var mesh := CylinderMesh.new()
	mesh.top_radius = hilt_top_radius
	mesh.bottom_radius = hilt_bottom_radius
	mesh.height = hilt_length
	mesh.radial_segments = 12
	hilt_mesh.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.25, 0.28)
	mat.metallic = 0.85
	mat.roughness = 0.3
	hilt_mesh.material_override = mat
	add_child(hilt_mesh)


func _build_blade():
	blade_mesh = MeshInstance3D.new()
	blade_mesh.name = "BladeMesh"
	var mesh := CylinderMesh.new()
	mesh.top_radius = blade_radius * 0.6
	mesh.bottom_radius = blade_radius
	mesh.height = blade_length
	mesh.radial_segments = 8
	blade_mesh.mesh = mesh

	blade_mesh.position = Vector3(0, (hilt_length + blade_length) * 0.5, 0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = blade_color
	mat.emission_enabled = true
	mat.emission = blade_color
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.92
	blade_mesh.material_override = mat
	blade_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var core_mesh := MeshInstance3D.new()
	core_mesh.name = "BladeCore"
	var core := CylinderMesh.new()
	core.top_radius = blade_radius * 0.25
	core.bottom_radius = blade_radius * 0.5
	core.height = blade_length * 0.98
	core.radial_segments = 6
	core_mesh.mesh = core
	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = Color(1, 1, 1, 0.85)
	core_mat.emission_enabled = true
	core_mat.emission = Color.WHITE
	core_mat.emission_energy_multiplier = 6.0
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mesh.material_override = core_mat
	core_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	blade_mesh.add_child(core_mesh)

	add_child(blade_mesh)


func _build_collision():
	blade_area = Area3D.new()
	blade_area.name = "BladeArea"
	blade_area.add_to_group("lightsaber_blade")

	# Blades on layer 6, detecting blades (6) and bolts (7).
	blade_area.collision_layer = 1 << 5
	blade_area.collision_mask = (1 << 5) | (1 << 6)

	var col_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	# Wider than the visual blade so a clash freezes before blades overlap.
	capsule.radius = blade_radius * 5.0
	capsule.height = blade_length
	col_shape.shape = capsule
	col_shape.position = Vector3(0, (hilt_length + blade_length) * 0.5, 0)
	blade_area.add_child(col_shape)

	blade_area.area_entered.connect(_on_blade_area_entered)
	blade_area.area_exited.connect(_on_blade_area_exited)

	add_child(blade_area)


func _build_light():
	blade_light = OmniLight3D.new()
	blade_light.name = "BladeLight"
	blade_light.light_color = blade_color
	blade_light.light_energy = 2.0
	blade_light.omni_range = 4.0
	blade_light.omni_attenuation = 1.5
	blade_light.shadow_enabled = false
	blade_light.position = Vector3(0, hilt_length + blade_length * 0.5, 0)
	add_child(blade_light)


func _build_clash_particles():
	clash_particles = GPUParticles3D.new()
	clash_particles.name = "ClashParticles"
	clash_particles.emitting = false
	clash_particles.one_shot = true
	clash_particles.amount = 20
	clash_particles.lifetime = 0.3
	clash_particles.explosiveness = 1.0

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 180.0
	mat.initial_velocity_min = 3.0
	mat.initial_velocity_max = 8.0
	mat.gravity = Vector3(0, -5, 0)
	mat.scale_min = 0.02
	mat.scale_max = 0.06
	mat.color = blade_color.lightened(0.5)
	clash_particles.process_material = mat

	var spark_mesh := QuadMesh.new()
	spark_mesh.size = Vector2(0.05, 0.05)
	var spark_mat := StandardMaterial3D.new()
	spark_mat.albedo_color = blade_color.lightened(0.6)
	spark_mat.emission_enabled = true
	spark_mat.emission = blade_color.lightened(0.4)
	spark_mat.emission_energy_multiplier = 5.0
	spark_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	spark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spark_mesh.material = spark_mat
	clash_particles.draw_pass_1 = spark_mesh

	add_child(clash_particles)


## Swings have their own player so they do not cut off clashes.
func _build_audio():
	_hum_player = AudioStreamPlayer3D.new()
	_hum_player.name = "HumPlayer"
	_hum_player.stream = _snd_hum
	_hum_player.autoplay = _snd_hum != null
	_hum_player.max_distance = 20.0
	_hum_player.volume_db = -6.0
	add_child(_hum_player)
	if _snd_hum:
		_hum_player.finished.connect(func(): _hum_player.play())

	_sfx_player = AudioStreamPlayer3D.new()
	_sfx_player.name = "SFXPlayer"
	_sfx_player.max_distance = 30.0
	add_child(_sfx_player)

	_swing_player = AudioStreamPlayer3D.new()
	_swing_player.name = "SwingPlayer"
	_swing_player.max_distance = 20.0
	_swing_player.volume_db = -3.0
	add_child(_swing_player)


func _play_sfx(player: AudioStreamPlayer3D, stream: AudioStream):
	if player and stream:
		player.stream = stream
		player.play()


func play_ignite():
	_play_sfx(_sfx_player, _snd_ignite)
	if _hum_player and _snd_hum:
		_hum_player.play()


func play_deactivate():
	_play_sfx(_sfx_player, _snd_deactivate)
	if _hum_player:
		_hum_player.stop()
