@tool
extends Node3D

## Editor-authored ambient layout: Zone*, Lane*, Tram*, District_<n>, Light*, Plot_<id> shapes of Marker3D points.

const LaneGraphScript := preload("res://src/life/lane_graph.gd")
const LayoutScript := preload("res://src/life/ambient_layout.gd")

const PREVIEW_LIFT := 0.4
const PLOT_TOP_MARKER := "top"
const DEFAULT_LIGHT_RADIUS := 60.0

@export var preview_in_game := false
## Side offset of a generated return lane.
@export var two_way_offset := 7.0
## Workspace units (5 per metre).
@export var plot_height := 50.0

@export_tool_button("Add Walk Zone") var _btn_add_zone: Callable = _add_zone
@export_tool_button("Add Traffic Lane") var _btn_add_lane: Callable = _add_lane
@export_tool_button("Add Tram Line") var _btn_add_tram: Callable = _add_tram
@export_tool_button("Add Traffic Light") var _btn_add_light: Callable = _add_light
@export_tool_button("Add District (rename node = its name)") var _btn_add_district: Callable = _add_district
@export_tool_button("Add Plot (rename node = Plot_<id>)") var _btn_add_plot: Callable = _add_plot
@export_tool_button("Add Reverse Lane (two-way) for selected") var _btn_two_way: Callable = _add_reverse_of_selected
@export_tool_button("Reverse selected lane direction") var _btn_reverse: Callable = _reverse_selected
@export_tool_button("Snap all points to ground") var _btn_snap: Callable = _snap_all_to_ground
@export_tool_button("Import JSON layout (user://)") var _btn_import: Callable = _import_json

var _preview: MeshInstance3D = null
var _mesh: ImmediateMesh = null
var _last_sig := 0


func _ready():
	if Engine.is_editor_hint() or preview_in_game:
		_ensure_preview()
		set_process(true)
	else:
		set_process(false)


func _process(_delta):
	var sig := _signature()
	if sig != _last_sig:
		_last_sig = sig
		_redraw()


func zones() -> Array:
	var out := []
	for shape in get_children():
		if _is_zone(shape):
			var pts := _shape_points(shape)
			if pts.size() >= 3:
				out.append(pts)
	return out


## Child order is driving direction.
func lanes() -> Array:
	var out := []
	for shape in get_children():
		if _is_lane(shape):
			var pts := _shape_points(shape)
			if pts.size() >= 2:
				out.append(pts)
	return out


func _is_kind(node: Node, prefix: String) -> bool:
	return node is Node3D and str(node.name).to_lower().begins_with(prefix)


func _is_zone(node: Node) -> bool:
	return _is_kind(node, "zone")


func _is_lane(node: Node) -> bool:
	return _is_kind(node, "lane")


func _is_tram(node: Node) -> bool:
	return _is_kind(node, "tram")


func _is_light(node: Node) -> bool:
	return _is_kind(node, "light")


func _is_district(node: Node) -> bool:
	return _is_kind(node, "district")


func _is_plot(node: Node) -> bool:
	return _is_kind(node, "plot")


## [{"id", "name", "points", "floor", "ceiling"}]; a Top child sets the ceiling, else plot_height.
func plots() -> Array:
	var out := []
	for shape in get_children():
		if not _is_plot(shape):
			continue
		var plot := _plot_of(shape)
		if not plot.is_empty():
			out.append(plot)
	return out


func _plot_of(shape: Node) -> Dictionary:
	var pts := PackedVector3Array()
	var top := NAN
	for child in shape.get_children():
		if not (child is Node3D):
			continue
		var lp := to_local((child as Node3D).global_position)
		if str(child.name).to_lower() == PLOT_TOP_MARKER:
			top = lp.y
		else:
			pts.append(lp)
	if pts.size() < 3:
		return {}
	var floor_y := INF
	for p in pts:
		floor_y = minf(floor_y, p.y)
	var ceiling_y := top if not is_nan(top) else floor_y + plot_height
	var pid := plot_id_of(str(shape.name))
	return {"id": pid, "name": pid.replace("_", " "), "points": pts,
		"floor": floor_y, "ceiling": maxf(ceiling_y, floor_y + 1.0)}


## "Plot_corner_house" -> "corner_house"; a bare "Plot1" keeps its whole name.
static func plot_id_of(node_name: String) -> String:
	if node_name.to_lower().begins_with("plot_"):
		var rest := node_name.substr(5).strip_edges()
		if rest != "":
			return rest
	return node_name


func districts() -> Array:
	var out := []
	for shape in get_children():
		if not _is_district(shape):
			continue
		var pts := _shape_points(shape)
		if pts.size() >= 3:
			out.append({"name": _district_display_name(str(shape.name)), "points": pts})
	return out


## "District_Old_Town" -> "Old Town".
static func _district_display_name(node_name: String) -> String:
	var n := node_name.substr("district".length())
	n = n.trim_prefix("_").trim_prefix(" ")
	return n.replace("_", " ").strip_edges()


func trams() -> Array:
	var out := []
	for shape in get_children():
		if _is_tram(shape):
			var pts := _shape_points(shape)
			if pts.size() >= 2:
				out.append(pts)
	return out


## A Light's first Node3D child is its radius handle (min 5).
func signals_data() -> Array:
	var out := []
	for child in get_children():
		if not _is_light(child):
			continue
		var light := child as Node3D
		var pos := to_local(light.global_position)
		var radius := DEFAULT_LIGHT_RADIUS
		for sub in light.get_children():
			if sub is Node3D:
				radius = maxf(5.0, pos.distance_to(to_local((sub as Node3D).global_position)))
				break
		out.append({"pos": pos, "radius": radius})
	return out


func _shape_points(shape: Node3D) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for child in shape.get_children():
		if child is Node3D:
			pts.append(to_local((child as Node3D).global_position))
	return pts


func _editor() -> Object:
	if not Engine.is_editor_hint():
		return null
	if Engine.has_singleton("EditorInterface"):
		return Engine.get_singleton("EditorInterface")
	return null


## 24 units ahead of the editor camera (or this node's origin), dropped to the ground.
func _spawn_anchor() -> Vector3:
	return _drop_to_ground(_camera_ahead())


func _camera_ahead() -> Vector3:
	var ei := _editor()
	if not ei:
		return Vector3.ZERO
	var vp = ei.get_editor_viewport_3d(0)
	if not vp:
		return Vector3.ZERO
	var cam: Camera3D = vp.get_camera_3d()
	if not cam:
		return Vector3.ZERO
	return to_local(cam.global_position - cam.global_basis.z * 24.0)


## Searched from 100 units above; `local_p` itself when nothing is hit.
func _drop_to_ground(local_p: Vector3) -> Vector3:
	if get_world_3d() == null:
		return local_p
	var gp := to_global(local_p)
	var query := PhysicsRayQueryParameters3D.create(gp + Vector3.UP * 100.0, gp + Vector3.DOWN * 1000.0)
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return local_p
	return to_local(result.position)


func _unique_name(prefix: String) -> String:
	var i := 1
	while get_node_or_null(prefix + str(i)) != null:
		i += 1
	return prefix + str(i)


## Gives an owner so the scene saves them.
func _register(node: Node):
	var root: Node = null
	var ei := _editor()
	if ei:
		root = ei.get_edited_scene_root()
	if root == null:
		root = owner if owner != null else self
	node.owner = root
	for child in node.get_children():
		child.owner = root


func _select_in_editor(node: Node):
	var ei := _editor()
	if ei:
		var sel = ei.get_selection()
		sel.clear()
		sel.add_node(node)


func _spawn_shape(prefix: String, offsets: Array, snap: bool) -> Node3D:
	var anchor := _spawn_anchor()
	var shape := Node3D.new()
	shape.name = _unique_name(prefix)
	add_child(shape)
	shape.position = anchor
	for offset in offsets:
		var m := Marker3D.new()
		m.name = "P" + str(shape.get_child_count() + 1)
		shape.add_child(m)
		m.position = offset
	_register(shape)
	if snap:
		_snap_shape_to_ground(shape)
	_select_in_editor(shape)
	return shape


func _add_zone():
	var shape := _spawn_shape("Zone", [Vector3(-12, 0, -12), Vector3(12, 0, -12),
		Vector3(12, 0, 12), Vector3(-12, 0, 12)], true)
	print("[AmbientLayout] Added ", shape.name, " — drag its markers; add points with Ctrl+D")


func _add_lane():
	var shape := _spawn_shape("Lane",
		[Vector3(0, 0, 0), Vector3(0, 0, -30), Vector3(0, 0, -60)], true)
	print("[AmbientLayout] Added ", shape.name, " — child order is the driving direction")


func _add_tram():
	var shape := _spawn_shape("Tram",
		[Vector3(0, 0, 0), Vector3(0, 0, -120), Vector3(0, 0, -240)], true)
	print("[AmbientLayout] Added ", shape.name, " — a tram shuttles between its end points")


func _add_district():
	var shape := _spawn_shape("District_Yeni_Mahalle", [Vector3(-60, 0, -60),
		Vector3(60, 0, -60), Vector3(60, 0, 60), Vector3(-60, 0, 60)], false)
	print("[AmbientLayout] Added ", shape.name,
		" — RENAME the node to name the place (District_<name>, underscores = spaces)")


func _add_plot():
	var shape := _spawn_shape("Plot_new_plot_", [Vector3(-20, 0, -20),
		Vector3(20, 0, -20), Vector3(20, 0, 20), Vector3(-20, 0, 20)], true)
	print("[AmbientLayout] Added ", shape.name,
		" — RENAME it Plot_<id> and give <id> an owner in the server's data/plots.json;",
		" add a Marker3D named Top to set its ceiling")


func _add_light():
	var anchor := _spawn_anchor()
	var light := Node3D.new()
	light.name = _unique_name("Light")
	add_child(light)
	light.position = anchor
	var handle := Marker3D.new()
	handle.name = "Radius"
	light.add_child(handle)
	handle.position = Vector3(DEFAULT_LIGHT_RADIUS, 0, 0)
	_register(light)
	_select_in_editor(light)
	print("[AmbientLayout] Added ", light.name,
		" — every lane END inside its circle obeys it; drag the Radius marker to size it")


func _selected_lane() -> Node3D:
	var ei := _editor()
	if ei == null:
		return null
	for node in ei.get_selection().get_selected_nodes():
		var n: Node = node
		if n.get_parent() == self and _is_lane(n):
			return n
		if n.get_parent() != null and n.get_parent().get_parent() == self and _is_lane(n.get_parent()):
			return n.get_parent()
	return null


func _reverse_selected():
	var lane := _selected_lane()
	if lane == null:
		push_warning("[AmbientLayout] Select a Lane node (or one of its points) first")
		return
	var children := lane.get_children()
	for i in children.size():
		lane.move_child(children[children.size() - 1 - i], i)
	print("[AmbientLayout] Reversed direction of ", lane.name)


func _add_reverse_of_selected():
	var lane := _selected_lane()
	if lane == null:
		push_warning("[AmbientLayout] Select a Lane node (or one of its points) first")
		return
	var pts := _shape_points(lane)
	if pts.size() < 2:
		return
	var rev: PackedVector3Array = LaneGraphScript.reversed_offset(pts, two_way_offset)
	var shape := _shape_from_points("Lane", rev)
	_select_in_editor(shape)
	print("[AmbientLayout] Added return lane ", shape.name, " for ", lane.name)


func _snap_all_to_ground():
	for shape in get_children():
		if shape is Node3D and (_is_zone(shape) or _is_lane(shape) or _is_plot(shape)):
			_snap_shape_to_ground(shape)
	print("[AmbientLayout] Snapped all points to ground")


func _snap_shape_to_ground(shape: Node3D):
	for child in shape.get_children():
		if not (child is Node3D):
			continue
		var c := child as Node3D
		if _is_plot(shape) and str(c.name).to_lower() == PLOT_TOP_MARKER:
			continue
		var local_in_container := to_local(c.global_position)
		c.global_position = to_global(_drop_to_ground(local_in_container))


func _import_json():
	var ws_name: String = str(get_parent().name) if get_parent() else "localworkspace"
	var layout = LayoutScript.new()
	layout.load_from(str(ws_name))
	if layout.zones.is_empty() and layout.lanes.is_empty():
		push_warning("[AmbientLayout] No JSON layout found for '%s'" % ws_name)
		return
	for zone in layout.zones:
		_shape_from_points("Zone", zone)
	for lane in layout.lanes:
		_shape_from_points("Lane", lane)
	print("[AmbientLayout] Imported %d zones, %d lanes from JSON" %
		[layout.zones.size(), layout.lanes.size()])


func _shape_from_points(prefix: String, pts: PackedVector3Array) -> Node3D:
	var shape := Node3D.new()
	shape.name = _unique_name(prefix)
	add_child(shape)
	for i in pts.size():
		var m := Marker3D.new()
		m.name = "P" + str(i + 1)
		shape.add_child(m)
		m.global_position = to_global(pts[i])
	_register(shape)
	return shape


func _signature() -> int:
	var parts := PackedStringArray()
	for shape in get_children():
		if not (shape is Node3D and (_is_zone(shape) or _is_lane(shape) or _is_tram(shape)
				or _is_light(shape) or _is_district(shape) or _is_plot(shape))):
			continue
		parts.append(str(shape.name))
		for child in shape.get_children():
			if child is Node3D:
				parts.append(str((child as Node3D).global_position))
	return "|".join(parts).hash()


func _ensure_preview():
	if _preview != null and is_instance_valid(_preview):
		return
	_mesh = ImmediateMesh.new()
	_preview = MeshInstance3D.new()
	_preview.name = "_PreviewDoNotSave"
	_preview.mesh = _mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_preview.material_override = mat
	add_child(_preview)
	# No owner, so it is never saved into the scene.


func _redraw():
	_ensure_preview()
	_mesh.clear_surfaces()

	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for shape in get_children():
		if _is_zone(shape):
			_fill_zone(_shape_points(shape))
	for p in plots():
		_fill_zone(p.points, Color(1.0, 0.6, 0.15, 0.18))
	# A surface may not be empty.
	_mesh.surface_set_color(Color.TRANSPARENT)
	for i in 3:
		_mesh.surface_add_vertex(Vector3.ZERO)
	_mesh.surface_end()

	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for shape in get_children():
		if _is_zone(shape):
			_outline(_shape_points(shape), Color(0.2, 1.0, 0.4), true)
		elif _is_tram(shape):
			_lane_lines(_shape_points(shape), Color(1.0, 0.85, 0.2))
		elif _is_lane(shape):
			_lane_lines(_shape_points(shape), Color(0.3, 0.7, 1.0))
		elif _is_district(shape):
			_outline(_shape_points(shape), Color(0.85, 0.3, 0.9), true)
	for p in plots():
		_plot_volume(p, Color(1.0, 0.6, 0.15))
	for sig in signals_data():
		_signal_circle(sig.pos, sig.radius)
	_mesh.surface_set_color(Color.TRANSPARENT)
	_mesh.surface_add_vertex(Vector3.ZERO)
	_mesh.surface_add_vertex(Vector3.ZERO)
	_mesh.surface_end()


func _fill_zone(zone: PackedVector3Array, color := Color(0.2, 0.9, 0.35, 0.2)):
	if zone.size() < 3:
		return
	var poly2 := PackedVector2Array()
	for p in zone:
		poly2.append(Vector2(p.x, p.z))
	var indices := Geometry2D.triangulate_polygon(poly2)
	if indices.is_empty():
		poly2.reverse()
		indices = Geometry2D.triangulate_polygon(poly2)
		if indices.is_empty():
			return
		var n := zone.size()
		var remapped := PackedInt32Array()
		for idx in indices:
			remapped.append(n - 1 - idx)
		indices = remapped
	_mesh.surface_set_color(color)
	for idx in indices:
		var p: Vector3 = zone[idx]
		_mesh.surface_add_vertex(p + Vector3.UP * PREVIEW_LIFT)


func _plot_volume(plot: Dictionary, color: Color):
	var pts: PackedVector3Array = plot.points
	if pts.size() < 3:
		return
	_outline(pts, color, true)
	var top := PackedVector3Array()
	for p in pts:
		top.append(Vector3(p.x, float(plot.ceiling), p.z))
	_mesh.surface_set_color(color.darkened(0.25))
	var n := top.size()
	for i in n:
		_mesh.surface_add_vertex(top[i])
		_mesh.surface_add_vertex(top[(i + 1) % n])
		_mesh.surface_add_vertex(pts[i] + Vector3.UP * PREVIEW_LIFT)
		_mesh.surface_add_vertex(top[i])


func _outline(points: PackedVector3Array, color: Color, closed: bool):
	if points.size() < 2:
		return
	_mesh.surface_set_color(color)
	var lift := Vector3.UP * (PREVIEW_LIFT + 0.1)
	for i in range(points.size() - 1):
		_mesh.surface_add_vertex(points[i] + lift)
		_mesh.surface_add_vertex(points[i + 1] + lift)
	if closed and points.size() >= 3:
		_mesh.surface_add_vertex(points[points.size() - 1] + lift)
		_mesh.surface_add_vertex(points[0] + lift)
	for p in points:
		_mesh.surface_add_vertex(p + lift)
		_mesh.surface_add_vertex(p + lift + Vector3.UP * 2.0)


func _signal_circle(pos: Vector3, radius: float):
	_mesh.surface_set_color(Color(1.0, 0.6, 0.1))
	var lift := Vector3.UP * (PREVIEW_LIFT + 0.15)
	var steps := 32
	for i in steps:
		var a0 := TAU * float(i) / float(steps)
		var a1 := TAU * float(i + 1) / float(steps)
		_mesh.surface_add_vertex(pos + lift + Vector3(cos(a0), 0, sin(a0)) * radius)
		_mesh.surface_add_vertex(pos + lift + Vector3(cos(a1), 0, sin(a1)) * radius)
	_mesh.surface_add_vertex(pos + lift)
	_mesh.surface_add_vertex(pos + lift + Vector3.UP * 14.0)


func _lane_lines(points: PackedVector3Array, color: Color):
	_outline(points, color, false)
	if points.size() < 2:
		return
	_mesh.surface_set_color(color)
	var lift := Vector3.UP * (PREVIEW_LIFT + 0.1)
	for i in range(points.size() - 1):
		var a: Vector3 = points[i]
		var b: Vector3 = points[i + 1]
		var fwd := b - a
		fwd.y = 0.0
		if fwd.length_squared() < 0.001:
			continue
		fwd = fwd.normalized()
		var right := fwd.cross(Vector3.UP)
		var mid := (a + b) * 0.5 + lift
		_mesh.surface_add_vertex(mid)
		_mesh.surface_add_vertex(mid - fwd * 2.5 + right * 1.5)
		_mesh.surface_add_vertex(mid)
		_mesh.surface_add_vertex(mid - fwd * 2.5 - right * 1.5)
