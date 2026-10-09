extends Node3D
## Orbit and first-person camera for the desktop character; VR uses its own.

@export var mouse_sensitivity := 0.005
@export var rotation_smoothing := 10.0
@export var zoom_sensitivity := 0.5
@export var min_zoom_distance := 1.0
@export var max_zoom_distance := 10.0

@export var first_person_eye_height := 1.6  # used when the head cannot be measured
@export var first_person_smoothing := 14.0

var cam_look: Node3D
var camera: Camera3D

var target_rotation := Vector2.ZERO
var current_rotation := Vector2.ZERO
var initial_rotation := Vector2.ZERO
var is_rotating := false
var current_zoom := 4.0

var first_person := false
var _third_person_pivot := Vector3.ZERO  # CamLook's authored offset, restored on the way out
var _eye_pivot := Vector3.ZERO
var _want_mouse_captured := false        # cleared by Escape, set again by a click in the world
var _hidden_for_first_person: Node3D = null
var _hidden_was_visible := true
var _we_captured_mouse := false          # only give back a cursor we took ourselves
var _refresh_accum := 0.0


func _ready():
	cam_look = $CamLook
	camera = $CamLook/Camera3D

	initial_rotation.x = rotation.y
	initial_rotation.y = cam_look.rotation.x
	target_rotation = initial_rotation
	current_rotation = initial_rotation

	camera.position.y = current_zoom
	_third_person_pivot = cam_look.position

	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# Browsers coalesce mouse motion to about 60 Hz; smooth less to keep the camera on the cursor.
	if OS.has_feature("web"):
		rotation_smoothing = 22.0


# Unhandled input, so the UI (and the chat box) gets events first.


func _unhandled_input(event):
	if event is InputEventKey and event.pressed and not event.echo:
		_on_key(event)
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		if is_rotating or Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			target_rotation.x -= event.relative.x * mouse_sensitivity
			target_rotation.y -= event.relative.y * mouse_sensitivity
			target_rotation.y = clamp(target_rotation.y, -PI/2, PI/2)
			get_viewport().set_input_as_handled()


## Escape hands the cursor back in first person so the chat bar and tools stay usable.
func _on_key(event: InputEventKey) -> void:
	var toggle_pressed: bool = event.keycode == KEY_KP_0
	if not toggle_pressed and InputMap.has_action("toggle_first_person"):
		toggle_pressed = event.is_action_pressed("toggle_first_person")
	if toggle_pressed:
		toggle_first_person()
		get_viewport().set_input_as_handled()
		return
	if event.keycode == KEY_ESCAPE and first_person:
		_want_mouse_captured = false


func _on_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if first_person and event.pressed and not _typing():
				_want_mouse_captured = true
		MOUSE_BUTTON_RIGHT:
			is_rotating = event.pressed
			if first_person:
				_want_mouse_captured = _want_mouse_captured or event.pressed
			elif is_rotating:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_WHEEL_UP:
			_zoom_in()
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_out()
			get_viewport().set_input_as_handled()


## A notch past the closest zoom enters first person.
func _zoom_in() -> void:
	if first_person:
		return
	if current_zoom <= min_zoom_distance + 0.001:
		set_first_person(true)
	else:
		current_zoom = max(current_zoom - zoom_sensitivity, min_zoom_distance)


## The first notch leaves first person.
func _zoom_out() -> void:
	if first_person:
		set_first_person(false)
	else:
		current_zoom = min(current_zoom + zoom_sensitivity, max_zoom_distance)


func _process(delta):
	_update_mouse_capture()
	if first_person:
		_refresh_first_person(delta)

	var t: float = 1.0 - exp(-rotation_smoothing * delta)
	current_rotation = current_rotation.lerp(target_rotation, t)
	rotation.y = current_rotation.x
	cam_look.rotation.x = current_rotation.y

	var f: float = 1.0 - exp(-first_person_smoothing * delta)
	var pivot: Vector3 = _eye_pivot if first_person else _third_person_pivot
	cam_look.position = cam_look.position.lerp(pivot, f)

	var zoom: float = 0.0 if first_person else current_zoom
	camera.position.y = lerp(camera.position.y, zoom, t)


## Polled because /transform swaps the model and /scale resizes it.
func _refresh_first_person(delta: float) -> void:
	_refresh_accum += delta
	if _refresh_accum < 0.5 and is_instance_valid(_hidden_for_first_person):
		return
	_refresh_accum = 0.0
	if _own_head() != _hidden_for_first_person:
		_hide_own_head(false)
		_hide_own_head(true)
	_eye_pivot = _measure_eye_pivot()


func toggle_first_person() -> void:
	set_first_person(not first_person)


## Hides the own head and takes or gives back the cursor.
func set_first_person(active: bool) -> void:
	if active == first_person:
		return
	first_person = active

	if active:
		_eye_pivot = _measure_eye_pivot()
		_hide_own_head(true)
		_want_mouse_captured = true
		current_zoom = min_zoom_distance
	else:
		_hide_own_head(false)
		_want_mouse_captured = false
		if _we_captured_mouse and not is_rotating:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_we_captured_mouse = false

	print("First person " + ("on" if active else "off"))


func is_first_person() -> bool:
	return first_person


## In CamOrigin's frame, a quarter turn about X: world (0, h, 0) is (0, 0, -h) here.
func _measure_eye_pivot() -> Vector3:
	return Vector3(0.0, 0.0, -_eye_height())


## The rig's eyes, else the head mesh, else near the capsule top, else first_person_eye_height.
func _eye_height() -> float:
	var character := get_parent()
	if character == null:
		return first_person_eye_height

	var model := character.get_node_or_null("CharacterModel")
	if model:
		var authored = preload("res://src/character/rig/joint_rig_animation.gd").find_rig(model)
		if authored != null and authored.has_method("get_eye_position"):
			return get_parent().to_local(authored.get_eye_position()).y
		var eyes := _head_eye_height(model)
		if eyes > 0.1:
			return eyes

	var shape_node := character.get_node_or_null("CollisionShape3D")
	if shape_node and shape_node.shape is CapsuleShape3D:
		var capsule: CapsuleShape3D = shape_node.shape
		return shape_node.position.y + capsule.height * 0.5 - capsule.radius * 0.4

	return first_person_eye_height


func _head_eye_height(model: Node) -> float:
	var head := _find_head(model)
	if not (head is MeshInstance3D and head.mesh != null):
		return 0.0
	var box: AABB = head.mesh.get_aabb()
	var xform: Transform3D = model.transform * head.transform
	var centre: Vector3 = xform * box.get_center()
	var head_size: float = absf((xform.basis * box.size).y)
	return centre.y + head_size * 0.15


func _find_head(model: Node) -> Node:
	var head := model.find_child("FirstPersonHead", true, false)
	if head == null:
		head = model.find_child("head", true, false)
	return head


## Only our own model; remote players are separate instances and keep their heads.
func _hide_own_head(hide: bool) -> void:
	if not hide:
		if is_instance_valid(_hidden_for_first_person):
			_hidden_for_first_person.visible = _hidden_was_visible
		_hidden_for_first_person = null
		return

	var head := _own_head()
	if head == null:
		return
	_hidden_for_first_person = head
	_hidden_was_visible = head.visible
	head.visible = false


## A humanoid loses just its head; a countryball or one-mesh custom character is all head.
func _own_head() -> Node3D:
	var character := get_parent()
	var model := character.get_node_or_null("CharacterModel") if character else null
	if model == null:
		return null
	var head := _find_head(model)
	return head if head is Node3D else model


## Not while the chat bar has the cursor or another camera (free cam, a ship) is rendering.
func _update_mouse_capture() -> void:
	if not first_person:
		return
	if camera == null or not camera.current:
		return

	var captured: bool = Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	if _want_mouse_captured and not _typing():
		if not captured:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			_we_captured_mouse = true
	elif captured and _we_captured_mouse:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_we_captured_mouse = false


func _typing() -> bool:
	var focus = get_viewport().gui_get_focus_owner() if get_viewport() else null
	return focus is LineEdit or focus is TextEdit
