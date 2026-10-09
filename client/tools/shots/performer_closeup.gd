extends SceneTree
## Close-ups of one performer at several times, for judging poses and costumes.
##   THEATER_PLAY=kata_reel CLOSE_WHO=Chorus2 CLOSE_TIMES="1,10" CLOSE_OUT=/tmp/shot \
##   Godot --resolution 1000x700 --path client --script res://tools/shots/performer_closeup.gd
## Saves <CLOSE_OUT>_<who>_<time>.png from a three-quarter view in front of the figure.
## CLOSE_SOLO=1 hides the other cast members for an unobstructed fit inspection.
## CLOSE_FILL=1 adds a camera fill light for inspecting poses in dark scenes.
func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var scene: Node = load("res://assets/scenes/theater_rehearsal.tscn").instantiate()
	root.add_child(scene)
	await create_timer(1.5).timeout
	var show = scene.get_node("Performance")
	var cam: Camera3D = scene.get_node("Camera3D")
	if OS.get_environment("CLOSE_FILL") == "1":
		var fill := OmniLight3D.new()
		fill.light_energy = 1.5
		fill.omni_range = 20.0
		cam.add_child(fill)
	show.pause()
	var who := OS.get_environment("CLOSE_WHO")
	var out := OS.get_environment("CLOSE_OUT")
	for t in OS.get_environment("CLOSE_TIMES").split(",", false):
		show.seek(float(t))
		var target: Node3D = null
		for p in show.performers:
			if p.name == who:
				target = p
		if OS.get_environment("CLOSE_SOLO") == "1":
			for p in show.performers:
				p.visible = p == target
		var s: float = show.global_basis.get_scale().y
		var side := target.global_basis.x.normalized()
		var fwd := target.global_basis.z.normalized()
		var focus: Vector3 = target.global_position + Vector3.UP * 2.0 * s
		cam.global_position = focus + (fwd * 7.0 + side * -2.0 + Vector3.UP * 3.0) * s
		cam.look_at(focus)
		await physics_frame
		await physics_frame
		await RenderingServer.frame_post_draw
		var path := "%s_%s_%s.png" % [out, who, t.strip_edges()]
		root.get_texture().get_image().save_png(path)
		print("saved ", path)
	quit()
