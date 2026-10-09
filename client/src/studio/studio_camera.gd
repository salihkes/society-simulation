extends Node3D
## The studio's camera rig: free flight, orbit or follow; angles are radians here, poses store degrees.

enum Mode { FREE, ORBIT, FOLLOW }

var camera: Camera3D
var mode: int = Mode.FREE
## Free-flight units per second; a person is about one unit tall.
var speed := 4.0
var mouse_sensitivity := 0.0035
var smooth := true
var smoothing := 18.0
var yaw := 0.0
var pitch := 0.0
var roll := 0.0
var _cur_yaw := 0.0
var _cur_pitch := 0.0

var target := Vector3.ZERO
var target_node: Node3D = null
## Height above target_node to look at.
var look_height := 0.8
var distance := 3.0
## Orbit: automatic turn in degrees per second.
var spin_deg := 0.0
## Follow: keep the angle relative to the person's facing.
var chase := true
var _chase_ref_yaw := 0.0


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.near = 0.02
	camera.far = 4000.0
	add_child(camera)
	camera.current = true
	_cur_yaw = yaw
	_cur_pitch = pitch
	_apply_rotation()


## Pitch is clamped; no smoothing.
func set_look(p_yaw: float, p_pitch: float, p_roll := 0.0) -> void:
	yaw = p_yaw
	pitch = clampf(p_pitch, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)
	roll = p_roll
	_cur_yaw = yaw
	_cur_pitch = pitch
	_apply_rotation()


## Angles in degrees, as stored in shot lists.
func get_pose() -> Dictionary:
	return {
		"pos": [global_position.x, global_position.y, global_position.z],
		"yaw": rad_to_deg(rotation.y), "pitch": rad_to_deg(rotation.x),
		"roll": rad_to_deg(roll), "fov": camera.fov,
	}


func set_pose(d: Dictionary) -> void:
	set_mode(Mode.FREE)
	var p = d.get("pos", [0, 0, 0])
	global_position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	set_look(deg_to_rad(float(d.get("yaw", 0.0))), deg_to_rad(float(d.get("pitch", 0.0))),
		deg_to_rad(float(d.get("roll", 0.0))))
	camera.fov = float(d.get("fov", camera.fov))


## For the fly-through, t 0..1; yaw takes the short way.
func apply_lerp(a: Dictionary, b: Dictionary, t: float) -> void:
	var pa = a.get("pos", [0, 0, 0])
	var pb = b.get("pos", [0, 0, 0])
	var va := Vector3(float(pa[0]), float(pa[1]), float(pa[2]))
	var vb := Vector3(float(pb[0]), float(pb[1]), float(pb[2]))
	global_position = va.lerp(vb, t)
	var y := lerp_angle(_rad(a, "yaw"), _rad(b, "yaw"), t)
	var pt := lerpf(_rad(a, "pitch"), _rad(b, "pitch"), t)
	var r := lerp_angle(_rad(a, "roll"), _rad(b, "roll"), t)
	set_look(y, pt, r)
	camera.fov = lerpf(float(a.get("fov", camera.fov)), float(b.get("fov", camera.fov)), t)


func point_at(p: Vector3) -> void:
	var d := p - global_position
	if d.length() < 0.001:
		return
	set_look(atan2(-d.x, -d.z), atan2(d.y, Vector2(d.x, d.z).length()), roll)


func _rad(pose: Dictionary, key: String) -> float:
	return deg_to_rad(float(pose.get(key, 0.0)))


## Keeps the current view.
func set_mode(m: int) -> void:
	if m == mode:
		return
	if m == Mode.FREE:
		yaw = rotation.y
		pitch = rotation.x
		_cur_yaw = yaw
		_cur_pitch = pitch
	elif mode == Mode.FREE and target_node == null:
		target = global_position + (-basis.z) * distance
	if m == Mode.FOLLOW and target_node != null and is_instance_valid(target_node):
		_chase_ref_yaw = target_node.global_rotation.y
	mode = m


## Without a node, orbits or follows p_point.
func aim_at(p_node: Node3D, p_point: Vector3, p_mode: int, p_distance := -1.0) -> void:
	target_node = p_node
	target = p_point
	if p_distance > 0.0:
		distance = p_distance
	if p_node != null and is_instance_valid(p_node):
		_chase_ref_yaw = p_node.global_rotation.y
	if mode == Mode.FREE:
		point_at(target_position())
	mode = p_mode


## look_height above target_node, else target.
func target_position() -> Vector3:
	if target_node != null and is_instance_valid(target_node):
		return target_node.global_position + Vector3.UP * look_height
	return target


## Takes effect through smoothing on the next tick.
func look_delta(rel: Vector2) -> void:
	yaw -= rel.x * mouse_sensitivity
	pitch = clampf(pitch - rel.y * mouse_sensitivity, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)


func pan(rel: Vector2) -> void:
	var k := 0.0025 * maxf(speed * 0.5 if mode == Mode.FREE else distance, 0.2)
	var d := -basis.x * rel.x * k + basis.y * rel.y * k
	if mode == Mode.FREE:
		global_position += d
	else:
		target = target_position() + d
		target_node = null


## Flight speed in free mode, distance otherwise.
func zoom(steps: float) -> void:
	if mode == Mode.FREE:
		speed = clampf(speed * pow(1.15, steps), 0.05, 200.0)
	else:
		distance = clampf(distance * pow(0.88, steps), 0.05, 500.0)


## move: x strafe, y up/down, z forward (-1 is ahead).
func tick(delta: float, move: Vector3, fast: bool, slow: bool) -> void:
	var v := speed * (3.0 if fast else 1.0) * (0.2 if slow else 1.0)
	match mode:
		Mode.FREE:
			_tick_free(delta, move, v)
		Mode.ORBIT, Mode.FOLLOW:
			_tick_orbit(delta, move, v)


func _tick_free(delta: float, move: Vector3, v: float) -> void:
	if move.length_squared() > 0.0:
		var dir: Vector3 = basis * Vector3(move.x, 0.0, move.z)
		dir.y += move.y
		if dir.length() > 0.0:
			global_position += dir.normalized() * v * delta
	_smooth_rotation(delta)
	_apply_rotation()


func _tick_orbit(delta: float, move: Vector3, v: float) -> void:
	if mode == Mode.ORBIT and spin_deg != 0.0:
		yaw += deg_to_rad(spin_deg) * delta
	if move.z != 0.0:
		distance = clampf(distance * (1.0 + move.z * delta * 1.5), 0.05, 500.0)
	if move.x != 0.0 and target_node == null:
		target += basis.x * move.x * v * delta
	if move.y != 0.0:
		look_height += move.y * delta * v * 0.5
	_smooth_rotation(delta)
	var y := _cur_yaw
	if mode == Mode.FOLLOW and chase and target_node != null and is_instance_valid(target_node):
		y += target_node.global_rotation.y - _chase_ref_yaw
	var cp := cos(_cur_pitch)
	var fwd := Vector3(-sin(y) * cp, sin(_cur_pitch), -cos(y) * cp)
	global_position = target_position() - fwd * distance
	rotation = Vector3(_cur_pitch, y, roll)


func _smooth_rotation(delta: float) -> void:
	if smooth and smoothing > 0.0:
		var w := 1.0 - exp(-delta * smoothing)
		_cur_yaw = lerp_angle(_cur_yaw, yaw, w)
		_cur_pitch = lerpf(_cur_pitch, pitch, w)
	else:
		_cur_yaw = yaw
		_cur_pitch = pitch


func _apply_rotation() -> void:
	rotation = Vector3(_cur_pitch, _cur_yaw, roll)
