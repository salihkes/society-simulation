extends MeshInstance3D
## Looping video on a quad via a SubViewport; its sound plays on an AudioStreamPlayer3D so it is positional.

@export var video_stream: VideoStream
## Leave empty for a silent billboard.
@export var audio_stream: AudioStream
## Audio falloff distance; larger is audible farther away.
@export var unit_size: float = 20.0

@onready var _sub: SubViewport = $SubViewport
@onready var _video: VideoStreamPlayer = $SubViewport/VideoStreamPlayer
@onready var _audio: AudioStreamPlayer3D = $AudioStreamPlayer3D


func _ready() -> void:
	_video.stream = video_stream
	_audio.stream = audio_stream
	_audio.unit_size = unit_size

	# Non-uniform quad scale would distort the audio's distance attenuation.
	_audio.top_level = true
	_audio.global_transform = Transform3D(Basis(), global_transform.origin)

	# A saved ViewportTexture does not resolve reliably in instanced scenes.
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var mat: StandardMaterial3D = get_surface_override_material(0)
	if mat:
		mat.albedo_texture = _sub.get_texture()

	if video_stream == null:
		return

	# Mute the video's own, non-positional audio.
	_video.volume_db = -80.0
	_video.finished.connect(_restart)
	_restart()
	_fit_viewport_to_video()


func _restart() -> void:
	_video.stop()
	_video.play()
	if _audio.stream != null:
		_audio.stop()
		_audio.play()


## Polls up to 30 frames for the video size; the quad's scale sets the aspect.
func _fit_viewport_to_video() -> void:
	for _i in 30:
		await get_tree().process_frame
		var tex: Texture2D = _video.get_video_texture()
		if tex != null and tex.get_width() > 0:
			_sub.size = tex.get_size()
			return
