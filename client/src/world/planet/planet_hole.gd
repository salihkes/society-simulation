@tool
class_name PlanetHole
extends Node3D
## A hole in the planet surface (tunnel mouths, stairwells): no terrain drawn, no collision.

## World units.
@export var radius := 12.0:
	set(v):
		radius = maxf(v, 0.5)
		_notify()


func _enter_tree() -> void:
	add_to_group("planet_holes")
	_notify()


func _exit_tree() -> void:
	_notify()


## Refreshes the first PlanetTerrain among the siblings of an ancestor.
func _notify() -> void:
	if not is_inside_tree():
		return
	var parent := get_parent()
	while parent:
		for child in parent.get_children():
			if child is PlanetTerrain:
				child.refresh_holes()
				return
		parent = parent.get_parent()
