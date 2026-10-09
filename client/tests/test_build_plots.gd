extends SceneTree
## Headless check of the plot rules: Plot_<id> polygons read from an
## AmbientLayout node, point/footprint containment, the clamp that keeps a
## plot object inside its polygon (sliding along edges, never trapping an
## object that is already out), and the server payload.
##
##   Godot --headless --path client --script res://tests/test_build_plots.gd

const LayoutNodeScript := preload("res://src/life/ambient_layout_node.gd")
const PlotsScript := preload("res://src/build/core/build_plots.gd")

var failures := 0
var ws: Node3D
var layout: Node3D


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)


func _initialize() -> void:
	call_deferred("run")


func marker(parent: Node3D, name: String, pos: Vector3) -> void:
	var m := Marker3D.new()
	m.name = name
	parent.add_child(m)
	m.position = pos


func polygon(name: String, pts: Array, top := NAN) -> Node3D:
	var shape := Node3D.new()
	shape.name = name
	layout.add_child(shape)
	for i in pts.size():
		marker(shape, "P" + str(i + 1), pts[i])
	if not is_nan(top):
		marker(shape, "Top", Vector3(0, top, 0))
	return shape


## A 2x2x2 box (local AABB centred on the origin) with a collider.
func box(name: String) -> Node3D:
	var body := StaticBody3D.new()
	body.name = name
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2, 2, 2)
	mesh.mesh = bm
	body.add_child(mesh)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2, 2, 2)
	col.shape = shape
	body.add_child(col)
	ws.add_child(body)
	return body


func run() -> void:
	# Scene: a ws scaled like the city (0.2), the layout untransformed under it.
	ws = Node3D.new()
	ws.name = "localworkspace"
	ws.scale = Vector3(0.2, 0.2, 0.2)
	get_root().add_child(ws)
	current_scene = ws
	layout = LayoutNodeScript.new()
	layout.name = "AmbientLayout"
	layout.plot_height = 50.0
	ws.add_child(layout)

	# An L-shaped plot (irregular: a 40x40 square missing its +x/+z quarter)
	# and a small square plot with an explicit Top marker.
	polygon("Plot_house", [Vector3(0, 1, 0), Vector3(40, 1, 0), Vector3(40, 1, 20),
		Vector3(20, 1, 20), Vector3(20, 1, 40), Vector3(0, 1, 40)])
	polygon("Plot_shed", [Vector3(100, 0, 100), Vector3(110, 0, 100), Vector3(110, 0, 110), Vector3(100, 0, 110)], 8.0)
	polygon("Zone1", [Vector3(-50, 0, -50), Vector3(-10, 0, -50), Vector3(-10, 0, -10)])   # not a plot
	polygon("Plot_broken", [Vector3(0, 0, 0), Vector3(1, 0, 0)])                           # < 3 points

	# Sandbox off: a PlotUIVisibility stand-in that says "online".
	var vis := Node.new()
	vis.name = "PlotUIVisibility"
	vis.set_script(load("res://tests/test_build_plots_vis_stub.gd"))
	ws.add_child(vis)

	await process_frame

	# ── layout node → plots ────────────────────────────────────────────
	var plots: Array = layout.plots()
	check(plots.size() == 2, "two valid plots (got %d)" % plots.size())
	var by_id := {}
	for p in plots:
		by_id[p.id] = p
	check(by_id.has("house") and by_id.has("shed"), "plot ids come from the Plot_ suffix: " + str(by_id.keys()))
	check(by_id.house.points.size() == 6, "L-plot keeps its six points")
	check(is_equal_approx(by_id.house.floor, 1.0) and is_equal_approx(by_id.house.ceiling, 51.0), "floor = lowest point, ceiling = floor + plot_height")
	check(by_id.shed.points.size() == 4, "Top marker is not a polygon point")
	check(is_equal_approx(by_id.shed.ceiling, 8.0), "Top marker sets the ceiling (got %f)" % by_id.shed.ceiling)
	check(LayoutNodeScript.plot_id_of("Plot1") == "Plot1" and LayoutNodeScript.plot_id_of("Plot_a_b") == "a_b", "plot_id_of")

	# ── containment ───────────────────────────────────────────────────
	var all: Array = PlotsScript.all_plots(ws)
	check(all.size() == 2 and all[0].has("poly") and all[0].has("area"), "all_plots adds poly + area")
	var house: Dictionary = PlotsScript.plot_by_id(ws, "house")
	check(is_equal_approx(house.area, 1200.0), "L-plot area 1200 (got %f)" % house.area)
	check(PlotsScript.point_violation(house, Vector3(10, 5, 10)) == 0.0, "inside the L")
	check(PlotsScript.point_violation(house, Vector3(30, 5, 30)) > 0.0, "the missing quarter is outside")
	check(is_equal_approx(PlotsScript.point_violation(house, Vector3(10, 60, 10)), 9.0), "above the ceiling by 9")
	check(is_equal_approx(PlotsScript.point_violation(house, Vector3(-3, 5, 10)), 3.0), "3 units past the west edge")
	check(PlotsScript.plot_at(ws, ws.to_global(Vector3(10, 5, 10))).id == "house", "plot_at finds the plot from a global point")
	check(PlotsScript.plot_at(ws, ws.to_global(Vector3(30, 5, 30))).is_empty(), "plot_at: nothing in the notch")
	check(PlotsScript.plot_at(ws, ws.to_global(Vector3(10, 5, 10)), ["shed"]).is_empty(), "plot_at honours the owned-id filter")

	# ── clamping ──────────────────────────────────────────────────────
	var piece := box("piece")
	piece.set_meta("is_plot_object", true)
	piece.set_meta("plot_id", "house")
	# 2-unit box at global scale 0.2: in layout units it is 2/0.2... no —
	# the box is a child of the scaled ws, so its local size IS 2 units.
	var at := func(local: Vector3) -> Transform3D:
		return Transform3D(ws.global_transform.basis, ws.to_global(local))
	piece.global_transform = at.call(Vector3(10, 2, 10))
	var corners := PlotsScript.corners_local(ws, piece, piece.global_transform)
	check(corners.size() == 8, "eight corners")
	check(PlotsScript.fits(house, corners), "box at (10,2,10) fits")

	var wanted: Transform3D = at.call(Vector3(-5, 2, 10))
	var got: Transform3D = PlotsScript.constrain(ws, piece, wanted, piece.global_transform)
	check(got.is_equal_approx(piece.global_transform), "a move straight out the west edge is refused")

	wanted = at.call(Vector3(-5, 2, 30))        # out west, but also north: slides along the edge
	got = PlotsScript.constrain(ws, piece, wanted, piece.global_transform)
	var got_local := ws.to_local(got.origin)
	check(is_equal_approx(got_local.x, 10.0) and is_equal_approx(got_local.z, 30.0), "slides along the edge (got %s)" % got_local)

	wanted = at.call(Vector3(10, 60, 10))       # through the ceiling
	got = PlotsScript.constrain(ws, piece, wanted, piece.global_transform)
	check(is_equal_approx(ws.to_local(got.origin).y, 2.0), "cannot rise through the ceiling")

	wanted = at.call(Vector3(10, 30, 10))       # floating is fine
	got = PlotsScript.constrain(ws, piece, wanted, piece.global_transform)
	check(is_equal_approx(ws.to_local(got.origin).y, 30.0), "floating inside the volume is allowed")

	wanted = at.call(Vector3(39.5, 2, 10))      # corner would poke out east
	got = PlotsScript.constrain(ws, piece, wanted, piece.global_transform)
	check(is_equal_approx(ws.to_local(got.origin).x, 10.0), "a corner poking out is refused (got %s)" % ws.to_local(got.origin))

	# A rotation that swings a corner out is refused; one that fits is kept.
	piece.global_transform = at.call(Vector3(1.0, 2, 10))   # touching the west edge
	var turned := Transform3D(piece.global_transform.basis.rotated(Vector3.UP, PI / 4), piece.global_transform.origin)
	got = PlotsScript.constrain(ws, piece, turned, piece.global_transform)
	check(got.basis.is_equal_approx(piece.global_transform.basis), "rotation that pokes out is refused")
	piece.global_transform = at.call(Vector3(10, 2, 10))
	turned = Transform3D(piece.global_transform.basis.rotated(Vector3.UP, PI / 4), piece.global_transform.origin)
	got = PlotsScript.constrain(ws, piece, turned, piece.global_transform)
	check(got.basis.is_equal_approx(turned.basis), "rotation that fits is kept")

	# Already outside: may come back in, may not go further out.
	piece.global_transform = at.call(Vector3(-5, 2, 10))
	got = PlotsScript.constrain(ws, piece, at.call(Vector3(-8, 2, 10)), piece.global_transform)
	check(is_equal_approx(ws.to_local(got.origin).x, -5.0), "an object outside cannot go further out")
	got = PlotsScript.constrain(ws, piece, at.call(Vector3(-2, 2, 10)), piece.global_transform)
	check(is_equal_approx(ws.to_local(got.origin).x, -2.0), "an object outside may come closer")

	# Not a plot object → never constrained; sandbox → never constrained.
	var scenery := box("scenery")
	scenery.global_transform = at.call(Vector3(10, 2, 10))
	got = PlotsScript.constrain(ws, scenery, at.call(Vector3(-50, 2, 10)), scenery.global_transform)
	check(is_equal_approx(ws.to_local(got.origin).x, -50.0), "scenery is free")
	vis.offline_sandbox = true
	got = PlotsScript.constrain(ws, piece, at.call(Vector3(-50, 2, 10)), piece.global_transform)
	check(is_equal_approx(ws.to_local(got.origin).x, -50.0), "offline sandbox is free")
	vis.offline_sandbox = false

	# ── floor drop ────────────────────────────────────────────────────
	var ground := box("ground")
	ground.global_transform = Transform3D(ws.global_transform.basis.scaled(Vector3(50, 1, 50)), ws.to_global(Vector3(10, 0, 10)))
	await physics_frame
	await physics_frame
	piece.global_transform = at.call(Vector3(10, 20, 10))
	# The scenery box (2 high, centred at y=2) still stands under the piece:
	# it lands on that first, then on the ground once the box is moved away.
	var dropped: Transform3D = PlotsScript.drop_to_floor(ws, piece, piece.global_transform)
	var dropped_local := ws.to_local(dropped.origin)
	check(is_equal_approx(dropped_local.y, 4.0), "drop_to_floor rests on the piece beneath (got %f)" % dropped_local.y)
	scenery.global_transform = at.call(Vector3(10, 2, -30))
	await physics_frame
	await physics_frame
	dropped = PlotsScript.drop_to_floor(ws, piece, piece.global_transform)
	dropped_local = ws.to_local(dropped.origin)
	# ground top is at local y = 1 (half-height 1); the piece's half-height is 1.
	check(is_equal_approx(dropped_local.y, 2.0), "drop_to_floor rests the box on the ground (got %f)" % dropped_local.y)
	check(is_equal_approx(dropped_local.x, 10.0) and is_equal_approx(dropped_local.z, 10.0), "drop keeps x/z")

	# ── payload ───────────────────────────────────────────────────────
	piece.global_transform = at.call(Vector3(10, 2, 10))
	var payload: Dictionary = PlotsScript.payload(ws, piece, piece.global_transform)
	check(payload.plot_id == "house", "payload names the plot")
	check(is_equal_approx(payload.local.x, 10.0) and is_equal_approx(payload.local.y, 2.0), "payload origin is workspace-local")
	check(payload.footprint.size() == 8, "payload carries eight corners")

	# ── every touched script still parses ─────────────────────────────
	for path in ["res://src/build/selection_manager.gd", "res://src/build/move_tool.gd",
			"res://src/build/rotate_tool.gd", "res://src/build/resize_tool.gd",
			"res://src/build/plot_object_tool.gd", "res://src/build/plot_object_sync.gd",
			"res://src/build/plot_ui_visibility.gd", "res://src/net/network_controller.gd",
			"res://src/life/ambient_manager.gd"]:
		var script = load(path)
		check(script != null and script.can_instantiate(), "compiles: " + path)

	# The build UI scene carries the new floor-snap controls.
	var ui_scene = load("res://assets/scenes/plot_ui.tscn")
	check(ui_scene != null, "plot_ui.tscn loads")
	if ui_scene != null:
		var ui = ui_scene.instantiate()
		check(ui.get_node_or_null("MoveTool/FloorSnap") != null and ui.get_node_or_null("MoveTool/DropToFloor") != null,
			"MoveTool has FloorSnap + DropToFloor")
		ui.free()

	if failures == 0:
		print("test_build_plots: all checks passed")
	else:
		print("test_build_plots: %d FAILURES" % failures)
	quit(1 if failures > 0 else 0)
