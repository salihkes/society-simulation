extends SceneTree
## The city glass swap: every surface of the city's glazing mesh is replaced,
## tints are preserved, other meshes are left alone, and the source materials
## are never modified. Desktop gets the Fresnel/transmission shader; the
## headset gets plain alpha glass with no screen read.
const GlassScript = preload("res://src/world/environment/mobile_glass.gd")

var failures := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + label)

func _initialize() -> void:
	run.call_deferred()

func panes(name: String, colors: Array) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var mesh := ArrayMesh.new()
	for c in colors:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	mi.mesh = mesh
	return mi

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world

	# Blue panes, a grey frame and a warm one: all part of the glazing mesh.
	var glass := panes("model_001_2_-1", [Color(0.51, 0.74, 0.86),
		Color(0.39, 0.37, 0.38), Color(0.57, 0.29, 0.15)])
	world.add_child(glass)
	var other := panes("BuildsMosque", [Color(0.51, 0.74, 0.86)])
	world.add_child(other)

	var g = GlassScript.new()
	world.add_child(g)
	await process_frame
	await process_frame

	check(g.swapped == 3, "every surface of the glazing mesh is swapped, got %d" % g.swapped)
	for s in 3:
		check(glass.get_surface_override_material(s) != null, "surface %d overridden" % s)
	check(other.get_surface_override_material(0) == null, "other meshes are left alone")

	# Desktop: real glass, tinted per pane, double-sided like the authored panes.
	var first := glass.get_surface_override_material(0) as ShaderMaterial
	check(first != null and first.shader != null, "desktop glass is the glass shader")
	var code := first.shader.code
	check(code.contains("hint_screen_texture"), "light behind the pane is transmitted")
	check(code.contains("cull_disabled"), "panes are visible from inside and out")
	var t0: Vector3 = first.get_shader_parameter("tint")
	var t2: Vector3 = (glass.get_surface_override_material(2) as ShaderMaterial).get_shader_parameter("tint")
	check(t2.x > t0.x, "authored tints stay distinct")
	check(t0.x > 0.51 and t0.y > 0.74, "tint is lighter than the authored paint")

	# The override must not have touched the mesh's own materials.
	check((glass.mesh.surface_get_material(0) as BaseMaterial3D).albedo_color.a == 1.0,
		"source material left opaque and unmodified")

	# Starting again must not duplicate the queue or signal connection.
	g.start()
	var late := panes("model_001_3_0", [Color(0.51, 0.74, 0.86)])
	world.add_child(late)
	await process_frame
	await process_frame
	check(g.swapped == 4, "late-loaded glazing is swapped exactly once")
	check(late.get_surface_override_material(0) != null, "late-loaded glazing gets glass")

	g.queue_free()
	await process_frame

	# Headset: plain alpha, no screen read or pre-pass on a tiled GPU.
	var vr = GlassScript.new()
	vr.use_shader = false
	var vr_panes := panes("model_001_9_9", [Color(0.51, 0.74, 0.86), Color(0.57, 0.29, 0.15)])
	world.add_child(vr_panes)
	world.add_child(vr)
	await process_frame
	await process_frame
	var vm := vr_panes.get_surface_override_material(0) as StandardMaterial3D
	check(vm != null, "headset glass is a StandardMaterial3D")
	check(vm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA, "headset glass is alpha blended")
	check(not vm.refraction_enabled, "no screen-space refraction on the headset")
	check(vm.albedo_color.a < 1.0, "headset panes are see-through")
	check(vm.albedo_texture == null, "headset glass has no sheen or grime texture")
	var vwarm := vr_panes.get_surface_override_material(1) as StandardMaterial3D
	check(vwarm.albedo_color.r > vm.albedo_color.r, "headset tints stay distinct")
	vr.queue_free()

	world.queue_free()
	await process_frame
	print("MOBILE GLASS: %d failures" % failures)
	quit(1 if failures else 0)
