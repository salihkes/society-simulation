extends AnimationBase
## Locomotion clips for a JointRig character, the walk rate following speed.

## Walk clip rate multiplier while running without a run clip.
const RUN_RATE := 1.6

var rig: Node3D = null


func setup(char: CharacterBody3D, model: Node3D, audio_player: AudioStreamPlayer3D) -> void:
	super.setup(char, model, audio_player)
	rig = find_rig(model)
	if rig == null:
		push_warning("JointRigAnimation: no JointRig under " + str(model.get_path()))
		return
	if character.get("animation_speed") != null:
		animation_speed = character.animation_speed
	if character.get("footstep_rate") != null:
		footstep_rate = character.footstep_rate
	rig.play("idle")


## The first node with rotate_bone, or null.
static func find_rig(model: Node) -> Node3D:
	if model == null:
		return null
	if model.has_method("rotate_bone"):
		return model
	for child in model.get_children():
		var found := find_rig(child)
		if found != null:
			return found
	return null


func animate(delta: float, speed: float, movement_dir: Vector3, is_running: bool, is_on_floor: bool) -> void:
	if rig == null or not rig.bones_ready:
		return
	var max_speed: float = character.run_speed if is_running else character.walk_speed
	var intensity := clampf(speed / maxf(max_speed, 0.01), 0.0, 1.0)
	if not is_on_floor:
		rig.speed_scale = 1.0
		rig.play("jump", false)
		footstep_timer = 0.0
		return
	if intensity > 0.05:
		if is_running and rig.has_clip("run"):
			rig.speed_scale = maxf(intensity, 0.5)
			rig.play("run", false)
		else:
			rig.speed_scale = maxf(intensity, 0.3) * (RUN_RATE if is_running else 1.0)
			rig.play("walk", false)
		footstep_timer -= delta
		if footstep_timer <= 0.0 and intensity > 0.1:
			play_footstep_sound(intensity)
			footstep_timer = footstep_rate / intensity
	else:
		rig.speed_scale = 1.0
		rig.play("idle", false)
		footstep_timer = 0.0


func animate_remote(speed: float, _direction: Vector3, is_on_floor: bool = true) -> void:
	var is_running: bool = speed > character.walk_speed
	animate(0.05, speed, Vector3.ZERO, is_running, is_on_floor)


## "" goes back to idle.
func play_clip(clip_name: String) -> void:
	if rig == null:
		return
	rig.play(clip_name if clip_name != "" else "idle")


func cleanup() -> void:
	if rig != null and is_instance_valid(rig):
		rig.stop()


## Pass through to rigs that have a face (skinned_character_rig.gd).
func set_emotion(value: String) -> bool:
	return rig.set_emotion(value) if rig != null and rig.has_method("set_emotion") else false


func get_emotion() -> String:
	return rig.get_emotion() if rig != null and rig.has_method("get_emotion") else "neutral"


func get_available_emotions() -> Array:
	if rig != null and rig.has_method("get_available_emotions"):
		return rig.get_available_emotions()
	return []


func say(text: String) -> void:
	if rig != null and rig.has_method("say"):
		rig.say(text)


func play_sit() -> void:
	if rig != null and rig.has_clip("sit"):
		rig.play("sit")
