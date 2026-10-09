class_name InGameComputer
extends Node3D
## A desk computer showing a server-hosted OS session; origin at the monitor's bottom centre.

@export var computer_id := ""
## Resident id (residents.json key) of the owner; "" for a library computer.
@export var owner_id := ""
@export var preset: Resource
@export var use_distance := 2.6
@export var leave_distance := 5.0
## 1.0 fills the view with the picture; larger values leave the bezel in view.
@export_range(1.0, 3.0, 0.05) var focus_margin := 1.4

@onready var _tv: Node3D = $CRTTV
@onready var _seat: Marker3D = $Seat
@onready var _prompt: Label3D = $Prompt

var _screen: RemoteScreen
var _session: Dictionary = {}
var _open := false
var _watching := false # over the owner's shoulder: look, don't touch
var _keys := false
var _focused := false
var _focus_cam: Camera3D = null
var _prev_cam: Camera3D = null
var _dof: Dictionary = {}
var _player: Node3D
var _nc: Node
var _mods_down: Array = []


func _ready() -> void:
	add_to_group("computers")
	if preset != null:
		_tv.preset = preset
	_tv.autoplay = false
	_tv.powered = false
	_prompt.visible = false
	_nc = get_node_or_null("/root/NetworkController")
	set_process_input(false)


func place_pos() -> Vector3:
	return global_position


func place_entry(world: Node3D) -> Dictionary:
	var p: Vector3 = world.to_local(global_position) if world != null else global_position
	return {"id": computer_id, "kind": "computer", "owner": owner_id,
		"pos": [snappedf(p.x, 0.1), snappedf(p.y, 0.1), snappedf(p.z, 0.1)], "verbs": ["use"]}


func _process(_delta: float) -> void:
	var me := _local_player()
	if me == null:
		_prompt.visible = false
		if _open:
			_leave()
		return
	var dist := me.global_position.distance_to(global_position)
	if _open:
		if dist > leave_distance:
			_leave()
			return
		if Input.is_action_just_pressed("screen_focus") and not _typing_elsewhere(me):
			set_focused(not _focused)
			return
		if not _keys and Input.is_action_just_pressed("interact") and not _typing_elsewhere(me):
			_leave()
			return
		_show_prompt()
		return
	var near := dist <= use_distance
	_prompt.visible = near
	if near and _prompt.text == "…":
		return
	if near and Input.is_action_just_pressed("interact") and not _typing_elsewhere(me):
		request_open()


func _local_player() -> Node3D:
	if _nc == null or not is_instance_valid(_nc.get_indexed("players:local_player")):
		return null
	return _nc.players.local_player


## True while the player types elsewhere (the chat bar), so E is not ours.
func _typing_elsewhere(me: Node) -> bool:
	if me.get("key_holder") == self:
		return false
	return me.has_method("_typing") and me._typing()


func _show_prompt() -> void:
	_prompt.visible = true
	if _watching:
		_say("watching · E leave")
	elif _focused:
		_say("F or Esc leans back out")
	elif _keys:
		_say("Esc gives the keys back")
	else:
		_say("F look closer · click to type · E leave")


func _say(text: String) -> void:
	_prompt.text = text
	_prompt.font_size = 48 if text.length() <= 3 else 18
	_prompt.outline_size = 12 if text.length() <= 3 else 5


func request_open() -> void:
	if _nc == null or not _nc.connected:
		_say("no connection")
		return
	_say("…")
	_nc.send_json({"type": "pc_open", "id": computer_id})


func on_session(msg: Dictionary) -> void:
	if msg.get("error", "") != "":
		_say(str(msg["error"]))
		await get_tree().create_timer(3.0).timeout
		_say("E")
		return
	var me := _local_player()
	if me == null:
		return
	_session = msg
	_watching = bool(msg.get("watching", false))
	if _screen == null:
		_screen = RemoteScreen.new()
		_screen.name = "Screen"
		add_child(_screen)
		_screen.connected.connect(_on_screen_connected)
		_screen.closed.connect(_on_screen_closed)
	_screen.open(str(msg.get("url", "")))
	_player = me
	_open = true
	_keys = false
	# The near depth of field would blur the screen; restored in _leave().
	_suppress_blur()
	set_process_input(true)
	_show_prompt()


func _on_screen_connected() -> void:
	_tv.set_source_texture(_screen.texture)
	_tv.power_on()


func _on_screen_closed(reason: String) -> void:
	_tv.power_off()
	if _open:
		_leave(false)
	_say("E")
	print("[Computer] %s: screen closed (%s)" % [computer_id, reason])


func set_focused(on: bool) -> void:
	if on == _focused:
		return
	if on and (not _open or _screen == null):
		return
	_focused = on
	if on:
		_focus_cam = _make_focus_camera()
		if _focus_cam == null:
			_focused = false
			return
		_prev_cam = get_viewport().get_camera_3d()
		_set_controller_running(false)
		_focus_cam.current = true
		_take_keys()
	else:
		if _focus_cam != null and is_instance_valid(_focus_cam):
			_focus_cam.queue_free()
		_focus_cam = null
		_set_controller_running(true)
		if _prev_cam != null and is_instance_valid(_prev_cam):
			_prev_cam.current = true
		_prev_cam = null
		_release_keys()
	_show_prompt()


func _make_focus_camera() -> Camera3D:
	if not _tv.has_method("viewing_transform"):
		return null
	var vp := get_viewport()
	var size: Vector2 = vp.get_visible_rect().size
	var aspect: float = size.x / maxf(size.y, 1.0)
	var cam := Camera3D.new()
	cam.name = "FocusCamera"
	cam.fov = 50.0
	cam.near = 0.01
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_near_enabled = false
	attrs.dof_blur_far_enabled = false
	cam.attributes = attrs
	add_child(cam)
	cam.global_transform = _tv.viewing_transform(cam.fov, aspect, focus_margin)
	return cam


func _set_controller_running(on: bool) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var rig = _player.get("camera_controller")
	if rig != null and is_instance_valid(rig):
		rig.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED


func _suppress_blur() -> void:
	if not _dof.is_empty():
		return
	var env := _world_environment()
	if env == null or env.camera_attributes == null:
		return
	var a = env.camera_attributes
	if not (a is CameraAttributesPractical):
		return
	var practical := a as CameraAttributesPractical
	_dof = {"near": practical.dof_blur_near_enabled, "far": practical.dof_blur_far_enabled}
	practical.dof_blur_near_enabled = false
	practical.dof_blur_far_enabled = false


func _restore_blur() -> void:
	if _dof.is_empty():
		return
	var env := _world_environment()
	if env != null and env.camera_attributes is CameraAttributesPractical:
		var practical := env.camera_attributes as CameraAttributesPractical
		practical.dof_blur_near_enabled = bool(_dof.get("near", true))
		practical.dof_blur_far_enabled = bool(_dof.get("far", true))
	_dof.clear()


func _world_environment() -> WorldEnvironment:
	var root := get_tree().current_scene
	if root == null:
		return null
	var found := root.find_child("WorldEnvironment", true, false)
	return found as WorldEnvironment


## The body stops reacting while the OS has the keys.
func _take_keys() -> void:
	if _keys or _watching or _player == null or not is_instance_valid(_player):
		return
	_keys = true
	_player.set("key_holder", self)
	_show_prompt()


func _release_keys() -> void:
	if not _keys:
		return
	_keys = false
	for ks in _mods_down:
		if _screen != null:
			_screen.send_key(ks, false)
	_mods_down.clear()
	if _player != null and is_instance_valid(_player) and _player.get("key_holder") == self:
		_player.set("key_holder", null)
	_show_prompt()


func _leave(tell_server := true) -> void:
	set_process_input(false)
	set_focused(false)
	_restore_blur()
	_release_keys()
	_open = false
	_watching = false
	_player = null
	if tell_server and _nc != null and _nc.connected:
		_nc.send_json({"type": "pc_close", "id": computer_id})
	if _screen != null:
		_screen.close("left")
	_tv.power_off()
	_say("E")


## Null when the cursor is not over the glass.
func _pointer_at_cursor() -> Variant:
	if _screen == null or not _screen.is_open or _screen.width <= 0:
		return null
	var vp := get_viewport()
	var cam := vp.get_camera_3d()
	if cam == null:
		return null
	var mp := vp.get_mouse_position()
	var uv: Vector2 = _tv.picture_uv_from_ray(cam.project_ray_origin(mp), cam.project_ray_normal(mp))
	if uv.x < 0.0:
		return null
	return Vector2i(int(uv.x * _screen.width), int(uv.y * _screen.height))


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventKey:
		_key_input(event as InputEventKey)
		return
	if _watching:
		return
	if event is InputEventMouseMotion:
		var at = _pointer_at_cursor()
		if at != null:
			_screen.send_move(at.x, at.y)
	elif event is InputEventMouseButton:
		_mouse_button_input(event as InputEventMouseButton)


func _key_input(k: InputEventKey) -> void:
	if not _keys:
		return
	if k.keycode == KEY_ESCAPE:
		if k.pressed:
			if _focused:
				set_focused(false)
			else:
				_release_keys()
		get_viewport().set_input_as_handled()
		return
	if _screen == null or not _screen.is_open:
		return
	var ks: String = RemoteScreen.KEYSYMS.get(k.keycode, "")
	if ks in ["Shift_L", "Control_L", "Alt_L", "Super_L"]:
		if k.pressed and not _mods_down.has(ks):
			_mods_down.append(ks)
		elif not k.pressed:
			_mods_down.erase(ks)
	if _screen.send_key_event(k):
		get_viewport().set_input_as_handled()


## The right button stays with the camera.
func _mouse_button_input(mb: InputEventMouseButton) -> void:
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		return
	var at = _pointer_at_cursor()
	if at == null:
		return
	_screen.send_move(at.x, at.y)
	var b := 0
	match mb.button_index:
		MOUSE_BUTTON_LEFT: b = 1
		MOUSE_BUTTON_MIDDLE: b = 2
		MOUSE_BUTTON_WHEEL_UP: b = 4
		MOUSE_BUTTON_WHEEL_DOWN: b = 5
	if b == 0:
		return
	if b >= 4:
		if mb.pressed:
			_screen.send_button(b, true)
			_screen.send_button(b, false)
	else:
		_screen.send_button(b, mb.pressed)
		if b == 1 and mb.pressed:
			_take_keys()
	get_viewport().set_input_as_handled()
