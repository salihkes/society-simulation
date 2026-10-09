extends RefCounted
class_name MovementBase
## Interface for the input modules (keyboard, VR) that produce the character's wanted movement.

var character: CharacterBody3D
var character_model: Node3D
var planet_node: Node3D
var gravity_direction: Vector3

var walk_speed := 4.0
var run_speed := 8.0
var jump_velocity := 8.0
var acceleration := 10.0
var air_control := 0.8

var movement_direction := Vector3.ZERO
var is_running := false
var is_jumping := false

func setup(char: CharacterBody3D, model: Node3D) -> void:
	character = char
	character_model = model

func update_input(delta: float) -> void:
	pass

func get_movement_direction() -> Vector3:
	return movement_direction

func is_movement_active() -> bool:
	return movement_direction.length() > 0.1

## Undoes anything the module changed before another module takes over.
func cleanup() -> void:
	pass

## On a planet in the surface plane, otherwise in the horizontal plane.
func get_camera_relative_direction(input_dir: Vector2, camera: Camera3D) -> Vector3:
	if not camera:
		return Vector3.ZERO
	var camera_transform = camera.get_global_transform()
	if planet_node:
		var up = -gravity_direction
		var camera_forward = -camera_transform.basis.z
		var forward = camera_forward - camera_forward.project(up)
		# Looking straight up or down leaves no usable forward on the surface.
		if forward.length() < 0.1:
			forward = character.transform.basis.z
		forward = forward.normalized()
		var right = forward.cross(up).normalized()
		return (forward * -input_dir.y + right * input_dir.x).normalized()
	var forward = -camera_transform.basis.z
	forward.y = 0
	forward = forward.normalized()
	var right = camera_transform.basis.x
	right.y = 0
	right = right.normalized()
	return (forward * -input_dir.y + right * input_dir.x).normalized()
