class_name MediaProjection
extends RefCounted
## Works out a video's projection (flat, 180, 360) and stereo layout from filename tags, then frame aspect.

enum Screen { FLAT, DOME180, SPHERE360 }
enum Layout { MONO, SBS, TB }

## Tokens split on non-alphanumerics and letter/digit edges, plus adjacent pairs ("vr" + "180").
const SPHERE_TOKENS: PackedStringArray = ["360", "equirect", "equirectangular", "spherical", "pano", "panorama"]
const DOME_TOKENS: PackedStringArray = ["180", "vr180"]
const SBS_TOKENS: PackedStringArray = ["sbs", "hsbs", "fsbs", "lr", "lrf", "3dh", "halfsbs", "sidebyside"]
const TB_TOKENS: PackedStringArray = ["tb", "ou", "htb", "ftb", "3dv", "overunder", "topbottom", "tab", "bt"]
const MONO_TOKENS: PackedStringArray = ["mono", "2d"]
## "3d" alone says stereo without saying which split; the aspect decides later.
const STEREO_TOKENS: PackedStringArray = ["3d", "stereo", "stereoscopic"]


## Consumer 360 camera file names (no "360" tag); only a hint, refine() checks for 2:1.
const CAMERA_360_PATTERNS: PackedStringArray = [
	"(?i)^vid_\\d{8}_\\d{6}_\\d{2}_\\d{3}",   # Insta360: VID_date_time_00_067
	"(?i)^cam_\\d{12,14}_\\d{3,4}(_|$)",      # Kandao/QooCam: CAM_ts_0088_D
]


static func _camera_360_name(base: String) -> bool:
	for p in CAMERA_360_PATTERNS:
		var re := RegEx.create_from_string(p)
		if re != null and re.search(base) != null:
			return true
	return false


## Returns {screen, layout, stereo_hint, camera_hint}; refine() resolves the hints.
static func detect(filename: String) -> Dictionary:
	var base := filename.get_file().get_basename()
	var tokens := _tokens_of(base)
	var out := {"screen": Screen.FLAT, "layout": Layout.MONO, "stereo_hint": false}
	for t in tokens:
		if SPHERE_TOKENS.has(t):
			out.screen = Screen.SPHERE360
		elif DOME_TOKENS.has(t):
			out.screen = Screen.DOME180
	if int(out.screen) == Screen.FLAT and _camera_360_name(base):
		out.screen = Screen.SPHERE360
		out.camera_hint = true
	for t in tokens:
		if SBS_TOKENS.has(t):
			out.layout = Layout.SBS
		elif TB_TOKENS.has(t):
			out.layout = Layout.TB
	if out.layout == Layout.MONO:
		for t in tokens:
			if MONO_TOKENS.has(t):
				return out          # explicitly mono: stop guessing
			if STEREO_TOKENS.has(t):
				out.stereo_hint = true
	# Untagged VR180 is usually SBS; refine() decides from the aspect.
	if out.screen == Screen.DOME180 and out.layout == Layout.MONO:
		out.stereo_hint = true
	return out


## w, h with pixel aspect applied (0, 0 if unknown); fills only what the filename left open.
static func refine(det: Dictionary, w: int, h: int) -> Dictionary:
	var out := det.duplicate()
	if w <= 0 or h <= 0:
		return out
	var aspect := float(w) / float(h)
	if bool(out.get("camera_hint", false)):
		# Stitched 360 is 2:1 mono; flat or 1:1 dual fisheye play flat. 16:9 must miss the tolerance.
		if absf(aspect - 2.0) > 0.1:
			out.screen = Screen.FLAT
		return out
	if out.layout == Layout.MONO and (out.stereo_hint or out.screen != Screen.FLAT):
		out.layout = _layout_from_aspect(out, aspect)
	return out


static func _layout_from_aspect(det: Dictionary, aspect: float) -> int:
	match int(det.screen):
		Screen.SPHERE360:
			# Mono 360 is 2:1; stacked eyes give 1:1, side by side 4:1.
			if absf(aspect - 1.0) < 0.2:
				return Layout.TB
			elif absf(aspect - 4.0) < 0.5:
				return Layout.SBS
		Screen.DOME180:
			# One 180 eye is square, so two side by side are 2:1.
			if absf(aspect - 2.0) < 0.3:
				return Layout.SBS
			elif absf(aspect - 1.0) < 0.2 and not bool(det.get("stereo_hint", false)):
				return Layout.MONO
		Screen.FLAT:
			# Tagged only "3D": 32:9 is SBS, squarish (8:9) is TB.
			if aspect > 2.6:
				return Layout.SBS
			elif aspect < 1.2:
				return Layout.TB
	return det.layout


## Half-size SBS/TB keep the frame aspect per eye; full-size ones (32:9, 8:9) are halved or doubled.
static func eye_aspect(full_aspect: float, layout: int) -> float:
	match layout:
		Layout.SBS:
			return full_aspect * 0.5 if full_aspect > 2.35 else full_aspect
		Layout.TB:
			return full_aspect * 2.0 if full_aspect < 1.2 else full_aspect
	return full_aspect


## v=0 at the top; eye 0 is left, stored on the left (SBS) or on top (TB).
static func eye_crop(layout: int, eye: int) -> Rect2:
	match layout:
		Layout.SBS:
			return Rect2(0.5 * eye, 0.0, 0.5, 1.0)
		Layout.TB:
			return Rect2(0.0, 0.5 * eye, 1.0, 0.5)
	return Rect2(0, 0, 1, 1)


## Only needs to be sharp at the layer's angular size; the decoder scales into it.
static func eye_surface_size(screen: int, layout: int) -> Vector2i:
	match screen:
		Screen.SPHERE360:
			return Vector2i(2880, 1440)     # 2:1, spread over the sphere
		Screen.DOME180:
			return Vector2i(1920, 1920)     # square eye ahead of you
	return Vector2i(1920, 1080)             # one flat eye, same as the 2D path


static func is_immersive(screen: int) -> bool:
	return screen != Screen.FLAT


static func is_stereo(layout: int) -> bool:
	return layout != Layout.MONO


## Short label for the Screen button: "Flat", "3D", "360", "180·3D"...
static func label(screen: int, layout: int) -> String:
	var s := ""
	match screen:
		Screen.SPHERE360: s = "360"
		Screen.DOME180: s = "180"
		_: s = "Flat"
	if layout != Layout.MONO:
		s += "·3D"
	return s


static func _tokens_of(base: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var cur := ""
	var cur_digit := false
	for ch in base.to_lower():
		var is_alnum: bool = (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9")
		var is_digit: bool = ch >= "0" and ch <= "9"
		if not is_alnum or (not cur.is_empty() and is_digit != cur_digit):
			if not cur.is_empty():
				out.append(cur)
			cur = ""
		if is_alnum:
			cur += ch
			cur_digit = is_digit
	if not cur.is_empty():
		out.append(cur)
	var joined: PackedStringArray = out.duplicate()
	for i in out.size() - 1:
		joined.append(out[i] + out[i + 1])
	return joined
