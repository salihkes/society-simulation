extends Node3D
## 16mm projector whose picture is a SpotLight3D projector texture, so people in the cone shadow it. Point -Z at the wall.

@export var reel: VideoStream
@export var still: Texture2D            ## used when no reel is assigned
@export var autoplay := true
@export var loop := true
@export var interactive := false       ## nearby local player can toggle with E
@export var use_distance := 2.6         ## world metres, like the computer
@export var picture_aspect := 4.0 / 3.0
@export var screen: MeshInstance3D      ## optional: white quad receiving the picture
@export_range(0.0, 200.0) var beam_energy := 60.0
@export_range(0.0, 1.0) var flicker_amount := 0.12
@export_range(0.0, 16.0) var fog_energy := 6.0
@export var rattle: AudioStream         ## projector mechanism loop
@export_range(-40.0, 6.0) var rattle_db := -14.0

@onready var _lens: SpotLight3D = $Lens
@onready var _hotspot: OmniLight3D = $Lens/Hotspot
@onready var _film: SubViewport = $Film
@onready var _player: VideoStreamPlayer = $Film/Reel
@onready var _still_rect: TextureRect = $Film/Still
@onready var _process_rect: ColorRect = $Film/Process
@onready var _shafts: MeshInstance3D = $Lens/Shafts
@onready var _dust: GPUParticles3D = $Lens/Dust
@onready var _audio: AudioStreamPlayer3D = $Rattle

var _compat := false
var _t := 0.0
var _proj_tex: ImageTexture      # CPU copy of the reel; Light3D refuses ViewportTexture
var _frame_acc := 0.0
const PROJECT_FPS := 24.0
var _flicker := 1.0
var _screen_mat: StandardMaterial3D
var _running := false
var _prompt: Label3D
var _nc: Node


func _ready() -> void:
	_compat = RenderingServer.get_current_rendering_method() == "gl_compatibility"
	_film.size = Vector2i(1024, 1024)
	_fit_picture_rect()
	_nc = get_node_or_null("/root/NetworkController")
	if interactive:
		_make_prompt()
	_player.visible = reel != null
	_still_rect.visible = reel == null
	if reel != null:
		_player.stream = reel
		_player.loop = loop
		_player.finished.connect(stop)
	elif still != null:
		_still_rect.texture = still
	_setup_lens(_film.get_texture())
	_fit_to_screen()
	if rattle != null:
		_setup_rattle()
	if autoplay:
		play()
	else:
		_set_running(false)


func _fit_picture_rect() -> void:
	var picture_size := Vector2(maxf(picture_aspect, 0.1), 1.0).normalized()
	var picture_min := (Vector2.ONE - picture_size) * 0.5
	var picture_max := Vector2.ONE - picture_min
	_process_rect.material = _process_rect.material.duplicate()
	_process_rect.material.set_shader_parameter("pic_min", picture_min)
	_process_rect.material.set_shader_parameter("pic_max", picture_max)
	for rect in [_player, _still_rect]:
		rect.anchor_left = picture_min.x
		rect.anchor_top = picture_min.y
		rect.anchor_right = picture_max.x
		rect.anchor_bottom = picture_max.y


func _make_prompt() -> void:
	_prompt = Label3D.new()
	_prompt.name = "Prompt"
	_prompt.text = "E"
	_prompt.font_size = 48
	_prompt.outline_size = 12
	_prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_prompt.no_depth_test = true
	_prompt.position = Vector3(0, 1.2, 0)
	_prompt.scale = Vector3.ONE / maxf(global_basis.get_scale().abs().x, 0.0001)
	_prompt.visible = false
	add_child(_prompt)


## Compatibility has no projector textures, so there the picture goes on `screen`.
func _setup_lens(tex: Texture2D) -> void:
	_lens.light_energy = beam_energy
	_lens.light_volumetric_fog_energy = fog_energy
	_lens.shadow_enabled = true
	if not _compat:
		return
	_lens.light_projector = null
	if screen != null:
		_screen_mat = StandardMaterial3D.new()
		_screen_mat.albedo_texture = tex
		_screen_mat.roughness = 1.0
		screen.set_surface_override_material(0, _screen_mat)


func _setup_rattle() -> void:
	var s := rattle.duplicate()
	if s is AudioStreamWAV:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	elif "loop" in s:
		s.loop = true
	_audio.stream = s
	_audio.volume_db = rattle_db


func _fit_to_screen() -> void:
	var dist := 8.0
	if screen != null and screen.mesh is QuadMesh:
		var size: Vector2 = (screen.mesh as QuadMesh).size
		dist = maxf(0.5, _lens.global_position.distance_to(screen.global_position))
		# Projector texture is square, so the picture's aspect comes from the SubViewport.
		var half := size.length() * 0.5
		_lens.spot_angle = rad_to_deg(atan(half / dist)) * 1.02
		_lens.spot_range = dist * 1.6
	var cone: CylinderMesh = _shafts.mesh
	var r := tan(deg_to_rad(_lens.spot_angle)) * dist
	cone.height = dist
	cone.bottom_radius = r
	# Shafts is rotated so its Y runs down -Z, and its origin is its centre.
	_shafts.position = Vector3(0, 0, -dist * 0.5)
	var box: ParticleProcessMaterial = _dust.process_material
	box.emission_box_extents = Vector3(r * 0.5, r * 0.5, dist * 0.5)
	_dust.position = Vector3(0, 0, -dist * 0.5)
	_dust.visibility_aabb = AABB(Vector3(-r, -r, -dist), Vector3(r * 2.0, r * 2.0, dist * 2.0))


func _process(delta: float) -> void:
	_update_interaction()
	if not _running:
		return
	_t += delta
	if not _compat and DisplayServer.get_name() != "headless":
		_frame_acc += delta
		if _frame_acc >= 1.0 / PROJECT_FPS:
			_frame_acc = fmod(_frame_acc, 1.0 / PROJECT_FPS)
			_copy_frame_to_lens()
	_apply_flicker()


## The projector atlas ignores in-place updates, so this must be a fresh texture.
func _copy_frame_to_lens() -> void:
	var frame := _film.get_texture().get_image()
	if frame != null and not frame.is_empty():
		_proj_tex = ImageTexture.create_from_image(frame)
		_lens.light_projector = _proj_tex


func _apply_flicker() -> void:
	var slow := sin(_t * 9.7) * 0.5 + sin(_t * 23.0) * 0.3 + sin(_t * 61.0) * 0.2
	var twitch := (randf() - 0.5) * 0.6
	_flicker = 1.0 + (slow * 0.6 + twitch) * flicker_amount
	_lens.light_energy = beam_energy * _flicker
	_hotspot.light_energy = 1.5 * _flicker
	var pm: ShaderMaterial = _process_rect.material
	pm.set_shader_parameter("flicker", _flicker)
	var sm: ShaderMaterial = _shafts.material_override
	sm.set_shader_parameter("flicker", _flicker)


func play() -> void:
	if reel != null:
		_player.play()
	_set_running(reel != null or still != null)


func stop() -> void:
	_player.stop()
	_set_running(false)


func _set_running(on: bool) -> void:
	_running = on
	_lens.visible = on
	_dust.emitting = on
	_film.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if _screen_mat != null:
		_screen_mat.albedo_texture = _film.get_texture() if on else null
	if on and _audio.stream != null:
		_audio.play()
	else:
		_audio.stop()


func _update_interaction() -> void:
	if not interactive:
		return
	var me: Node3D = _nc.get_indexed("players:local_player") as Node3D if is_instance_valid(_nc) else null
	var near := is_instance_valid(me) and me.global_position.distance_to(global_position) <= use_distance
	var typing: bool = is_instance_valid(me) and me.has_method("_typing") and me._typing()
	_prompt.visible = near and not typing
	if near and not typing and Input.is_action_just_pressed("interact"):
		if _running:
			stop()
		else:
			play()
