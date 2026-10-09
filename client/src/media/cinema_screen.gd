extends MeshInstance3D
## Mesh showing a CinemaStream channel (JPEG frames, WAV over WebSocket), for clients without a video decoder.

## Left empty, CinemaStream derives the URL from the world server.
@export var websocket_url: String = ""

@export var volume_db := 0.0
@export var max_distance := 30.0
@export var attenuation_model := 0   # ATTENUATION_INVERSE_DISTANCE
@export var unit_size := 10.0

var stream: CinemaStream


func _ready() -> void:
	_prepare_material()
	stream = CinemaStream.new()
	stream.volume_db = volume_db
	stream.max_distance = max_distance
	stream.attenuation_model = attenuation_model
	stream.unit_size = unit_size
	add_child(stream)
	stream.resized.connect(_on_resized)
	stream.open(websocket_url)


func _prepare_material() -> void:
	var mat := get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		set_surface_override_material(0, mat)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission_energy_multiplier = 1.5


func _on_resized(w: int, h: int) -> void:
	var mat := get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_texture = stream.texture
	mat.emission_texture = stream.texture
	print("CinemaScreen: %dx%d from %s" % [w, h, stream.stream_url])


func set_audio_properties(new_volume_db: float, new_max_distance: float,
		new_attenuation_model: int) -> void:
	volume_db = new_volume_db
	max_distance = new_max_distance
	attenuation_model = new_attenuation_model
	if stream != null and stream.audio_player != null:
		stream.audio_player.volume_db = volume_db
		stream.audio_player.max_distance = max_distance
		stream.audio_player.attenuation_model = attenuation_model
