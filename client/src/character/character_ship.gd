class_name CharacterShip
extends RefCounted
## A character aboard a spaceship: boarding, walking the deck, the pilot seat, flight keys, ship camera and guns.

## Null when not aboard.
var boarded: Node3D = null

var _body: UnifiedCharacter = null
var _keys_held := {}
var _camera_active := false


func _init(body: UnifiedCharacter) -> void:
	_body = body


func is_aboard() -> bool:
	return boarded != null and is_instance_valid(boarded)


func is_piloting() -> bool:
	return is_aboard() and boarded.get("pilot") == _body


func board(ship: Node3D) -> bool:
	if not ship or not ship.has_method("board"):
		return false
	if boarded:
		return false
	if ship.board(_body):
		boarded = ship
		return true
	return false


## Rebinds gravity to the nearest planet.
func depart() -> bool:
	if not boarded or not boarded.has_method("depart"):
		return false
	if not boarded.depart(_body):
		return false
	restore_character_camera()
	boarded = null
	_body.planet.leave_ship()
	return true


func physics(delta: float) -> void:
	var ship_up = boarded.global_transform.basis.y
	var ship_down = -ship_up
	_body.gravity_direction = ship_down
	_body.up_direction = ship_up
	_body.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	_body.floor_snap_length = 0.6
	if _body.is_remote_player:
		return
	_body.planet.orient(delta)
	var piloting = boarded.get("pilot") == _body
	var movement = _body.current_movement
	if piloting:
		_process_pilot_input(delta)
		_body.movement_dir = Vector3.ZERO
	elif movement:
		_read_walk_input(delta, ship_down)
	var on_floor = _body.is_on_floor()
	if not on_floor:
		_body.velocity += ship_down * _body.gravity * delta
	if movement and movement.is_jumping and on_floor and not piloting:
		_body.velocity += ship_up * _body.jump_velocity
		_body.play_jump_sound()
	_move(delta, ship_down, on_floor)
	_body.move_and_slide()
	_body.update_animation_floor_state(delta, on_floor)
	if _body.current_animation:
		var speed = (_body.velocity - _body.velocity.project(ship_down)).length()
		_body.animate_local(delta, speed)
	if boarded.has_method("check_passenger_exit"):
		boarded.check_passenger_exit(_body)
		if not boarded or not is_instance_valid(boarded):
			return
	_body.update_grab_and_interact(delta)
	_body.was_on_floor = on_floor


## The keyboard module's rotation is skipped; the model turns in ship space.
func _read_walk_input(delta: float, ship_down: Vector3) -> void:
	var movement = _body.current_movement
	var camera = _body.get_viewport().get_camera_3d()
	_body.movement_dir = Vector3.ZERO
	if camera:
		var input_dir = Vector2.ZERO if _body._typing() else Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
		if input_dir != Vector2.ZERO:
			_body.movement_dir = movement.get_camera_relative_direction(input_dir, camera)
	movement.planet_node = boarded
	movement.gravity_direction = ship_down
	movement.is_running = not _body._typing() and Input.is_action_pressed("ui_sprint")
	movement.is_jumping = not _body._typing() and Input.is_action_just_pressed("jump")
	var model: Node3D = _body.character_model
	if _body.movement_dir.length() > 0.1 and model:
		var local_dir = boarded.global_transform.basis.inverse() * _body.movement_dir
		var target_angle = atan2(local_dir.x, local_dir.z)
		if movement.get("mesh_forward_is_backward"):
			target_angle += PI
		model.rotation.y = lerp_angle(model.rotation.y, target_angle, delta * 8.0)


func _move(delta: float, ship_down: Vector3, on_floor: bool) -> void:
	var movement = _body.current_movement
	var gravity_vel = _body.velocity.project(ship_down)
	var floor_vel = _body.velocity - gravity_vel
	var dir: Vector3 = _body.movement_dir
	if dir and dir.length() > 0.1:
		var target_speed = _body.run_speed if (movement and movement.is_running) else _body.walk_speed
		var current_accel = _body.acceleration if on_floor else _body.acceleration * _body.air_control
		floor_vel = floor_vel.lerp(dir * target_speed, delta * current_accel)
	else:
		var friction = _body.acceleration * (2.5 if on_floor else 0.3)
		floor_vel = floor_vel.lerp(Vector3.ZERO, delta * friction)
		if floor_vel.length() < 0.15:
			floor_vel = Vector3.ZERO
	_body.velocity = floor_vel + gravity_vel


## Takes or leaves the pilot seat; boarding is by zones.
func handle_interact() -> void:
	if not boarded or not is_instance_valid(boarded):
		return
	if boarded.pilot == _body:
		restore_character_camera()
		boarded.clear_pilot()
		print("Left pilot seat")
		return
	var pilot_seat = boarded.get_node_or_null("Interior/PilotSeat")
	if pilot_seat and _body.global_position.distance_to(pilot_seat.global_position) < 5.0:
		boarded.set_pilot(_body)
		print("Took pilot seat")


func _toggle_camera() -> void:
	if not boarded or not is_instance_valid(boarded):
		return
	_camera_active = not _camera_active
	if _camera_active:
		_body.disable_camera()
		boarded.activate_ship_camera()
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		print("Ship camera: ON")
	else:
		restore_character_camera()
		print("Ship camera: OFF")


## The pilot's left click fires the ship's guns.
func input(event: InputEvent) -> void:
	var is_pilot = boarded and is_instance_valid(boarded) and boarded.get("pilot") == _body
	if is_pilot and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			boarded.manual_fire(_fire_direction())
		else:
			boarded.stop_manual_fire()
		_body.get_viewport().set_input_as_handled()


## 1000 along the ray when nothing is under the mouse.
func _fire_direction() -> Vector3:
	var viewport := _body.get_viewport()
	var cam = viewport.get_camera_3d()
	if not cam:
		return (-boarded.global_transform.basis.z).normalized()
	var mouse_pos = viewport.get_mouse_position()
	var ray_origin = cam.project_ray_origin(mouse_pos)
	var ray_dir = cam.project_ray_normal(mouse_pos)
	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_dir * 2000.0)
	query.exclude = [_body, boarded]
	var result = _body.get_world_3d().direct_space_state.intersect_ray(query)
	var target_point: Vector3
	if not result.is_empty():
		target_point = result.position
	else:
		target_point = ray_origin + ray_dir * 1000.0
	return (target_point - boarded.global_position).normalized()


## With the ship camera on, right mouse held captures the cursor.
func unhandled_input(event: InputEvent) -> void:
	if not (_camera_active and boarded and is_instance_valid(boarded)):
		return
	boarded.ship_camera_input(event)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


## Ship camera off, the character's own camera back.
func restore_character_camera() -> void:
	_camera_active = false
	if boarded and is_instance_valid(boarded):
		boarded.deactivate_ship_camera()
	_body.enable_camera()


## W/S thrust, A/D yaw, I/K pitch, J/L roll, Space/Shift up/down, B brake, X align, C camera, H weapons.
func _process_pilot_input(delta: float) -> void:
	if not boarded or not is_instance_valid(boarded):
		return
	if _key_pressed_once(KEY_X):
		boarded.toggle_planet_align()
	if _key_pressed_once(KEY_C):
		_toggle_camera()
	if _key_pressed_once(KEY_H):
		_toggle_weapons()
	if Input.is_key_pressed(KEY_W):
		boarded.apply_thrust(Vector3.FORWARD, delta)
	if Input.is_key_pressed(KEY_S):
		boarded.apply_thrust(Vector3.BACK, delta)
	if Input.is_key_pressed(KEY_A):
		boarded.apply_rotation(Vector3.UP, 1.0, delta)
	if Input.is_key_pressed(KEY_D):
		boarded.apply_rotation(Vector3.UP, -1.0, delta)
	if Input.is_key_pressed(KEY_I):
		boarded.apply_rotation(Vector3.RIGHT, -1.0, delta)
	if Input.is_key_pressed(KEY_K):
		boarded.apply_rotation(Vector3.RIGHT, 1.0, delta)
	if Input.is_key_pressed(KEY_J):
		boarded.apply_rotation(Vector3.FORWARD, -1.0, delta)
	if Input.is_key_pressed(KEY_L):
		boarded.apply_rotation(Vector3.FORWARD, 1.0, delta)
	if Input.is_key_pressed(KEY_SPACE):
		boarded.apply_thrust(Vector3.UP, delta)
	if Input.is_key_pressed(KEY_SHIFT):
		boarded.apply_thrust(Vector3.DOWN, delta)
	# Free flight brakes itself without thrust; planet-aligned flight coasts until B.
	var has_thrust = (Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_S)
		or Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_SHIFT))
	if Input.is_key_pressed(KEY_B):
		boarded.apply_brake(delta)
	elif not has_thrust and not boarded.align_to_planet:
		boarded.apply_brake(delta)


func _key_pressed_once(key: Key) -> bool:
	var down := Input.is_key_pressed(key)
	var just: bool = down and not _keys_held.get(key, false)
	_keys_held[key] = down
	return just


func _toggle_weapons() -> void:
	if boarded.get("_fire_active"):
		boarded.stop_firing()
		print("Weapons: OFF")
	else:
		boarded.start_firing()
		print("Weapons: ON")
