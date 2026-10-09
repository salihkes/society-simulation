extends AnimationBase
class_name CountryballAnimation
## Countryball animation: squash-and-bounce movement and a material-swapping face.

## Remote players are animated once per network update, about every 0.05 s.
const REMOTE_STEP := 0.05

var bounce_amount := 0.3  # height of the bounce
var bounce_speed := 8.0
var squash_amount := 0.2  # how much wider and shorter the ball gets while moving

var base_mesh: MeshInstance3D
var emotions_mesh: MeshInstance3D

var bounce_timer := 0.0
var original_scale: Vector3

var current_emotion := "neutral"
var emotion_materials := {}
var blink_material: Material
var is_blinking := false
var blink_timer := 0.0
var next_blink_time := 3.0
var blink_duration := 0.15


func setup(char: CharacterBody3D, model: Node3D, audio_player: AudioStreamPlayer3D) -> void:
	super.setup(char, model, audio_player)

	base_mesh = character_model.find_child("Base")
	emotions_mesh = character_model.find_child("Emotions")
	original_scale = character_model.scale
	_load_emotion_materials()

	if character.get("bounce_amount") != null:
		bounce_amount = character.bounce_amount
	if character.get("bounce_speed") != null:
		bounce_speed = character.bounce_speed
	if character.get("squash_amount") != null:
		squash_amount = character.squash_amount
	if character.get("footstep_rate") != null:
		footstep_rate = character.footstep_rate

	next_blink_time = randf_range(2.0, 5.0)


## Subclasses with other faces override this.
func _load_emotion_materials():
	emotion_materials["neutral"] = load("res://assets/entities/countryball/Emotions/neutral.tres")
	emotion_materials["happy"] = load("res://assets/entities/countryball/Emotions/happy.tres")
	emotion_materials["sad"] = load("res://assets/entities/countryball/Emotions/sad.tres")
	emotion_materials["serious"] = load("res://assets/entities/countryball/Emotions/serious.tres")
	blink_material = load("res://assets/entities/countryball/blink.tres")


## False if there is no face for `emotion`.
func set_emotion(emotion: String) -> bool:
	var emotion_lower = emotion.to_lower()
	if emotion_materials.has(emotion_lower):
		current_emotion = emotion_lower
		if not is_blinking and emotions_mesh:
			emotions_mesh.set_surface_override_material(0, emotion_materials[current_emotion])
		print("Countryball emotion set to: ", current_emotion)
		return true
	return false


func get_emotion() -> String:
	return current_emotion


## The rest scale the squash and stretch are relative to.
func update_original_scale(new_scale: Vector3) -> void:
	original_scale = new_scale


func animate(delta: float, speed: float, movement_dir: Vector3, is_running: bool, is_on_floor: bool) -> void:
	_update_blink(delta)

	if speed > 0.1 and is_on_floor:
		_bounce(delta, speed, is_running)
		footstep_timer -= delta
		if footstep_timer <= 0:
			play_footstep_sound(speed / character.walk_speed)
			footstep_timer = footstep_rate / (2.0 if is_running else 1.0)
	else:
		_settle(delta * 5.0)
		bounce_timer = 0.0

	if not is_on_floor:
		_stretch(1.0 + abs(character.velocity.y) * 0.05)


func animate_remote(speed: float, direction: Vector3, is_on_floor: bool = true) -> void:
	_update_blink(REMOTE_STEP)

	var is_running = speed > character.walk_speed * 0.8
	if speed > 0.1 and is_on_floor:
		_bounce(REMOTE_STEP, speed, is_running)
	else:
		_settle(0.1)

	if not is_on_floor:
		_stretch(1.0 + abs(character.velocity.y) * 0.05 if character else 1.2)


func _bounce(step: float, speed: float, is_running: bool) -> void:
	bounce_timer += step * bounce_speed * (2.0 if is_running else 1.0)
	var squash_factor = 1.0 - (speed / character.run_speed) * squash_amount
	character_model.scale = Vector3(
		original_scale.x * (1.0 + squash_amount * 0.5),
		original_scale.y * squash_factor,
		original_scale.z * (1.0 + squash_amount * 0.5)
	)
	character_model.position.y = sin(bounce_timer) * bounce_amount


func _settle(weight: float) -> void:
	character_model.scale = character_model.scale.lerp(original_scale, weight)
	character_model.position.y = lerp(character_model.position.y, 0.0, weight)


func _stretch(factor: float) -> void:
	character_model.scale = Vector3(
		original_scale.x * factor,
		original_scale.y / factor,
		original_scale.z * factor
	)


## Then waits 2-6 s.
func _update_blink(delta: float) -> void:
	if not emotions_mesh or not blink_material:
		return

	if is_blinking:
		blink_timer += delta
		if blink_timer >= blink_duration:
			is_blinking = false
			blink_timer = 0.0
			if emotion_materials.has(current_emotion):
				emotions_mesh.set_surface_override_material(0, emotion_materials[current_emotion])
			next_blink_time = randf_range(2.0, 6.0)
		return

	next_blink_time -= delta
	if next_blink_time <= 0:
		is_blinking = true
		blink_timer = 0.0
		emotions_mesh.set_surface_override_material(0, blink_material)


## The flag-carrying mesh, for texture_manager.
func get_base_mesh() -> MeshInstance3D:
	return base_mesh
