extends Node3D
## A short-lived lift floor picker in VR; it stays where it opened, not with the head.

const PANEL_SIZE := Vector2(0.8, 1.0)
const VIEWPORT_SIZE := Vector2i(480, 600)
const BUTTON_HEIGHT := 64
const FONT_SIZE := 24
const Pointer := preload("res://src/ui/vr/vr_ui_pointer.gd")

var panel_visible := true

var sub_viewport: SubViewport
var quad: MeshInstance3D
var pointer: Node3D
var player: Node3D
var _camera: Camera3D
var _closed := false
var _close_callback: Callable


## close is called on cancel, or at once without an XR camera.
func open(body: Node3D, title: String, labels: Array, choose: Callable,
		close: Callable) -> void:
	player = body
	_close_callback = close
	_camera = body.get_node_or_null("XROrigin3D/XRCamera3D")
	if _camera == null:
		close.call()
		return
	sub_viewport = SubViewport.new()
	sub_viewport.size = VIEWPORT_SIZE
	sub_viewport.transparent_bg = true
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(sub_viewport)
	_build_list(title, labels, choose, close)
	_build_quad()
	_face_camera()
	pointer = Pointer.new()
	add_child(pointer)
	pointer.setup(self)
	# The chat laser must not click through the picker onto another panel.
	for panel in get_tree().get_nodes_in_group("vr_chat_panel"):
		panel.set_panel_visible(false)


func _build_list(title: String, labels: Array, choose: Callable, close: Callable) -> void:
	var card := PanelContainer.new()
	sub_viewport.add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	card.add_child(list)
	var heading := Label.new()
	heading.text = title
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", FONT_SIZE)
	list.add_child(heading)
	for i in range(labels.size() - 1, -1, -1):
		var button := Button.new()
		button.text = str(labels[i])
		button.custom_minimum_size.y = BUTTON_HEIGHT
		button.add_theme_font_size_override("font_size", FONT_SIZE)
		button.pressed.connect(choose.bind(i))
		list.add_child(button)
	var cancel := Button.new()
	cancel.text = "Close · X / B / Y"
	cancel.custom_minimum_size.y = BUTTON_HEIGHT
	cancel.pressed.connect(close)
	list.add_child(cancel)


## Drawn over everything.
func _build_quad() -> void:
	var mesh := QuadMesh.new()
	mesh.size = PANEL_SIZE
	quad = MeshInstance3D.new()
	quad.mesh = mesh
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.albedo_texture = sub_viewport.get_texture()
	quad.material_override = material
	add_child(quad)


func _face_camera() -> void:
	var forward := -_camera.global_basis.z
	forward.y = 0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	var at := _camera.global_position + (forward * 1.1 + Vector3.DOWN * 0.1) * world_scale()
	global_transform = Transform3D(
			Basis.looking_at(forward).scaled(Vector3.ONE * world_scale()), at)


func world_scale() -> float:
	return _camera.global_basis.x.length() if is_instance_valid(_camera) else 1.0


func request_redraw() -> void:
	if sub_viewport != null and not _closed:
		sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _process(delta: float) -> void:
	if _closed:
		return
	if not is_instance_valid(player) or player.get("is_vr_mode") != true:
		_close_callback.call()
		return
	if pointer != null:
		pointer.update_pointer(delta)


func dismiss() -> void:
	_closed = true
	set_process(false)
	if pointer != null:
		pointer.cancel_press()
	queue_free()


func all_windows() -> Array:
	return [self]
