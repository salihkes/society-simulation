@tool
class_name PlanetPadStamp
extends Node3D
## A free-standing terrain pad: flattens the planet ground under this node.

@export var pad_radius := 60.0
@export var falloff := 40.0
## true: tangent plane (flat-authored assets); false: constant elevation (sphere-bent assets).
@export var planar := true


func _enter_tree() -> void:
	add_to_group("planet_height_stampers")


## None when this node is at the planet centre.
func get_height_stamps(terrain: PlanetTerrain) -> Array:
	var dir := position.normalized()
	if dir.length_squared() < 0.5 or pad_radius <= 0.0:
		return []
	return [{
		"dir": dir,
		"target": terrain.base_height_at_dir(dir),
		"half": pad_radius,
		"falloff": maxf(falloff, 1.0),
		"planar": planar,
	}]
