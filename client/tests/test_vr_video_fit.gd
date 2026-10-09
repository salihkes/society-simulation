extends SceneTree
## Compare compositor dimensions (tracking-space meters) with the actual
## scene quad projected back through a scaled XR origin. No headset needed.
const PanelScript := preload("res://src/ui/vr_chat_panel.gd")
const CHAT := "res://assets/ui/chat_ui.tscn"
var failures := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + label)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var origin := Node3D.new()
	world.add_child(origin)
	origin.rotation = Vector3(0.2, 0.4, -0.1)
	var camera := Camera3D.new()
	origin.add_child(camera)
	camera.position = Vector3(0.1, 1.7, -0.1)
	var chat = (load(CHAT) as PackedScene).instantiate()
	world.add_child(chat)
	var panel := PanelScript.new()
	world.add_child(panel)
	panel.attach_chat(chat)
	panel._target_camera = camera
	panel.set_process(false)
	panel.set_panel_visible(true)
	panel.shell.show_player("Fit regression")
	panel.video.layer = OpenXRCompositionLayerQuad.new()
	panel.add_child(panel.video.layer)
	panel.video.layer_r = OpenXRCompositionLayerQuad.new()
	panel.add_child(panel.video.layer_r)
	panel.video.subtitle_layer = OpenXRCompositionLayerQuad.new()
	panel.add_child(panel.video.subtitle_layer)
	panel.video.subtitle_viewport = SubViewport.new()
	panel.video.subtitle_viewport.size = Vector2i(1280, 220)
	panel.add_child(panel.video.subtitle_viewport)
	for world_scale in [0.2, 0.6, 1.0, 3.0]:
		origin.scale = Vector3.ONE * world_scale
		XRServer.world_origin = origin.global_transform
		for user_scale in [0.45, 1.0, 2.2]:
			panel.user_scale = user_scale
			panel._place(camera)
			for aspect in [4.0 / 3.0, 16.0 / 9.0, 2.39, 9.0 / 16.0]:
				panel.video.aspect = aspect
				panel.video.align()
				await process_frame
				await process_frame
				panel.video.align()
				var r: Rect2 = panel.shell.video_area_rect()
				var local_size: Vector2 = r.size / Vector2(panel.VIEWPORT_SIZE) * panel.PANEL_SIZE
				var in_tracking_space := origin.global_transform.affine_inverse() * panel.quad.global_transform
				var rendered_size := Vector2(in_tracking_space.basis.x.length(), in_tracking_space.basis.y.length()) * local_size
				var layer := panel.video.layer as OpenXRCompositionLayerQuad
				var label := "world=%s resize=%s aspect=%s" % [world_scale, user_scale, aspect]
				check(layer.quad_size.distance_to(rendered_size) < 0.002 * maxf(1.0, rendered_size.length()), "video fills container: " + label)
				check(is_equal_approx(layer.quad_size.x / layer.quad_size.y, aspect), "video preserves aspect: " + label)
				check(layer.quad_size == panel.video.layer_r.quad_size, "both eyes align: " + label)
				# Subtitles should remain inside the picture even after resizing.
				var sub_offset: float = absf(panel.video.subtitle_layer.position.y - layer.position.y) * in_tracking_space.basis.y.length()
				check(sub_offset + panel.video.subtitle_layer.quad_size.y * 0.5 <= layer.quad_size.y * 0.5 + 0.001, "subtitles inside resized picture: " + label)
	XRServer.world_origin = Transform3D.IDENTITY
	world.queue_free()
	await process_frame
	print("VR VIDEO FIT: %d failures" % failures)
	quit(1 if failures else 0)
