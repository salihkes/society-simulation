extends SceneTree
## Headless check of media_projection.gd — the filename/aspect semantics that
## decide whether a video wraps around you and which half each eye gets.
## Run: godot --headless --script tools/verify_projection.gd

const MP := preload("res://src/media/media_projection.gd")

var failures := 0


func _init() -> void:
	# --- filename detection -------------------------------------------------
	_det("holiday.mp4", MP.Screen.FLAT, MP.Layout.MONO)
	_det("Movie.2019.1080p.mkv", MP.Screen.FLAT, MP.Layout.MONO)
	_det("clip_360_4k.mp4", MP.Screen.SPHERE360, MP.Layout.MONO)
	_det("trip360.mp4", MP.Screen.SPHERE360, MP.Layout.MONO)
	_det("dive 360 TB.mkv", MP.Screen.SPHERE360, MP.Layout.TB)
	_det("rollercoaster_360_ou.mp4", MP.Screen.SPHERE360, MP.Layout.TB)
	_det("concert_VR180.mp4", MP.Screen.DOME180, MP.Layout.MONO)   # hint resolves later
	_det("concert_180_sbs.mp4", MP.Screen.DOME180, MP.Layout.SBS)
	_det("film.3D.HSBS.1080p.mkv", MP.Screen.FLAT, MP.Layout.SBS)
	_det("film-sbs.mp4", MP.Screen.FLAT, MP.Layout.SBS)
	_det("film_ou.mkv", MP.Screen.FLAT, MP.Layout.TB)
	_det("equirectangular_test.webm", MP.Screen.SPHERE360, MP.Layout.MONO)
	_det("360_video_mono.mp4", MP.Screen.SPHERE360, MP.Layout.MONO)
	# Tokenizer honesty: digits inside a longer digit run must not match.
	_det("R2D2 1802 restoration.mp4", MP.Screen.FLAT, MP.Layout.MONO)

	# --- 360 camera naming conventions (no tag in sight) --------------------
	_det("360_0005_Stitch_XHC_av1.mp4", MP.Screen.SPHERE360, MP.Layout.MONO)
	_det("VID_20250223_142400_00_067_av1.mp4", MP.Screen.SPHERE360, MP.Layout.MONO)
	_det("CAM_20260728194450_0088_D_av1.mp4", MP.Screen.SPHERE360, MP.Layout.MONO)
	_det("VID_20250223_142400_00_067.mp4", MP.Screen.SPHERE360, MP.Layout.MONO)
	_det("CAM_20260728194450_0088_D.mp4", MP.Screen.SPHERE360, MP.Layout.MONO)
	# An ordinary phone video has no index tail — it must stay flat.
	_det("VID_20250223_142400.mp4", MP.Screen.FLAT, MP.Layout.MONO)
	_det("CAM_holiday.mp4", MP.Screen.FLAT, MP.Layout.MONO)
	# The frame has veto power over the naming convention: 2:1 keeps the
	# sphere, any other shape (mis-named flat file, unstitched dual-fisheye)
	# plays flat — and never trips the stereo guesses.
	_ref("VID_20250223_142400_00_067_av1.mp4", 5760, 2880, MP.Screen.SPHERE360, MP.Layout.MONO)
	_ref("CAM_20260728194450_0088_D_av1.mp4", 7680, 3840, MP.Screen.SPHERE360, MP.Layout.MONO)
	_ref("VID_20250223_142400_00_067_av1.mp4", 1920, 1080, MP.Screen.FLAT, MP.Layout.MONO)
	_ref("VID_20250223_142400_00_067_av1.mp4", 2880, 2880, MP.Screen.FLAT, MP.Layout.MONO)
	# An explicit tag is NOT demotable — only the camera hint is.
	_ref("holiday_360.mp4", 1920, 1080, MP.Screen.SPHERE360, MP.Layout.MONO)
	# "3d" alone: stereo hint, no layout yet.
	var d3 := MP.detect("film.3D.2010.mkv")
	_check("3d sets stereo_hint", bool(d3.stereo_hint) and int(d3.layout) == MP.Layout.MONO)

	# --- aspect refinement --------------------------------------------------
	_ref("a_360.mp4", 3840, 1920, MP.Screen.SPHERE360, MP.Layout.MONO)   # 2:1 stays mono
	_ref("a_360.mp4", 3840, 3840, MP.Screen.SPHERE360, MP.Layout.TB)     # 1:1 -> stacked eyes
	_ref("a_360.mp4", 7680, 1920, MP.Screen.SPHERE360, MP.Layout.SBS)    # 4:1 -> side by side
	_ref("b_vr180.mp4", 3840, 1920, MP.Screen.DOME180, MP.Layout.SBS)    # VR180 2:1 -> SBS
	_ref("b_180_mono.mp4", 1920, 1920, MP.Screen.DOME180, MP.Layout.MONO)
	_ref("c_3d.mkv", 3840, 1080, MP.Screen.FLAT, MP.Layout.SBS)          # 32:9 full SBS
	_ref("c_3d.mkv", 1920, 2160, MP.Screen.FLAT, MP.Layout.TB)           # stacked frame
	# A tag is never overridden by the aspect.
	_ref("d_360_sbs.mp4", 3840, 1920, MP.Screen.SPHERE360, MP.Layout.SBS)
	# Flat untagged never becomes immersive, whatever the shape.
	_ref("landscape_pan.mp4", 3840, 1920, MP.Screen.FLAT, MP.Layout.MONO)

	# --- eye geometry -------------------------------------------------------
	_eq("full SBS eye aspect", MP.eye_aspect(32.0 / 9.0, MP.Layout.SBS), 16.0 / 9.0)
	_eq("half SBS eye aspect", MP.eye_aspect(16.0 / 9.0, MP.Layout.SBS), 16.0 / 9.0)
	_eq("full TB eye aspect", MP.eye_aspect(8.0 / 9.0, MP.Layout.TB), 16.0 / 9.0)
	_eq("half TB eye aspect", MP.eye_aspect(16.0 / 9.0, MP.Layout.TB), 16.0 / 9.0)
	_check("SBS left crop", MP.eye_crop(MP.Layout.SBS, 0) == Rect2(0, 0, 0.5, 1))
	_check("SBS right crop", MP.eye_crop(MP.Layout.SBS, 1) == Rect2(0.5, 0, 0.5, 1))
	_check("TB left eye is the TOP half", MP.eye_crop(MP.Layout.TB, 0) == Rect2(0, 0, 1, 0.5))
	_check("TB right eye is the bottom", MP.eye_crop(MP.Layout.TB, 1) == Rect2(0, 0.5, 1, 0.5))
	_check("mono crop is everything", MP.eye_crop(MP.Layout.MONO, 0) == Rect2(0, 0, 1, 1))

	_check("labels", MP.label(MP.Screen.FLAT, MP.Layout.MONO) == "Flat"
		and MP.label(MP.Screen.SPHERE360, MP.Layout.TB) == "360·3D"
		and MP.label(MP.Screen.DOME180, MP.Layout.SBS) == "180·3D")

	if failures == 0:
		print("verify_projection: ALL OK")
	else:
		print("verify_projection: %d FAILURES" % failures)
	quit(1 if failures > 0 else 0)


func _det(fname: String, screen: int, layout: int) -> void:
	var d := MP.detect(fname)
	_check("detect(%s) -> %s" % [fname, MP.label(screen, layout)],
		int(d.screen) == screen and int(d.layout) == layout)


func _ref(fname: String, w: int, h: int, screen: int, layout: int) -> void:
	var d := MP.refine(MP.detect(fname), w, h)
	_check("refine(%s, %dx%d) -> %s" % [fname, w, h, MP.label(screen, layout)],
		int(d.screen) == screen and int(d.layout) == layout)


func _eq(what: String, got: float, wanted: float) -> void:
	_check("%s (%f vs %f)" % [what, got, wanted], absf(got - wanted) < 0.0001)


func _check(what: String, ok: bool) -> void:
	if ok:
		print("  ok: ", what)
	else:
		failures += 1
		printerr("FAIL: ", what)
