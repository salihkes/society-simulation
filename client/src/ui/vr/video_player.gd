class_name VRVideoPlayer
extends RefCounted
## A VR panel's video: the Android player, its composition layers, tracks, subtitles and resume point.

const AndroidPlayerScript = preload("res://src/media/android_media_player.gd")
const MediaProjectionScript = preload("res://src/media/media_projection.gd")
const MediaCatalogScript = preload("res://src/media/media_catalog.gd")
const MediaCommandsScript = preload("res://src/media/media_commands.gd")
const SubtitlesScript = preload("res://src/media/subtitles.gd")
const ReadingStateScript = preload("res://src/library/reading_state.gd")

## Far enough that head movement does not show, near enough to stay inside the sky.
const IMMERSIVE_RADIUS := 40.0
## The setters silently reject exactly PI/2 and keep the old value.
const EQUIRECT_VERTICAL := PI / 2.0 - 1e-4

# Stereo uses two layers, one per eye, fed by the media bridge's frame splitter.
var layer: OpenXRCompositionLayer = null       # mono, or the left eye
var layer_r: OpenXRCompositionLayer = null     # right eye, stereo only
var subtitle_layer: OpenXRCompositionLayerQuad = null
var subtitle_viewport: SubViewport = null
var aspect := 0.0
var screen_mode := MediaProjectionScript.Screen.FLAT

var _panel: VRPanel = null
## The video composites over all scene geometry, so the shell needs its own layer while a sphere is up.
var _ui_layer: OpenXRCompositionLayerQuad = null
## Black, so the world does not show where the video does not cover.
var _backdrop_layer: OpenXRCompositionLayerEquirect = null
var _backdrop_viewport: SubViewport = null
var _last_area_rect := Rect2() # re-align when the page reflows
var _surface = null
var _player = null
var _pending := ""
var _size := Vector2i.ZERO
var _subs = null
var _subs_on := true
var _fill := false
var _poll := 0.0
var _range: Dictionary = {}
var _resume_key := ""
var _resume_saved := 0.0
var _audio_tracks: Array = []
var _audio_index := 0
var _text_tracks: Array = []
var _text_index := -1
var _decoder_reported := false
var _tracks_settled := false
var _layout_mode := MediaProjectionScript.Layout.MONO
var _split := false
var _split_sent := [false, false]
var _immersive_anchor := Basis.IDENTITY
var _immersive_anchored := false
## Everything needed to reopen the current video after a mode switch.
var _open_args := {}
## {source, det}: a mode override for one source; empty trusts the filename.
var _forced_modes := {}
var _refined_once := false
var _pending_seek := -1
var _sub_label: Label = null


func _init(panel: VRPanel) -> void:
	_panel = panel


func open_range(archive_path: String, offset: int, size: int, title: String, cues = null) -> void:
	open(archive_path, title)
	_range = {"offset": offset, "size": size}
	# Each item of an archive needs its own resume key.
	_resume_key = "%s#%d" % [archive_path, offset]
	_open_args = {"source": archive_path, "title": title,
		"range": _range, "cues": cues}
	if cues != null:
		_subs = cues
		_panel.shell.set_player_cc_available(true)


## The shape comes from a Screen-menu override, else the filename; playback is Android-only.
func open(source: String, title: String) -> void:
	_range = {}
	close()
	_resume_key = source
	_open_args = {"source": source, "title": title}
	_pending_seek = -1
	_refined_once = false
	_panel.set_panel_visible(true)
	var shell: Control = _panel.shell
	shell.show_player(title)
	_subs = SubtitlesScript.load_sidecar(source)
	shell.set_player_cc_available(_subs != null)
	var det := _detect_modes(source)
	screen_mode = int(det.screen)
	_layout_mode = int(det.layout)
	shell.set_player_screen_label(MediaProjectionScript.label(screen_mode, _layout_mode))
	if not OS.has_feature("android"):
		shell.set_player_hint("%s\n(playback is Quest-only for now)" % title)
		return
	_split = MediaProjectionScript.is_stereo(_layout_mode)
	if _split and not AndroidPlayerScript.can_split():
		# Without the splitter neither eye can be cut out: play it flat.
		_split = false
		_layout_mode = MediaProjectionScript.Layout.MONO
		screen_mode = MediaProjectionScript.Screen.FLAT
		shell.set_player_screen_label(MediaProjectionScript.label(screen_mode, _layout_mode))
		_say("3D video needs the media3 build — playing flat.")
	_split_sent = [false, false]
	_build_layers()
	_pending = source
	_size = Vector2i.ZERO
	aspect = 0.0
	shell.set_player_hint("Loading...")
	align()


func _say(text: String) -> void:
	var chat: Control = _panel.chat_ui
	if chat and chat.has_method("add_message"):
		chat.add_message("System", text, true)


## {screen, layout, stereo_hint}; clears an override that belongs to another source.
func _detect_modes(source: String) -> Dictionary:
	if str(_forced_modes.get("source", "")) == source:
		return _forced_modes.det
	_forced_modes = {}
	if MediaCatalogScript.AUDIO_EXTS.has(source.get_extension().to_lower()):
		return {"screen": MediaProjectionScript.Screen.FLAT,
			"layout": MediaProjectionScript.Layout.MONO, "stereo_hint": false}
	return MediaProjectionScript.detect(source.get_file())


func _build_layers() -> void:
	_immersive_anchored = false
	layer = _make_layer(0 if _split else -1)
	# A runtime without equirect layers gets the flat quad instead.
	if MediaProjectionScript.is_immersive(screen_mode) \
			and not layer.is_natively_supported():
		_say("This runtime cannot composite 360° layers — playing flat.")
		layer.queue_free()
		screen_mode = MediaProjectionScript.Screen.FLAT
		_panel.shell.set_player_screen_label(MediaProjectionScript.label(screen_mode, _layout_mode))
		layer = _make_layer(0 if _split else -1)
	if _split:
		layer_r = _make_layer(1)
	if MediaProjectionScript.is_immersive(screen_mode):
		_build_backdrop_layer()
		_build_ui_layer()


## Eye -1 is both, 0 left, 1 right.
func _make_layer(eye: int) -> OpenXRCompositionLayer:
	var l: OpenXRCompositionLayer
	if MediaProjectionScript.is_immersive(screen_mode):
		l = OpenXRCompositionLayerEquirect.new()
	else:
		# Composited over the scene: the mobile renderer cannot write the
		# framebuffer alpha an underlay would need.
		l = OpenXRCompositionLayerQuad.new()
	# use_android_surface must be set before entering the tree; the other
	# setters need the live OpenXR handle they only get inside it.
	l.use_android_surface = true
	l.android_surface_size = \
			MediaProjectionScript.eye_surface_size(screen_mode, _layout_mode)
	_panel.add_child(l)
	l.sort_order = 2               # above the void backdrop (1)
	if eye == 0:
		l.eye_visibility = OpenXRCompositionLayer.EYE_VISIBILITY_LEFT
	elif eye == 1:
		l.eye_visibility = OpenXRCompositionLayer.EYE_VISIBILITY_RIGHT
	var eq := l as OpenXRCompositionLayerEquirect
	if eq != null:
		# Placed on the head by _place_immersive, not by the panel.
		eq.top_level = true
		eq.radius = IMMERSIVE_RADIUS
		eq.central_horizontal_angle = TAU \
			if screen_mode == MediaProjectionScript.Screen.SPHERE360 else PI
		eq.upper_vertical_angle = EQUIRECT_VERTICAL
		eq.lower_vertical_angle = EQUIRECT_VERTICAL
	VRPanel.apply_surface_flip(l)
	return l


## From a 16 px viewport rendered once.
func _build_backdrop_layer() -> void:
	if _backdrop_layer != null:
		return
	_backdrop_viewport = SubViewport.new()
	_backdrop_viewport.size = Vector2i(16, 16)
	_backdrop_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop_viewport.add_child(black)
	_panel.add_child(_backdrop_viewport)
	_backdrop_layer = OpenXRCompositionLayerEquirect.new()
	_panel.add_child(_backdrop_layer)
	_backdrop_layer.layer_viewport = _backdrop_viewport
	_backdrop_layer.sort_order = 1
	_backdrop_layer.top_level = true
	# Beyond the picture, for runtimes that depth-sort layers.
	_backdrop_layer.radius = IMMERSIVE_RADIUS * 1.5
	_backdrop_layer.central_horizontal_angle = TAU
	_backdrop_layer.upper_vertical_angle = EQUIRECT_VERTICAL
	_backdrop_layer.lower_vertical_angle = EQUIRECT_VERTICAL


## An immersive picture would otherwise bury the panel.
func _build_ui_layer() -> void:
	if _ui_layer != null or _panel.sub_viewport == null:
		return
	var xr := XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		return
	_ui_layer = OpenXRCompositionLayerQuad.new()
	_panel.add_child(_ui_layer)
	_ui_layer.layer_viewport = _panel.sub_viewport
	_ui_layer.sort_order = 4          # above picture (2) and subs (3)
	_ui_layer.alpha_blend = true
	_ui_layer.quad_size = _panel.composition_quad_size(VRPanel.PANEL_SIZE)


## Remembers the position.
func close() -> void:
	if _player:
		_remember_position()
		_player.release()
		_player = null
	_pending = ""
	_subs = null
	_free_layers()
	_split = false
	_split_sent = [false, false]
	_immersive_anchored = false
	_panel.end_remote_hide()
	_clear_subtitle_layer()
	if _panel.shell and _panel.shell.is_player_open():
		_panel.shell.set_subtitle("")


## Stores the position past 30 s; forgets it in the last minute.
func _remember_position() -> void:
	if _resume_key.is_empty():
		return
	var at: int = _player.position_ms()
	var total: int = _player.duration_ms()
	if total > 0 and at > total - 60000:
		ReadingStateScript.forget(_resume_key)
	elif at > 30000:
		ReadingStateScript.remember(_resume_key, at)


func _free_layers() -> void:
	if layer:
		layer.queue_free()
		layer = null
		_surface = null
	if layer_r:
		layer_r.queue_free()
		layer_r = null
	if _ui_layer:
		_ui_layer.queue_free()
		_ui_layer = null
	if _backdrop_layer:
		_backdrop_layer.queue_free()
		_backdrop_layer = null
	if _backdrop_viewport:
		_backdrop_viewport.queue_free()
		_backdrop_viewport = null


## The pointer then has the shell draw its cursor.
func is_immersive() -> bool:
	return layer != null and MediaProjectionScript.is_immersive(screen_mode)


func has_player() -> bool:
	return _player != null


func toggle() -> void:
	if _player == null:
		return
	if _player.state == AndroidPlayerScript.State.PLAYING:
		_player.pause()
	else:
		_player.play()


func pause() -> void:
	if _player:
		_player.pause()


func resume() -> void:
	if _player:
		_player.play()


func seek(ms: int) -> void:
	if _player:
		_player.seek_ms(ms)


func tracks() -> Array:
	return _player.track_info() if _player else []


func select_track(index: int) -> bool:
	return _player.select_track(index) if _player else false


func set_volume(linear: float) -> void:
	if _player:
		_player.set_volume(linear)


func set_subtitles_on(on: bool) -> void:
	_subs_on = on
	align()


func set_fill(fill: bool) -> void:
	_fill = fill
	align()


## While the page's own menu is open over the picture.
func set_picture_visible(on: bool) -> void:
	for l in [layer, layer_r]:
		if l:
			l.visible = on


## Every layer but the subtitles, which show themselves with their next cue.
func show_layers() -> void:
	for l in [layer, layer_r, _ui_layer, _backdrop_layer]:
		if l:
			l.visible = true


func hide_layers() -> void:
	for l in [layer, layer_r, _ui_layer, subtitle_layer, _backdrop_layer]:
		if l:
			l.visible = false


func hide_ui_layer() -> void:
	if _ui_layer:
		_ui_layer.visible = false


func process(delta: float) -> void:
	if _pending.is_empty() and _player == null:
		return
	# The page reflows a frame after it opens, so re-align when the area moves.
	if layer != null and _panel.shell != null:
		if MediaProjectionScript.is_immersive(screen_mode):
			_place_immersive()
		else:
			var r_now: Rect2 = _panel.shell.video_area_rect()
			if r_now.size.x > 2.0 and r_now != _last_area_rect:
				align()
	if not _pending.is_empty() and layer != null:
		_start_pending()
	if _player == null:
		return
	if _split:
		_route_split_outputs()
	_player.poll()
	_poll += delta
	if _poll < 0.25:
		return
	_poll = 0.0
	_poll_state()


## Mono waits for the layer's surface, which appears a few frames after it joins the session.
func _start_pending() -> void:
	if _split:
		var src_split := _pending
		_pending = ""
		_start_player(src_split, null)
		return
	if _surface == null:
		_surface = layer.get_android_surface()
	if _surface != null:
		var src := _pending
		_pending = ""
		_start_player(src, _surface)


func _poll_state() -> void:
	var pos: int = _player.position_ms()
	var playing: bool = _player.state == AndroidPlayerScript.State.PLAYING
	_panel.shell.update_player_time(pos, _player.duration_ms(), playing)
	# Saved as it plays, because a headset video usually ends by being taken off.
	if playing and not _resume_key.is_empty():
		_resume_saved += 0.25
		if _resume_saved >= 5.0:
			_resume_saved = 0.0
			ReadingStateScript.remember(_resume_key, pos)
	var sub_text := ""
	if _subs != null and _subs_on:
		sub_text = SubtitlesScript.cue_at(_subs, pos)
	if sub_text.is_empty() and _subs_on:
		sub_text = _player.subtitle()   # embedded, via media3
	_show_subtitle(sub_text)
	if not _tracks_settled:
		_refresh_tracks()
	var a: float = _player.video_aspect()
	if a > 0.0 and not is_equal_approx(a, aspect):
		aspect = a
		_size = _player.video_size()
		_maybe_refine()
		align()
	if _decoder_reported:
		return
	# Known only a moment after playback starts.
	var name: String = _player.audio_decoder()
	if not name.is_empty():
		_decoder_reported = true
		_say("Audio decoder: %s" % name)


## Seeks back after a mode switch, or resumes (not within the first 30 s or the last minute).
func _on_prepared(w: int, h: int, _dur: int) -> void:
	_size = Vector2i(w, h)
	_player.set_volume(_panel.shell.player_volume())
	if _pending_seek > 0:
		_player.seek_ms(_pending_seek)
		_pending_seek = -1
	else:
		var duration: int = _player.duration_ms()
		var was := int(ReadingStateScript.recall(_resume_key, 0))
		if was > 30000 and duration > 0 and was < duration - 60000:
			_player.seek_ms(was)
			_say("Resumed at %d:%02d." % [was / 60000, (was / 1000) % 60])
	_player.play()
	_maybe_refine()
	align()
	_report_audio()


## Into the splitter for stereo, else into surface.
func _start_player(src: String, surface) -> void:
	if _player:
		_player.release()
	_player = AndroidPlayerScript.new()
	_player.prepared.connect(_on_prepared)
	_player.failed.connect(func(msg): _panel.shell.set_player_hint("Failed: %s" % msg))
	_player.completed.connect(func(): _panel.shell.set_player_hint("Finished"))
	if _split:
		var off: int = int(_range.offset) if not _range.is_empty() else -1
		var sz: int = int(_range.size) if not _range.is_empty() else -1
		_player.open_split(src, off, sz, false)
	elif _range.is_empty():
		_player.open(src, surface, false)
	else:
		_player.open_range(src, int(_range.offset),
			int(_range.size), surface, false)


func _route_split_outputs() -> void:
	for eye in 2:
		if _split_sent[eye]:
			continue
		var l := layer if eye == 0 else layer_r
		if l == null:
			continue
		var surf = l.get_android_surface()
		if surf != null and _player.set_split_output(eye, surf,
				MediaProjectionScript.eye_crop(_layout_mode, eye)):
			_split_sent[eye] = true


## Orientation is taken once, level and facing where the player faced, then stays world-anchored.
func _place_immersive() -> void:
	var cam := _panel.tracked_camera()
	if cam == null or not is_instance_valid(cam):
		return
	if not _immersive_anchored:
		var up: Vector3 = cam.global_transform.basis.y
		var fwd: Vector3 = -cam.global_transform.basis.z
		fwd = fwd - up * fwd.dot(up)
		if fwd.length_squared() < 0.0001:
			return                          # looking straight down; next frame
		fwd = fwd.normalized()
		_immersive_anchor = Basis(fwd.cross(up).normalized(), up, -fwd).orthonormalized()
		_immersive_anchored = true
	for l in [layer, layer_r]:
		var eq := l as OpenXRCompositionLayerEquirect
		if eq != null:
			eq.global_transform = Transform3D(_immersive_anchor, cam.global_position)
			eq.radius = IMMERSIVE_RADIUS
	if _backdrop_layer != null:
		_backdrop_layer.global_transform = Transform3D(_immersive_anchor, cam.global_position)
		_backdrop_layer.radius = IMMERSIVE_RADIUS * 1.5


## Reopens the video if the frame's shape changes the filename's guess.
func _maybe_refine() -> void:
	if _refined_once or not _forced_modes.is_empty():
		return
	if _size.x <= 0 or _size.y <= 0:
		return
	_refined_once = true
	var det := MediaProjectionScript.detect(str(_open_args.get("source", "")).get_file())
	var refined := MediaProjectionScript.refine(det, _size.x, _size.y)
	if int(refined.screen) == screen_mode and int(refined.layout) == _layout_mode:
		return
	_forced_modes = {"source": _open_args.get("source", ""), "det": refined}
	# Deferred: reopening releases the player whose callback this is.
	_reopen_current.call_deferred()


func _reopen_current() -> void:
	if _open_args.is_empty():
		return
	var args := _open_args
	var at := 0
	if _player:
		at = _player.position_ms()
	if args.has("range"):
		var r: Dictionary = args.range
		open_range(str(args.source), int(r.offset), int(r.size),
			str(args.title), args.get("cues"))
	else:
		open(str(args.source), str(args.title))
	_pending_seek = at


func open_screen_menu() -> void:
	_panel.shell.show_screen_menu(screen_mode, _layout_mode)


func choose_screen(screen: int, layout: int) -> void:
	if _open_args.is_empty():
		return
	if screen == screen_mode and layout == _layout_mode:
		return
	_forced_modes = {"source": _open_args.get("source", ""),
		"det": {"screen": screen, "layout": layout, "stereo_hint": false}}
	_reopen_current()


func _report_audio() -> void:
	_audio_index = 0
	_text_index = -1
	_decoder_reported = false
	_tracks_settled = false
	_audio_tracks = []
	_text_tracks = []
	_panel.shell.set_player_audio_label("")
	_refresh_tracks()


## Warns when no audio track can be decoded without the FFmpeg decoders.
func _announce_tracks() -> void:
	var chat: Control = _panel.chat_ui
	if chat == null or not chat.has_method("add_message"):
		return
	if _audio_tracks.is_empty():
		chat.add_message("System", "No audio track in this file.", true)
		return
	var first: Dictionary = _audio_tracks[0]
	if not AndroidPlayerScript.has_ffmpeg_decoders() and _decodable_audio_count() == 0:
		chat.add_message("System", "Audio is %s — no decoder on this device. "
				% first.mime + "Silence is expected.", true)
		return
	var bits: Array[String] = ["%d audio" % _audio_tracks.size()]
	if not _text_tracks.is_empty():
		bits.append("%d subtitle" % _text_tracks.size())
	chat.add_message("System", "%s — press Tracks to choose." % " · ".join(bits), true)


func _decodable_audio_count() -> int:
	var playable := 0
	for t in _audio_tracks:
		if MediaCommandsScript._decodable(String(t.mime)):
			playable += 1
	return playable


## Letterboxed, or stretched with Fill; cuts the page's window to match.
func align() -> void:
	var shell: Control = _panel.shell
	if layer == null or shell == null:
		return
	if MediaProjectionScript.is_immersive(screen_mode):
		_align_immersive()
		return
	# Subtitles ride a layer of their own, so no strip is reserved.
	var strip := 0.0
	var a: float = aspect
	if a <= 0.0 and _size.x > 0 and _size.y > 0:
		a = float(_size.x) / float(_size.y)
	if a > 0.0:
		# Each eye sees half of a stereo frame.
		a = MediaProjectionScript.eye_aspect(a, _layout_mode)
		shell.set_player_aspect(a, strip)
	var r: Rect2 = shell.video_area_rect()
	if r.size.x < 2.0 or r.size.y < 2.0:
		align.call_deferred() # not laid out yet
		return
	_last_area_rect = r
	var vp := Vector2(VRPanel.VIEWPORT_SIZE)
	var panel_size := VRPanel.PANEL_SIZE
	r.size.y = maxf(r.size.y - strip, 50.0)
	var area_local := Vector2(r.size.x / vp.x * panel_size.x, r.size.y / vp.y * panel_size.y)
	var fitted := area_local
	if not _fill and a > 0.0:
		var shape := Vector2(a, 1.0)
		var k: float = minf(area_local.x / shape.x, area_local.y / shape.y)
		fitted = shape * k
	var c := r.get_center()
	var local_pos := Vector3(
		(c.x / vp.x - 0.5) * panel_size.x,
		(0.5 - c.y / vp.y) * panel_size.y,
		0.012)
	# Both eyes' quads sit in the same place; only their pictures differ.
	for l in [layer, layer_r]:
		var q := l as OpenXRCompositionLayerQuad
		if q != null:
			q.position = local_pos
			q.quad_size = _panel.composition_quad_size(fitted)
	var window_px: Vector2 = fitted * (vp.x / panel_size.x)
	shell.set_video_hole(Rect2(r.get_center() - window_px * 0.5, window_px))
	_place_subtitle_layer()


func _align_immersive() -> void:
	if _ui_layer != null:
		_ui_layer.quad_size = _panel.composition_quad_size(VRPanel.PANEL_SIZE)
	_panel.shell.set_video_hole(Rect2())
	if _player != null and _size.x > 0:
		_panel.shell.set_player_hint("Playing all around you — look up.")
	_place_immersive()
	_place_subtitle_layer()


## The list arrives some time after the player is ready; called until it is non-empty.
func _refresh_tracks() -> void:
	if _player == null:
		return
	var audio: Array = []
	var texts: Array = []
	for t in _player.track_info():
		if t.type == "audio":
			audio.append(t)
		elif t.type == "subtitle":
			texts.append(t)
	if audio.is_empty() and texts.is_empty():
		return
	_tracks_settled = true
	_audio_tracks = audio
	_text_tracks = texts
	_announce_tracks()
	align()
	_panel.shell.set_player_cc_available(not texts.is_empty() or _subs != null)
	var choices: int = audio.size() + texts.size()
	_panel.shell.set_player_audio_label("" if choices < 2 else "Tracks")


func open_track_menu() -> void:
	_refresh_tracks()
	_panel.shell.show_track_menu(_audio_tracks, _text_tracks, _audio_index, _text_index)


## Index -1 turns subtitles off.
func choose_track(kind: String, index: int) -> void:
	if _player == null:
		return
	if kind == "audio":
		if _player.select_track(index):
			_audio_index = index
			_decoder_reported = false   # a new decoder may take over
	else:
		if _player.select_text_track(index):
			_text_index = index
	_say("%s track: %s" % [kind, "off" if index < 0 else str(index)])


## On its own layer, since the shell is under the video; empty text hides it.
func _show_subtitle(text: String) -> void:
	if text.is_empty():
		if subtitle_layer:
			subtitle_layer.visible = false
		return
	if subtitle_layer == null:
		_build_subtitle_layer()
		if subtitle_layer == null:
			_panel.shell.set_subtitle(text)   # not in XR: fall back to the shell
			return
	if _sub_label.text != text:
		_sub_label.text = text
		subtitle_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	subtitle_layer.visible = true
	_place_subtitle_layer()


func _build_subtitle_layer() -> void:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		return
	subtitle_viewport = SubViewport.new()
	subtitle_viewport.size = Vector2i(1280, 220)
	subtitle_viewport.transparent_bg = true
	subtitle_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_panel.add_child(subtitle_viewport)

	_sub_label = Label.new()
	_sub_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_sub_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sub_label.add_theme_font_size_override("font_size", 46)
	_sub_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_sub_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_sub_label.add_theme_constant_override("outline_size", 12)
	subtitle_viewport.add_child(_sub_label)

	subtitle_layer = OpenXRCompositionLayerQuad.new()
	_panel.add_child(subtitle_layer)
	subtitle_layer.layer_viewport = subtitle_viewport
	subtitle_layer.sort_order = 3          # above the picture (2)
	subtitle_layer.alpha_blend = true


func _place_subtitle_layer() -> void:
	if subtitle_layer == null or layer == null:
		return
	var panel_size := VRPanel.PANEL_SIZE
	if MediaProjectionScript.is_immersive(screen_mode):
		var w: float = panel_size.x * 0.92
		subtitle_layer.quad_size = _panel.composition_quad_size(Vector2(w,
			w * float(subtitle_viewport.size.y) / float(subtitle_viewport.size.x)))
		subtitle_layer.position = Vector3(0.0, -(panel_size.y * 0.5 + 0.12), 0.012)
		return
	var quad_l := layer as OpenXRCompositionLayerQuad
	if quad_l == null:
		return
	var video_size: Vector2 = quad_l.quad_size
	if video_size.x <= 0.0:
		return
	var width: float = video_size.x * 0.92
	var height: float = width * float(subtitle_viewport.size.y) / float(subtitle_viewport.size.x)
	subtitle_layer.quad_size = Vector2(width, height)
	var pos: Vector3 = quad_l.position
	# Convert the compositor-space offset back to the panel's local units.
	var tracking_scale := _panel.composition_quad_size(Vector2.ONE)
	pos.y -= (video_size.y * 0.5 - height * 0.5 - video_size.y * 0.03) / tracking_scale.y
	pos.z += 0.002                      # break the tie with the picture
	subtitle_layer.position = pos


func _clear_subtitle_layer() -> void:
	if subtitle_layer:
		subtitle_layer.queue_free()
		subtitle_layer = null
	if subtitle_viewport:
		subtitle_viewport.queue_free()
		subtitle_viewport = null
	_sub_label = null
