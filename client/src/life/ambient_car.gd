extends Node3D

## Ambient traffic car without physics: the authority drives it along the lane graph, others interpolate.

const PALETTE: Array[Color] = [
	Color(0.75, 0.16, 0.14),
	Color(0.16, 0.32, 0.65),
	Color(0.88, 0.86, 0.82),
	Color(0.15, 0.15, 0.17),
	Color(0.75, 0.6, 0.2),
	Color(0.24, 0.5, 0.3),
	Color(0.55, 0.57, 0.6),
]

# Workspace units (a player capsule is about 5).
var target_len := 16.0
const BODY_LEN := 16.0
const BODY_WID := 7.0
const BODY_H := 3.2
const WHEEL_R := 1.6

var car_id := ""
var kind := 0
var model_path := ""  # "" builds the placeholder
var model_yaw_deg := 0.0  # turns models authored facing backwards

var _is_authority := true
var _remote_pos := Vector3.ZERO
var _remote_rot := 0.0
var _got_remote := false
var last_seen_msec := 0

var _speed := 0.0  # set by the manager (authority) / derived (remote)
var _wheels: Array = []
var _prev_pos := Vector3.ZERO
var _vm: VehicleModel = null
var _prev_yaw := 0.0
var _prev_speed := 0.0
var _steer := 0.0
var _night_check := 0.0
var _night := false
var _env = null


const DialogRegistry := preload("res://src/life/dialog/dialog_registry.gd")
const HORN_CLIP := "res://assets/art/sound/city/car_horn_pip.wav"
const ENGINE_LOOP := "res://assets/art/sound/city/car_engine_loop.mp3"
const YELL_LINES := ["drv_yell_1", "drv_yell_2", "drv_yell_3"]

var _engine: AudioStreamPlayer3D = null
var _horn: AudioStreamPlayer3D = null
var _voice: AudioStreamPlayer3D = null
# -1 until the first snapshot, so a late joiner does not replay old honks.
var _seen_honk := -1
var _seen_yell := -1


func _ready():
	if not _build_model():
		_build_placeholder()
	_remote_pos = position
	_prev_pos = position
	_engine = _make_player(60.0)
	_engine.stream = looped_stream(ENGINE_LOOP)
	_engine.volume_db = -26.0
	_engine.autoplay = true
	add_child(_engine)


## Null if it does not load.
static func looped_stream(path: String):
	var stream = load(path)
	if stream == null:
		return null
	var s = stream.duplicate()
	if "loop" in s:
		s.loop = true
	return s


func _make_player(max_distance: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.max_distance = max_distance
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	return p


func honk(double := false):
	if _horn == null:
		_horn = _make_player(90.0)
		var clip = load(HORN_CLIP)
		if clip != null:
			_horn.stream = clip
		add_child(_horn)
	if _horn.stream == null:
		return
	_horn.play()
	if double:
		get_tree().create_timer(0.28).timeout.connect(func():
			if is_instance_valid(_horn):
				_horn.play())


## The voice comes from the car id, so every peer hears the same driver.
func yell(line: int):
	var lid: String = YELL_LINES[clampi(line, 0, YELL_LINES.size() - 1)]
	var path := DialogRegistry.clip(DialogRegistry.voice_for(car_id), lid)
	if not ResourceLoader.exists(path):
		path = DialogRegistry.clip("generic", lid)
	var clip = load(path)
	if clip == null:
		return
	if _voice == null:
		_voice = _make_player(60.0)
		add_child(_voice)
	_voice.stream = clip
	_voice.play()


func apply_events(honk_n: int, honk_double: int, yell_n: int, yell_line: int):
	if _seen_honk < 0:
		_seen_honk = honk_n
		_seen_yell = yell_n
		return
	if honk_n > _seen_honk:
		honk(honk_double == 1)
	if yell_n > _seen_yell:
		yell(yell_line)
	_seen_honk = honk_n
	_seen_yell = yell_n


func set_authority(is_auth: bool) -> void:
	_is_authority = is_auth
	if not is_auth:
		_remote_pos = position
		_remote_rot = rotation.y


func set_driven_state(pos: Vector3, rot_y: float, speed: float) -> void:
	position = pos
	rotation.y = rot_y
	_speed = speed


## The first update snaps.
func apply_remote_state(pos: Vector3, rot_y: float) -> void:
	if not _got_remote:
		position = pos
		rotation.y = rot_y
		_got_remote = true
	_remote_pos = pos
	_remote_rot = rot_y
	last_seen_msec = Time.get_ticks_msec()


func _process(delta: float):
	if not _is_authority:
		position = position.lerp(_remote_pos, delta * 10.0)
		rotation.y = lerp_angle(rotation.y, _remote_rot, delta * 10.0)
		if delta > 0.0:
			_speed = position.distance_to(_prev_pos) / delta
	_prev_pos = position
	if _vm != null:
		_animate_definition(delta)
	elif _speed > 0.05:
		var spin := _speed / WHEEL_R * delta
		for w in _wheels:
			w.rotate_x(-spin)
	if _engine != null:
		var load_amt := clampf(_speed / 16.0, 0.0, 1.0)
		_engine.volume_db = move_toward(_engine.volume_db, -26.0 + load_amt * 12.0, delta * 30.0)
		_engine.pitch_scale = lerpf(_engine.pitch_scale, 0.85 + load_amt * 0.55,
			minf(delta * 4.0, 1.0))


func _animate_definition(delta: float) -> void:
	var dyaw: float = wrapf(rotation.y - _prev_yaw, -PI, PI)
	_prev_yaw = rotation.y
	var want := 0.0
	if _speed > 0.3 and delta > 0.0 and _vm.is_built:
		want = atan2((dyaw / delta) * _vm.definition.wheelbase * _vm.fit_scale, _speed)
	var lock := deg_to_rad(_vm.definition.max_steer_deg) if _vm.is_built else 0.5
	_steer = clampf(lerpf(_steer, want, minf(delta * 8.0, 1.0)), -lock, lock)
	_vm.animate(delta, _speed, _steer)
	_night_check -= delta
	if _night_check <= 0.0:
		_night_check = 5.0
		_night = _is_night()
	var brake: bool = (_prev_speed - _speed) / maxf(delta, 0.001) > 3.0 and _speed > 0.2
	_prev_speed = _speed
	_vm.set_lights(_night, brake)


## 18:30 to 06:30 by the scene's EnvironmentController.
func _is_night() -> bool:
	if _env == null or not is_instance_valid(_env):
		var root := get_tree().current_scene if get_tree() != null else null
		_env = root.find_child("EnvironmentController", true, false) if root != null else null
	if _env == null or not ("current_time" in _env):
		return false
	var hour: float = float(_env.current_time) * 24.0
	return hour < 6.5 or hour >= 18.5


func _build_model() -> bool:
	if model_path == "":
		return false
	if model_path.ends_with(".tres") or model_path.ends_with(".res"):
		return _build_definition()
	return _build_scene()


func _build_definition() -> bool:
	var definition = load(model_path)
	if definition == null or not (definition is VehicleDefinition):
		push_warning("[AmbientCar] Not a VehicleDefinition: " + model_path)
		return false
	_vm = VehicleModel.new()
	_vm.name = "Model"
	add_child(_vm)
	_vm.built.connect(func(): _vm.paint_from_id(car_id))
	_vm.build(definition, "car:" + car_id)
	_prev_yaw = rotation.y
	return true


## Longest horizontal axis along Z, scaled to target_len, centred, wheels on the ground.
func _build_scene() -> bool:
	var scene = load(model_path)
	if scene == null or not (scene is PackedScene):
		push_warning("[AmbientCar] Cannot load car model: " + model_path)
		return false
	var model: Node3D = (scene as PackedScene).instantiate() as Node3D
	if model == null:
		return false
	add_child(model)

	var aabb := _combined_aabb(model)
	if aabb.size.length_squared() < 0.000001:
		model.queue_free()
		return false

	var yaw := deg_to_rad(model_yaw_deg)
	if aabb.size.x > aabb.size.z:
		yaw += PI / 2.0
	var length: float = maxf(aabb.size.x, aabb.size.z)
	var s: float = target_len / maxf(length, 0.001)

	model.rotation.y = yaw
	model.scale = Vector3.ONE * s
	var center := aabb.get_center()
	var c2 := Vector3(center.x, 0.0, center.z).rotated(Vector3.UP, yaw) * s
	model.position = Vector3(-c2.x, -aabb.position.y * s, -c2.z)
	return true


## Needs the model in the tree.
func _combined_aabb(model: Node3D) -> AABB:
	var inv := model.global_transform.affine_inverse()
	var merged := AABB()
	var first := true
	var stack: Array = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D):
			continue
		var mi := node as MeshInstance3D
		var rel: Transform3D = inv * mi.global_transform
		var box := mi.get_aabb()
		for c in 8:
			var corner: Vector3 = rel * box.get_endpoint(c)
			if first:
				merged = AABB(corner, Vector3.ZERO)
				first = false
			else:
				merged = merged.expand(corner)
	return merged


func _build_placeholder():
	var paint := StandardMaterial3D.new()
	paint.albedo_color = PALETTE[kind % PALETTE.size()]
	_add_box(Vector3(BODY_WID, BODY_H, BODY_LEN), paint,
		Vector3(0, WHEEL_R + BODY_H * 0.5, 0))

	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.12, 0.16, 0.2)
	_add_box(Vector3(BODY_WID * 0.85, BODY_H * 0.8, BODY_LEN * 0.45), glass,
		Vector3(0, WHEEL_R + BODY_H + BODY_H * 0.4, BODY_LEN * 0.05))

	_build_placeholder_wheels()
	_build_placeholder_lamps()


func _add_box(size: Vector3, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


func _build_placeholder_wheels():
	var wheel_mesh := CylinderMesh.new()
	wheel_mesh.top_radius = WHEEL_R
	wheel_mesh.bottom_radius = WHEEL_R
	wheel_mesh.height = 1.0
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color(0.08, 0.08, 0.08)
	for side in [-1.0, 1.0]:
		for fore in [-1.0, 1.0]:
			var pivot := Node3D.new()
			pivot.position = Vector3(side * BODY_WID * 0.5, WHEEL_R, fore * BODY_LEN * 0.32)
			add_child(pivot)
			var wheel := MeshInstance3D.new()
			wheel.mesh = wheel_mesh
			wheel.material_override = rubber
			wheel.rotation.z = PI / 2.0
			pivot.add_child(wheel)
			_wheels.append(pivot)


## Emissive quads rather than lights: dozens of OmniLight3Ds would cost too much.
func _build_placeholder_lamps():
	var lamp := StandardMaterial3D.new()
	lamp.albedo_color = Color(1.0, 0.95, 0.8)
	lamp.emission_enabled = true
	lamp.emission = Color(1.0, 0.95, 0.7)
	lamp.emission_energy_multiplier = 2.0
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(1.2, 0.8, 0.2)
	for side in [-1.0, 1.0]:
		var l := MeshInstance3D.new()
		l.mesh = lamp_mesh
		l.material_override = lamp
		l.position = Vector3(side * BODY_WID * 0.32, WHEEL_R + BODY_H * 0.6, -BODY_LEN * 0.5)
		add_child(l)
