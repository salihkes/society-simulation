extends CanvasLayer
## Autoload: on-screen touch controls feeding the game's existing actions and camera; off in VR.

const STICK_RADIUS := 110.0        # thumb travel from the stick's centre
const STICK_DEADZONE := 0.14
const LOOK_SENSITIVITY := 0.004    # radians per pixel dragged
const TAP_MAX_MS := 250            # a shorter press that moved less than
const TAP_MAX_DRAG := 12.0         # this many pixels is a tap
const BUTTON_SIZE := Vector2(96, 96)
const BUTTON_GAP := 12.0
const EDGE := 28.0                 # margin from the screen edge

const COL_RING := Color(1, 1, 1, 0.22)
const COL_KNOB := Color(1, 1, 1, 0.40)
const COL_BTN := Color(0, 0, 0, 0.28)
const COL_BTN_DOWN := Color(1, 1, 1, 0.34)
const COL_LABEL := Color(1, 1, 1, 0.85)

var enabled := false

var _root: Control
var _stick: Control
## {node, action, label, held, col, row, finger}
var _buttons: Array[Dictionary] = []

# A finger belongs to the region it started in until it lifts.
var _stick_finger := -1
var _stick_origin := Vector2.ZERO
var _stick_vec := Vector2.ZERO

var _look_finger := -1
var _look_start_ms := 0
var _look_moved := 0.0

var _pressed_actions := {}
var _camera: Node3D = null

const HUD_SIZE := Vector2(232, 76)
var _hud: Control
var _hud_accum := 0.0
var _fps := 0.0
var _frame_ms := 0.0
var _env: Node = null


func _ready() -> void:
	if not DisplayServer.is_touchscreen_available() or _in_vr():
		set_process(false)
		set_process_input(false)
		return
	enabled = true
	layer = 5                          # under the chat, which must stay typable
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	print("[TouchControls] active on %s (%s)" % [
		OS.get_name(), DisplayServer.screen_get_size()])


func _in_vr() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized()


func _build() -> void:
	_root = Control.new()
	_root.name = "TouchRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Drawn only: touches arrive through _unhandled_input, so other UI keeps its events.
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_stick = Control.new()
	_stick.name = "Stick"
	_stick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick.draw.connect(_draw_stick)
	_root.add_child(_stick)

	for spec in [
		{"action": "jump", "label": Labels.text("jump", "Jump"), "col": 0, "row": 0},
		{"action": "interact", "label": Labels.text("interact", "Use"), "col": 1, "row": 0},
		{"action": "grab", "label": Labels.text("grab", "Grab"), "col": 0, "row": 1},
		{"action": "ui_sprint", "label": Labels.text("sprint", "Run"), "col": 1, "row": 1},
	]:
		if InputMap.has_action(spec.action):
			_add_button(spec)

	_hud = Control.new()
	_hud.name = "Perf"
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.size = HUD_SIZE
	_hud.draw.connect(_draw_hud)
	_root.add_child(_hud)

	get_viewport().size_changed.connect(_layout)
	_layout()


func _add_button(spec: Dictionary) -> void:
	var b := Control.new()
	b.name = String(spec.action)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.custom_minimum_size = BUTTON_SIZE
	b.size = BUTTON_SIZE
	var entry := {"node": b, "action": String(spec.action),
		"label": String(spec.label), "held": false,
		"col": int(spec.col), "row": int(spec.row), "finger": -1}
	b.draw.connect(_draw_button.bind(entry))
	_root.add_child(b)
	_buttons.append(entry)


func _layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	_hud.position = Vector2(vp.x - EDGE - HUD_SIZE.x, EDGE)
	_stick.position = Vector2(EDGE, vp.y - EDGE - STICK_RADIUS * 2.0)
	_stick.size = Vector2(STICK_RADIUS * 2.0, STICK_RADIUS * 2.0)
	for e in _buttons:
		var b: Control = e.node
		b.position = Vector2(
			vp.x - EDGE - (BUTTON_SIZE.x + BUTTON_GAP) * (2 - int(e.col)),
			vp.y - EDGE - (BUTTON_SIZE.y + BUTTON_GAP) * (2 - int(e.row)))
	_root.queue_redraw()
	_stick.queue_redraw()
	for e in _buttons:
		e.node.queue_redraw()


func _draw_stick() -> void:
	var c := Vector2(STICK_RADIUS, STICK_RADIUS)
	_stick.draw_arc(c, STICK_RADIUS, 0, TAU, 48, COL_RING, 3.0, true)
	_stick.draw_circle(c + _stick_vec * STICK_RADIUS, 34.0, COL_KNOB)


func _draw_hud() -> void:
	var r := Rect2(Vector2.ZERO, HUD_SIZE)
	_hud.draw_rect(r, Color(0, 0, 0, 0.42), true)
	_hud.draw_rect(r, COL_RING, false, 1.5)
	var font := ThemeDB.fallback_font
	var vp := get_viewport().get_visible_rect().size
	var profile := "full"
	if _env != null and is_instance_valid(_env):
		profile = "tile-gpu" if bool(_env.get("_mobile_rendering")) else "full"
	var lines := [
		"%.0f fps   %.1f ms" % [_fps, _frame_ms],
		"%d x %d   %s" % [int(vp.x), int(vp.y),
			RenderingServer.get_current_rendering_driver_name()],
		"profile: %s  (tap)" % profile,
	]
	var y := 20.0
	for line in lines:
		_hud.draw_string(font, Vector2(10, y), line,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 17, COL_LABEL)
		y += 21.0


func _process(delta: float) -> void:
	if not enabled:
		return
	_hud_accum += delta
	if _hud_accum < 0.25:
		return
	_hud_accum = 0.0
	_fps = Engine.get_frames_per_second()
	_frame_ms = 1000.0 / maxf(_fps, 0.001)
	_find_env()
	_hud.queue_redraw()


func _find_env() -> void:
	if _env == null or not is_instance_valid(_env):
		_env = get_tree().get_root().find_child("EnvironmentController", true, false)


## Flips the EnvironmentController between full and tile-GPU rendering.
func _toggle_profile() -> void:
	_find_env()
	if _env == null or not _env.has_method("set_mobile_rendering"):
		return
	_env.set_mobile_rendering(not bool(_env.get("_mobile_rendering")))
	_hud.queue_redraw()


func _draw_button(entry: Dictionary) -> void:
	var b: Control = entry.node
	var r := Rect2(Vector2.ZERO, b.size)
	b.draw_circle(r.size * 0.5, r.size.x * 0.5, COL_BTN_DOWN if entry.held else COL_BTN)
	b.draw_arc(r.size * 0.5, r.size.x * 0.5 - 1.5, 0, TAU, 32, COL_RING, 2.0, true)
	var font := ThemeDB.fallback_font
	var size := 34
	var w := font.get_string_size(entry.label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	b.draw_string(font, r.size * 0.5 + Vector2(-w * 0.5, size * 0.38),
		entry.label, HORIZONTAL_ALIGNMENT_LEFT, -1, size, COL_LABEL)


## Unclaimed touches pass on.
func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventScreenTouch:
		var claimed := _press(event.index, event.position) if event.pressed \
			else _release(event.index)
		if claimed:
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if _drag(event.index, event.position, event.relative):
			get_viewport().set_input_as_handled()


## Readout, button, stick (left half) or look, in that order; true when claimed.
func _press(index: int, pos: Vector2) -> bool:
	if _hud != null and Rect2(_hud.position, HUD_SIZE).has_point(pos):
		_toggle_profile()
		return true
	for e in _buttons:
		var b: Control = e.node
		if Rect2(b.position, b.size).has_point(pos):
			e.held = true
			e["finger"] = index
			_hold(e.action)
			b.queue_redraw()
			return true
	if _stick_finger < 0 and pos.x < get_viewport().get_visible_rect().size.x * 0.5:
		_stick_finger = index
		# The stick centres under the thumb.
		_stick_origin = pos
		_stick.position = pos - Vector2(STICK_RADIUS, STICK_RADIUS)
		_stick_vec = Vector2.ZERO
		_stick.queue_redraw()
		return true
	if _look_finger < 0:
		_look_finger = index
		_look_start_ms = Time.get_ticks_msec()
		_look_moved = 0.0
		return true
	return false


## True when claimed.
func _drag(index: int, pos: Vector2, relative: Vector2) -> bool:
	if index == _stick_finger:
		var v := (pos - _stick_origin) / STICK_RADIUS
		if v.length() > 1.0:
			v = v.normalized()
		_stick_vec = v
		_apply_stick(v)
		_stick.queue_redraw()
		return true
	elif index == _look_finger:
		_look_moved += relative.length()
		_look(relative)
		return true
	return false


## A quick still look is a tap.
func _release(index: int) -> bool:
	for e in _buttons:
		if e.get("finger", -1) == index:
			e.held = false
			e["finger"] = -1
			_unhold(e.action)
			e.node.queue_redraw()
			return true
	if index == _stick_finger:
		_stick_finger = -1
		_stick_vec = Vector2.ZERO
		_apply_stick(Vector2.ZERO)
		_layout()
		return true
	if index == _look_finger:
		var quick := Time.get_ticks_msec() - _look_start_ms <= TAP_MAX_MS
		if quick and _look_moved <= TAP_MAX_DRAG and InputMap.has_action("interact"):
			_tap_interact()
		_look_finger = -1
		return true
	return false


## Screen y and Input.get_vector's y both grow downward, so no inversion.
func _apply_stick(v: Vector2) -> void:
	_axis("ui_left", "ui_right", v.x)
	_axis("ui_up", "ui_down", v.y)


## Strength |value|; neither in the dead zone.
func _axis(neg: String, pos: String, value: float) -> void:
	if absf(value) < STICK_DEADZONE:
		_unhold(neg)
		_unhold(pos)
		return
	if value < 0.0:
		_unhold(pos)
		_hold(neg, absf(value))
	else:
		_unhold(neg)
		_hold(pos, absf(value))


func _hold(action: String, strength: float = 1.0) -> void:
	if not InputMap.has_action(action):
		return
	Input.action_press(action, strength)
	_pressed_actions[action] = true


func _unhold(action: String) -> void:
	if not _pressed_actions.has(action):
		return
	Input.action_release(action)
	_pressed_actions.erase(action)


## Two frames, so is_action_just_pressed sees it.
func _tap_interact() -> void:
	Input.action_press("interact")
	await get_tree().process_frame
	await get_tree().process_frame
	Input.action_release("interact")


func _look(relative: Vector2) -> void:
	var cam := _get_camera()
	if cam == null:
		return
	# Same update and clamp as the mouse path.
	cam.target_rotation.x -= relative.x * LOOK_SENSITIVITY
	cam.target_rotation.y -= relative.y * LOOK_SENSITIVITY
	cam.target_rotation.y = clampf(cam.target_rotation.y, -PI / 2.0, PI / 2.0)


## Looked up again whenever it is replaced (respawn, transform).
func _get_camera() -> Node3D:
	if is_instance_valid(_camera):
		return _camera
	_camera = null
	var nc := get_node_or_null("/root/NetworkController")
	if nc == null:
		return null
	var player = nc.get_indexed("players:local_player")
	if player == null or not is_instance_valid(player):
		return null
	var cam = player.get("camera_controller")
	if cam != null and is_instance_valid(cam) and "target_rotation" in cam:
		_camera = cam
	return _camera


func _notification(what: int) -> void:
	# Otherwise losing focus with a thumb down walks forever.
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and enabled:
		_release_everything()


func _release_everything() -> void:
	for action in _pressed_actions.keys():
		Input.action_release(action)
	_pressed_actions.clear()
	_stick_finger = -1
	_look_finger = -1
	_stick_vec = Vector2.ZERO
	for e in _buttons:
		e.held = false
		e["finger"] = -1
		e.node.queue_redraw()
	if _stick != null:
		_stick.queue_redraw()
