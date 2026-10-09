class_name BuildTargeting
extends RefCounted

## What is under the mouse, raycast from the viewport's current camera.

const RAY_LENGTH := 2000.0


static func active_camera(ctx: Node) -> Camera3D:
	return ctx.get_viewport().get_camera_3d()


## Returns the intersect_ray() dictionary, or {} on a miss.
static func raycast(ctx: Node, mouse_pos: Vector2, exclude: Array[RID] = []) -> Dictionary:
	var camera := active_camera(ctx)
	if not camera:
		return {}

	var from := camera.project_ray_origin(mouse_pos)
	var to := from + camera.project_ray_normal(mouse_pos) * RAY_LENGTH

	var space_state := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	if not exclude.is_empty():
		query.exclude = exclude

	return space_state.intersect_ray(query)


## "part" is the hit's selectable ancestor, or null for scenery such as the baseplate.
static func target(ctx: Node, mouse_pos: Vector2, exclude: Array[RID] = []) -> Dictionary:
	var hit := raycast(ctx, mouse_pos, exclude)
	if hit.is_empty():
		return {}
	hit["part"] = BuildSelectable.find_selectable_parent(hit.collider, ctx.get_tree().current_scene)
	return hit


static func collision_rids(node: Node) -> Array[RID]:
	var rids: Array[RID] = []
	var stack: Array = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is CollisionObject3D:
			rids.append(current.get_rid())
		for child in current.get_children():
			stack.push_back(child)
	return rids


static func paint_target_at(ctx: Node, mouse_pos: Vector2, roots: Array) -> Node3D:
	var active_camera = ctx.get_viewport().get_camera_3d()
	if not active_camera:
		return null

	var from = active_camera.project_ray_origin(mouse_pos)
	var to = from + active_camera.project_ray_normal(mouse_pos) * 1000.0

	var space_state = ctx.get_viewport().world_3d.direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var result = space_state.intersect_ray(query)
	if result and result.collider:
		return BuildSelectable.paint_target(result.collider, roots)

	return null
