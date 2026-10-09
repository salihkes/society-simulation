extends Node3D

## A building's walkable interior floor, sampled from physics and joined to the street nav.

const InteriorNav := preload("res://src/life/interior_nav.gd")

@export var floor_polygon := PackedVector2Array()

var nav = null
var world: Node3D
var street = null
var ready_ok := false
var last_block := ""


func _ready() -> void:
	add_to_group("restaurant_layouts")


func point(marker: Node3D) -> Vector3:
	return world.to_local(marker.global_position)


func entrance() -> Vector3:
	return point($Entrance)


func contains(p: Vector3) -> bool:
	if world == null:
		return false
	var local := to_local(world.to_global(p))
	return local.y > -0.3 and local.y < 2.4 \
		and Geometry2D.is_point_in_polygon(Vector2(local.x, local.z), floor_polygon)


## Awaitable; ready_ok tells whether it was built.
func prepare(workspace: Node3D, street_nav) -> void:
	world = workspace
	street = street_nav
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _wait_for_storefront()
	var bounds := AABB(point($Entrance), Vector3.ZERO)
	for p in floor_polygon:
		bounds = bounds.expand(world.to_local(to_global(Vector3(p.x, 0.025, p.y))))
	nav = InteriorNav.new()
	nav.cell_size = 0.5
	nav.body_radius = 1.75
	nav.body_height = 5.0889206
	nav.headroom = 5.1
	var sample_y := world.to_local(to_global(Vector3(0, 1.6, 0))).y
	ready_ok = await nav.build_chunked(get_tree(), 3.0, get_world_3d().direct_space_state,
		world, bounds, [], sample_y)
	if not ready_ok:
		push_error("Restaurant floor navigation could not be built")


## The storefront opening installs deferred; before it the door is still a wall.
func _wait_for_storefront() -> void:
	var building := get_parent()
	if building == null or not ("installed" in building):
		return
	for i in 600:
		if building.installed:
			break
		await get_tree().physics_frame
	if not building.installed:
		push_warning("%s: storefront opening never installed; sampling the floor anyway" % building.name)
	await get_tree().physics_frame


## {} when neither end is on this floor; an empty "route" means blocked, never walk through walls.
func route_between(from: Vector3, to: Vector3) -> Dictionary:
	var start_inside := contains(from)
	var end_inside := contains(to)
	if not start_inside and not end_inside: return {}
	var path := PackedVector3Array()
	if not ready_ok:
		last_block = "floor navigation not built"
		return {"route": path}
	var gate := entrance()
	if start_inside and end_inside:
		path = nav.route(from, to)
	elif end_inside:
		var indoors: PackedVector3Array = nav.route(gate, to)
		var outdoors: PackedVector3Array = street.find_route(from, gate)
		if not indoors.is_empty() and not outdoors.is_empty():
			path = outdoors
			path.append_array(indoors)
		else:
			last_block = "%s%s from %s (walkable %s)" % [
				"no street way to the door " if outdoors.is_empty() else "",
				"no indoor way from the door" if indoors.is_empty() else "",
				from.snapped(Vector3.ONE * 0.1), street.is_walkable(Vector2(from.x, from.z))]
	else:
		var indoors: PackedVector3Array = nav.route(from, gate)
		var outdoors: PackedVector3Array = street.find_route(gate, to)
		if not indoors.is_empty() and not outdoors.is_empty():
			path = indoors
			path.append_array(outdoors)
	return {"route": path}
