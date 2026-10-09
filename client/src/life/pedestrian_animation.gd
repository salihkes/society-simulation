class_name PedestrianAnimation
extends RefCounted
## A pedestrian's body motion: walk swing, bounce, floor and seated poses, bow, kick, held props and stance.

# Relative to the pivots' rest. A .tscn writes a basis by rows, Basis() takes axes: transposed.
const FOLD_L := Basis(Vector3(0.8008841, 0.51156044, 0.31127232),
	Vector3(-0.59881926, 0.68418074, 0.41630763),
	Vector3(0.0, -0.5198101, 0.85428184))
const FOLD_R := Basis(Vector3(0.7104351, -0.63287747, -0.30781192),
	Vector3(0.7014323, 0.60119647, 0.3828256),
	Vector3(-0.057226293, -0.48788193, 0.87103164))
const BOOK_ARM := Basis(Vector3(0.9659258, -0.109381646, -0.23456973),
	Vector3(0.25881904, 0.40821785, 0.8754262), Vector3(0.0, -0.90630776, 0.42261827))
# The arm bases turn about the arm's inner edge, not the pivot at its centre.
const SHOULDER_EDGE_L := Vector3(-1.0, 0.5, 0.0)
const SHOULDER_EDGE_R := Vector3(1.0, 0.5, 0.0)
const KICK_S := 0.55
const BOW_S := 2.8
const BOW_DEG := 30.0
const STANCE_ARM_BACK := 0.7  # at ease: upper arm behind the back (positive pitch = back)
const STANCE_ARM_IN := 0.4  # at ease: inward, so the hands meet at the back
const STANCE_ELBOW := -1.2  # at ease: forearm folded toward the body
const STANCE_LEG_APART := 0.13  # at ease: each leg out to its side (rad)
const STANCE_ARM_TIGHT := 0.08  # attention: arms drawn a touch back, straight

var _ped: AmbientPedestrian = null
var _walk_cycle := 0.0
var _pose := HumanoidPoses.Blend.new()
var _kick_t := 0.0  # seconds left
var _bow_t := 0.0
var _bowing := false
var _stance_k := 0.0  # eased 0..1


func _init(ped: AmbientPedestrian) -> void:
	_ped = ped


func kick() -> void:
	_kick_t = KICK_S


## The legs stay.
func bow() -> void:
	_bow_t = BOW_S


## The first that applies wins: lying, floor pose, seated, module, else swing or bounce.
func animate(delta: float) -> void:
	var speed: float = _ped.current_speed()
	if _animate_lying(delta):
		return
	var model: Node3D = _ped.character_model
	var limbs: bool = _ped.has_limbs()
	if limbs:
		var how: String = _ped.sit_how
		_pose.wanted = how if (_ped.sitting and how != "chair" and how != "lie") else ""
		if _pose.drive(_ped.limb_rig(), model, _ped.base_model_y(), delta):
			return

	# Countryballs have no legs to bend: they perch, and their module keeps animating.
	if _ped.sitting and limbs:
		_animate_seated(delta)
		return

	var module = _ped.anim_module()
	if module:
		var on_floor: bool = _ped.is_on_floor() if _ped.is_authority() else true
		module.animate(delta, speed, Vector3.ZERO, speed > _ped.walk_speed + 0.5, on_floor)
		return

	var intensity: float = clampf(speed / maxf(_ped.walk_speed, 0.01), 0.0, 1.0)
	if limbs:
		_animate_limbs(delta, intensity)
	elif model:
		_animate_bounce(delta, intensity)


## Lying puts the head at +Z, so a bed's spot faces away from the headboard. True while lying.
func _animate_lying(delta) -> bool:
	var model: Node3D = _ped.character_model
	if model == null:
		return false
	var lying: bool = _ped.sitting and _ped.sit_how == "lie"
	var tilt := PI / 2.0 if lying else 0.0
	if absf(model.rotation.x - tilt) > 0.001:
		model.rotation.x = lerp_angle(model.rotation.x, tilt, minf(delta * 6.0, 1.0))
	if not lying:
		return false
	if _ped.has_limbs():
		_ped.limb_rig().relax(delta * 5.0)
	return true


func _animate_seated(delta):
	var rig = _ped.limb_rig()
	rig.pitch_toward(rig.left_leg, 1.5, minf(delta * 6.0, 1.0))
	rig.pitch_toward(rig.right_leg, 1.5, minf(delta * 6.0, 1.0))
	if _ped.arms_pose == "folded":
		_pose_authored_arm(rig.left_arm, FOLD_L)
		_pose_authored_arm(rig.right_arm, FOLD_R)
		return
	rig.pitch_toward(rig.left_arm, 0.35, minf(delta * 6.0, 1.0))
	if _ped.held_prop in ["book", "notebook"]:
		_pose_authored_arm(rig.right_arm, BOOK_ARM)
	else:
		rig.pitch_toward(rig.right_arm, 0.35, minf(delta * 6.0, 1.0))


func _animate_limbs(delta, intensity: float):
	var rig = _ped.limb_rig()
	var folded: bool = _ped.arms_pose == "folded"
	if intensity > 0.01:
		var amp := 0.45 if folded else 0.8
		_walk_cycle = fmod(_walk_cycle + (10.0 if folded else 8.0) * intensity * delta, TAU)
		var swing := sin(_walk_cycle) * amp * intensity
		var opp := sin(_walk_cycle + PI) * amp * intensity
		if not folded:
			rig.pitch(rig.left_arm, opp)
			rig.pitch(rig.right_arm, swing)
		rig.pitch(rig.left_leg, swing)
		rig.pitch(rig.right_leg, opp)
	else:
		rig.relax(delta * 5.0)
	_animate_bow(delta, folded)
	_animate_kick(delta)
	_pose_held_prop(delta)
	if _ped.calling:
		rig.pitch_toward(rig.right_arm, 2.7, minf(delta * 8.0, 1.0))
	if folded and _bow_t <= 0.0 and _kick_t <= 0.0 and not _ped.calling:
		_pose_authored_arm(rig.left_arm, FOLD_L)
		_pose_authored_arm(rig.right_arm, FOLD_R)
	_apply_stance(delta, intensity, folded)


func _bow_limbs() -> Array:
	var rig = _ped.limb_rig()
	return [rig.torso, rig.head, rig.hair, rig.accessories, rig.left_arm, rig.right_arm]


## Down over the first 15% of BOW_S, held until 70%, then up.
func _animate_bow(delta, folded: bool):
	var rig = _ped.limb_rig()
	var worn: Node3D = _ped.accessory_container()
	if _bow_t <= 0.0:
		if _bowing:
			_bowing = false
			for limb in _bow_limbs():
				rig.reset(limb)
			if worn != null and is_instance_valid(worn):
				worn.transform = Transform3D.IDENTITY
		return
	_bow_t -= delta
	_bowing = true
	var u: float = 1.0 - _bow_t / BOW_S
	var k: float
	if u < 0.15:
		k = u / 0.15
	elif u < 0.7:
		k = 1.0
	else:
		k = 1.0 - (u - 0.7) / 0.3
	k = smoothstep(0.0, 1.0, clampf(k, 0.0, 1.0))
	var rot := Basis(Vector3.RIGHT, -deg_to_rad(BOW_DEG) * k)
	var hips := Vector3(0.0, -1.0, 0.0)
	for limb in _bow_limbs():
		rig.pose_about(limb, hips, rot)
	if folded:
		_fold_arms_about(hips, rot)
	# Worn things live in our own container, whose rest is identity.
	if worn != null and is_instance_valid(worn):
		worn.transform = Transform3D(rot, hips - rot * hips)


func _animate_kick(delta):
	if _kick_t <= 0.0:
		return
	_kick_t -= delta
	var rig = _ped.limb_rig()
	var u: float = 1.0 - _kick_t / KICK_S
	var a: float = -0.9 * sin(u / 0.35 * PI) if u < 0.35 else 1.6 * sin((u - 0.35) / 0.65 * PI)
	rig.pitch(rig.right_leg, a)
	rig.pitch(rig.left_arm, a * 0.5)
	rig.pitch(rig.right_arm, -a * 0.4)


func _pose_held_prop(delta):
	var rig = _ped.limb_rig()
	var prop: String = _ped.held_prop
	if prop in ["book", "notebook"]:
		_pose_authored_arm(rig.right_arm, BOOK_ARM)
	elif prop in ["pot", "bowl", "mug"]:
		rig.pitch_toward(rig.right_arm, -1.3, minf(delta * 8.0, 1.0))
		if prop == "pot":
			rig.pitch_toward(rig.left_arm, -1.3, minf(delta * 8.0, 1.0))
	elif prop == "broom":
		rig.pitch_toward(rig.right_arm, -0.6, minf(delta * 8.0, 1.0))


func _animate_bounce(delta, intensity: float):
	var model: Node3D = _ped.character_model
	var base_y: float = _ped.base_model_y()
	if intensity > 0.01:
		_walk_cycle = fmod(_walk_cycle + 9.0 * intensity * delta, TAU)
		model.position.y = base_y + absf(sin(_walk_cycle)) * 0.35 * intensity
	else:
		model.position.y = lerpf(model.position.y, base_y, delta * 6.0)


## Not while walking, bowing, kicking, calling, sitting, holding a prop or with arms folded.
func _apply_stance(delta: float, intensity: float, folded: bool):
	var stance: String = _ped.stance
	var want: bool = stance != "" and intensity <= 0.01 and _bow_t <= 0.0 and _kick_t <= 0.0 \
		and not folded and not _ped.calling and _ped.held_prop == "" and not _ped.sitting
	_stance_k = move_toward(_stance_k, 1.0 if want else 0.0, delta * 3.0)
	if _stance_k <= 0.0:
		return
	var rig = _ped.limb_rig()
	var k: float = smoothstep(0.0, 1.0, _stance_k)
	if stance == "at_ease":
		var back := Basis(Vector3.RIGHT, STANCE_ARM_BACK * k)
		rig.pose_about(rig.left_arm, rig.pivot_of(rig.left_arm),
			Basis(Vector3.BACK, STANCE_ARM_IN * k) * back)
		rig.pose_about(rig.right_arm, rig.pivot_of(rig.right_arm),
			Basis(Vector3.BACK, -STANCE_ARM_IN * k) * back)
		if rig.has_joint(rig.left_arm):
			rig.flex(rig.left_arm, STANCE_ELBOW * k)
			rig.flex(rig.right_arm, STANCE_ELBOW * k)
		rig.swing(rig.left_leg, Vector3.BACK, -STANCE_LEG_APART * k)
		rig.swing(rig.right_leg, Vector3.BACK, STANCE_LEG_APART * k)
	else:
		rig.pitch(rig.left_arm, STANCE_ARM_TIGHT * k)
		rig.pitch(rig.right_arm, STANCE_ARM_TIGHT * k)
		if rig.has_joint(rig.left_arm):
			rig.flex(rig.left_arm, 0.0)
			rig.flex(rig.right_arm, 0.0)
		rig.yaw_head_toward(0.0, minf(delta * 8.0, 1.0))


func _fold_arms_about(hips: Vector3, rot: Basis):
	var rig = _ped.limb_rig()
	var bend := Transform3D(rot, hips - rot * hips)
	if rig.left_arm != null:
		rig.left_arm.transform = bend * _authored_arm(rig.left_arm, FOLD_L)
	if rig.right_arm != null:
		rig.right_arm.transform = bend * _authored_arm(rig.right_arm, FOLD_R)


func _authored_arm(limb: Node3D, basis: Basis) -> Transform3D:
	var rig = _ped.limb_rig()
	var edge := SHOULDER_EDGE_L if limb == rig.left_arm else SHOULDER_EDGE_R
	var rest: Transform3D = rig.rest_of(limb)
	return Transform3D(basis * rest.basis, edge + basis * (rest.origin - edge))


func _pose_authored_arm(limb: Node3D, basis: Basis):
	if limb != null:
		limb.transform = _authored_arm(limb, basis)
