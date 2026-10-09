extends SceneTree
## Builds a city's source scene (city.scn) from its .glb: every mesh carries
## its own trimesh collision (StaticBody3D/CollisionShape3D, layer 1), except
## the glazing, which gets its glass here instead. The chunk bake reads this
## scene, not the .glb.
##
##   godot --headless --path client -s res://tools/build_city_scene.gd -- \
##     res://assets/art/models/<city>/<city>.glb res://assets/art/models/<city>/city.scn Export_Glass

const MobileGlass = preload("res://src/world/environment/mobile_glass.gd")
const GLASS_SHADER := preload("res://src/world/environment/city_glass.gdshader")


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.size() < 3:
		print("CITY usage: -- <source.glb> <out.scn> <glazing node name>")
		quit(1)
		return
	var src := argv[0]
	var out := argv[1]
	var glass := argv[2]
	var world := (load(src) as PackedScene).instantiate() as Node3D
	root.add_child(world)
	await process_frame
	# Tells the bake and the runtime swap which node is the glazing.
	world.set_meta(MobileGlass.GLASS_META, glass)

	var made := {}
	var panes := 0
	var bodies := 0
	var faces := 0
	for node in world.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		if String(mi.name).begins_with(glass):
			# A copy, so the glass is saved with this scene and not lost as an
			# unchanged reference into the imported .glb.
			var mesh := mi.mesh.duplicate() as Mesh
			for s in mesh.get_surface_count():
				var paint := mesh.surface_get_material(s) as BaseMaterial3D
				if paint == null:
					continue
				if not made.has(paint):
					made[paint] = MobileGlass.desktop_glass(paint, GLASS_SHADER)
				mesh.surface_set_material(s, made[paint])
				panes += 1
			mi.mesh = mesh
			continue
		if mi.get_node_or_null("StaticBody3D") != null:
			continue
		var body := StaticBody3D.new()
		body.name = "StaticBody3D"
		var shape := CollisionShape3D.new()
		shape.name = "CollisionShape3D"
		shape.shape = mi.mesh.create_trimesh_shape()
		body.add_child(shape)
		mi.add_child(body)
		body.owner = world
		shape.owner = world
		bodies += 1
		faces += (shape.shape as ConcavePolygonShape3D).get_faces().size() / 3
	print("CITY %s: %d glass surfaces on %s*, %d static bodies, %d collision faces" % [
		src, panes, glass, bodies, faces])
	if panes == 0:
		print("CITY ABORT: no glazing named %s*" % glass)
		quit(1)
		return

	var scene := PackedScene.new()
	if scene.pack(world) != OK:
		print("CITY ABORT: pack failed")
		quit(1)
		return
	var err := ResourceSaver.save(scene, out, ResourceSaver.FLAG_COMPRESS)
	print("CITY wrote %s err=%d" % [out, err])
	quit(0 if err == OK else 1)
