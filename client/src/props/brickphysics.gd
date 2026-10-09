extends Node3D
## Build-mode brick: tiles its texture with its scale and toggles collision.

@onready var stud_mesh = $MATERIAL

@export var can_collide: bool = true:
	set(value):
		can_collide = value
		update_collision()

@export var locked: bool = false

func _ready():
	update_uv_scale()
	update_collision()
	set_notify_transform(true)

func _notification(what):
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		update_uv_scale()

## Gives the brick its own material first so tiling one does not re-tile others.
func update_uv_scale():
	if not stud_mesh or not stud_mesh.mesh:
		return

	var current_scale = scale

	for i in range(stud_mesh.mesh.get_surface_count()):
		var mat = _own_material(i)
		if mat is BaseMaterial3D:
			mat.uv1_scale = Vector3(current_scale.x, current_scale.z, current_scale.y)
			mat.texture_repeat = true

func _own_material(i: int):
	var mat = stud_mesh.get_surface_override_material(i)
	if mat == null:
		var base = stud_mesh.mesh.surface_get_material(i)
		mat = base.duplicate() if base else StandardMaterial3D.new()
		mat.resource_local_to_scene = true
		stud_mesh.set_surface_override_material(i, mat)
	elif not mat.resource_local_to_scene:
		mat = mat.duplicate()
		mat.resource_local_to_scene = true
		stud_mesh.set_surface_override_material(i, mat)
	return mat

func update_collision():
	if not stud_mesh:
		return

	var static_body = stud_mesh.get_node_or_null("StaticBody3D")
	if static_body:
		if can_collide:
			static_body.collision_layer = 1
			static_body.collision_mask = 1
		else:
			static_body.collision_layer = 0
			static_body.collision_mask = 0
