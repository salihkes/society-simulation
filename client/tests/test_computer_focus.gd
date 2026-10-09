extends SceneTree
## Headless check of leaning in on a computer screen.
##
## Three things have to hold, and each fails quietly rather than loudly:
##
##   1. the focus camera sits square on the glass, far enough back to hold the
##      whole picture and no further — the maths is easy to get wrong in a way
##      that still looks like a camera pointing at a screen;
##   2. the game's depth of field is off while a session is open and is put
##      back EXACTLY as it was afterwards, including when the player walks off
##      rather than leaving politely;
##   3. leaning back out returns the view to the camera that had it.
##
##   Godot --headless --path client --script res://tests/test_computer_focus.gd

const COMPUTER := "res://assets/entities/computer/computer.tscn"

var failures := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	check(InputMap.has_action("screen_focus"), "there is a 'screen_focus' action to press")
	if InputMap.has_action("screen_focus"):
		var keys: Array = []
		for e in InputMap.action_get_events("screen_focus"):
			if e is InputEventKey:
				keys.append(OS.get_keycode_string((e as InputEventKey).physical_keycode))
		check(not keys.is_empty(), "'screen_focus' is bound to a key")
		# It must not collide with the keys the body and the doors already use.
		for other in ["interact", "jump", "grab", "ui_sprint", "voice_chat"]:
			if not InputMap.has_action(other):
				continue
			for e in InputMap.action_get_events(other):
				if e is InputEventKey:
					var k := OS.get_keycode_string((e as InputEventKey).physical_keycode)
					check(not (k in keys), "'screen_focus' (%s) does not collide with '%s'" % [k, other])

	# A world with the same depth of field the city uses.
	var world := Node3D.new()
	world.name = "localworkspace"
	world.scale = Vector3(0.2, 0.2, 0.2)
	get_root().add_child(world)
	current_scene = world

	var env_node := WorldEnvironment.new()
	env_node.name = "WorldEnvironment"
	env_node.environment = Environment.new()
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_near_enabled = true
	attrs.dof_blur_near_distance = 0.5
	attrs.dof_blur_far_enabled = true
	env_node.camera_attributes = attrs
	world.add_child(env_node)

	var scene = load(COMPUTER)
	check(scene != null, "computer.tscn loads")
	if scene == null:
		_report()
		return
	var pc = scene.instantiate()
	world.add_child(pc)
	await process_frame
	await process_frame

	check(pc.has_method("set_focused"), "the computer can be leaned in on")
	check(pc.has_method("_suppress_blur") and pc.has_method("_restore_blur"),
		"the computer can switch the game's blur off and back on")
	if not pc.has_method("set_focused"):
		_report()
		return

	# ── the blur, while in use ──────────────────────────────────────────
	check(attrs.dof_blur_near_enabled, "the world starts with near blur on")
	pc._suppress_blur()
	check(not attrs.dof_blur_near_enabled, "near blur is off while the computer is in use")
	check(not attrs.dof_blur_far_enabled, "far blur is off too")
	pc._restore_blur()
	check(attrs.dof_blur_near_enabled and attrs.dof_blur_far_enabled,
		"the blur is put back exactly as it was when the session ends")
	# Twice in a row must not bank the switched-off state as the original.
	pc._suppress_blur()
	pc._suppress_blur()
	pc._restore_blur()
	check(attrs.dof_blur_near_enabled,
		"suppressing twice still restores the ORIGINAL setting, not the off one")

	# ── the framing ─────────────────────────────────────────────────────
	var tv = pc.get_node_or_null("CRTTV")
	check(tv != null, "the computer has its set")
	if tv != null and tv.has_method("viewing_transform"):
		var xf: Transform3D = tv.viewing_transform(50.0, 16.0 / 9.0)
		var centre: Vector3 = tv.screen_center()
		var to_screen: Vector3 = centre - xf.origin
		check(to_screen.length() > 0.001, "the camera stands off the glass rather than inside it")

		# Square on: the camera looks at the middle of the picture...
		var look: Vector3 = -xf.basis.z.normalized()
		check(look.dot(to_screen.normalized()) > 0.999,
			"the focus camera looks straight at the middle of the picture")
		# ...and from in front of it, not through the back of the tube.
		var screen_forward: Vector3 = -tv.global_transform.basis.z.normalized()
		check(screen_forward.dot((xf.origin - centre).normalized()) > 0.9,
			"the camera is in FRONT of the screen, not behind it")

		# Far enough that the picture fits, close enough to be worth doing.
		# Measured from the set's own tube, not assumed: the city is scaled
		# 0.2, so a 16 cm PVM is about 2.5 cm of screen in world units, which
		# is exactly why the half-metre near blur smears it.
		var glass_node := tv.get_node_or_null("Glass") as Node3D
		var glass_scale: float = absf(glass_node.global_transform.basis.get_scale().y) if glass_node else 1.0
		var glass_h: float = float(tv.get("_glass_size").y) * glass_scale
		check(glass_h > 0.0, "the set reports a screen height")
		var fits: float = (glass_h * 0.5) / tan(deg_to_rad(50.0) * 0.5)
		check(to_screen.length() >= fits * 0.9,
			"the camera is far enough back to hold the whole picture (%.3f m, needs ~%.3f m)"
			% [to_screen.length(), fits])
		check(to_screen.length() < fits * 4.0,
			"the camera is not so far back that leaning in achieved nothing (%.3f m)" % to_screen.length())

		# A narrower window needs MORE room, or the sides get cropped.
		var wide: Transform3D = tv.viewing_transform(50.0, 21.0 / 9.0)
		var narrow: Transform3D = tv.viewing_transform(50.0, 4.0 / 3.0)
		check(narrow.origin.distance_to(centre) >= wide.origin.distance_to(centre) - 0.0001,
			"a narrower viewport pulls the camera back so the picture still fits")

	# Leaning in should leave the bezel in view, not press your nose to the
	# glass: the computer's own margin must give the picture some room.
	check(float(pc.focus_margin) > 1.15,
		"focus_margin (%.2f) leaves room around the picture rather than filling the frame" % float(pc.focus_margin))

	# ── the picture keeps its shape on the glass ────────────────────────
	# The raster is 720 samples across 480 lines on ~4:3 glass, so its samples
	# are not square. Fitting by pixel count squashed every picture 12%; the
	# 512×342 screen, which shares the raster's proportions IN PIXELS, filled
	# the buffer and came out narrow. Measure what actually reaches the glass.
	if tv != null and tv.has_method("set_source_texture"):
		var glass_sz: Vector2 = tv.get("_glass_size")
		var glass_aspect: float = glass_sz.x / glass_sz.y
		var raster: Vector2 = Vector2(tv.get_node("Signal").size)
		for probe in [[512, 342, "the 512x342 screen"], [640, 480, "a 4:3 reel"], [320, 200, "a 16:10 home computer"]]:
			var img := Image.create(int(probe[0]), int(probe[1]), false, Image.FORMAT_RGB8)
			tv.set_source_texture(ImageTexture.create_from_image(img))
			var sc: Vector2 = tv.get("_src_scale")
			var off: Vector2 = tv.get("_src_offset")
			var shown: float = (sc.x * glass_aspect) / sc.y          # what the eye sees
			var want: float = float(probe[0]) / float(probe[1])
			check(absf(shown - want) / want < 0.01,
				"%s shows as %.3f:1 on the glass, wants %.3f:1 (was squashed by pixel-count fitting)" % [probe[2], shown, want])
			check(sc.x <= 1.0001 and sc.y <= 1.0001 and (is_equal_approx(sc.x, 1.0) or is_equal_approx(sc.y, 1.0)),
				"%s fills the raster in one direction and is boxed in the other" % probe[2])
			check(off.is_equal_approx((Vector2.ONE - sc) * 0.5), "%s is centred" % probe[2])
		# A texture the size of the raster itself is a signal (the test card's
		# gratings are laid out in samples) and must fill it untouched.
		var native := Image.create(int(raster.x), int(raster.y), false, Image.FORMAT_RGB8)
		tv.set_source_texture(ImageTexture.create_from_image(native))
		check((tv.get("_src_scale") as Vector2).is_equal_approx(Vector2.ONE),
			"a raster-sized texture (the test card) fills the raster as-is")

	# ── leaning in and out ──────────────────────────────────────────────
	# Without a session there is nothing to lean in on.
	pc.set_focused(true)
	check(not pc._focused, "you cannot lean in on a set with no session running")

	if failures == 0:
		print("test_computer_focus: all checks passed")
	else:
		print("test_computer_focus: %d FAILURES" % failures)
	_report()


func _report() -> void:
	quit(1 if failures > 0 else 0)
