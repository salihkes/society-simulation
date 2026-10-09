extends RefCounted
class_name AnimationBase
## Interface for the swappable character animation modules, plus their shared sounds.

var character: CharacterBody3D
var character_model: Node3D
var sound_player: AudioStreamPlayer3D

var animation_speed := 10.0
var footstep_rate := 0.3

var footstep_sound: AudioStream
var jump_sound: AudioStream

var footstep_timer := 0.0
var walk_cycle := 0.0

func setup(char: CharacterBody3D, model: Node3D, audio_player: AudioStreamPlayer3D) -> void:
	character = char
	character_model = model
	sound_player = audio_player
	footstep_sound = load("res://assets/art/sound/bfsl-minifigfoots1.mp3")
	jump_sound = load("res://assets/art/sound/swoosh.wav")

func animate(delta: float, speed: float, movement_dir: Vector3, is_running: bool, is_on_floor: bool) -> void:
	pass

func animate_remote(speed: float, direction: Vector3, is_on_floor: bool = true) -> void:
	pass

## Undoes anything the module changed before another module takes over.
func cleanup() -> void:
	pass

## Intensity scales both pitch and volume.
func play_footstep_sound(intensity: float = 1.0):
	if sound_player and footstep_sound:
		sound_player.stream = footstep_sound
		sound_player.pitch_scale = randf_range(0.8, 1.2) * intensity
		sound_player.volume_db = linear_to_db(0.3 * intensity)
		sound_player.play()

func play_jump_sound():
	if sound_player and jump_sound:
		sound_player.stream = jump_sound
		sound_player.pitch_scale = randf_range(0.9, 1.1)
		sound_player.volume_db = linear_to_db(0.5)
		sound_player.play()

func _is_character_on_floor() -> bool:
	var walker = character.get("planet")
	if walker != null:
		return walker.is_on_floor()
	return character.is_on_floor()
