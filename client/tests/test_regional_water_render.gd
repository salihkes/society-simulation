extends SceneTree
## GPU smoke test: compile both water paths and both terrain shaders, then
## verify freezing changes the rendered surface. Run without --headless.
var materials: Array[ShaderMaterial] = []
func _initialize(): run.call_deferred()
func shot(path: String) -> Image:
	await process_frame
	await process_frame
	RenderingServer.force_draw()
	var image := root.get_texture().get_image()
	image.save_png(path)
	return image
func run():
	root.size = Vector2i(960, 640)
	var world := Node3D.new()
	world.scale = Vector3.ONE * 0.2
	root.add_child(world)
	current_scene = world
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 220, 280)
	camera.look_at(world.to_global(Vector3.ZERO))
	camera.current = true
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.1, 0.15, 0.2)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.65
	world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-65, 20, 0)
	world.add_child(sun)
	var files := ["water/sea_water.gdshader", "water/water_shader.gdshader", "region/terrain.gdshader", "geo/city_terrain.gdshader"]
	for i in files.size():
		var mesh := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(150, 150)
		plane.subdivide_width = 40
		plane.subdivide_depth = 40
		mesh.mesh = plane
		var material: ShaderMaterial
		if i == 0:
			material = load("res://assets/world/water/sea_water_material.tres").duplicate()
		else:
			material = ShaderMaterial.new()
			material.shader = load("res://src/world/" + files[i])
		materials.append(material)
		mesh.material_override = material
		mesh.position = Vector3(-80 if i % 2 == 0 else 80, 0, -80 if i < 2 else 80)
		world.add_child(mesh)
		material.set_shader_parameter("regional_enabled", true)
		material.set_shader_parameter("regional_scale", 0.2)
		material.set_shader_parameter("regional_values", PackedVector4Array([Vector4.ZERO, Vector4.ZERO, Vector4.ZERO, Vector4.ZERO, Vector4.ZERO]))
	var clear := await shot("/tmp/regional-water-clear.png")
	for material in materials:
		material.set_shader_parameter("regional_values", PackedVector4Array([Vector4(0,0,1,0), Vector4(0,0,1,0), Vector4(0,0,1,0), Vector4(0,0,1,0), Vector4(0,0,1,0)]))
	var frozen := await shot("/tmp/regional-water-frozen.png")
	var difference := 0.0
	# Rear two tiles are water; verify a substantial on-screen change.
	for y in range(120, 320, 4):
		for x in range(160, 800, 4):
			var a := clear.get_pixel(x, y)
			var b := frozen.get_pixel(x, y)
			difference += absf(a.r-b.r) + absf(a.g-b.g) + absf(a.b-b.b)
	print("REGIONAL WATER RENDER: image difference = ", difference)
	world.queue_free()
	await process_frame
	quit(0 if difference > 50 else 1)
