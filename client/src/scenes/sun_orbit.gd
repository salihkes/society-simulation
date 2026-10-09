@tool
extends Node3D
## Moves the sun from the UTC clock, so every client sees the same sun without sync.

## Radians per real-world second; 0.02 is a day/night cycle of about 5 minutes.
@export var orbit_speed: float = 0.02

## Distance from the planet centre; only the direction matters to the light.
@export var orbit_radius: float = 1200.0

## Tilt of the orbit plane in degrees.
@export var orbit_tilt: float = 23.5


func _physics_process(_delta: float) -> void:
	var now := Time.get_unix_time_from_system()
	var angle := fmod(now * orbit_speed, TAU)

	var tilt_rad := deg_to_rad(orbit_tilt)
	var x := cos(angle) * orbit_radius
	var z := sin(angle) * cos(tilt_rad) * orbit_radius
	var y := sin(angle) * sin(tilt_rad) * orbit_radius

	global_position = Vector3(x, y, z)

	# The child DirectionalLight3D inherits this rotation.
	var up := Vector3.UP
	if abs(y / orbit_radius) > 0.99:
		up = Vector3.RIGHT
	look_at(Vector3.ZERO, up)
