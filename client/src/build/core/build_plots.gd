class_name BuildPlots
extends RefCounted

## Plot rules for the build tools: a plot is a Plot_<id> polygon under AmbientLayout.

const LAYOUT_NODE := "AmbientLayout"
const EPS := 0.001


static func layout_node(scene_root: Node) -> Node3D:
	if scene_root == null:
		return null
	return scene_root.get_node_or_null(LAYOUT_NODE) as Node3D


## Returns [{id, name, points, poly, floor, ceiling, area}].
static func all_plots(scene_root: Node) -> Array:
	var node := layout_node(scene_root)
	if node == null or not node.has_method("plots"):
		return []
	var out := []
	for p in node.plots():
		var poly := PackedVector2Array()
		for pt in p.points:
			poly.append(Vector2(pt.x, pt.z))
		var entry: Dictionary = p.duplicate()
		entry["poly"] = poly
		entry["area"] = polygon_area(poly)
		out.append(entry)
	return out


static func plot_by_id(scene_root: Node, plot_id: String) -> Dictionary:
	if plot_id == "":
		return {}
	for p in all_plots(scene_root):
		if str(p.id) == plot_id:
			return p
	return {}


## The smallest containing plot (plots may nest), or {}.
static func plot_at(scene_root: Node, global_pos: Vector3, only_ids: Array = []) -> Dictionary:
	var node := layout_node(scene_root)
	if node == null:
		return {}
	var local := node.to_local(global_pos)
	var best := {}
	for p in all_plots(scene_root):
		if not only_ids.is_empty() and not (str(p.id) in only_ids):
			continue
		if point_violation(p, local) > 0.0:
			continue
		if best.is_empty() or p.area < best.area:
			best = p
	return best


## The server-assigned plot_id meta, else the plot its origin stands in.
static func plot_for_object(scene_root: Node, obj: Node3D) -> Dictionary:
	if obj == null:
		return {}
	var plot := plot_by_id(scene_root, str(obj.get_meta("plot_id", "")))
	if plot.is_empty():
		plot = plot_at(scene_root, obj.global_position)
	return plot


static func is_enforced(scene_root: Node, obj: Node3D) -> bool:
	if obj == null or not obj.has_meta("is_plot_object"):
		return false
	return not sandbox(scene_root)


static func sandbox(scene_root: Node) -> bool:
	if scene_root == null:
		return true
	var vis = scene_root.get_node_or_null("PlotUIVisibility")
	if vis != null and vis.get("offline_sandbox") == true:
		return true
	return false


## From the server's plots_info.
static func owned_plot_ids(scene_root: Node) -> Array:
	var nc = _network_controller(scene_root)
	if nc != null and nc.get("workspace") != null:
		return nc.workspace.owned_plot_ids()
	return []


static func _network_controller(scene_root: Node) -> Node:
	if scene_root == null:
		return null
	var nc = scene_root.get_node_or_null("/root/NetworkController")
	if nc == null:
		nc = scene_root.get_tree().root.find_child("NetworkController", true, false)
	return nc


static func polygon_area(poly: PackedVector2Array) -> float:
	var area := 0.0
	for i in poly.size():
		area += poly[i].cross(poly[(i + 1) % poly.size()])
	return absf(area) * 0.5


static func polygon_centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	if poly.is_empty():
		return c
	for p in poly:
		c += p
	return c / float(poly.size())


static func distance_to_boundary(poly: PackedVector2Array, p: Vector2) -> float:
	var best := INF
	var n := poly.size()
	for i in n:
		var q := Geometry2D.get_closest_point_to_segment(p, poly[i], poly[(i + 1) % n])
		best = minf(best, p.distance_to(q))
	return best


## 0 inside; else horizontal distance plus overshoot below the floor or above the ceiling.
static func point_violation(plot: Dictionary, p: Vector3) -> float:
	var poly: PackedVector2Array = plot.poly
	if poly.size() < 3:
		return 0.0
	var p2 := Vector2(p.x, p.z)
	var v := 0.0
	if not Geometry2D.is_point_in_polygon(p2, poly):
		v += distance_to_boundary(poly, p2)
	var floor_y := float(plot.get("floor", -INF))
	var ceiling_y := float(plot.get("ceiling", INF))
	if p.y < floor_y:
		v += floor_y - p.y
	elif p.y > ceiling_y:
		v += p.y - ceiling_y
	return v


static func violation(plot: Dictionary, corners: PackedVector3Array) -> float:
	var worst := 0.0
	for c in corners:
		worst = maxf(worst, point_violation(plot, c))
	return worst


static func fits(plot: Dictionary, corners: PackedVector3Array) -> bool:
	return violation(plot, corners) <= EPS


static func corners_global(local_aabb: AABB, xform: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in 8:
		out.append(xform * local_aabb.get_endpoint(i))
	return out


## Layout-local corners as if the object had `xform`.
static func corners_local(scene_root: Node, obj: Node3D, xform: Transform3D) -> PackedVector3Array:
	var node := layout_node(scene_root)
	var aabb := BuildSelectable.get_aabb(obj)
	var out := PackedVector3Array()
	for c in corners_global(aabb, xform):
		out.append(node.to_local(c) if node != null else c)
	return out


## Allows any move no further outside than `current`, else the first partial move that fits.
static func constrain(scene_root: Node, obj: Node3D, desired: Transform3D, current: Transform3D) -> Transform3D:
	if not is_enforced(scene_root, obj):
		return desired
	var plot := plot_for_object(scene_root, obj)
	if plot.is_empty():
		return desired
	var limit := violation(plot, corners_local(scene_root, obj, current)) + EPS
	if violation(plot, corners_local(scene_root, obj, desired)) <= limit:
		return desired
	var d := desired.origin - current.origin
	var masks := [Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3.ZERO]
	var candidates: Array[Transform3D] = []
	for m in masks:
		candidates.append(Transform3D(desired.basis, current.origin + d * m))
	candidates.append(Transform3D(current.basis, desired.origin))
	for m in masks:
		candidates.append(Transform3D(current.basis, current.origin + d * m))
	for c in candidates:
		if c.is_equal_approx(current):
			continue
		if violation(plot, corners_local(scene_root, obj, c)) <= limit:
			return c
	return current


static func apply(scene_root: Node, obj: Node3D, desired: Transform3D) -> Transform3D:
	var allowed := constrain(scene_root, obj, desired, obj.global_transform)
	obj.global_transform = allowed
	return allowed


static func fits_object(scene_root: Node, obj: Node3D, xform: Transform3D, plot: Dictionary) -> bool:
	if plot.is_empty():
		return false
	return fits(plot, corners_local(scene_root, obj, xform))


## Keeps x/z and rotation; returns `xform` unchanged when nothing is underneath.
static func drop_to_floor(scene_root: Node, obj: Node3D, xform: Transform3D, max_drop := 1000.0) -> Transform3D:
	if obj == null or obj.get_world_3d() == null:
		return xform
	var aabb := BuildSelectable.get_aabb(obj)
	var center: Vector3 = xform * aabb.get_center()
	var extent := BuildSnapping.support_extent(xform.basis, aabb, Vector3.UP)
	var bottom := center - Vector3.UP * extent
	var from := bottom + Vector3.UP * (extent + 0.05)
	var query := PhysicsRayQueryParameters3D.create(from, bottom + Vector3.DOWN * max_drop)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = BuildTargeting.collision_rids(obj)
	var hit := obj.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return xform
	var out := xform
	out.origin.y += hit.position.y - bottom.y
	return out


## Origin and corners in workspace-local units plus the claimed plot id, for the server.
static func payload(scene_root: Node, obj: Node3D, xform: Transform3D) -> Dictionary:
	var node := layout_node(scene_root)
	var origin: Vector3 = node.to_local(xform.origin) if node != null else xform.origin
	var footprint := []
	for c in corners_local(scene_root, obj, xform):
		footprint.append([snappedf(c.x, 0.01), snappedf(c.y, 0.01), snappedf(c.z, 0.01)])
	var plot := plot_for_object(scene_root, obj)
	return {
		"plot_id": str(plot.get("id", obj.get_meta("plot_id", ""))),
		"local": {"x": snappedf(origin.x, 0.01), "y": snappedf(origin.y, 0.01), "z": snappedf(origin.z, 0.01)},
		"footprint": footprint,
	}
