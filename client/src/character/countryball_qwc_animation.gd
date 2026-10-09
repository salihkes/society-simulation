extends CountryballAnimation
class_name CountryballQWCAnimation

## Face driver for the QWC countryball, whose model has one mesh per expression.

const FACE_MESHES := {
	"neutral": "Eyes",
	"happy": "happy",
	"sad": "Sad",
	"serious": "Serious",
	"angry": "angry",
	"afraid": "Afraid",
	"scarystare": "ScaryStare",
	"shocked": "Shocked",
}
const BLINK_MESH := "Blink"

var _faces := {}  # emotion -> MeshInstance3D
var _blink_face: MeshInstance3D


## owned = false because the meshes belong to the instanced model scene.
func _load_emotion_materials():
	if base_mesh == null:
		base_mesh = character_model.find_child("Base", true, false)

	for emotion in FACE_MESHES:
		var mesh = character_model.find_child(FACE_MESHES[emotion], true, false)
		if mesh is MeshInstance3D:
			_faces[emotion] = mesh

	_blink_face = character_model.find_child(BLINK_MESH, true, false)
	if _blink_face and not _blink_face is MeshInstance3D:
		_blink_face = null

	if _faces.is_empty():
		push_warning("QWC countryball: no face meshes found under " + str(character_model))
	else:
		_show_face(current_emotion)


## False if the model has no mesh for `emotion`.
func set_emotion(emotion: String) -> bool:
	var emotion_lower = emotion.to_lower()
	if not _faces.has(emotion_lower):
		return false

	current_emotion = emotion_lower
	if not is_blinking:
		_show_face(current_emotion)
	print("QWC countryball emotion set to: ", current_emotion)
	return true


func get_available_emotions() -> Array:
	return _faces.keys()


func _show_face(emotion: String) -> void:
	for face in _faces:
		_faces[face].visible = (face == emotion)
	if _blink_face:
		_blink_face.visible = false


func _update_blink(delta: float) -> void:
	if _faces.is_empty() or not _blink_face:
		return

	if is_blinking:
		blink_timer += delta
		if blink_timer >= blink_duration:
			is_blinking = false
			blink_timer = 0.0
			_show_face(current_emotion)
			next_blink_time = randf_range(2.0, 6.0)
		return

	next_blink_time -= delta
	if next_blink_time <= 0:
		is_blinking = true
		blink_timer = 0.0
		for face in _faces:
			_faces[face].visible = false
		_blink_face.visible = true
