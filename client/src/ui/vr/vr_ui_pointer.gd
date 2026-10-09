class_name VRUIPointer
extends Node3D
## Right-controller laser for VR panels: the ray hit becomes mouse events in each window's SubViewport.

## The host; all_windows() lists the windows to aim at.
var panel = null
var _right_hand: XRController3D = null
var _refind_cooldown := 0.0
var _beam: MeshInstance3D
var _dot: MeshInstance3D
var _last_pixel := Vector2.ZERO
var active = null
var _last_target = null
## The window being carried, and how far out in front it is held.
var _dragging = null
var _drag_distance := 0.0
var _resize_target = null
var _was_pressed := false
var _trigger_was_down := false
var _hovering := false
## An immersive video covers the beam and dot, so this window's shell draws the cursor itself.
var _cursor_window = null

# Motion and redraws are capped at PUSH_HZ so hand tremor does not redraw every frame.
const PUSH_HZ := 12.0
const MOVE_DEADZONE_PX := 3.0
var _push_accum := 0.0

const SCROLL_HZ := 9.0
const SCROLL_DEADZONE := 0.25
var _scroll_accum := 0.0
var _scrolling := false

## Fraction of the half-extent where a resize corner starts.
const CORNER_ZONE := 0.86
var _resizing := false
var _resize_start_dist := 0.0
var _resize_start_scale := 1.0


func setup(host) -> void:
	panel = host
	top_level = true

	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3(0.004, 0.004, 1.0)  # unit length, scaled per frame
	_beam = MeshInstance3D.new()
	_beam.mesh = beam_mesh
	_beam.material_override = _unshaded(Color(0.65, 0.85, 1.0, 0.5))
	_beam.visible = false
	add_child(_beam)

	var dot_mesh := SphereMesh.new()
	dot_mesh.radius = 0.011
	dot_mesh.height = 0.022
	_dot = MeshInstance3D.new()
	_dot.mesh = dot_mesh
	_dot.material_override = _unshaded(Color(1, 1, 1, 0.9))
	_dot.visible = false
	add_child(_dot)


func _unshaded(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = color
	m.no_depth_test = true
	m.render_priority = 101
	return m


## Called every frame the host is shown: carries, resizes or points at the nearest window.
func update_pointer(delta: float) -> void:
	var hand := _valid_hand(delta)
	var pressed: bool = hand != null and hand.get_has_tracking_data() \
			and hand.is_button_pressed("trigger_click")
	var just_pressed := pressed and not _trigger_was_down
	_trigger_was_down = pressed
	if hand == null or not hand.get_has_tracking_data() or panel == null:
		_set_feedback(false)
		return

	var origin: Vector3 = hand.global_position
	var dir: Vector3 = -hand.global_transform.basis.z.normalized()
	var gripping: bool = hand.is_button_pressed("grip_click")

	# Grip carries a window, so a window full of buttons can still be moved.
	if _dragging != null:
		_carry(origin, dir, gripping)
		return

	var hit := _nearest_hit(origin, dir)
	if hit.is_empty():
		_set_feedback(false)
		_resizing = false
		return

	active = hit["window"]
	var local: Vector3 = hit["local"]
	var hit_point: Vector3 = origin + dir * float(hit["t"])

	_set_feedback(true)
	_show_beam(origin, hit_point, active.world_scale())
	_dot.global_position = hit_point - dir * 0.005

	if gripping and active.has_method("drag_to"):
		_begin_drag(active, origin.distance_to(hit_point))
		return

	if _handle_resize(local, hit_point, pressed, just_pressed):
		return

	var uv := Vector2(local.x / active.PANEL_SIZE.x + 0.5, 0.5 - local.y / active.PANEL_SIZE.y)
	var pixel: Vector2 = uv * Vector2(active.VIEWPORT_SIZE)

	# Moving to another window must not drag a selection across the gap.
	if active != _last_target:
		cancel_press()
		_last_target = active
		_last_pixel = Vector2(-1000, -1000)
		_hovering = true
	# Snapped so hand tremor does not redraw the shell every frame.
	_update_shell_cursor(active, pixel.snapped(Vector2(4.0, 4.0)))

	_push_motion(delta, pixel, pressed, just_pressed)
	_push_click(pixel, pressed, just_pressed)
	_push_scroll(delta, hand.get_vector2("primary").y, pixel)


func _carry(origin: Vector3, dir: Vector3, gripping: bool) -> void:
	if gripping and is_instance_valid(_dragging):
		var carried: Vector3 = origin + dir * _drag_distance
		_dragging.drag_to(carried)
		_set_feedback(true)
		_show_beam(origin, carried, _dragging.world_scale())
		_dot.global_position = carried
		return
	_end_drag()


## {window, t, local}, or {}.
func _nearest_hit(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_distance := INF
	for w in panel.all_windows():
		if not is_instance_valid(w) or not w.panel_visible or w.quad == null:
			continue
		var hit := _intersect(w, origin, dir)
		if hit.is_empty() or float(hit["t"]) >= best_distance:
			continue
		best_distance = float(hit["t"])
		best = {"window": w, "t": hit["t"], "local": hit["local"]}
	return best


## True while resizing, which swallows UI input.
func _handle_resize(local: Vector3, hit_point: Vector3, pressed: bool,
		just_pressed: bool) -> bool:
	var half: Vector2 = active.PANEL_SIZE * 0.5
	var in_corner: bool = active.has_method("set_user_scale") \
			and absf(local.x) > half.x * CORNER_ZONE and absf(local.y) > half.y * CORNER_ZONE
	if _resizing:
		if pressed and is_instance_valid(_resize_target):
			var d: float = (hit_point - _resize_target.global_position).length()
			_resize_target.set_user_scale(
				clampf(_resize_start_scale * d / maxf(_resize_start_dist, 0.001), 0.45, 2.2))
		else:
			_resizing = false
		_dot.scale = Vector3.ONE * active.world_scale() * 2.0
		_was_pressed = pressed
		return true
	_dot.scale = Vector3.ONE * active.world_scale() * (1.8 if in_corner else 1.0)
	if in_corner and just_pressed:
		_resizing = true
		_resize_target = active
		_resize_start_dist = (hit_point - active.global_position).length()
		_resize_start_scale = active.user_scale
		_was_pressed = pressed
		return true
	return false


## At most PUSH_HZ times a second (at once on a press), and only past the dead zone.
func _push_motion(delta: float, pixel: Vector2, pressed: bool, just_pressed: bool) -> void:
	_push_accum += delta
	var may_push := just_pressed or _push_accum >= (1.0 / PUSH_HZ)
	if not may_push or pixel.distance_to(_last_pixel) <= MOVE_DEADZONE_PX:
		return
	_push_accum = 0.0
	var mm := InputEventMouseMotion.new()
	mm.position = pixel
	mm.relative = pixel - _last_pixel
	mm.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	active.sub_viewport.push_input(mm)
	active.request_redraw()
	_last_pixel = pixel


func _push_click(pixel: Vector2, pressed: bool, just_pressed: bool) -> void:
	if not ((just_pressed and not _was_pressed) or (not pressed and _was_pressed)):
		return
	_was_pressed = pressed
	var mb := InputEventMouseButton.new()
	mb.position = pixel
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = pressed
	mb.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	active.sub_viewport.push_input(mb)
	active.request_redraw()


## Wheel clicks at SCROLL_HZ.
func _push_scroll(delta: float, stick_y: float, pixel: Vector2) -> void:
	_scrolling = absf(stick_y) > SCROLL_DEADZONE
	if not _scrolling:
		_scroll_accum = 0.0
		return
	_scroll_accum += delta * SCROLL_HZ * absf(stick_y)
	while _scroll_accum >= 1.0:
		_scroll_accum -= 1.0
		var wheel_index := MOUSE_BUTTON_WHEEL_UP if stick_y > 0.0 else MOUSE_BUTTON_WHEEL_DOWN
		for wheel_pressed in [true, false]:
			var wheel := InputEventMouseButton.new()
			wheel.position = pixel
			wheel.button_index = wheel_index
			wheel.pressed = wheel_pressed
			wheel.factor = 1.0
			active.sub_viewport.push_input(wheel)
		active.request_redraw()


## {} when it misses, else {t, local}.
func _intersect(w, origin: Vector3, dir: Vector3) -> Dictionary:
	var quad: MeshInstance3D = w.quad
	var n: Vector3 = quad.global_transform.basis.z.normalized()
	var denom := dir.dot(n)
	if absf(denom) < 0.0001:
		return {}
	var t := (quad.global_position - origin).dot(n) / denom
	if t < 0.0 or t > 12.0:
		return {}
	var local: Vector3 = quad.global_transform.affine_inverse() * (origin + dir * t)
	var half: Vector2 = w.PANEL_SIZE * 0.5
	if absf(local.x) > half.x or absf(local.y) > half.y:
		return {}
	return {"t": t, "local": local}


func _show_beam(origin: Vector3, hit: Vector3, ws: float) -> void:
	var length := origin.distance_to(hit)
	_beam.global_position = (origin + hit) * 0.5
	if length > 0.01:
		var along := (hit - origin).normalized()
		_beam.look_at(hit, Vector3.UP if absf(along.y) < 0.99 else Vector3.FORWARD)
		_beam.scale = Vector3(ws, ws, length)


## Releases any held click underneath.
func _begin_drag(w, distance: float) -> void:
	_dragging = w
	_drag_distance = distance
	_resizing = false
	if _was_pressed and w.sub_viewport != null:
		var release := InputEventMouseButton.new()
		release.position = _last_pixel
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		w.sub_viewport.push_input(release)
		_was_pressed = false


## Snaps it to the ring when it wants that.
func _end_drag() -> void:
	if is_instance_valid(_dragging) and _dragging.snap_enabled:
		_dragging.snap_to_ring()
	_dragging = null


func is_hovering() -> bool:
	return _hovering


## Movement suppresses smooth turn meanwhile.
func is_scrolling() -> bool:
	return _hovering and _scrolling


## Leaving a window cancels any press.
func _set_feedback(hovering: bool) -> void:
	if not hovering:
		cancel_press()
	_hovering = hovering
	_beam.visible = hovering
	_dot.visible = hovering
	if not hovering:
		_scrolling = false
		_update_shell_cursor(null, Vector2.ZERO)


## Only drawn on a window playing immersive video.
func _update_shell_cursor(w, pixel: Vector2) -> void:
	var wants: bool = w != null and w.get("video") != null \
		and w.video.is_immersive() and w.shell != null
	if wants:
		if _cursor_window != null and _cursor_window != w \
				and is_instance_valid(_cursor_window) and _cursor_window.shell != null:
			_cursor_window.shell.set_laser_cursor(Vector2(-1000, -1000))
		w.shell.set_laser_cursor(pixel)
		_cursor_window = w
	elif _cursor_window != null:
		if is_instance_valid(_cursor_window) and _cursor_window.shell != null:
			_cursor_window.shell.set_laser_cursor(Vector2(-1000, -1000))
		_cursor_window = null


## Searched again at most twice a second when lost.
func _valid_hand(delta: float) -> XRController3D:
	if _right_hand != null and is_instance_valid(_right_hand) and _right_hand.is_inside_tree():
		return _right_hand
	_right_hand = null
	_refind_cooldown -= delta
	if _refind_cooldown <= 0.0:
		_refind_cooldown = 0.5
		_right_hand = _find_right_hand()
	return _right_hand


## Remote players have rigs too.
func _find_right_hand() -> XRController3D:
	for body in get_tree().root.find_children("*", "CharacterBody3D", true, false):
		if not (body.get("is_remote_player") == false and body.get("is_vr_mode") == true):
			continue
		var origin = body.find_child("XROrigin3D", true, false)
		if not origin:
			continue
		var hand = origin.find_child("RightHand", true, false)
		if hand is XRController3D:
			return hand
	return null


## Releases a held click off-window, so a button pressed and left is not activated.
func cancel_press() -> void:
	var target = _last_target
	if _was_pressed and is_instance_valid(target) and target.sub_viewport != null:
		var motion := InputEventMouseMotion.new()
		motion.position = Vector2(-1, -1)
		motion.relative = motion.position - _last_pixel
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		target.sub_viewport.push_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = motion.position
		release.pressed = false
		target.sub_viewport.push_input(release)
		target.request_redraw()
	_was_pressed = false
	_resizing = false
	_dragging = null
	_hovering = false
	_scrolling = false
	_update_shell_cursor(null, Vector2.ZERO)
