extends RefCounted
class_name StagePose
## The channel pose a performer holds at one instant (a Dictionary, radians), and the arithmetic on it.

const LIMBS := ["left_arm", "right_arm", "left_leg", "right_leg"]
const ANGLES := ["yaw", "head_yaw"]
const SCALARS := ["x", "z", "head_pitch", "bow", "fan_open", "travel"]
const TAGS := ["gait", "fan", "prop", "presence"]
## Channels the movement library may write in degrees.
const DEGREE_CHANNELS := ["yaw", "head_yaw", "head_pitch", "bow"]


static func standing() -> Dictionary:
	return {
		"x": 0.0, "z": 0.0, "yaw": 0.0, "head_yaw": 0.0, "head_pitch": 0.0, "bow": 0.0,
		"left_arm": [0.0, 0.0, 0.0], "right_arm": [0.0, 0.0, 0.0],
		"left_leg": [0.0, 0.0, 0.0], "right_leg": [0.0, 0.0, 0.0],
		"gait": "slide", "fan": "", "fan_open": 0.0, "prop": "", "presence": "", "travel": 0.0,
	}


## A deep copy: limb arrays are shared references otherwise.
static func copy(p: Dictionary) -> Dictionary:
	var out := p.duplicate()
	for limb in LIMBS:
		if out.has(limb):
			out[limb] = Array(out[limb]).duplicate()
	return out


## A two-element limb keeps the base flex.
static func merge(base: Dictionary, partial: Dictionary) -> Dictionary:
	var out := copy(base)
	for key in partial:
		var value = partial[key]
		if key in LIMBS:
			var arr: Array = Array(value).duplicate()
			while arr.size() < 3:
				arr.append(float(out[key][arr.size()]) if out.has(key) else 0.0)
			out[key] = [float(arr[0]), float(arr[1]), float(arr[2])]
		elif key in TAGS:
			out[key] = String(value)
		else:
			out[key] = float(value)
	return out


## Degrees (movement definitions, cue scores) to engine radians.
static func from_degrees(partial: Dictionary) -> Dictionary:
	var out := {}
	for key in partial:
		var value = partial[key]
		if key in LIMBS:
			var arr: Array = []
			for v in value:
				arr.append(deg_to_rad(float(v)))
			out[key] = arr
		elif key in DEGREE_CHANNELS:
			out[key] = deg_to_rad(float(value))
		else:
			out[key] = value
	return out


## Linear blend of two full poses; tags come from `a` (they switch at keys).
static func blend(a: Dictionary, b: Dictionary, w: float) -> Dictionary:
	var out := {}
	for key in SCALARS:
		out[key] = lerpf(float(a.get(key, 0.0)), float(b.get(key, 0.0)), w)
	for key in ANGLES:
		out[key] = lerp_angle(float(a.get(key, 0.0)), float(b.get(key, 0.0)), w)
	for limb in LIMBS:
		var la: Array = a.get(limb, [0.0, 0.0, 0.0])
		var lb: Array = b.get(limb, [0.0, 0.0, 0.0])
		out[limb] = [lerpf(float(la[0]), float(lb[0]), w), lerpf(float(la[1]), float(lb[1]), w), lerpf(float(la[2]), float(lb[2]), w)]
	for key in TAGS:
		out[key] = String(a.get(key, ""))
	return out


## Spread about Z first, then pitch about X, so "outward" holds at any pitch; flex is applied at the joint.
static func limb_basis(limb: String, entry: Array) -> Basis:
	var pitch := float(entry[0])
	var spread := float(entry[1])
	var side := -1.0 if limb.begins_with("left") else 1.0
	return Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, side * spread)


## Yaw 0 faces the house (+Z); positive turns toward +X.
static func heading(yaw: float) -> Vector2:
	return Vector2(sin(yaw), cos(yaw))


static func yaw_toward(from: Vector2, to: Vector2) -> float:
	var d := to - from
	if d.length_squared() < 1e-8:
		return 0.0
	return atan2(d.x, d.y)


## Legs folded to the floor (seiza, kneel).
static func seated(p: Dictionary) -> bool:
	return float(p.left_leg[2]) > 1.2 and float(p.right_leg[2]) > 1.2
