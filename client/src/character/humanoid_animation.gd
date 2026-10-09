extends AnimationBase
class_name HumanoidAnimation

## Box humanoid animation: swinging limbs, jump and floor poses, and the drawn face.

const LimbRigScript := preload("res://src/character/limb_rig.gd")
const HumanoidFaceScript := preload("res://src/character/face/humanoid_face.gd")

## Remote players are animated once per network update, about every 0.05 s.
const REMOTE_STEP := 0.05

var arm_swing_amount := 1.2
var leg_swing_amount := 0.8

# Handles both the pivot-node box rig and models instanced from a .glb.
var rig := LimbRigScript.new()

# Its knees come from rig.enable_joints().
var _pose := HumanoidPoses.Blend.new()
var _base_model_y := 0.0

# Null for a model without the box head.
var face: Node = null


func setup(char: CharacterBody3D, model: Node3D, audio_player: AudioStreamPlayer3D) -> void:
	super.setup(char, model, audio_player)

	if rig.resolve(character_model):
		rig.enable_joints()
	face = HumanoidFaceScript.attach(character_model)
	_base_model_y = character_model.position.y

	if character.get("arm_swing_amount") != null:
		arm_swing_amount = character.arm_swing_amount
	if character.get("leg_swing_amount") != null:
		leg_swing_amount = character.leg_swing_amount
	if character.get("animation_speed") != null:
		animation_speed = character.animation_speed
	if character.get("footstep_rate") != null:
		footstep_rate = character.footstep_rate


func set_emotion(emotion: String) -> bool:
	return face != null and face.set_emotion(emotion)


func get_emotion() -> String:
	return face.get_emotion() if face else "neutral"


func get_available_emotions() -> Array:
	return face.get_available_emotions() if face else []


func say(text: String) -> void:
	if face:
		face.say(text)


func can_pose() -> bool:
	return rig.has_joint(rig.left_leg) and rig.has_joint(rig.right_leg)


## "seiza", "agura", or "" to stand back up.
func set_pose(pose_name: String) -> void:
	_pose.wanted = pose_name if HumanoidPoses.has(pose_name) else ""


## True while the pose owns the limbs this frame.
func _drive_pose(delta: float) -> bool:
	if not _pose.drive(rig, character_model, _base_model_y, delta):
		return false
	rig.yaw_head_toward(0.0, minf(delta * 4.0, 1.0))
	footstep_timer = 0.0
	return true


func animate(delta: float, speed: float, movement_dir: Vector3, is_running: bool, is_on_floor: bool) -> void:
	if _drive_pose(delta):
		return
	var max_speed = character.run_speed if is_running else character.walk_speed
	var movement_intensity = clamp(speed / max_speed, 0.0, 1.0)

	if movement_intensity > 0.05 and is_on_floor:
		_walk(delta, movement_intensity, is_running)
	elif is_on_floor:
		rig.relax(delta * 5.0)
		footstep_timer = 0.0

	if not is_on_floor:
		_air_pose(delta * 5.0)

	if rig.head:
		if movement_intensity > 0.1:
			rig.yaw_head_toward(-movement_dir.x * 0.2, delta * 2.0)
		else:
			rig.yaw_head_toward(0.0, delta * 2.0)


func animate_remote(speed: float, direction: Vector3, is_on_floor: bool = true) -> void:
	if _drive_pose(REMOTE_STEP):
		return
	var max_speed = character.run_speed if speed > character.walk_speed else character.walk_speed
	var movement_intensity = clamp(speed / max_speed, 0.0, 1.0)

	if not is_on_floor:
		_air_pose(0.1)
		rig.yaw_head_toward(-direction.x * 0.2, 0.1)
		footstep_timer = 0.0
		return

	if movement_intensity > 0.05:
		_walk(REMOTE_STEP, movement_intensity, speed > character.walk_speed)
		if rig.head:
			rig.yaw_head(-direction.x * 0.2)
	else:
		rig.relax(0.1)
		rig.yaw_head_toward(0.0, 0.1)


## Arms swing opposite to the legs.
func _walk(step: float, intensity: float, running: bool) -> void:
	var cycle_speed = animation_speed * intensity * step
	if running:
		cycle_speed *= 1.5
	walk_cycle += cycle_speed

	footstep_timer -= step
	if footstep_timer <= 0 and intensity > 0.1:
		play_footstep_sound(intensity)
		footstep_timer = footstep_rate / intensity

	walk_cycle = fmod(walk_cycle, 2.0 * PI)

	var arm_swing = sin(walk_cycle) * arm_swing_amount * intensity
	var leg_swing = sin(walk_cycle) * leg_swing_amount * intensity
	var opposite_swing = sin(walk_cycle + PI) * leg_swing_amount * intensity
	rig.pitch(rig.left_arm, opposite_swing)
	rig.pitch(rig.right_arm, arm_swing)
	rig.pitch(rig.left_leg, leg_swing)
	rig.pitch(rig.right_leg, opposite_swing)


func _air_pose(weight: float) -> void:
	rig.pitch_toward(rig.left_arm, PI, weight)
	rig.pitch_toward(rig.right_arm, PI, weight)
	rig.pitch_toward(rig.left_leg, 0.0, weight)
	rig.pitch_toward(rig.right_leg, 0.0, weight)
