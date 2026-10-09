extends CharacterBody3D
class_name DrivableVehicle

## A borrowable vehicle built from a VehicleDefinition; the authority simulates it, other peers interpolate.

enum Mode { IDLE, PLAYER, NPC }

# Zoom runs from 0 (the driver's eyes) to 1 (far chase).
const FP_ZOOM := 0.03            # at or below this the view is first person
const CAM_ZOOM_STEP := 0.06      # one mouse-wheel notch
const CAM_ZOOM_CURVE := 1.6      # >1 puts the fine control near the vehicle
const CAM_EYE_BLEND := 0.18      # zoom by which the origin has left the eyes
const DOOR_SECONDS := 0.55
const NO_ONE := -1
const NPC_FIGURE_SCENE := "res://assets/entities/character/humanoid.tscn"
## Downward velocity (workspace units/s) kept when grounded so push-outs cannot ratchet it up.
const GROUND_STICK := 1.0

var definition: VehicleDefinition
var net_id := ""
var manager = null               # VehicleManager
var mode: int = Mode.IDLE
var driver_id: int = NO_ONE      # player id at the wheel (replicated)
var driver: Node = null          # that player's node on this peer (may be null)
var occupants: Dictionary = {}   # player id -> player node
var occupant_seat: Dictionary = {}  # player id -> seat name

var _is_authority := false
var _speed := 0.0                # workspace units / s, signed
var _steer := 0.0                # radians, + = left
var _braking := false
var _prev_speed := 0.0
# Paint indices; -1 means the colour derived from net_id.
var _paint_body := -1
var _paint_roof := -1
var _sim_driven := false         # the ambient lane sim places us
var _model_ready := false
var _scale := 1.0                # model fit scale
var _vm: VehicleModel = null     # the fitted model: wheels, pivots, doors, lights
var _seats: Dictionary = {}      # seat name -> unscaled Node3D under the body
var _wheel_radius_units := 1.0
var _wheelbase_units := 10.0
var _ground_probes: Array[Vector3] = []  # wheel centres in body space
var _extent := AABB()            # model bounds in body space after the fit
var _scan_points: Array[Node3D] = []   # what traffic scans: body, nose, tail
var _npc_figure: Node3D = null
var _impact_cd := 0.0
var _sim_last_msec := 0

var _remote_xform := Transform3D.IDENTITY
var _has_remote := false

var _engine: AudioStreamPlayer3D = null
var _horn: AudioStreamPlayer3D = null

# Local camera; it lives under the current scene, outside the world's scale.
var _camera: Camera3D = null
var _cam_zoom := 0.6             # 0 = first person in the driver seat, 1 = far chase
var _last_tp_zoom := 0.6
var _cam_yaw := 0.0
var _cam_pitch := 0.0
var _orbiting := false


func setup(p_definition: VehicleDefinition, p_net_id: String, p_manager) -> void:
	definition = p_definition
	net_id = p_net_id
	manager = p_manager


func _ready() -> void:
	if definition == null:
		definition = VehicleDefinition.new()
	floor_max_angle = deg_to_rad(52.0)
	_build_sounds()
	_vm = VehicleModel.new()
	_vm.name = "Model"
	add_child(_vm)
	_vm.built.connect(_on_model_built)
	_vm.build(definition, "vehicle:" + net_id)


func is_ready() -> bool:
	return _model_ready


func _apply_paint() -> void:
	if _vm == null or not _vm.has_paint():
		return
	if _paint_body < 0:
		_vm.paint_from_id(net_id)
		return
	var pick: Dictionary = definition.paint_at(_paint_body, _paint_roof)
	_vm.set_paint(pick.body, pick.roof)


func paintable() -> bool:
	return _vm != null and _vm.has_paint()


func paint_indices() -> Vector2i:
	return Vector2i(_paint_body, _paint_roof)


func set_paint_indices(body_index: int, roof_index: int) -> void:
	_paint_body = body_index
	_paint_roof = roof_index
	_apply_paint()


## Returns the new (body, roof) indices, or (-1, -1) if unpaintable.
func next_paint() -> Vector2i:
	if not paintable():
		return Vector2i(-1, -1)
	var b: int = _paint_body if _paint_body >= 0 else int(hash(net_id))
	var r: int = _paint_roof if _paint_roof >= 0 else int(hash(net_id + "roof"))
	b = posmod(b + 1, maxi(definition.paint_colors.size(), 1))
	if b == 0 and not definition.roof_colors.is_empty():
		r = posmod(r + 1, definition.roof_colors.size())
	set_paint_indices(b, r)
	return Vector2i(b, r)


func _on_model_built() -> void:
	_scale = _vm.fit_scale
	_extent = _vm.extent
	_wheel_radius_units = definition.wheel_radius * _scale if not _vm.wheels.is_empty() else 0.0
	_wheelbase_units = definition.wheelbase * _scale
	_make_seats()
	_make_scan_points()
	_build_collision()
	_apply_paint()
	_model_ready = true


## Seats are unscaled so a seated player keeps its own scale.
func _make_seats() -> void:
	for seat_name in definition.seat_names():
		var node := Node3D.new()
		node.name = "Seat_" + seat_name
		add_child(node)
		var at = _vm.anchor_local(seat_name)
		if at != null:
			node.position = at
		else:
			if definition.model_path != "":
				push_warning("[Vehicle] %s: no seat node '%s' in model" %
						[definition.display_name, seat_name])
			node.position = Vector3(0.0, _extent.size.y * 0.45, 0.0)
		_seats[seat_name] = node


## Nose and tail too, so a long vehicle is not seen only at its centre.
func _make_scan_points() -> void:
	_scan_points = [self]
	for pair in [["Nose", _extent.position.z], ["Tail", _extent.end.z]]:
		var m := Node3D.new()
		m.name = pair[0]
		add_child(m)
		m.position = Vector3(_extent.get_center().x, _extent.get_center().y, pair[1])
		_scan_points.append(m)


## Wheel spheres let kerbs roll under instead of stopping the body box.
func _build_collision() -> void:
	var clearance: float = _wheel_radius_units * 0.9
	var size: Vector3
	var center: Vector3
	if definition.body_size != Vector3.ZERO:
		size = definition.body_size * _scale
		center = definition.body_offset * _scale
	else:
		size = Vector3(_extent.size.x * 0.9, maxf(_extent.size.y - clearance, 0.1),
				_extent.size.z * 0.96)
		center = _extent.get_center()
		center.y = clearance + size.y * 0.5
	var body := CollisionShape3D.new()
	body.name = "Body"
	var box := BoxShape3D.new()
	box.size = size
	body.shape = box
	body.position = center
	add_child(body)
	for wp in _vm.wheel_positions_local():
		var cs := CollisionShape3D.new()
		cs.name = "WheelShape"
		var sphere := SphereShape3D.new()
		sphere.radius = _wheel_radius_units * 0.98
		cs.shape = sphere
		add_child(cs)
		cs.position = wp
		_ground_probes.append(wp)


func _build_sounds() -> void:
	_engine = AudioStreamPlayer3D.new()
	var loop = load(definition.engine_loop) if definition.engine_loop != "" else null
	if loop != null:
		var s = loop.duplicate()
		if "loop" in s:
			s.loop = true
		_engine.stream = s
	_engine.max_distance = 60.0
	_engine.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_engine.volume_db = definition.engine_volume_db
	add_child(_engine)


func snap_to_ground() -> void:
	if not is_inside_tree():
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var ws := _world_scale()
	var from := global_position + Vector3.UP * 3.0
	var to := global_position - Vector3.UP * 12.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	if not hit.is_empty():
		global_position.y = hit.position.y + 0.02 * ws


func _physics_process(delta: float) -> void:
	if _is_authority:
		if not _sim_driven:
			_integrate(delta)
	elif _has_remote:
		global_transform = global_transform.interpolate_with(
			_remote_xform, clampf(delta * 12.0, 0.0, 1.0))
	_animate(delta)
	if _camera != null and _camera.current:
		_update_camera(delta)


func _integrate(delta: float) -> void:
	var controls := _read_controls()
	var braking := controls.z > 0.0
	_braking = braking
	var on_floor := is_on_floor()
	_update_speed(controls.x, braking, delta)
	_update_steering(controls.y, on_floor, delta)
	var fwd := _move(on_floor, delta)
	_scrub_on_impact(fwd, delta)


## (throttle, steer, brake) from the local driver; zero otherwise.
func _read_controls() -> Vector3:
	if mode != Mode.PLAYER or not _local_drives() or _typing():
		return Vector3.ZERO
	var throttle := 0.0
	var steer_in := 0.0
	var braking := false
	if driver.get("is_vr_mode") == true:
		var controls := vr_controls(driver.get("vr_movement"))
		throttle = controls.x
		steer_in = controls.y
		braking = controls.z > 0.0
	if Input.is_key_pressed(KEY_W):
		throttle += 1.0
	if Input.is_key_pressed(KEY_S):
		throttle -= 1.0
	if Input.is_key_pressed(KEY_A):
		steer_in += 1.0
	if Input.is_key_pressed(KEY_D):
		steer_in -= 1.0
	braking = braking or Input.is_key_pressed(KEY_SPACE)
	return Vector3(throttle, steer_in, 1.0 if braking else 0.0)


func _update_speed(throttle: float, braking: bool, delta: float) -> void:
	var d := definition
	if braking:
		_speed = move_toward(_speed, 0.0, d.drive_brake * delta)
	elif throttle > 0.0:
		if _speed < -0.5:
			_speed = move_toward(_speed, 0.0, d.drive_brake * delta)
		else:
			_speed = move_toward(_speed, d.drive_max_speed, d.drive_accel * delta)
	elif throttle < 0.0:
		if _speed > 0.5:
			_speed = move_toward(_speed, 0.0, d.drive_brake * delta)
		else:
			_speed = move_toward(_speed, -d.drive_reverse_speed, d.drive_accel * 0.8 * delta)
	else:
		_speed = move_toward(_speed, 0.0, d.drive_coast * delta)


## The steering lock shrinks with speed; the body yaws only when grounded.
func _update_steering(steer_in: float, on_floor: bool, delta: float) -> void:
	var lock := _steer_lock()
	_steer = move_toward(_steer, steer_in * lock, deg_to_rad(definition.drive_steer_rate) * delta)
	if on_floor and absf(_speed) > 0.01 and absf(_steer) > 0.0001:
		var yaw_rate := _speed / maxf(_wheelbase_units, 0.1) * tan(_steer)
		global_rotate(Vector3.UP, yaw_rate * delta)


## Velocity is in world metres (workspace units times world scale). Returns the heading.
func _move(on_floor: bool, delta: float) -> Vector3:
	var ws := _world_scale()
	floor_snap_length = maxf(_wheel_radius_units * 0.5, 0.25) * ws
	var fwd := _forward()
	var travel := fwd
	if on_floor:
		travel = fwd.slide(get_floor_normal()).normalized()
	var horiz := travel * _speed * ws
	velocity.x = horiz.x
	velocity.z = horiz.z
	if not on_floor:
		velocity.y -= definition.drive_gravity * delta
	else:
		velocity.y = horiz.y - GROUND_STICK * ws
	move_and_slide()
	# Uphill velocity disables floor snapping; keep contact at crests.
	if on_floor and not is_on_floor():
		apply_floor_snap()
	if is_on_floor():
		_align_to_ground(delta)
	return fwd


## A head-on hit scrubs most of the speed instead of grinding into the wall.
func _scrub_on_impact(fwd: Vector3, delta: float) -> void:
	_impact_cd = maxf(_impact_cd - delta, 0.0)
	if _impact_cd > 0.0:
		return
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		if n.y > 0.7:
			continue
		if n.dot(fwd * signf(_speed)) < -0.5 and absf(_speed) > 1.0:
			_speed *= 0.35
			_impact_cd = 0.3
			break


func _align_to_ground(delta: float) -> void:
	var normal := get_floor_normal()
	var fitted := _plane_normal(_wheel_contacts())
	if fitted != Vector3.ZERO and fitted.y >= cos(floor_max_angle):
		normal = fitted
	var basis := global_basis
	var up := basis.y.normalized().slerp(normal, 1.0 - exp(-12.0 * delta)).normalized()
	var heading := _forward()
	var forward := (heading + Vector3.UP * (-heading.dot(up) / maxf(up.y, 0.001))).normalized()
	var right := forward.cross(up).normalized()
	global_basis = Basis(right, up, -forward).scaled(basis.get_scale())


## Static walkable ground only; other bodies are obstacles, not road.
func _wheel_contacts() -> Array[Vector3]:
	var points: Array[Vector3] = []
	var reach := maxf(_wheelbase_units * 0.65, _wheel_radius_units * 2.0) * _world_scale()
	var space := get_world_3d().direct_space_state
	for wheel in _ground_probes:
		var centre := to_global(wheel)
		var query := PhysicsRayQueryParameters3D.create(
			centre + Vector3.UP * reach, centre - Vector3.UP * reach, collision_mask)
		query.exclude = [get_rid()]
		var hit := space.intersect_ray(query)
		if not hit.is_empty() and hit.collider is StaticBody3D \
				and hit.normal.y >= cos(floor_max_angle):
			points.append(hit.position)
	return points


## Vector3.ZERO when the points span no plane.
static func _plane_normal(points: Array[Vector3]) -> Vector3:
	var sum := Vector3.ZERO
	for a in points.size():
		for b in range(a + 1, points.size()):
			for c in range(b + 1, points.size()):
				var n := (points[b] - points[a]).cross(points[c] - points[a])
				sum += n if n.y >= 0.0 else -n
	if sum.length_squared() > 0.000001:
		return sum.normalized()
	return Vector3.ZERO


## Left stick drives and steers, right grip brakes.
static func vr_controls(movement) -> Vector3:
	if movement == null:
		return Vector3.ZERO
	var left = movement.left_hand
	var right = movement.right_hand
	var stick := Vector2.ZERO
	if is_instance_valid(left) and left.get_has_tracking_data():
		stick = left.get_vector2("primary")
	var brake: bool = is_instance_valid(right) and right.get_has_tracking_data() \
			and right.is_button_pressed("grip_click")
	return Vector3(_stick_axis(stick.y), -_stick_axis(stick.x), 1.0 if brake else 0.0)


static func _stick_axis(value: float) -> float:
	return signf(value) * clampf((absf(value) - 0.15) / 0.85, 0.0, 1.0)


func vr_eye_position(seat: Node3D) -> Vector3:
	return seat.global_position + Vector3.UP * definition.eye_height * _scale * _world_scale()


func _steer_lock() -> float:
	var d := definition
	var t := clampf(absf(_speed) / maxf(d.drive_max_speed, 1.0), 0.0, 1.0)
	return deg_to_rad(d.max_steer_deg) * lerpf(1.0, d.drive_steer_at_speed, t)


## Wheels, lights and engine sound, on every peer.
func _animate(delta: float) -> void:
	if _vm == null or not _model_ready:
		return
	_vm.animate(delta, _speed, _steer)
	# Brake lights: the pedal, a clear slow-down, or reversing.
	var decel: float = (absf(_prev_speed) - absf(_speed)) / maxf(delta, 0.001)
	_prev_speed = _speed
	var brake: bool = _braking or (decel > 6.0 and absf(_speed) > 0.5) or (_speed < -0.5)
	_vm.set_lights(mode != Mode.IDLE, brake)
	_update_engine(delta)


func _update_engine(delta: float) -> void:
	if _engine == null or _engine.stream == null:
		return
	var running: bool = mode != Mode.IDLE or absf(_speed) > 0.5
	if running and not _engine.playing:
		_engine.play()
	elif not running and _engine.playing:
		_engine.stop()
	if not _engine.playing:
		return
	var load_amt := clampf(absf(_speed) / maxf(definition.drive_max_speed, 1.0), 0.0, 1.0)
	_engine.volume_db = move_toward(_engine.volume_db,
			definition.engine_volume_db + load_amt * 12.0, delta * 30.0)
	_engine.pitch_scale = lerpf(_engine.pitch_scale, 0.8 + load_amt * 0.7,
			minf(delta * 4.0, 1.0))


func _forward() -> Vector3:
	var f := -global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.001 else Vector3.FORWARD


func _world_scale() -> float:
	var s := global_transform.basis.get_scale().x
	return s if s > 0.0001 else 1.0


func _local_drives() -> bool:
	return driver != null and is_instance_valid(driver) and manager != null \
		and driver == manager.local_player()


## Whether the driver (or, without one, the focused GUI) is typing text.
func _typing() -> bool:
	if driver != null and is_instance_valid(driver) and driver.has_method("_typing"):
		return driver._typing()
	var f = get_viewport().gui_get_focus_owner() if get_viewport() else null
	return f is LineEdit or f is TextEdit


func speed() -> float:
	return _speed


## Called by AmbientManager each tick; `pos` is in the parent's (workspace) frame.
func set_driven_state(pos: Vector3, rot_y: float, speed: float) -> void:
	var now := Time.get_ticks_msec()
	var dt := clampf(float(now - _sim_last_msec) / 1000.0, 0.001, 0.25)
	_sim_last_msec = now
	var dyaw := wrapf(rot_y - rotation.y, -PI, PI)
	position = pos
	rotation = Vector3(0.0, rot_y, 0.0)
	velocity = Vector3.ZERO
	_speed = speed
	var want := 0.0
	if absf(speed) > 0.3:
		want = atan2((dyaw / dt) * _wheelbase_units, absf(speed))
	var lock := deg_to_rad(definition.max_steer_deg)
	_steer = clampf(lerpf(_steer, want, 0.2), -lock, lock)


func set_sim_driven(on: bool) -> void:
	_sim_driven = on
	if on:
		velocity = Vector3.ZERO


func is_sim_driven() -> bool:
	return _sim_driven


func honk(double := false) -> void:
	if _horn == null:
		_horn = AudioStreamPlayer3D.new()
		_horn.max_distance = 90.0
		_horn.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		var clip = load(definition.horn_clip) if definition.horn_clip != "" else null
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


## Traffic cars yell at whoever cut them off; this vehicle's driver stays quiet.
func yell(_line: int) -> void:
	pass


func set_npc_figure(on: bool) -> void:
	if on == (_npc_figure != null):
		return
	if not on:
		_npc_figure.queue_free()
		_npc_figure = null
		return
	var seat: Node3D = _seats.get(definition.driver_seat, null)
	if seat == null or not ResourceLoader.exists(NPC_FIGURE_SCENE):
		return
	var scene = load(NPC_FIGURE_SCENE)
	if scene == null:
		return
	var fig: Node = scene.instantiate()
	_strip_to_meshes(fig)
	if fig is CharacterBody3D:
		(fig as CharacterBody3D).collision_layer = 0
		(fig as CharacterBody3D).collision_mask = 0
	fig.process_mode = Node.PROCESS_MODE_DISABLED
	seat.add_child(fig)
	if fig is Node3D:
		(fig as Node3D).position = Vector3(0.0, 1.2, 0.0)
	_npc_figure = fig as Node3D


static func _strip_to_meshes(fig: Node) -> void:
	var stack: Array = [fig]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		n.set_script(null)
		if n is Camera3D or n is AudioStreamPlayer3D or n is AudioStreamPlayer \
				or n is CollisionShape3D:
			n.get_parent().remove_child(n)
			n.queue_free()


## The wheel if free and wanted, else the first empty passenger seat; "" when full.
func free_seat(as_driver: bool) -> String:
	if as_driver and driver_id == NO_ONE:
		return definition.driver_seat
	var taken: Array = occupant_seat.values()
	for s in definition.passenger_seats:
		if not taken.has(s):
			return s
	return ""


## Taking the wheel switches to PLAYER mode and re-evaluates authority.
func board(player: Node, pid: int, seat_name: String, as_driver: bool) -> void:
	if occupants.has(pid):
		return
	if seat_name == "" or not _seats.has(seat_name):
		seat_name = free_seat(as_driver)
		if seat_name == "":
			return
	occupants[pid] = player
	occupant_seat[pid] = seat_name
	if as_driver:
		driver_id = pid
		driver = player
		mode = Mode.PLAYER
		set_npc_figure(false)
		if manager != null:
			manager.refresh_authority(self)
	if player != null and is_instance_valid(player):
		if player is PhysicsBody3D:
			add_collision_exception_with(player)
		var seat: Node3D = _seats.get(seat_name, null)
		if player.has_method("enter_vehicle"):
			player.enter_vehicle(self, seat if seat != null else self, as_driver)
	_swing_door_for(seat_name)


## The driver leaving parks it.
func depart(player: Node, pid: int, exit_pos: Vector3) -> void:
	var seat_name: String = str(occupant_seat.get(pid, ""))
	occupants.erase(pid)
	occupant_seat.erase(pid)
	if pid == driver_id:
		driver_id = NO_ONE
		driver = null
		mode = Mode.IDLE
		if manager != null:
			manager.refresh_authority(self)
	if player != null and is_instance_valid(player):
		if player is PhysicsBody3D:
			remove_collision_exception_with(player)
		if player.has_method("exit_vehicle"):
			player.exit_vehicle(exit_pos)
	_swing_door_for(seat_name)


## Drop an occupant who left without a node to place (disconnected).
func remove_occupant(pid: int) -> void:
	if not occupants.has(pid):
		return
	var node = occupants[pid]
	depart(node if is_instance_valid(node) else null, pid, global_position)


func seat_of(pid: int) -> String:
	return str(occupant_seat.get(pid, ""))


## Outside the seat's door (or beside the body), on the first surface below.
func exit_position(seat_name: String, exclude: Array = []) -> Vector3:
	var p := _step_out_point(seat_name)
	p.y = global_position.y
	p = _ground_under(p, exclude)
	return p + Vector3.UP * 1.0


func _step_out_point(seat_name: String) -> Vector3:
	var door_i := definition.door_for_seat(seat_name)
	var door_local = _vm.door_position_local(door_i) if _vm != null else null
	if door_local != null:
		var out: Vector3 = definition.doors[door_i].get("out", Vector3(-1, 0, 0))
		var dir: Vector3 = (global_transform.basis * out)
		dir.y = 0.0
		dir = dir.normalized() if dir.length() > 0.001 else global_transform.basis.x.normalized()
		return to_global(door_local) + dir * 1.3
	var seat: Node3D = _seats.get(seat_name, null)
	var from: Vector3 = seat.global_position if seat != null else global_position
	var side: float = -1.0 if seat != null and seat.position.x < 0.0 else 1.0
	return from + global_transform.basis.x.normalized() * side \
			* (_extent.size.x * 0.5 * _world_scale() + 1.0)


## `p` moved down (or up) onto the first surface within 2.5 above / 4 below.
func _ground_under(p: Vector3, exclude: Array) -> Vector3:
	var space := get_world_3d().direct_space_state
	if space == null:
		return p
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 2.5, p - Vector3.UP * 4.0)
	var ex: Array[RID] = [get_rid()]
	for e in exclude:
		if e is CollisionObject3D:
			ex.append(e.get_rid())
	q.exclude = ex
	var hit: Dictionary = space.intersect_ray(q)
	if not hit.is_empty():
		p.y = hit.position.y
	return p


## Authority only: door state replicates in the sync.
func _swing_door_for(seat_name: String) -> void:
	if not _is_authority or _vm == null:
		return
	var i := definition.door_for_seat(seat_name)
	if i < 0 or i >= _vm.doors.size() or _vm.doors[i] == null:
		return
	if (_vm.doors_open >> i) & 1:
		return
	_vm.doors_open |= 1 << i
	get_tree().create_timer(DOOR_SECONDS * 2.2).timeout.connect(func():
		if is_instance_valid(self) and _is_authority and _vm != null:
			_vm.doors_open &= ~(1 << i))


## Bit i = door i.
func set_doors_mask(mask: int) -> void:
	if _vm != null:
		_vm.set_doors_mask(mask)


func doors_mask() -> int:
	return _vm.doors_open if _vm != null else 0


func all_doors_mask() -> int:
	return _vm.all_doors_mask() if _vm != null else 0


func scan_points() -> Array:
	return _scan_points


## World metres to the nearest door, or to the body's side when there are no doors.
func door_distance(from: Vector3) -> float:
	var best := INF
	if _vm != null:
		for i in _vm.doors.size():
			var dp = _vm.door_position_local(i)
			if dp != null:
				best = minf(best, from.distance_to(to_global(dp)))
	if best == INF:
		var half := _extent.size.x * 0.5 * _world_scale()
		best = maxf(from.distance_to(global_position) - half, 0.0)
	return best


func reset_to(xf: Transform3D) -> void:
	global_transform = xf
	velocity = Vector3.ZERO
	_speed = 0.0
	_steer = 0.0
	_remote_xform = xf
	snap_to_ground()


## Taking over starts from the last received transform so the body does not jump.
func set_authority(on: bool) -> void:
	if on == _is_authority:
		return
	_is_authority = on
	if on:
		if _has_remote:
			global_transform = _remote_xform
		velocity = Vector3.ZERO
	else:
		_remote_xform = global_transform
		_has_remote = true
		if _sim_driven:
			_sim_driven = false


func is_authority() -> bool:
	return _is_authority


func get_sync_data() -> Dictionary:
	var xf := global_transform
	var occ := []
	for pid in occupants:
		occ.append(int(pid))
	return {
		"net_id": net_id,
		"o": _snapped3(xf.origin, 0.001),
		"b": _snapped3(xf.basis.x, 0.0001) + _snapped3(xf.basis.y, 0.0001) \
				+ _snapped3(xf.basis.z, 0.0001),
		"spd": snappedf(_speed, 0.01),
		"str": snappedf(_steer, 0.001),
		"drs": doors_mask(),
		"m": mode,
		"d": driver_id,
		"occ": occ,
		"pb": _paint_body,
		"pr": _paint_roof,
	}


static func _snapped3(v: Vector3, step: float) -> Array:
	return [snappedf(v.x, step), snappedf(v.y, step), snappedf(v.z, step)]


## The first packet snaps; later ones are interpolated in _physics_process.
func apply_sync_data(data: Dictionary) -> void:
	if _is_authority:
		return
	var o: Array = data.get("o", [])
	var b: Array = data.get("b", [])
	if o.size() == 3 and b.size() == 9:
		var basis := Basis(Vector3(b[0], b[1], b[2]), Vector3(b[3], b[4], b[5]),
				Vector3(b[6], b[7], b[8]))
		_remote_xform = Transform3D(basis, Vector3(o[0], o[1], o[2]))
		if not _has_remote:
			global_transform = _remote_xform
			_has_remote = true
	_speed = float(data.get("spd", 0.0))
	_steer = float(data.get("str", 0.0))
	set_doors_mask(int(data.get("drs", 0)))
	var pb := int(data.get("pb", _paint_body))
	var pr := int(data.get("pr", _paint_roof))
	if pb != _paint_body or pr != _paint_roof:
		set_paint_indices(pb, pr)
	var new_mode := int(data.get("m", mode))
	var new_driver := int(data.get("d", driver_id))
	if new_mode != mode or new_driver != driver_id:
		mode = new_mode
		driver_id = new_driver
		if manager != null:
			manager.refresh_authority(self)
	if manager != null:
		manager.reconcile_occupants(self, data.get("occ", []))


func activate_camera() -> void:
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "VehicleCamera_" + net_id
		_camera.far = 8000.0
		_camera.near = 0.03
		get_tree().current_scene.add_child(_camera)
	_cam_yaw = 0.0
	_cam_pitch = 0.0
	_update_camera(1.0, true)
	_camera.current = true


func deactivate_camera() -> void:
	if _camera != null:
		_camera.current = false


func is_first_person() -> bool:
	return _cam_zoom <= FP_ZOOM


func set_first_person(on: bool) -> void:
	if on == is_first_person():
		return
	if on:
		_last_tp_zoom = maxf(_cam_zoom, 0.3)
		_cam_zoom = 0.0
	else:
		_cam_zoom = _last_tp_zoom
	_cam_yaw = 0.0
	_cam_pitch = 0.0


## Includes the cosmetic lean.
func _eye_position() -> Vector3:
	var seat: Node3D = _seats.get(definition.driver_seat, null)
	var local: Vector3 = to_local(seat.global_position) if seat != null else Vector3.ZERO
	local.y += definition.eye_height * _scale
	if _vm != null:
		local = _vm.lean_basis() * local
	return to_global(local)


## World metres.
func _cam_distance(z: float) -> float:
	return definition.cam_distance * pow(clampf(z, 0.0, 1.0), CAM_ZOOM_CURVE)


## `blend` 0 at the eyes, 1 clear of the body: the origin and tilt fade from cabin to chase.
func _update_camera(delta: float, snap := false) -> void:
	if _camera == null:
		return
	var blend := clampf(_cam_zoom / CAM_EYE_BLEND, 0.0, 1.0)
	blend = blend * blend * (3.0 - 2.0 * blend)
	var origin: Vector3 = _eye_position().lerp(
		global_position + Vector3.UP * definition.cam_pivot_height, blend)
	var ground_view := _ground_view(blend)
	var orbit := ground_view * _orbit_direction(blend)
	var want := _clear_of_walls(origin, orbit, _cam_distance(_cam_zoom))
	# Stiffer near the eyes so first person does not swim.
	var follow := 1.0
	if not snap and blend > 0.02:
		follow = 1.0 - exp(-lerpf(90.0, 14.0, blend) * delta)
	_camera.global_position = _camera.global_position.lerp(want, follow)
	# Up close the horizon tilts with the cabin's lean; the chase view stays level.
	var up := ground_view * Vector3.UP
	if _vm != null:
		var lean: Vector2 = _vm.lean_angles() * (1.0 - blend)
		if absf(lean.x) > 0.0001:
			up = up.rotated(global_transform.basis.z.normalized(), lean.x)
		if absf(lean.y) > 0.0001:
			orbit = orbit.rotated(global_transform.basis.x.normalized(), lean.y)
	_camera.look_at(_camera.global_position - orbit * 10.0, up)


## Negated it is the look direction: one yaw and pitch turn the head up close and orbit from afar.
func _orbit_direction(blend: float) -> Vector3:
	var orbit := (-_forward()).rotated(Vector3.UP, _cam_yaw)
	var orbit_right := orbit.cross(Vector3.UP)
	if orbit_right.length() > 0.001:
		orbit = orbit.rotated(orbit_right.normalized(), definition.cam_pitch * blend - _cam_pitch)
	return orbit.normalized()


## Faded out as `blend` reaches 1 so a banked car does not roll the chase view.
func _ground_view(blend: float) -> Basis:
	var back := -_forward()
	var level_basis := Basis(Vector3.UP.cross(back), Vector3.UP, back)
	return Basis.IDENTITY.slerp(
		global_basis.orthonormalized() * level_basis.transposed(), 1.0 - blend)


## The camera point `distance` along `orbit`, pulled in front of any wall.
func _clear_of_walls(origin: Vector3, orbit: Vector3, distance: float) -> Vector3:
	var want := origin + orbit * distance
	if distance <= 0.3:
		return want
	var space := get_world_3d().direct_space_state
	if space == null:
		return want
	var q := PhysicsRayQueryParameters3D.create(origin, want)
	q.exclude = [get_rid()]
	q.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(q)
	if not hit.is_empty():
		want = hit.position - orbit * 0.25
	return want


## Leaving first person looks straight ahead again.
func _set_zoom(z: float) -> void:
	var was_fp := is_first_person()
	_cam_zoom = clampf(z, 0.0, 1.0)
	if not is_first_person():
		_last_tp_zoom = _cam_zoom
		if was_fp:
			_cam_yaw = 0.0
			_cam_pitch = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if _camera == null or not _camera.current:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_set_zoom(_cam_zoom - CAM_ZOOM_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_set_zoom(_cam_zoom + CAM_ZOOM_STEP)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
	elif event is InputEventMouseMotion and _orbiting:
		_cam_yaw -= event.relative.x * 0.005
		_cam_pitch = clampf(_cam_pitch - event.relative.y * 0.005, -1.2, 1.2)
	elif event is InputEventKey and event.pressed and not event.echo and not _typing():
		_handle_key(event)


func _handle_key(event: InputEventKey) -> void:
	var toggle: bool = event.keycode == KEY_KP_0
	if not toggle and InputMap.has_action("toggle_first_person"):
		toggle = event.is_action_pressed("toggle_first_person")
	if toggle:
		set_first_person(not is_first_person())
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_H and _local_drives():
		honk(false)
		if manager != null:
			manager.broadcast_horn(self)


func _exit_tree() -> void:
	if is_instance_valid(_camera):
		_camera.queue_free()
