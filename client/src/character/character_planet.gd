class_name CharacterPlanet
extends RefCounted
## A character's ground: the planet it walks on, its gravity, floor detection, orientation and walking physics.

## Null in space or with flat-world gravity.
var current: Node3D = null
var current_name := "Ground"
var orientation_speed := 8.0
var custom_is_on_floor := false
var floor_detection_distance := 5.0
var settling_timer := 0.0
## Liberal mode counts any surface a ray finds below as floor; strict uses the planet radius.
var liberal_floor_mode := true
var min_floor_distance := 1.0
var max_floor_distance := 8.0

var _body: UnifiedCharacter = null
var _scan_accum := 0.0


func _init(body: UnifiedCharacter) -> void:
	_body = body


func set_planet(planet: Node3D, planet_name: String = "Planet") -> void:
	current = planet
	current_name = planet_name
	if current:
		calc_gravity_direction()
		print("Set planet: ", current_name)


func rename(planet_name: String) -> void:
	current_name = planet_name
	print("Setting planet name: ", current_name)


## Streamed planets join the "planets" group: looked for once a second.
func tick_scan(delta: float) -> void:
	_scan_accum += delta
	if _scan_accum >= 1.0:
		_scan_accum = 0.0
		update_nearest()


## Remote players only track gravity.
func physics(delta: float) -> void:
	if current and current_name != "space":
		calc_gravity_direction()
		orient(delta)
		_update_custom_floor_detection()
	if _body.is_remote_player:
		return
	if current:
		_body.up_direction = -_body.gravity_direction
		_body.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		_body.floor_snap_length = 0.6
	else:
		_body.up_direction = Vector3.UP
		_body.floor_snap_length = 0.0
	var movement = _body.current_movement
	if movement:
		movement.planet_node = current
		movement.gravity_direction = _body.gravity_direction
		movement.update_input(delta)
		_body.movement_dir = movement.get_movement_direction()
	var on_floor = is_on_floor()
	_apply_gravity(delta, on_floor)
	if movement and movement.is_jumping and on_floor:
		var jump_speed: float = _body.vr_movement.jump_velocity if _body.is_vr_mode else _body.jump_velocity
		if current:
			_body.velocity += -_body.gravity_direction * jump_speed
		else:
			_body.velocity.y = jump_speed
		_body.play_jump_sound()
	if _body.movement_dir and _body.movement_dir.length() > 0.1:
		_accelerate(delta, on_floor)
	else:
		_apply_friction(delta)
	_zero_small_velocity()
	_body.move_and_slide()
	if current and is_on_floor():
		_settle_on_planet()
	_leash_to_planet()
	_body.update_animation_floor_state(delta, on_floor)
	if _body.current_animation:
		var speed: float
		if current:
			speed = surface_velocity().length()
		else:
			speed = Vector2(_body.velocity.x, _body.velocity.z).length()
		_body.animate_local(delta, speed)
	_body.update_grab_and_interact(delta)
	# Leaving the debounced floor while rising is a jump the input did not start.
	if _body.was_on_floor and not _body.animation_floor_state and up_speed() > 1.0:
		_body.play_jump_sound()
	_body.was_on_floor = _body.animation_floor_state


## Packs or tiles still loading and no collider below: do not fall yet.
func _waiting_for_ground() -> bool:
	if _body.is_remote_player:
		return false
	var pckm := _body.get_node_or_null("/root/PCKManager")
	var packs_pending: bool = pckm != null and pckm.has_method("required_content_pending") \
			and pckm.required_content_pending()
	var region_files := _body.get_node_or_null("/root/RegionFiles")
	var ground_pending: bool = region_files != null and region_files.is_fetching()
	if not packs_pending and not ground_pending:
		return false
	var world := _body.get_world_3d()
	if world == null:
		return false
	var down: Vector3 = _body.gravity_direction if _body.gravity_direction != Vector3.ZERO else Vector3.DOWN
	var from := _body.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from + down * 5000.0)
	q.exclude = [_body.get_rid()]
	return world.direct_space_state.intersect_ray(q).is_empty()


## In liberal mode a detected floor without real contact or while rising still gets gravity.
func _apply_gravity(delta: float, on_floor: bool) -> void:
	var down: Vector3 = _body.gravity_direction
	var should_apply_gravity = not on_floor
	if current and liberal_floor_mode and on_floor:
		should_apply_gravity = _body.velocity.dot(-down) > 0.1 or not _body.is_on_floor()
	# Hold position over missing ground while the world streams in.
	if should_apply_gravity and _waiting_for_ground():
		_body.velocity = Vector3.ZERO
		should_apply_gravity = false
	if not should_apply_gravity:
		return
	var gravity_strength = _body.gravity
	if up_speed() < 0:
		gravity_strength = _body.gravity * 1.5
	if current:
		_body.velocity += down * gravity_strength * delta
	else:
		_body.velocity.y -= gravity_strength * delta


func _accelerate(delta: float, on_floor: bool) -> void:
	var movement = _body.current_movement
	var target_speed = _body.run_speed if (movement and movement.is_running) else _body.walk_speed
	if _body.is_vr_mode:
		var vr = _body.vr_movement
		target_speed = vr.run_speed if vr.is_running else vr.walk_speed
	var current_acceleration = _body.acceleration
	if not on_floor:
		current_acceleration *= _body.air_control
	var target_velocity = _body.movement_dir * target_speed
	if current:
		var surface = surface_velocity()
		surface = surface.lerp(target_velocity, delta * current_acceleration)
		_body.velocity = surface + _body.velocity.project(_body.gravity_direction)
	else:
		_body.velocity.x = lerp(_body.velocity.x, target_velocity.x, delta * current_acceleration)
		_body.velocity.z = lerp(_body.velocity.z, target_velocity.z, delta * current_acceleration)


func _apply_friction(delta: float) -> void:
	var on_floor_check = is_on_floor()
	var friction = _body.acceleration * (0.3 if not on_floor_check else 2.5)
	if not current:
		_body.velocity.x = _damp_axis(_body.velocity.x, delta, friction)
		_body.velocity.z = _damp_axis(_body.velocity.z, delta, friction)
		if abs(_body.velocity.x) < 0.15:
			_body.velocity.x = 0.0
		if abs(_body.velocity.z) < 0.15:
			_body.velocity.z = 0.0
		return
	var surface = surface_velocity()
	if on_floor_check:
		surface = surface.lerp(Vector3.ZERO, delta * friction)
		if surface.length() < 0.3:
			surface = surface.lerp(Vector3.ZERO, delta * friction * 5.0)
		if surface.length() < 0.15:
			surface = Vector3.ZERO
	else:
		surface = surface.lerp(Vector3.ZERO, delta * friction * 0.4)
	_body.velocity = surface + _body.velocity.project(_body.gravity_direction)


static func _damp_axis(v: float, delta: float, friction: float) -> float:
	if abs(v) < 0.3:
		return lerp(v, 0.0, delta * friction * 5.0)
	return lerp(v, 0.0, delta * friction)


func _zero_small_velocity() -> void:
	if current:
		if surface_velocity().length() < 0.2:
			_body.velocity = _body.velocity.project(_body.gravity_direction)
		return
	if abs(_body.velocity.x) < 0.2:
		_body.velocity.x = 0.0
	if abs(_body.velocity.z) < 0.2:
		_body.velocity.z = 0.0


## Not while jumping or, in liberal mode, with nothing solid below.
func _settle_on_planet() -> void:
	if _body.velocity.dot(-_body.gravity_direction) > 1.0:
		return
	if liberal_floor_mode and _cast_from_body(_body.gravity_direction, max_floor_distance).is_empty():
		return
	_adjust_to_planet_surface()


## 10 above the radius, or 80 above the terrain when the planet knows its height.
func _leash_to_planet() -> void:
	if not current:
		return
	var max_distance = _get_planet_radius() + 10.0
	if current.has_method("surface_height_at"):
		max_distance = current.surface_height_at(_body.global_position) + 80.0
	var distance_to_center = _body.global_position.distance_to(current.global_position)
	if distance_to_center > max_distance:
		var direction_to_planet = (current.global_position - _body.global_position).normalized()
		_body.global_position = current.global_position - direction_to_planet * max_distance
		print("Character too far from planet, pulled back to surface")


func surface_velocity() -> Vector3:
	return _body.velocity - _body.velocity.project(_body.gravity_direction)


## Along the planet's up, or world up without one.
func up_speed() -> float:
	if current:
		return _body.velocity.dot(-_body.gravity_direction)
	return _body.velocity.y


func _cast_from_body(dir: Vector3, length: float) -> Dictionary:
	var from := _body.global_position
	var query = PhysicsRayQueryParameters3D.create(from, from + dir * length)
	query.exclude = [_body]
	return _body.get_world_3d().direct_space_state.intersect_ray(query)


## A node named "Planet" next to the body or anywhere in the current scene.
func find() -> void:
	var parent = _body.get_parent()
	if parent and parent.has_node("Planet"):
		current = parent.get_node("Planet")
		current_name = "Planet"
	else:
		var root = _body.get_tree().current_scene
		if root:
			var planets = _find_nodes_by_name(root, "Planet")
			if planets.size() > 0:
				current = planets[0]
				current_name = "Planet"
	if current:
		print("Found planet: ", current.name)
		calc_gravity_direction()
		_ensure_on_planet_surface()
	else:
		print("No planet found, using default gravity")


func _find_nodes_by_name(node: Node, node_name: String) -> Array:
	var result = []
	if node.name == node_name:
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_nodes_by_name(child, node_name))
	return result


## Measured to the surface when the planet knows its radius; drops a freed planet.
func update_nearest() -> void:
	if current and not is_instance_valid(current):
		current = null
	var best: Node3D = null
	var best_d = INF
	for p in _body.get_tree().get_nodes_in_group("planets"):
		if not (p is Node3D) or not is_instance_valid(p) or not p.is_inside_tree():
			continue
		var d = _body.global_position.distance_to(p.global_position)
		if p.has_method("get_surface_radius"):
			d -= p.get_surface_radius()
		if d < best_d:
			best_d = d
			best = p
	if best and best != current:
		set_planet(best, best.name)


## The planet's gravity force, the surface normal on mesh planets, else toward the centre.
func calc_gravity_direction() -> void:
	if not current:
		_body.gravity_direction = Vector3.DOWN
		return
	if _body.ship.is_aboard():
		_body.gravity_direction = Vector3.DOWN
		return
	if current.has_method("get_gravity_force"):
		var gravity_force = current.get_gravity_force(_body.global_position)
		if gravity_force.length() > 0.001:
			_body.gravity_direction = gravity_force.normalized()
		else:
			_body.gravity_direction = Vector3.DOWN
		return
	var toward_center = (current.global_transform.origin - _body.global_transform.origin).normalized()
	if not _planet_shape_is_complex():
		_body.gravity_direction = toward_center
		return
	var result = _cast_from_body(toward_center, max_floor_distance)
	_body.gravity_direction = -result.normal if not result.is_empty() else toward_center


func _planet_shape_is_complex() -> bool:
	if not current.has_node("CollisionShape3D"):
		return false
	var shape = current.get_node("CollisionShape3D").shape
	if not shape:
		return false
	return shape is ConcavePolygonShape3D or shape is ConvexPolygonShape3D


func _ensure_on_planet_surface() -> void:
	if not current:
		return
	var planet_radius = _get_planet_radius()
	var distance_to_center = _body.global_position.distance_to(current.global_position)
	if distance_to_center >= planet_radius + 2.0:
		return
	var direction_from_center = (_body.global_position - current.global_position).normalized()
	if direction_from_center.length() < 0.1:
		direction_from_center = Vector3.UP
	_body.global_position = current.global_position + direction_from_center * (planet_radius + 3.0)
	print("Repositioned character to planet surface")


## From the planet, else its collision shape (scaled), else its mesh.
func _get_planet_radius() -> float:
	if not current:
		return 1.0
	# Terrain planets have no full-size collision sphere to read.
	if current.has_method("get_surface_radius"):
		return current.get_surface_radius()
	if not current.has_node("CollisionShape3D"):
		return _estimate_radius_from_mesh()
	var collision_shape = current.get_node("CollisionShape3D")
	var final_radius = _shape_radius(collision_shape) * collision_shape.transform.basis.get_scale().x
	var workspace_scale = 1.0
	var parent = _body.get_parent()
	if parent:
		workspace_scale = parent.transform.basis.get_scale().x
	return final_radius * workspace_scale


## Boxes and meshes use half their largest side.
func _shape_radius(collision_shape: CollisionShape3D) -> float:
	var shape = collision_shape.shape
	if shape is SphereShape3D:
		return shape.radius
	if shape is CapsuleShape3D:
		return shape.radius
	if shape is CylinderShape3D:
		return shape.top_radius
	if shape is BoxShape3D:
		return _half_largest_side(shape.size)
	if shape is ConvexPolygonShape3D or shape is ConcavePolygonShape3D:
		var aabb = _get_shape_aabb(collision_shape)
		if aabb != AABB():
			return _half_largest_side(aabb.size)
		return _estimate_radius_from_mesh()
	return 25.0


static func _half_largest_side(size: Vector3) -> float:
	return max(size.x, max(size.y, size.z)) * 0.5


## From the debug mesh or the points.
func _get_shape_aabb(collision_shape: CollisionShape3D) -> AABB:
	if not collision_shape or not collision_shape.shape:
		return AABB()
	var shape = collision_shape.shape
	if shape.has_method("get_debug_mesh"):
		var debug_mesh = shape.get_debug_mesh()
		if debug_mesh:
			return debug_mesh.get_aabb().abs()
	if not (shape is ConvexPolygonShape3D) or shape.points.size() == 0:
		return AABB()
	var points = shape.points
	var min_point = points[0]
	var max_point = points[0]
	for point in points:
		min_point = Vector3(min(min_point.x, point.x), min(min_point.y, point.y), min(min_point.z, point.z))
		max_point = Vector3(max(max_point.x, point.x), max(max_point.y, point.y), max(max_point.z, point.z))
	return AABB(min_point, max_point - min_point)


## 25 without a mesh.
func _estimate_radius_from_mesh() -> float:
	if not current:
		return 25.0
	var mesh_instance: MeshInstance3D = null
	if current.has_node("MeshInstance3D"):
		mesh_instance = current.get_node("MeshInstance3D")
	elif current is MeshInstance3D:
		mesh_instance = current as MeshInstance3D
	else:
		for child in current.get_children():
			if child is MeshInstance3D:
				mesh_instance = child as MeshInstance3D
				break
	if not (mesh_instance and mesh_instance.mesh):
		return 25.0
	var radius = _half_largest_side(mesh_instance.mesh.get_aabb().size)
	return radius * mesh_instance.transform.basis.get_scale().x


## Quickly while moving, slowly once standing still a moment.
func orient(delta) -> void:
	if not current:
		return
	# Aboard, the body is a child of the ship, so its local up is the deck's up.
	if _body.ship.is_aboard():
		_orient_to_ship_floor(delta)
		return
	if not is_on_floor():
		settling_timer = 0.0
		return
	var is_moving = surface_velocity().length() > 0.2
	if is_moving:
		settling_timer = 0.0
	else:
		settling_timer += delta
	var target_up = -_body.gravity_direction
	var current_up = _body.transform.basis.y
	_rotate_up_toward(target_up, delta, is_moving, settling_timer > 0.2)
	if is_on_floor():
		var lerp_factor = min(orientation_speed * delta * (0.15 if is_moving else 0.08), 0.3)
		var new_up = current_up.lerp(target_up, lerp_factor).normalized()
		var right = new_up.cross(_body.transform.basis.z)
		if right.length() < 0.1:
			right = Vector3.RIGHT if abs(new_up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
			right = new_up.cross(right).normalized()
		else:
			right = right.normalized()
		_set_basis_axes(right, new_up)


## The misalignment threshold tightens while standing still.
func _rotate_up_toward(target_up: Vector3, delta: float, is_moving: bool, is_settling: bool) -> void:
	var current_up = _body.transform.basis.y
	var alignment = current_up.dot(target_up)
	var alignment_threshold = 0.985
	if is_moving:
		alignment_threshold = 0.99
	elif is_settling:
		alignment_threshold = 0.9995
	if alignment >= alignment_threshold:
		return
	var rotation_axis = current_up.cross(target_up)
	if rotation_axis.length() <= (0.01 if is_moving else 0.001):
		return
	var angle = current_up.angle_to(target_up)
	var rate: float
	if is_settling:
		rate = 0.02
	elif not is_moving:
		rate = 0.1
	elif alignment < 0.5:
		rate = 0.8
	else:
		rate = 0.4
	var rotation_amount = min(angle, orientation_speed * delta * rate)
	_body.transform.basis = Basis(Quaternion(rotation_axis.normalized(), rotation_amount)) * _body.transform.basis
	_body.transform.basis = _body.transform.basis.orthonormalized()


func _orient_to_ship_floor(delta: float) -> void:
	var local_up = _body.transform.basis.y
	if local_up.dot(Vector3.UP) >= 0.999:
		return
	var lerp_factor = min(orientation_speed * delta * 0.3, 0.5)
	var new_up = local_up.lerp(Vector3.UP, lerp_factor).normalized()
	var right = new_up.cross(_body.transform.basis.z)
	if right.length() < 0.1:
		right = Vector3.RIGHT
	_set_basis_axes(right.normalized(), new_up)


func _set_basis_axes(right: Vector3, up: Vector3) -> void:
	var forward = right.cross(up).normalized()
	_body.transform.basis.x = right
	_body.transform.basis.y = up
	_body.transform.basis.z = forward


func _update_custom_floor_detection() -> void:
	if not current:
		custom_is_on_floor = _body.is_on_floor()
		return
	var distance_to_surface = _body.global_position.distance_to(current.global_position) - _get_planet_radius()
	if liberal_floor_mode:
		var result = _cast_from_body(_body.gravity_direction, max_floor_distance)
		if not result.is_empty():
			var hit_distance = _body.global_position.distance_to(result.position)
			custom_is_on_floor = hit_distance >= min_floor_distance and hit_distance <= max_floor_distance
		else:
			custom_is_on_floor = distance_to_surface <= min_floor_distance
		return
	custom_is_on_floor = distance_to_surface <= floor_detection_distance
	if not custom_is_on_floor:
		return
	var result = _cast_from_body(_body.gravity_direction, floor_detection_distance * 1.5)
	if result.is_empty():
		custom_is_on_floor = distance_to_surface <= floor_detection_distance * 0.5
	else:
		custom_is_on_floor = true


## Used instead of is_on_floor(); on a planet it accepts a nearby surface unless sliding fast.
func is_on_floor() -> bool:
	if not current:
		return _body.is_on_floor()
	if custom_is_on_floor or _body.is_on_floor():
		return true
	if liberal_floor_mode:
		var result = _cast_from_body(_body.gravity_direction, max_floor_distance * 1.2)
		if result.is_empty():
			return false
		var hit_distance = _body.global_position.distance_to(result.position)
		return hit_distance <= max_floor_distance * 1.2 and surface_velocity().length() < 2.0
	var distance_to_center = _body.global_position.distance_to(current.global_position)
	var distance_to_surface = distance_to_center - _get_planet_radius()
	return distance_to_surface <= floor_detection_distance * 1.2 and surface_velocity().length() < 0.2


## Primitive-shaped planets only; mesh planets are left to physics.
func _adjust_to_planet_surface() -> void:
	if not current or _planet_shape_is_complex():
		return
	var planet_radius = _get_planet_radius()
	var distance_to_surface = _body.global_position.distance_to(current.global_position) - planet_radius
	if liberal_floor_mode:
		var target_gap = 2.0
		if distance_to_surface <= target_gap + 1.0:
			return
		_lerp_to_height(planet_radius + target_gap, 0.15 if surface_velocity().length() > 0.5 else 0.05)
		if distance_to_surface > target_gap + 3.0:
			_body.velocity += _body.gravity_direction * min(distance_to_surface * 1.0, 3.0) * 0.05
		return
	var target_gap = 0.1
	if distance_to_surface <= target_gap + 0.05:
		return
	_lerp_to_height(planet_radius + target_gap, 0.3 if surface_velocity().length() > 0.1 else 0.1)
	if distance_to_surface > target_gap + 0.5:
		_body.velocity += _body.gravity_direction * min(distance_to_surface * 2.0, 5.0) * 0.1


func _lerp_to_height(height: float, weight: float) -> void:
	var direction_from_center = (_body.global_position - current.global_position).normalized()
	var target_position = current.global_position + direction_from_center * height
	_body.global_position = _body.global_position.lerp(target_position, weight)


## After leaving a ship: in space until the nearest planet is found.
func leave_ship() -> void:
	current = null
	current_name = "space"
	_body.gravity_direction = Vector3.DOWN
	_body.velocity = Vector3.ZERO
	custom_is_on_floor = false
	_find_nearest_planet_after_depart()


func _find_nearest_planet_after_depart() -> void:
	var root = _body.get_tree().current_scene
	if not root:
		return
	var best_planet: Node3D = null
	var best_dist := INF
	for p in _collect_planets(root):
		var dist = _body.global_position.distance_to(p.global_position)
		if dist < best_dist:
			best_dist = dist
			best_planet = p
	if best_planet:
		set_planet(best_planet, best_planet.name)
		print("Reassigned to planet: ", best_planet.name)


## Gravity sources, StaticBody3D named like a planet or ground, or "Planet"; skips ships.
func _collect_planets(node: Node) -> Array:
	var result := []
	if node.has_method("apply_thrust"):
		return result
	if node.has_method("get_gravity_force") and node.has_method("get_surface_normal"):
		result.append(node)
	elif node is StaticBody3D:
		if _looks_like_planet_body(node):
			result.append(node)
	elif node.name == "Planet":
		result.append(node)
	for child in node.get_children():
		result.append_array(_collect_planets(child))
	return result


static func _looks_like_planet_body(node: Node) -> bool:
	if not (node.has_node("CollisionShape3D") or node.has_node("MeshInstance3D")):
		return false
	var lower = node.name.to_lower()
	return lower.contains("planet") or lower.contains("ground")
