extends RefCounted
## Finds and rotates the limbs of an R6-style box humanoid (limb_pivots / limb_names metadata for imports).

const LimbBenderScript := preload("res://src/character/limb_bender.gd")

## Slot -> node names to try, in order.
const DEFAULT_NAMES := {
	"left_arm": ["LeftArm"],
	"right_arm": ["RightArm"],
	"left_leg": ["LeftLeg"],
	# The box rig's right leg pivot is "RightLeg2"; its mesh child is "RightLeg".
	"right_leg": ["RightLeg2", "RightLeg"],
	"head": ["head"],
	"hair": ["Hair"],
	"torso": ["Torso"],
	"accessories": ["Accessories"],
}

var left_arm: Node3D
var right_arm: Node3D
var left_leg: Node3D
var right_leg: Node3D
var head: Node3D
var hair: Node3D
var torso: Node3D
var accessories: Node3D
var _config: Node = null  # node carrying the limb_pivots / limb_names metadata
var _rest := {}  # Node3D -> Transform3D captured at resolve()
var _pivot := {}  # Node3D -> Vector3 joint in the limb's parent space
var _angle := {}  # Node3D -> float current swing angle
var _joint := {}  # Node3D -> LimbBender, once enable_joints() ran
var _flex := {}  # Node3D -> float current fold at the mid joint


## True only for a complete set of arms and legs.
func resolve(model: Node3D) -> bool:
	if model == null:
		return false
	_config = _find_config(model)

	left_arm = _find_limb(model, "left_arm")
	right_arm = _find_limb(model, "right_arm")
	left_leg = _find_limb(model, "left_leg")
	right_leg = _find_limb(model, "right_leg")
	head = _find_limb(model, "head")
	hair = _find_limb(model, "hair")
	torso = _find_limb(model, "torso")
	accessories = _find_limb(model, "accessories")

	for limb in [left_arm, right_arm, left_leg, right_leg, head, hair, torso, accessories]:
		_register(limb)

	return left_arm != null and right_arm != null and left_leg != null and right_leg != null


## A limb_names override first, then DEFAULT_NAMES.
func _find_limb(model: Node3D, slot: String) -> Node3D:
	var names: Array = []
	if _config != null and _config.has_meta("limb_names"):
		var overrides: Dictionary = _config.get_meta("limb_names")
		if overrides.has(slot):
			names.append(String(overrides[slot]))
	names.append_array(DEFAULT_NAMES[slot])
	for limb_name in names:
		# owned=false finds limbs inside an instanced model scene.
		var found := model.find_child(str(limb_name), true, false)
		if found is Node3D:
			return found
	return null


## The model, then its subtree, then its ancestors.
func _find_config(model: Node3D) -> Node:
	if _carries_config(model):
		return model
	for child in model.find_children("*", "", true, false):
		if _carries_config(child):
			return child
	var node: Node = model.get_parent()
	while node != null:
		if _carries_config(node):
			return node
		node = node.get_parent()
	return null


func _carries_config(node: Node) -> bool:
	return node.has_meta("limb_pivots") or node.has_meta("limb_names")


func _register(limb: Node3D) -> void:
	if limb == null:
		return
	_rest[limb] = limb.transform
	_angle[limb] = 0.0
	_pivot[limb] = _find_pivot(limb)


## From limb_pivots, else the limb's own origin (a real pivot node).
func _find_pivot(limb: Node3D) -> Vector3:
	if _config != null and _config.has_meta("limb_pivots"):
		var pivots: Dictionary = _config.get_meta("limb_pivots")
		var key := String(limb.name)
		if pivots.has(key):
			return pivots[key]
	return limb.transform.origin


func angle_of(limb: Node3D) -> float:
	return _angle.get(limb, 0.0)


func rest_of(limb: Node3D) -> Transform3D:
	return _rest.get(limb, Transform3D.IDENTITY)


## Composed with the rest transform.
func swing(limb: Node3D, axis: Vector3, angle: float) -> void:
	if limb == null:
		return
	_angle[limb] = angle
	var rot := Basis(axis, angle)
	var pivot: Vector3 = _pivot[limb]
	var pose: Transform3D = Transform3D(rot, pivot - rot * pivot) * _rest[limb]
	if limb.transform != pose:
		limb.transform = pose


func pitch(limb: Node3D, angle: float) -> void:
	swing(limb, Vector3.RIGHT, angle)


func pitch_toward(limb: Node3D, target: float, weight: float) -> void:
	if limb == null:
		return
	var next := lerpf(angle_of(limb), target, weight)
	# Snap the last tiny step so idle limbs stop dirtying transforms.
	if absf(next - target) < 0.0001:
		next = target
	pitch(limb, next)


## Hair worn on the head turns with it.
func yaw_head(angle: float) -> void:
	swing(head, Vector3.UP, angle)
	swing(hair, Vector3.UP, angle)


func yaw_head_toward(target: float, weight: float) -> void:
	if head == null:
		return
	yaw_head(lerp(angle_of(head), target, weight))


## In the parent's space.
func pivot_of(limb: Node3D) -> Vector3:
	return _pivot.get(limb, limb.transform.origin if limb != null else Vector3.ZERO)


## `pivot` is in the parent's space (the hips, for a bow); composed with the rest transform.
func pose_about(limb: Node3D, pivot: Vector3, rot: Basis) -> void:
	if limb == null or not _rest.has(limb):
		return
	limb.transform = Transform3D(rot, pivot - rot * pivot) * _rest[limb]


func pose_basis(limb: Node3D, basis: Basis) -> void:
	if limb == null or not _rest.has(limb):
		return
	var rest: Transform3D = _rest[limb]
	limb.transform = Transform3D(basis * rest.basis, rest.origin)


func reset(limb: Node3D) -> void:
	if limb != null and _rest.has(limb):
		limb.transform = _rest[limb]
		_angle[limb] = 0.0
		flex(limb, 0.0)


func relax(weight: float) -> void:
	pitch_toward(left_arm, 0.0, weight)
	pitch_toward(right_arm, 0.0, weight)
	pitch_toward(left_leg, 0.0, weight)
	pitch_toward(right_leg, 0.0, weight)
	for limb in _joint:
		flex_toward(limb, 0.0, weight)


## True if any limb got a joint.
func enable_joints() -> bool:
	for limb in [left_arm, right_arm, left_leg, right_leg]:
		if limb == null or _joint.has(limb):
			continue
		var bender = LimbBenderScript.build(limb)
		if bender != null:
			_joint[limb] = bender
			_flex[limb] = 0.0
	return not _joint.is_empty()


func has_joint(limb: Node3D) -> bool:
	return _joint.has(limb)


func joint_of(limb: Node3D):
	return _joint.get(limb)


## A knee folds the shin back, an elbow folds the forearm forward.
func flex_sign(limb: Node3D) -> float:
	return 1.0 if (limb == left_arm or limb == right_arm) else -1.0


## Radians, positive the natural way, on top of the whole-limb swing.
func flex(limb: Node3D, angle: float) -> void:
	if not _joint.has(limb):
		return
	_flex[limb] = angle
	_joint[limb].bend(Vector3.RIGHT, angle * flex_sign(limb))


func flex_of(limb: Node3D) -> float:
	return _flex.get(limb, 0.0)


func flex_toward(limb: Node3D, target: float, weight: float) -> void:
	if not _joint.has(limb):
		return
	var next := lerpf(flex_of(limb), target, weight)
	if absf(next - target) < 0.0001:
		next = target
	flex(limb, next)
