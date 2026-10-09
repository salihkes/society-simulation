extends RefCounted
class_name HumanoidPoses

## Floor poses for the box humanoid (forward -Z, left -X, hips at y = -1, feet at y = -3).

const BLEND_S := 0.45          # seconds from standing into the pose
const FLOOR_Y := -3.0

const NAMES := ["seiza", "agura"]

static var _drop_cache := {}   # pose name -> model drop at full weight


static func has(pose: String) -> bool:
	return pose in NAMES


## Returns the model drop (model units) at weight `k`; without rig joints only the hips pose.
static func apply(rig, pose: String, k: float) -> float:
	var limbs := _limbs(rig, pose)
	if limbs.is_empty():
		return 0.0
	k = clampf(k, 0.0, 1.0)
	for limb in limbs:
		var p: Dictionary = limbs[limb]
		if k <= 0.0:
			rig.reset(limb)
		else:
			rig.pose_basis(limb, Basis.IDENTITY.slerp(p.basis, k))
			rig.flex(limb, p.flex * k)
	return drop(rig, pose) * k


## The lowest posed limb centreline point, less half the box, brought to the floor.
static func drop(rig, pose: String) -> float:
	if _drop_cache.has(pose):
		return _drop_cache[pose]
	var limbs := _limbs(rig, pose)
	var lowest := INF
	for limb in limbs:
		for p in limb_points(rig, limb, limbs[limb]):
			lowest = minf(lowest, p.y)
	if lowest == INF:
		return 0.0
	var half: float = 0.5
	var d := maxf(0.0, (lowest - half) - FLOOR_Y)
	_drop_cache[pose] = d
	return d


## Model space, from the top of the box to its free end.
static func limb_points(rig, limb: Node3D, entry: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	var bender = rig.joint_of(limb)
	var rest: Transform3D = rig.rest_of(limb)
	var joint: Vector3
	var half := 0.5
	if bender != null:
		joint = bender.joint
		half = bender.half_width
	else:
		joint = Vector3(0.0, -1.0, 0.0)
	var signed_angle: float = entry.flex * rig.flex_sign(limb)
	for i in 21:
		var u := -1.0 + 0.1 * i
		var r := joint + Vector3.DOWN * u
		var t := Transform3D.IDENTITY
		if bender != null:
			t = LimbBender.ring_transform(u, joint, half, Vector3.RIGHT, signed_angle)
		out.append(rest.origin + (entry.basis as Basis) * (t * r))
	return out


## Set `wanted` and call drive() every frame; a switch between poses goes through standing.
class Blend:
	var wanted := ""
	var shown := ""      # the pose still on the limbs while easing out
	var k := 0.0

	## True while a pose is on the limbs; the caller then skips its own limb animation.
	func drive(rig, model: Node3D, base_y: float, delta: float) -> bool:
		if wanted != "" and wanted == shown:
			k = minf(k + delta / BLEND_S, 1.0)
		elif k > 0.0:
			k = maxf(k - delta / BLEND_S, 0.0)
		elif wanted != "" and HumanoidPoses.has(wanted):
			shown = wanted
			k = minf(delta / BLEND_S, 1.0)
		else:
			shown = ""
			return false
		var d := HumanoidPoses.apply(rig, shown, k)
		if model != null:
			model.position.y = base_y - d * model.scale.y
		if k <= 0.0:
			shown = ""
		return true


# The knee closes 90 + THIGH_DEG so the shin lies level.
const SEIZA_THIGH_DEG := 30.0
const SEIZA_ARM_PITCH_DEG := 12.0
const SEIZA_ARM_IN_DEG := 14.0
const SEIZA_ELBOW_DEG := 24.0

const AGURA_YAW_DEG := 55.0       # thigh swung outward from straight ahead
const AGURA_RAISE_L_DEG := 4.0    # left knee above the hips
const AGURA_RAISE_R_DEG := 14.0   # right knee, higher: its shin crosses over
const AGURA_KNEE_L_DEG := 150.0   # left shin tucked in toward the body
const AGURA_KNEE_R_DEG := 135.0   # right shin further out, ankles crossing
const AGURA_ARM_PITCH_DEG := 25.0
const AGURA_ARM_IN_DEG := 12.0
const AGURA_ELBOW_DEG := 35.0


## Limb -> {basis, flex} for `pose`; empty for a rig without box legs.
static func _limbs(rig, pose: String) -> Dictionary:
	if rig == null or rig.left_leg == null or rig.right_leg == null:
		return {}   # a ball, or a rig without box limbs
	match pose:
		"seiza":
			return _seiza(rig)
		"agura":
			return _agura(rig)
	return {}


static func _seiza(rig) -> Dictionary:
	var thigh := deg_to_rad(SEIZA_THIGH_DEG)
	var leg := {"basis": Basis(Vector3.RIGHT, thigh), "flex": PI / 2.0 + thigh}
	var pitch := deg_to_rad(SEIZA_ARM_PITCH_DEG)
	var inward := deg_to_rad(SEIZA_ARM_IN_DEG)
	var elbow := deg_to_rad(SEIZA_ELBOW_DEG)
	var out := {}
	out[rig.left_leg] = leg
	out[rig.right_leg] = leg
	# Adduction about the model's Z: the left arm (at -X) swings toward +X.
	out[rig.left_arm] = {"basis": Basis(Vector3.BACK, inward) * Basis(Vector3.RIGHT, pitch), "flex": elbow}
	out[rig.right_arm] = {"basis": Basis(Vector3.BACK, -inward) * Basis(Vector3.RIGHT, pitch), "flex": elbow}
	return out


static func _agura(rig) -> Dictionary:
	var out := {}
	out[rig.left_leg] = {
		"basis": _hip_frame(-1.0, deg_to_rad(AGURA_YAW_DEG), deg_to_rad(AGURA_RAISE_L_DEG)),
		"flex": deg_to_rad(AGURA_KNEE_L_DEG),
	}
	out[rig.right_leg] = {
		"basis": _hip_frame(1.0, deg_to_rad(AGURA_YAW_DEG), deg_to_rad(AGURA_RAISE_R_DEG)),
		"flex": deg_to_rad(AGURA_KNEE_R_DEG),
	}
	var pitch := deg_to_rad(AGURA_ARM_PITCH_DEG)
	var inward := deg_to_rad(AGURA_ARM_IN_DEG)
	var elbow := deg_to_rad(AGURA_ELBOW_DEG)
	out[rig.left_arm] = {"basis": Basis(Vector3.BACK, inward) * Basis(Vector3.RIGHT, pitch), "flex": elbow}
	out[rig.right_arm] = {"basis": Basis(Vector3.BACK, -inward) * Basis(Vector3.RIGHT, pitch), "flex": elbow}
	return out


## `side` -1 left, +1 right; the hinge flips per side to keep the thigh under the torso.
static func _hip_frame(side: float, yaw: float, raise: float) -> Basis:
	var d := Vector3(side * sin(yaw) * cos(raise), sin(raise), -cos(yaw) * cos(raise)).normalized()
	var a := (Vector3.UP - d * Vector3.UP.dot(d)).normalized()
	var x := a * -side
	var y := -d
	return Basis(x, y, x.cross(y))
