extends Node
class_name HumanoidFace
## The box humanoid's drawn face: expression tweens, blinks and a talking mouth.

const SHADER := preload("res://src/character/face/classic_face.gdshader")
const NODE_NAME := "HumanoidFace"
const HEAD_MESH_NAME := "humanoid_head"   # only the robloxian box head carries this face
const DEFAULT_SKIN := Color(0.992, 0.918, 0.553)
const CHEEK_UV := Vector2(0.8977, 0.0885)  # where the non-face head faces sample the skin

## The painted default face: what every knob rests at.
const REST := {
	"eye_open": 1.0, "eye_size": 1.0, "eye_look": Vector2.ZERO,
	"brow_show": 0.0, "brow_angle": 0.0, "brow_lift": 0.0,
	"mouth_curve": 1.0, "mouth_width": 1.0, "mouth_open": 0.0,
}

## "neutral" is the painted default smile, which the server also assumes at spawn.
const PRESETS := {
	"neutral": {},
	"happy": {"mouth_curve": 1.3, "mouth_width": 1.15, "eye_open": 0.9},
	"sad": {"mouth_curve": -0.7, "mouth_width": 0.8, "eye_open": 0.65},
	"serious": {"mouth_curve": 0.0, "mouth_width": 0.9, "brow_show": 1.0},
	"angry": {"mouth_curve": -0.8, "mouth_width": 0.9, "eye_size": 0.9,
		"brow_show": 1.0, "brow_angle": 1.0},
	"afraid": {"mouth_curve": -0.9, "mouth_width": 0.5, "eye_size": 1.3,
		"brow_show": 1.0, "brow_angle": -0.8, "brow_lift": 0.5},
	"scarystare": {"mouth_curve": 0.0, "mouth_width": 0.5, "eye_size": 1.6},
	"shocked": {"mouth_curve": 0.0, "mouth_width": 0.5, "mouth_open": 1.0, "eye_size": 1.4,
		"brow_show": 1.0, "brow_lift": 0.8},
}
const DEFAULT_EMOTION := "neutral"

const SETTLE := 14.0        # 1/s; an expression change lands in about 0.2 s
const BLINK_DOWN := 0.06
const BLINK_HOLD := 0.05
const BLINK_UP := 0.09
const BLINK_GAP := Vector2(2.0, 6.0)
const TALK_HZ := 7.0
const SKIN_POLL := 0.5      # s between checks for a swapped skin texture

# The Compatibility renderer (web) has no instance uniforms, so each head gets its own material.
var _overlay: ShaderMaterial
static var _skin_cache := {}   # texture key -> Color

var head: MeshInstance3D
var _emotion := DEFAULT_EMOTION
var _target := {}
var _value := {}
var _sent := {}
var _blink_t := -1.0        # time into the current blink; < 0 while waiting
var _next_blink := 0.0
var _talk_left := 0.0
var _talk_phase := 0.0
var _skin_poll := 0.0
var _skin_tex: Texture2D


## Returns the existing face if any; null for anything but the robloxian head.
static func attach(model: Node3D) -> Node:
	if model == null:
		return null
	var head_node := model.find_child("head", true, false) as MeshInstance3D
	if head_node == null or head_node.mesh == null or head_node.mesh.resource_name != HEAD_MESH_NAME:
		return null
	var existing := head_node.get_node_or_null(NODE_NAME)
	if existing != null:
		return existing
	var face := new()
	face.name = NODE_NAME
	face.head = head_node
	head_node.add_child(face)
	return face


func _ready() -> void:
	_overlay = ShaderMaterial.new()
	_overlay.shader = SHADER
	head.material_overlay = _overlay
	_value = REST.duplicate()
	_target = REST.duplicate()
	_apply_preset(_emotion)
	_next_blink = randf_range(BLINK_GAP.x, BLINK_GAP.y)
	_refresh_skin()
	_push(true)


## "" means the default; false if the name is unknown.
func set_emotion(emotion: String) -> bool:
	var key := emotion.strip_edges().to_lower()
	if key == "":
		key = DEFAULT_EMOTION
	if not PRESETS.has(key):
		return false
	_emotion = key
	_apply_preset(key)
	return true


func get_emotion() -> String:
	return _emotion


func get_available_emotions() -> Array:
	return PRESETS.keys()


## For about as long as `text` takes to say.
func say(text: String) -> void:
	_talk_left = clampf(0.4 + 0.045 * text.length(), 0.6, 4.0)


func _apply_preset(key: String) -> void:
	_target = REST.duplicate()
	for knob in PRESETS[key]:
		_target[knob] = PRESETS[key][knob]


func _process(delta: float) -> void:
	var k := 1.0 - exp(-delta * SETTLE)
	for knob in _target:
		_value[knob] = lerp(_value[knob], _target[knob], k)

	var closed := _advance_blink(delta)

	# Talking rides on top of whatever the expression holds the mouth at.
	var talk := 0.0
	if _talk_left > 0.0:
		_talk_left -= delta
		_talk_phase += delta * TALK_HZ * TAU
		talk = 0.15 + 0.45 * absf(sin(_talk_phase))

	_skin_poll -= delta
	if _skin_poll <= 0.0:
		_skin_poll = SKIN_POLL
		_refresh_skin()

	_push(false, 1.0 - closed, talk)


## Returns how closed the eyes are (0..1).
func _advance_blink(delta: float) -> float:
	if _blink_t >= 0.0:
		_blink_t += delta
	else:
		_next_blink -= delta
		if _next_blink <= 0.0:
			_blink_t = 0.0
	if _blink_t < 0.0:
		return 0.0
	if _blink_t < BLINK_DOWN:
		return _blink_t / BLINK_DOWN
	if _blink_t < BLINK_DOWN + BLINK_HOLD:
		return 1.0
	if _blink_t < BLINK_DOWN + BLINK_HOLD + BLINK_UP:
		return 1.0 - (_blink_t - BLINK_DOWN - BLINK_HOLD) / BLINK_UP
	_blink_t = -1.0
	_next_blink = randf_range(BLINK_GAP.x, BLINK_GAP.y)
	return 0.0


## `force` resends every knob.
func _push(force: bool, eye_scale: float = 1.0, talk: float = 0.0) -> void:
	for knob in _value:
		var v = _value[knob]
		match knob:
			"eye_open":
				v = float(v) * eye_scale
			"mouth_open":
				v = maxf(float(v), talk)
		if force or not _sent.has(knob) or not _same(_sent[knob], v):
			_sent[knob] = v
			_overlay.set_shader_parameter(knob, v)


static func _same(a, b) -> bool:
	if a is Vector2:
		return a.distance_to(b) < 0.002
	return absf(float(a) - float(b)) < 0.002


## Polled: skins arrive late and are swapped by replacing the surface material.
func _refresh_skin() -> void:
	var mat := head.get_active_material(0)
	var tex: Texture2D = null
	if mat is BaseMaterial3D:
		tex = mat.albedo_texture
	if tex == _skin_tex and _sent.has("skin_color"):
		return
	_skin_tex = tex
	var color := _skin_color_of(tex)
	_sent["skin_color"] = color
	_overlay.set_shader_parameter("skin_color", color)


## Cached per texture.
static func _skin_color_of(tex: Texture2D) -> Color:
	if tex == null:
		return DEFAULT_SKIN
	var key = tex.resource_path if tex.resource_path != "" else tex.get_instance_id()
	if _skin_cache.has(key):
		return _skin_cache[key]
	var color := DEFAULT_SKIN
	var img := tex.get_image()
	if img != null and not img.is_empty():
		if img.is_compressed():
			img.decompress()
		var px := Vector2i(int(CHEEK_UV.x * img.get_width()), int(CHEEK_UV.y * img.get_height()))
		px = px.clamp(Vector2i.ZERO, img.get_size() - Vector2i.ONE)
		var c := img.get_pixelv(px)
		if c.a > 0.5:
			color = Color(c.r, c.g, c.b)
	_skin_cache[key] = color
	return color
