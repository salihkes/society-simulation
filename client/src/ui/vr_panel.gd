class_name VRPanel
extends Node3D

## World-space VR panel hosting a SpatialShell, video and browser layers; lives at the scene root, which survives character swaps.

const PANEL_SIZE := Vector2(1.6, 1.0)   # perceived metres
const VIEWPORT_SIZE := Vector2i(1280, 800)
const CHAT_UI_SCALE := 1.35             # the desktop ChatUI's scale inside its page
const PLACE_DISTANCE := 1.25            # perceived metres in front of the gaze
const PLACE_DROP := 0.1                 # perceived metres below eye height
const REPLACE_DISTANCE := 2.2           # re-place when the player is this far away

const CHAT_UI_SCENE := "res://assets/ui/chat_ui.tscn"
const SPATIAL_SHELL_SCENE := "res://assets/ui/vr/spatial_shell.tscn"
const VRUIPointerScript = preload("res://src/ui/vr/vr_ui_pointer.gd")
const WebViewScript = preload("res://src/media/web_view.gd")
const ZimServerScript = preload("res://src/media/zim_server.gd")

@export var player_path: NodePath = ^"../Player"

# The primary window owns the laser and the menu button; closing it hides rather than destroys.

## Including the first; each is a live render target.
const MAX_WINDOWS := 4
const RING_GAP := 0.06
## Further out than a single panel, so four fit in front of the player without turning.
const RING_DISTANCE := 1.9

var is_primary := true
var primary: Node = null
## Extra windows, kept on the first one only.
var windows: Array[Node3D] = []
var snap_enabled := true
var ring_slot := 0

var chat_ui: Control
var shell: Control
var sub_viewport: SubViewport
var quad: MeshInstance3D
var pointer: Node3D
var panel_visible := false

var _target_camera: Camera3D = null
var _refind_cooldown := 0.0
var _placed := false
var _keyboard_focused := false
var _tick_accum := 0.0
var _prev_menu_button := false

## The node stays live (the film's layers are its children) but the UI, laser and input are off.
var _remote_hidden := false
var video := VRVideoPlayer.new(self)
var _browser_layer: OpenXRCompositionLayerQuad = null
var _browser_surface = null
var _web = null
var _zim_server = null
var _browser_pending := ""
var _browser_wanted := false
## Set to the view region's aspect when the layer is built.
var _browser_surface_size := Vector2i(1440, 900)
var _browser_area := Rect2()
var _browser_poll := 0.0
var _browser_zoom := 140

var pinned := false
var user_scale := 1.0


## World units per perceived metre; the XR rig sits under a scaled workspace.
func world_scale() -> float:
	if _target_camera != null and is_instance_valid(_target_camera):
		return _target_camera.global_transform.basis.x.length()
	return 1.0


## OpenXR takes quad_size raw while Godot converts layer positions itself.
func composition_quad_size(local_size: Vector2) -> Vector2:
	var tracking_basis := (XRServer.world_origin.affine_inverse() * global_transform).basis
	return local_size * Vector2(tracking_basis.x.length(), tracking_basis.y.length())


## Registers with the player as its ui_panel.
func _ready() -> void:
	var ui: Control = load(CHAT_UI_SCENE).instantiate()
	add_child(ui)
	ui.vr_panel = self
	ui.player = get_node_or_null(player_path)
	attach_chat(ui)
	var body := get_node_or_null(player_path)
	if is_primary and body and "ui_panel" in body:
		body.ui_panel = self


func attach_chat(ui: Control) -> void:
	chat_ui = ui
	top_level = true

	sub_viewport = SubViewport.new()
	sub_viewport.size = VIEWPORT_SIZE
	sub_viewport.transparent_bg = true
	sub_viewport.gui_embed_subwindows = true
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(sub_viewport)

	shell = (load(SPATIAL_SHELL_SCENE) as PackedScene).instantiate()
	sub_viewport.add_child(shell)
	_connect_shell()
	_connect_browser()

	ui.get_parent().remove_child(ui)
	shell.dock_chat_ui(ui, CHAT_UI_SCALE)

	var field := _input_field()
	if field:
		field.text_changed.connect(func(_t): request_redraw())
		field.focus_entered.connect(func():
			_on_keyboard_focus(true)
			DisplayServer.virtual_keyboard_show(field.text))
		field.focus_exited.connect(func():
			_on_keyboard_focus(false)
			DisplayServer.virtual_keyboard_hide())

	_build_quad()

	# One laser for all windows; it picks whichever the ray lands on.
	if is_primary:
		pointer = VRUIPointerScript.new()
		add_child(pointer)
		pointer.setup(self)

	# Extra windows are opened on purpose, so they start shown.
	var in_headset: bool = _in_headset()
	set_panel_visible(in_headset or not is_primary, false)
	if is_primary and chat_ui.has_method("add_message"):
		if in_headset:
			chat_ui.add_message("System", "Left Y toggles the panels. Point with the right "
					+ "controller, trigger to click, squeeze grip to move a window.", true)
		else:
			chat_ui.add_message("System", "Tab toggles the panels.", true)


func _connect_shell() -> void:
	shell.content_changed.connect(request_redraw)
	shell.keyboard_focus.connect(_on_keyboard_focus)
	shell.player_closed.connect(video.close)
	shell.player_toggle.connect(video.toggle)
	shell.player_seek.connect(video.seek)
	shell.player_volume_changed.connect(video.set_volume)
	shell.player_cc_toggled.connect(video.set_subtitles_on)
	shell.player_aspect_changed.connect(video.set_fill)
	shell.panel_pin_toggled.connect(func(on): pinned = on)
	shell.window_new.connect(func(): spawn_window())
	shell.window_close.connect(close_window)
	shell.snap_toggled.connect(func(on: bool):
		set_snap(on)
		if snap_enabled:
			snap_to_ring())
	shell.player_track_menu.connect(video.open_track_menu)
	shell.player_track_chosen.connect(video.choose_track)
	shell.player_screen_menu.connect(video.open_screen_menu)
	shell.player_screen_chosen.connect(video.choose_screen)
	shell.player_menu_visible.connect(func(open: bool): video.set_picture_visible(not open))


func _connect_browser() -> void:
	shell.browse_navigate.connect(open_browser)
	shell.browse_open_file.connect(open_local_page)
	shell.browse_open_archive.connect(open_archive_in_browser)
	shell.browse_back.connect(func(): if _web: _web.back())
	shell.browse_forward.connect(func(): if _web: _web.forward())
	shell.browse_reload.connect(func():
		if _web == null:
			return
		# One button: it says Stop while a page is loading.
		if _web.is_loading():
			_web.stop_loading()
		else:
			_web.reload())
	shell.browse_close.connect(close_browser)
	shell.browse_touch.connect(func(action: int, uv: Vector2):
		if _web: _web.touch(action, uv))
	shell.browse_scroll.connect(func(lines: int):
		if _web: _web.scroll_by(0, lines * 120))
	shell.browse_type.connect(func(text: String):
		if _web: _web.type_text(text))
	shell.browse_key.connect(func(code: int):
		if _web: _web.key(code))
	shell.browse_zoom.connect(func(delta: int):
		_browser_zoom = clampi(_browser_zoom + delta, 70, 260)
		if _web: _web.set_text_zoom(_browser_zoom))


## Drawn over world geometry so it never clips into walls.
func _build_quad() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = 100
	mat.albedo_texture = sub_viewport.get_texture()

	var mesh := QuadMesh.new()
	mesh.size = PANEL_SIZE
	quad = MeshInstance3D.new()
	quad.mesh = mesh
	quad.material_override = mat
	add_child(quad)


## The SubViewport renders only on request, plus periodic ticks.
func request_redraw() -> void:
	if sub_viewport and panel_visible:
		sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## _process refreshes the caret meanwhile.
func _on_keyboard_focus(active: bool) -> void:
	_keyboard_focused = active
	if sub_viewport:
		sub_viewport.render_target_update_mode = (
			SubViewport.UPDATE_ONCE if panel_visible
			else SubViewport.UPDATE_DISABLED)


## With the remote hidden, only the immersive video is kept going.
func _process(delta: float) -> void:
	_poll_menu_button()
	if not panel_visible:
		if _remote_hidden and _valid_camera(delta) != null:
			video.process(delta)
		return
	var cam := _valid_camera(delta)
	if cam == null:
		return
	var ws := world_scale()
	if not _placed or (not pinned
			and global_position.distance_to(cam.global_position) > REPLACE_DISTANCE * ws):
		_place(cam)
	if pointer:
		pointer.update_pointer(delta)
	video.process(delta)
	_browser_process(delta)
	# Caret refresh while typing, otherwise 1 Hz for message fades.
	_tick_accum += delta
	if _tick_accum >= (1.0 / 12.0 if _keyboard_focused else 1.0):
		_tick_accum = 0.0
		request_redraw()


## Runtimes disagree on the orientation of Android surface swapchains.
static func apply_surface_flip(layer: OpenXRCompositionLayer) -> void:
	var xr := XRServer.find_interface("OpenXR")
	if not xr:
		return
	var runtime_name := str(xr.get_system_info().get("XRRuntimeName", ""))
	var renderer := RenderingServer.get_current_rendering_driver_name()
	var flip := false
	if runtime_name.begins_with("Oculus"):
		flip = renderer in ["opengl3", "opengl3_es"]
	elif runtime_name.begins_with("Pico"):
		flip = renderer == "vulkan"
	layer.set("XR_FB_composition_layer_image_layout/vertical_flip", flip)


## In the head's own frame, so it faces the player however the planet or rig is turned.
func _place(cam: Camera3D) -> void:
	var ws := world_scale()
	var head: Basis = cam.global_transform.basis.orthonormalized()
	var fwd: Vector3 = -head.z
	var up: Vector3 = head.y
	var pos: Vector3 = cam.global_position + fwd * PLACE_DISTANCE * ws - up * PLACE_DROP * ws
	# -Z along fwd turns the quad's textured +Z face to the player.
	look_at_from_position(pos, pos + fwd, up)
	scale = Vector3.ONE * ws * user_scale
	_placed = true
	video.align()
	request_redraw()


func set_user_scale(factor: float) -> void:
	user_scale = factor
	scale = Vector3.ONE * world_scale() * user_scale
	video.align()


## Searched again at most twice a second when lost.
func _valid_camera(delta: float) -> Camera3D:
	if _target_camera != null and is_instance_valid(_target_camera) \
			and _target_camera.is_inside_tree():
		return _target_camera
	_target_camera = null
	_refind_cooldown -= delta
	if _refind_cooldown <= 0.0:
		_refind_cooldown = 0.5
		_target_camera = _find_local_xr_camera()
	return _target_camera


func _find_local_xr_camera() -> Camera3D:
	var body := get_node_or_null(player_path)
	if body and body.has_method("active_camera"):
		var cam: Camera3D = body.active_camera()
		if cam and cam.is_inside_tree():
			return cam
	return get_viewport().get_camera_3d()


func _input_field() -> LineEdit:
	if chat_ui:
		return chat_ui.get_node_or_null("VBoxContainer/InputContainer/InputField")
	return null


func toggle() -> void:
	set_panel_visible(not panel_visible)


## Hiding pauses the video, except an immersive film, where only the remote hides.
func set_panel_visible(value: bool, _show_keyboard: bool = true) -> void:
	if is_primary:
		for w in windows:
			if is_instance_valid(w):
				w.set_panel_visible(value, false)
	if not value and video.is_immersive() and video.has_player():
		_hide_remote()
		return
	_remote_hidden = false
	if pointer:
		pointer.visible = true
	panel_visible = value
	visible = value
	if not pinned:
		_placed = false
	if value:
		request_redraw()
		video.show_layers()
	else:
		video.pause()
		# Composition layers draw regardless of their parent's visibility.
		if _browser_layer:
			_browser_layer.visible = false
		video.hide_layers()
		_drop_input_focus()


## The node stays visible because the film's layers are its children.
func _hide_remote() -> void:
	panel_visible = false
	_remote_hidden = true
	video.hide_ui_layer()
	if pointer:
		pointer.visible = false
	if _browser_layer:
		_browser_layer.visible = false
	_drop_input_focus()


## A film closed while its remote was hidden: finish the hide, or the quad would reappear with input off.
func end_remote_hide() -> void:
	if _remote_hidden:
		_remote_hidden = false
		visible = false


## The camera last found, without searching again.
func tracked_camera() -> Camera3D:
	return _target_camera


func _drop_input_focus() -> void:
	var field := _input_field()
	if field:
		field.release_focus()
	DisplayServer.virtual_keyboard_hide()
	_keyboard_focused = false
	if sub_viewport:
		sub_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


## Tab toggles the panel on a desktop; other keys go to the window that owns the keyboard.
func _input(event: InputEvent) -> void:
	if is_primary and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_TAB \
			and (sub_viewport == null or sub_viewport.gui_get_focus_owner() == null):
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not panel_visible or sub_viewport == null:
		return
	if event is InputEventKey:
		if not _owns_keyboard():
			return
		sub_viewport.push_input(event)
		request_redraw()


## The primary when no window has a focused control.
func _owns_keyboard() -> bool:
	if sub_viewport.gui_get_focus_owner() != null:
		return true
	for w in all_windows():
		if is_instance_valid(w) and w != self and w.sub_viewport != null \
				and w.sub_viewport.gui_get_focus_owner() != null:
			return false
	return is_primary


## Left Y; the right hand has the laser and walk/fly.
func _poll_menu_button() -> void:
	if not is_primary:
		return
	var body := get_node_or_null(player_path)
	if body == null or not ("left_hand" in body) or body.left_hand == null:
		return
	var now: bool = body.left_hand.is_button_pressed("by_button")
	if now and not _prev_menu_button:
		toggle()
	_prev_menu_button = now


# Archives are served to the WebView over loopback HTTP so their own HTML shows.

func open_archive_in_browser(archive_path: String) -> void:
	if not _ensure_browser():
		return
	if _zim_server != null and _zim_server.archive_path == archive_path:
		open_browser(_zim_server.start_url())
		return
	if _zim_server != null:
		_zim_server.stop()
	_zim_server = ZimServerScript.new()
	if not _zim_server.start(archive_path):
		_zim_server = null
		shell.set_browse_status("could not serve %s" % archive_path.get_file(), "", false, 0)
		return
	if chat_ui and chat_ui.has_method("add_message"):
		chat_ui.add_message("System", "Serving %s at %s" % [
			archive_path.get_file(), _zim_server.base_url()], true)
	open_browser(_zim_server.start_url())


## A bare path means a page in the archive being served, else an https address.
func open_browser(url: String) -> void:
	set_panel_visible(true)
	shell.show_browser()
	if not _ensure_browser():
		return
	var target := url.strip_edges()
	if target.is_empty():
		return
	if not target.contains("://"):
		if _zim_server != null:
			target = _zim_server.base_url() + target.trim_prefix("/")
		else:
			target = "https://" + target
	if _web != null and _web.is_ready():
		_web.load_url(target)
	else:
		_browser_pending = target


func open_local_page(path: String) -> void:
	var segments: Array[String] = []
	for part in path.split("/"):
		segments.append(String(part).uri_encode())
	open_browser("file://" + "/".join(segments))


func close_browser() -> void:
	if _web != null:
		_web.close()
		_web = null
	if _browser_layer != null:
		_browser_layer.queue_free()
		_browser_layer = null
		_browser_surface = null
	if _zim_server != null:
		_zim_server.stop()
		_zim_server = null
	_browser_pending = ""
	_browser_wanted = false
	_browser_area = Rect2()
	if shell:
		shell.set_browse_window(Rect2())


## The layer is built later, once the page has a size.
func _ensure_browser() -> bool:
	if not OS.has_feature("android"):
		shell.set_browse_status("the browser is Quest-only — it is an Android WebView",
			"", false, 0)
		return false
	if WebViewScript.is_supported() == false:
		shell.set_browse_status("this build has no WebBridge", "", false, 0)
		return false
	_browser_wanted = true
	return true


## Surface of the area's aspect, so the page fills it without bars.
func _build_browser_layer(area: Rect2) -> void:
	var height := 900
	var width := int(round(height * area.size.x / area.size.y))
	_browser_surface_size = Vector2i(clampi(width - width % 2, 640, 2400), height)
	_browser_layer = OpenXRCompositionLayerQuad.new()
	_browser_layer.use_android_surface = true
	_browser_layer.android_surface_size = _browser_surface_size
	add_child(_browser_layer)
	_browser_layer.sort_order = 1
	apply_surface_flip(_browser_layer)


func _browser_process(delta: float) -> void:
	if not _browser_wanted:
		return
	var on_page: bool = shell != null and shell.is_browse_open()
	if _browser_layer != null:
		_browser_layer.visible = on_page
	if not on_page:
		return
	if _browser_layer == null:
		var area: Rect2 = shell.browse_area_rect()
		if area.size.x < 2.0 or area.size.y < 2.0:
			return
		_build_browser_layer(area)
		return

	if _browser_surface == null and not _start_web():
		return

	var r: Rect2 = shell.browse_area_rect()
	if r.size.x > 2.0 and r != _browser_area:
		_align_browser_layer(r)

	if _web == null:
		return
	if not _browser_pending.is_empty() and _web.is_ready():
		_web.load_url(_browser_pending)
		_browser_pending = ""
	_browser_poll += delta
	if _browser_poll < 0.35:
		return
	_browser_poll = 0.0
	shell.set_browse_typing(_web.input_focused())
	var err := str(_web.error())
	shell.set_browse_status(
		_web.title() if err.is_empty() else "failed: %s" % err,
		_web.url(), _web.is_loading(), _web.progress())


## False until the surface exists, or on failure.
func _start_web() -> bool:
	_browser_surface = _browser_layer.get_android_surface()
	if _browser_surface == null:
		return false
	_web = WebViewScript.new()
	if not _web.open(_browser_surface, _browser_surface_size, _browser_pending):
		_web = null
		shell.set_browse_status("the WebView would not start", "", false, 0)
		return false
	_web.set_text_zoom(_browser_zoom)
	_browser_pending = ""
	return true


## Tells the shell the covered rect, so taps map onto the page.
func _align_browser_layer(r: Rect2) -> void:
	_browser_area = r
	var vp := Vector2(VIEWPORT_SIZE)
	var area_local := Vector2(r.size.x / vp.x * PANEL_SIZE.x, r.size.y / vp.y * PANEL_SIZE.y)
	var shape := Vector2(_browser_surface_size) / float(_browser_surface_size.y)
	var k: float = minf(area_local.x / shape.x, area_local.y / shape.y)
	var fitted := shape * k
	var c := r.get_center()
	_browser_layer.position = Vector3(
		(c.x / vp.x - 0.5) * PANEL_SIZE.x,
		(0.5 - c.y / vp.y) * PANEL_SIZE.y,
		0.012)
	_browser_layer.quad_size = composition_quad_size(fitted)
	var window_px: Vector2 = fitted * (vp.x / PANEL_SIZE.x)
	shell.set_browse_window(Rect2(c - window_px * 0.5, window_px))


## The laser walks this list.
func all_windows() -> Array:
	var host: Node = primary if primary != null else self
	var out: Array = [host]
	for w in host.windows:
		if is_instance_valid(w):
			out.append(w)
	return out


func camera() -> Camera3D:
	if _target_camera != null and is_instance_valid(_target_camera) \
			and _target_camera.is_inside_tree():
		return _target_camera
	_target_camera = _find_local_xr_camera()
	return _target_camera


## Null at the limit.
func spawn_window() -> Node:
	if not is_primary:
		return primary.spawn_window() if primary != null else null
	if windows.size() + 1 >= MAX_WINDOWS:
		if chat_ui and chat_ui.has_method("add_message"):
			chat_ui.add_message("System",
				"%d windows is the limit — each one is a live render target." % MAX_WINDOWS,
				true)
		return null
	var script: GDScript = get_script()
	var w = script.new()
	# Set before _ready() runs.
	w.is_primary = false
	w.primary = self
	w.player_path = player_path
	w.snap_enabled = snap_enabled
	w.user_scale = user_scale
	w.pinned = true
	get_parent().add_child(w)
	# Not placed in front of the face for a frame before taking its slot.
	w._placed = true
	windows.append(w)
	w.call_deferred("place_in_free_slot")
	return w


## The primary only hides, with every window.
func close_window() -> void:
	if is_primary:
		set_panel_visible(false)
		return
	video.close()
	close_browser()
	if primary != null:
		primary.windows.erase(self)
	queue_free()


func set_snap(on: bool) -> void:
	snap_enabled = on
	if is_primary:
		for w in windows:
			if is_instance_valid(w):
				w.snap_enabled = on


## Right, left, then two out, and so on.
func place_in_free_slot() -> void:
	var cam := camera()
	if cam == null:
		call_deferred("place_in_free_slot")   # the rig is not up yet
		return
	var taken: Array[int] = []
	for w in all_windows():
		if is_instance_valid(w) and w != self:
			taken.append(w.ring_slot)
	for candidate in [1, -1, 2, -2, 3, -3]:
		if not taken.has(candidate):
			ring_slot = candidate
			break
	_place_on_ring(cam, ring_slot, 0)


## Kept upright and facing away from the camera.
func drag_to(at: Vector3) -> void:
	var cam := camera()
	if cam == null:
		return
	var up: Vector3 = cam.global_transform.basis.orthonormalized().y
	var away: Vector3 = at - cam.global_position
	var flat: Vector3 = away - up * away.dot(up)
	if flat.length() < 0.05:
		return
	look_at_from_position(at, at + flat.normalized(), up)
	pinned = true
	_placed = true
	video.align()
	if _browser_layer != null and shell != null:
		_align_browser_layer(shell.browse_area_rect())


## Measured from the first window.
func snap_to_ring() -> void:
	var cam := camera()
	if cam == null:
		return
	var ws := world_scale()
	var up: Vector3 = cam.global_transform.basis.orthonormalized().y
	var away: Vector3 = global_position - cam.global_position
	var height: float = away.dot(up)
	var flat: Vector3 = away - up * height
	if flat.length() < 0.05:
		return
	var reference: Vector3 = _ring_forward(cam, up)
	var step: float = _ring_step()
	ring_slot = roundi(_signed_angle(reference, flat.normalized(), up) / step)
	var row := roundi((height + PLACE_DROP * ws) / (_row_step() * ws))
	_place_on_ring(cam, ring_slot, row)


func _place_on_ring(cam: Camera3D, slot: int, row: int) -> void:
	var ws := world_scale()
	var up: Vector3 = cam.global_transform.basis.orthonormalized().y
	var dir: Vector3 = _ring_forward(cam, up).rotated(up, _ring_step() * slot)
	var pos: Vector3 = cam.global_position + dir * RING_DISTANCE * ws \
		+ up * (row * _row_step() * ws - PLACE_DROP * ws)
	look_at_from_position(pos, pos + dir, up)
	scale = Vector3.ONE * ws * user_scale
	pinned = true
	_placed = true
	video.align()
	request_redraw()


## The grid's zero.
func _ring_forward(cam: Camera3D, up: Vector3) -> Vector3:
	var host: Node3D = primary if primary != null else self
	var away: Vector3 = host.global_position - cam.global_position
	var flat: Vector3 = away - up * away.dot(up)
	if flat.length() < 0.05:
		flat = -cam.global_transform.basis.z
		flat = flat - up * flat.dot(up)
	return flat.normalized()


func _ring_step() -> float:
	return 2.0 * atan((PANEL_SIZE.x * user_scale * 0.5 + RING_GAP) / RING_DISTANCE)


func _row_step() -> float:
	return PANEL_SIZE.y * user_scale + RING_GAP


static func _signed_angle(from: Vector3, to: Vector3, axis: Vector3) -> float:
	return atan2(from.cross(to).dot(axis), from.dot(to))


func _in_headset() -> bool:
	var boot := get_node_or_null(^"/root/XRBoot")
	return boot != null and boot.active
