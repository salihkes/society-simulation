extends SceneTree
## GPU verification and review images, runnable on Compatibility or Forward+.
const Cover = preload("res://src/world/environment/snow_cover.gd")
class Owner extends Node:
	func _owns_weather(): return true
var failures := 0
func check(ok: bool, label: String):
	if not ok:
		failures += 1
		push_error("FAIL: " + label)
func _initialize(): run.call_deferred()
func shot(path: String) -> Image:
	await process_frame
	RenderingServer.force_draw()
	var img := root.get_texture().get_image()
	img.save_png(path)
	return img
func run():
	root.size = Vector2i(1000, 750)
	var world := Node3D.new()
	world.scale = Vector3.ONE * 0.2
	root.add_child(world)
	current_scene = world
	var owner := Owner.new()
	world.add_child(owner)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(3.8, 4.2, 7.2)
	camera.look_at(Vector3(3.8, 0, 3.5))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 7.7
	camera.current = true
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.28, 0.32, 0.38)
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.75, 0.82, 1.0)
	env.environment.ambient_light_energy = 0.2
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-23, -48, 0)
	sun.light_energy = 0.65
	sun.shadow_enabled = true
	root.add_child(sun)
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	shape.shape.size = Vector3(40,0.2,40)
	floor_body.add_child(shape)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.mesh.size = shape.shape.size
	mesh.material_override = StandardMaterial3D.new()
	mesh.material_override.albedo_color = Color(0.12,0.13,0.15)
	floor_body.add_child(mesh)
	root.add_child(floor_body)
	floor_body.position.y = -0.1
	var cover = Cover.new()
	cover.weather = owner
	cover.patch_radius = 1
	world.add_child(cover)
	cover.set_physics_process(false)
	cover.state.set_depth(0.12)
	cover.state.melt = 0.0
	await physics_frame
	await physics_frame
	cover.advance(0.0, true)
	print("SNOW RENDER building ",cover._queue.size()," patches")
	var frames := 0
	while not cover._queue.is_empty() and frames < 1200:
		cover._physics_process(0.016)
		frames += 1
		if frames % 50 == 0: print("SNOW RENDER build frame ",frames," remaining=",cover._queue.size())
		await process_frame
	check(cover._queue.is_empty(), "snow surface finishes budgeted build")
	cover._update_materials()
	var clean := await shot("/tmp/snow-clean.png")
	for i in 12:
		cover.state.stamp(Vector3(1.4 + (0.13 if i % 2 else -0.13),0,1.0 + i * 0.4), 0,0.16,0.3)
	for i in 22:
		for x in [3.4, 4.7]:
			cover.state.stamp(Vector3(x,0,0.8+i*0.25),0,0.24,0.35,true)
	cover.advance(0.0,true)
	var marked := await shot("/tmp/snow-tracks.png")
	cover.refresh_surfaces()
	cover._physics_process(0.016)
	var rebuilding := await shot("/tmp/snow-refresh.png")
	check(marked.get_data() == rebuilding.get_data(), "refresh leaves the displayed snow and tracks pixel-identical while rebuilding")
	var changed := 0
	var darkened := 0
	for y in clean.get_height():
		for x in clean.get_width():
			var a := clean.get_pixel(x,y).get_luminance()
			var b := marked.get_pixel(x,y).get_luminance()
			if absf(a-b) > 0.015: changed += 1
			if a-b > 0.03: darkened += 1
	check(changed > 1000 and darkened > 300, "footprints and tire depressions appear in the rendered surface")
	print("SNOW RENDER changed=",changed," darkened=",darkened," build_frames=",frames)
	cover.state.set_depth(0.0)
	cover.advance(0.0,false)
	var clear := await shot("/tmp/snow-melted.png")
	check(clear.get_pixel(500,450).get_luminance() < clean.get_pixel(500,450).get_luminance() * 0.8, "zero snow exposes original road")
	print("SNOW RENDER: %d failures" % failures)
	quit(1 if failures else 0)
