class_name AnimeFaceController
extends Node
## Drives the blend shapes of a skinned anime face: emotions, blinking and a talking mouth.

const MOUTH := ["mouthClosedSmile", "mouthOpenSmile", "mouthWideOpen", "mouthRound",
	"mouthSmallRound", "mouthGrin"]

## Emotion name -> blend shape weights.
const EMOTIONS := {
	"neutral": {},
	"happy": {"mouthClosedSmile": 0.75, "eyeSquintLeft": 0.2, "eyeSquintRight": 0.2},
	"sad": {"browInnerUp": 0.7, "eyeSquintLeft": 0.25, "eyeSquintRight": 0.25},
	"serious": {"browDownLeft": 0.35, "browDownRight": 0.35},
	"angry": {"browDownLeft": 0.9, "browDownRight": 0.9, "eyeSquintLeft": 0.3,
		"eyeSquintRight": 0.3},
	"afraid": {"browInnerUp": 0.8, "mouthSmallRound": 0.75},
	"scarystare": {"browDownLeft": 0.25, "browDownRight": 0.25},
	"shocked": {"browInnerUp": 1.0, "mouthRound": 0.9},
}

var skeleton: Skeleton3D
var targets: Dictionary = {}    # blend shape name -> [[MeshInstance3D, index], ...]
var values: Dictionary = {}
var dimple_strength := {"Left": 0.6, "Right": 0.6}
var auto_blink := true

var _emotion := "neutral"
var _age := 0.0
var _blink_at := 3.0
var _speech_left := 0.0


## Resets every blend shape to zero.
func attach(model: Node) -> void:
	targets.clear()
	values.clear()
	var skeletons := model.find_children("*", "Skeleton3D", true, false)
	assert(skeletons.size() == 1, "Expected one facial skeleton")
	skeleton = skeletons[0] as Skeleton3D
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		for i in mesh_instance.get_blend_shape_count():
			var control := String(mesh_instance.mesh.get_blend_shape_name(i))
			if not targets.has(control):
				targets[control] = []
			targets[control].append([mesh_instance, i])
	reset()


## `value` 0..1; keeps the eyelid and mouth groups consistent.
func set_expression(control: String, value: float) -> void:
	if not targets.has(control):
		push_warning("Unknown facial control: " + control)
		return
	values[control] = clampf(value, 0.0, 1.0)
	if (control.begins_with("eyeBlink") or control.begins_with("eyeSquint")
			or control.begins_with("eyeSmile")):
		_apply_eyelids("Left" if control.ends_with("Left") else "Right")
	else:
		_apply(control, values[control])
	if control in MOUTH:
		_apply_mouth()


## Blink, squint and smile share eyelid geometry, so they are composited.
func _apply_eyelids(side: String) -> void:
	var blink := float(values.get("eyeBlink" + side, 0.0))
	var squint := float(values.get("eyeSquint" + side, 0.0))
	var happy := float(values.get("eyeSmile" + side, 0.0))
	_apply("eyeBlink" + side, blink * (1.0 - happy))
	_apply("eyeSquint" + side, squint * (1.0 - blink) * (1.0 - happy))
	_apply("eyeSmile" + side, happy)


## The mouth shapes never sum past 1; the cheeks dimple with the smile.
func _apply_mouth() -> void:
	var total := 0.0
	for key in MOUTH:
		total += float(values.get(key, 0.0))
	for key in MOUTH:
		_apply(key, float(values.get(key, 0.0)) / maxf(1.0, total))
	var smile := minf(1.0, float(values.get("mouthClosedSmile", 0.0))
		+ float(values.get("mouthOpenSmile", 0.0)) + float(values.get("mouthGrin", 0.0)))
	for side in ["Left", "Right"]:
		var key: String = "cheekDimple" + side
		values[key] = smile * dimple_strength[side]
		_apply(key, values[key])


func _apply(control: String, value: float) -> void:
	for target in targets.get(control, []):
		(target[0] as MeshInstance3D).set_blend_shape_value(target[1], value)


func reset() -> void:
	for key in targets:
		values[key] = 0.0
		_apply(key, 0.0)


## False if the name is unknown.
func set_emotion(emotion: String) -> bool:
	var key := emotion.to_lower().strip_edges()
	if not EMOTIONS.has(key):
		return false
	_emotion = key
	reset()
	for control in EMOTIONS[key]:
		set_expression(control, EMOTIONS[key][control])
	return true


func get_emotion() -> String:
	return _emotion


func get_available_emotions() -> Array:
	return EMOTIONS.keys()


## For about as long as `text` takes to say.
func say(text: String) -> void:
	_speech_left = clampf(0.4 + 0.045 * text.length(), 0.6, 4.0)


func _process(delta: float) -> void:
	if targets.is_empty():
		return
	_age += delta
	if auto_blink:
		var blink := maxf(0.0, 1.0 - absf(_age - _blink_at) / 0.10)
		set_expression("eyeBlinkLeft", blink)
		set_expression("eyeBlinkRight", blink)
		if _age > _blink_at + 0.12:
			_blink_at = _age + randf_range(2.5, 5.5)
	if _speech_left > 0.0:
		_speech_left = maxf(0.0, _speech_left - delta)
		var mouth := maxf(0.0, sin(_age * 40.0)) * 0.45 if _speech_left > 0.0 else 0.0
		set_expression("mouthWideOpen", mouth)
