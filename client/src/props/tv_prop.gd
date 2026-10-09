extends Node3D

## TV: plays an Ogg Theora video while powered and a person is within active_distance.

@export var video_path := "res://assets/art/video/big_buck_bunny_trailer.ogv"
@export var screen_size := Vector2(14.0, 8.0)
@export var powered := true
@export var loop := true
@export var active_distance := 120.0
## VideoStreamPlayer audio is not positional; -80 mutes it.
@export var volume_db := -12.0
@export var build_frame := true

var _viewport: SubViewport = null
var _video: VideoStreamPlayer = null
var _screen: MeshInstance3D = null
var _mat_on: StandardMaterial3D = null
var _mat_off: StandardMaterial3D = null
var _nc = null
var _manager = null
var _poll := 0.0
var _active := false


func _ready():
	var stream = load(video_path)
	if stream == null:
		push_warning("[TV] Cannot load video: " + video_path)
	_build_video(stream)
	if build_frame:
		_build_frame()
	_build_screen()

	_nc = get_node_or_null("/root/NetworkController")
	var root := get_tree().current_scene
	if root:
		_manager = root.find_child("AmbientManager", true, false)
	_poll = randf_range(0.0, 0.5)


func _build_video(stream) -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(512, 288)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.disable_3d = true
	add_child(_viewport)

	_video = VideoStreamPlayer.new()
	if stream != null:
		_video.stream = stream
	_video.set_anchors_preset(Control.PRESET_FULL_RECT)
	if "expand" in _video:
		_video.expand = true
	_video.volume_db = volume_db
	_video.finished.connect(_on_finished)
	_viewport.add_child(_video)


func _build_frame() -> void:
	var frame := MeshInstance3D.new()
	var frame_mesh := BoxMesh.new()
	frame_mesh.size = Vector3(screen_size.x + 1.2, screen_size.y + 1.2, 0.8)
	frame.mesh = frame_mesh
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = Color(0.08, 0.08, 0.09)
	frame.material_override = frame_mat
	add_child(frame)


func _build_screen() -> void:
	_screen = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = screen_size
	_screen.mesh = quad
	_screen.position = Vector3(0, 0, 0.45)
	add_child(_screen)

	_mat_on = StandardMaterial3D.new()
	_mat_on.albedo_texture = _viewport.get_texture()
	_mat_on.emission_enabled = true
	_mat_on.emission_texture = _viewport.get_texture()
	_mat_on.emission_energy_multiplier = 1.2
	_mat_on.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_off = StandardMaterial3D.new()
	_mat_off.albedo_color = Color(0.03, 0.03, 0.04)
	_screen.material_override = _mat_off


func _on_finished():
	if loop and _active:
		_video.play()


func _nearest_person_dist() -> float:
	var best := INF
	if _manager != null:
		for p in _manager.people_positions_global():
			best = minf(best, global_position.distance_to(p))
	elif _nc and is_instance_valid(_nc.players.local_player):
		best = global_position.distance_to(_nc.players.local_player.global_position)
	return best


func _process(delta):
	_poll += delta
	if _poll < 0.5:
		return
	_poll = 0.0
	var want := powered
	if want:
		want = _nearest_person_dist() <= active_distance * global_basis.get_scale().x
	if want == _active:
		return
	_active = want
	if want:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_video.play()
		_video.paused = false
		_screen.material_override = _mat_on
	else:
		_video.paused = true
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_screen.material_override = _mat_off
