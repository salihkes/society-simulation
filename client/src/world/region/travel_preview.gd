extends Node3D
## Free-fly terrain preview with a streaming stats HUD.

var speed := 500.0
var _hud_timer := 0.0

@onready var camera: Camera3D = $Camera3D
@onready var terrain: Node3D = $CityTerrain
@onready var label: Label = $CanvasLayer/Label


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera.rotation.y -= event.relative.x * 0.002
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * 0.002, -1.5, 1.5)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = minf(speed * 1.4, 12000)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = maxf(speed / 1.4, 20)


func _process(delta: float) -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_fly(delta)
	_hud_timer -= delta
	if _hud_timer <= 0:
		_hud_timer = 0.25
		_update_hud()


func _fly(delta: float) -> void:
	var direction := Vector3(
		_axis(KEY_D, KEY_A),
		_axis(KEY_E, KEY_Q),
		_axis(KEY_S, KEY_W))
	var boost := 4.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0
	camera.position += camera.basis * direction.normalized() * speed * delta * boost


func _axis(positive: Key, negative: Key) -> float:
	return float(Input.is_physical_key_pressed(positive)) - float(Input.is_physical_key_pressed(negative))


func _update_hud() -> void:
	var stats: Dictionary = terrain.get_streaming_stats()
	label.text = ("Country terrain preview\n"
		+ "WASD move · Q/E down/up · Shift boost · Wheel speed · Esc mouse\n"
		+ "Speed %.0f · Position %.0f, %.0f\n"
		+ "%d tiles · %d colliders · %s triangles · %d queued\n"
		+ "FPS %d · largest tile upload %.2f ms") % [
		speed, camera.position.x, camera.position.z,
		stats.tiles, stats.colliders, stats.triangles, stats.queued,
		Engine.get_frames_per_second(), stats.max_upload_ms]
