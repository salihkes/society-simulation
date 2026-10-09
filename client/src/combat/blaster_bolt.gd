extends Node3D
class_name BlasterBolt
## A glowing blaster bolt that lightsaber blades bounce back.

const FIRE_SOUND := "res://assets/art/sound/Sci-fi_laser_blaster_#2-1775687143997.wav"
const DEFLECT_SOUND := "res://assets/art/sound/Laser_bolt_deflectin_#3-1775687165063.wav"

@export var speed := 12.0
@export var lifetime := 6.0
@export var bolt_color := Color(1.0, 0.15, 0.1)
@export var bolt_length := 2.5
@export var bolt_radius := 0.12

## A blade within this distance blocks the bolt, even without a direct hit.
@export var proximity_deflect_radius := 1.2

var velocity := Vector3.ZERO
var _age := 0.0
var _deflected := false

var _snd_fire: AudioStream = optional_audio(FIRE_SOUND)
var _snd_deflect: AudioStream = optional_audio(DEFLECT_SOUND)


static func optional_audio(path: String) -> AudioStream:
	return load(path) if ResourceLoader.exists(path) else null

var bolt_area: Area3D
var bolt_mesh: MeshInstance3D
var bolt_light: OmniLight3D
var _sfx_player: AudioStreamPlayer3D


func _ready():
	_build_visual()
	_build_collision()
	_build_light()
	_build_audio()


func _physics_process(delta: float):
	_age += delta
	if _age > lifetime:
		queue_free()
		return

	var old_pos = global_position
	global_position += velocity * delta

	# Ship bolts (speed >= 30) skip their first 0.1 s to clear the firing hull.
	if speed >= 30.0 and _age > 0.1:
		_check_ship_hit(old_pos)


func _check_ship_hit(old_pos: Vector3):
	var source = get_meta("source_ship") if has_meta("source_ship") else null
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(old_pos, global_position)
	if source and is_instance_valid(source):
		query.exclude = [source]
	var result = space_state.intersect_ray(query)
	if result.is_empty():
		return
	var hit_body = result.collider
	if hit_body and hit_body.has_method("take_ship_damage"):
		hit_body.take_ship_damage(get_meta("bolt_damage") if has_meta("bolt_damage") else 15.0)
	_spawn_impact(result.position)
	queue_free()


func fire(from: Vector3, direction: Vector3):
	global_position = from
	velocity = direction.normalized() * speed
	if direction.length() > 0.001:
		look_at(from + direction, Vector3.UP)
	if _sfx_player and _snd_fire:
		_sfx_player.stream = _snd_fire
		_sfx_player.play()


## Bounce off a blade once, at 80% speed, with 40% of its lifetime left.
func deflect(blade_normal: Vector3):
	if _deflected:
		return
	_deflected = true

	velocity = velocity.bounce(blade_normal) * 0.8
	if velocity.length() > 0.001:
		look_at(global_position + velocity, Vector3.UP)

	_age = lifetime * 0.6


func _on_bolt_hit_blade(area: Area3D):
	if _deflected:
		return
	if not area.is_in_group("lightsaber_blade"):
		return

	var blade_owner := area.get_parent() as Node3D
	var blade_up := blade_owner.global_transform.basis.y.normalized()
	deflect(blade_up)
	if _sfx_player and _snd_deflect:
		_sfx_player.stream = _snd_deflect
		_sfx_player.play()


func _build_visual():
	bolt_mesh = MeshInstance3D.new()
	bolt_mesh.name = "BoltMesh"

	var mesh := CylinderMesh.new()
	mesh.top_radius = bolt_radius * 0.5
	mesh.bottom_radius = bolt_radius
	mesh.height = bolt_length
	mesh.radial_segments = 6
	bolt_mesh.mesh = mesh
	bolt_mesh.rotation.x = deg_to_rad(90)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = bolt_color
	mat.emission_enabled = true
	mat.emission = bolt_color
	mat.emission_energy_multiplier = 5.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.95
	bolt_mesh.material_override = mat
	bolt_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	add_child(bolt_mesh)


func _build_collision():
	bolt_area = Area3D.new()
	bolt_area.name = "BoltArea"
	bolt_area.add_to_group("blaster_bolt")

	# Bolts on layer 7, detecting blades on layer 6.
	bolt_area.collision_layer = 1 << 6
	bolt_area.collision_mask = 1 << 5

	var col_shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	# Much larger than the visible bolt so blocking is forgiving.
	sphere.radius = proximity_deflect_radius
	col_shape.shape = sphere
	bolt_area.add_child(col_shape)

	bolt_area.area_entered.connect(_on_bolt_hit_blade)

	add_child(bolt_area)


func _build_light():
	bolt_light = OmniLight3D.new()
	bolt_light.name = "BoltLight"
	bolt_light.light_color = bolt_color
	bolt_light.light_energy = 1.5
	bolt_light.omni_range = 2.0
	bolt_light.omni_attenuation = 2.0
	bolt_light.shadow_enabled = false
	add_child(bolt_light)


func _spawn_impact(pos: Vector3):
	var particles = GPUParticles3D.new()
	particles.emitting = true
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.amount = 12
	particles.lifetime = 0.4
	var mat = ParticleProcessMaterial.new()
	mat.direction = Vector3.ZERO
	mat.spread = 180.0
	mat.initial_velocity_min = 1.0
	mat.initial_velocity_max = 5.0
	mat.gravity = Vector3.ZERO
	mat.scale_min = 0.3
	mat.scale_max = 1.0
	mat.color = bolt_color
	particles.process_material = mat
	var mesh = SphereMesh.new()
	mesh.radius = 0.2
	mesh.height = 0.4
	particles.draw_pass_1 = mesh
	get_tree().current_scene.add_child(particles)
	particles.global_position = pos
	get_tree().create_timer(1.0).timeout.connect(func():
		if is_instance_valid(particles):
			particles.queue_free()
	)


func _build_audio():
	_sfx_player = AudioStreamPlayer3D.new()
	_sfx_player.name = "BoltSFX"
	_sfx_player.max_distance = 30.0
	add_child(_sfx_player)
