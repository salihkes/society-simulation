extends AnimatableBody3D
class_name Spaceship

## A boardable, flyable ship with its own interior gravity, turrets, shields and network sync.

signal ship_damaged(hull: float, shield: float)
signal ship_destroyed()
signal passenger_boarded(character: CharacterBody3D)
signal passenger_departed(character: CharacterBody3D)
signal pilot_changed(new_pilot: CharacterBody3D)

const BOARDING_COOLDOWN := 2.0
## How far past interior_radius (and past a boarding zone) still counts as aboard.
const BOARD_MARGIN := 10.0

@export var ship_name: String = "Unnamed Ship"
@export var gravity_strength: float = 9.8
@export var gravity_radius: float = 50.0
## Grown at _ready to the ship's measured size.
@export var interior_radius: float = 15.0
@export var max_speed: float = 100.0
@export var thrust_force: float = 40.0
@export var rotation_speed: float = 2.0
@export var align_speed: float = 20.0
@export var surface_speed: float = 40.0
@export var camera_min_zoom: float = 10.0
@export var camera_max_zoom: float = 500.0

@export var max_hull_hp: float = 1000.0
@export var max_shield_hp: float = 500.0
@export var shield_regen_rate: float = 10.0
@export var shield_regen_delay: float = 5.0
@export var turret_count: int = 6
@export var turret_fire_rate: float = 0.4
@export var turret_bolt_speed: float = 60.0
@export var turret_bolt_damage: float = 15.0
@export var turret_range: float = 300.0
@export var turret_bolt_color: Color = Color(0.2, 1.0, 0.3)

var ship_velocity: Vector3 = Vector3.ZERO
var is_landed: bool = false
var landed_planet: Node3D = null
var align_to_planet: bool = false
var _align_target_planet: Node3D = null

var passengers: Array[CharacterBody3D] = []
var pilot: CharacterBody3D = null
var ship_camera: Camera3D = null
var _ship_cam_pivot: Node3D = null
var _ship_cam_yaw: float = 0.0
var _ship_cam_pitch: float = -0.3
var _ship_cam_zoom: float = 60.0

var hull_hp: float = 1000.0
var shield_hp: float = 500.0
var _shield_regen_timer: float = 0.0
var _is_destroyed: bool = false
var _turret_positions: Array[Vector3] = []
var _turret_fire_timers: Array[float] = []
var _current_target: Node3D = null
var _fire_active: bool = false
var _manual_fire: bool = false
var _manual_fire_dir: Vector3 = Vector3.FORWARD
var _boarding_cooldown: float = 0.0

## Derived from the scene path, so it is the same on every client.
var net_id: String = ""

var interior: Node3D
var boarding_zone: Area3D
var pilot_seat: Node3D


func _ready():
	sync_to_physics = true
	interior = get_node_or_null("Interior")
	boarding_zone = get_node_or_null("BoardingZone")
	pilot_seat = get_node_or_null("Interior/PilotSeat")

	if not interior:
		interior = Node3D.new()
		interior.name = "Interior"
		add_child(interior)

	# Every child Area3D named BoardingZone* boards characters.
	for child in get_children():
		if child is Area3D and child.name.begins_with("BoardingZone"):
			child.body_entered.connect(_on_boarding_zone_entered)
			child.body_exited.connect(_on_boarding_zone_exited)

	if net_id.is_empty():
		net_id = "ship_%s" % str(get_path()).replace("/", "_").replace(" ", "_")

	_auto_calculate_interior_radius()

	hull_hp = max_hull_hp
	shield_hp = max_shield_hp
	_setup_turrets()

	var nc = _get_network_controller()
	if nc and nc.get("objects") != null:
		nc.objects.register_ship(self)
		print("Ship registered: ", net_id)


func _physics_process(delta):
	if _is_destroyed:
		return
	if _boarding_cooldown > 0:
		_boarding_cooldown -= delta
	if not is_landed and pilot:
		_process_flight(delta)
	_process_combat(delta)


func _process_flight(delta):
	if align_to_planet and _align_target_planet and is_instance_valid(_align_target_planet):
		_fly_along_surface(delta)
	elif ship_velocity.length() > 0.01:
		var parent_inv = get_parent().global_transform.affine_inverse()
		position += parent_inv.basis * (ship_velocity * delta)


## ship_velocity is only a direction here; the ship moves at surface_speed and stops with thrust.
func _fly_along_surface(delta):
	var planet_pos = _align_target_planet.global_position
	var target_pos = global_position
	if ship_velocity.length() > 0.1:
		target_pos = _surface_step(planet_pos, delta)
	# Thrust adds velocity again next frame while held.
	ship_velocity = Vector3.ZERO
	_align_to_nearest_planet_at(delta, target_pos)


## The tangential part of the intent moves around the planet, the radial part changes altitude.
func _surface_step(planet_pos: Vector3, delta: float) -> Vector3:
	var altitude = global_position.distance_to(planet_pos)
	var target_pos = global_position
	var move_dir = ship_velocity.normalized()
	var radial = (target_pos - planet_pos).normalized()
	var radial_component = move_dir.dot(radial)
	var tangent_vel = move_dir - radial * radial_component

	if tangent_vel.length() > 0.01:
		var new_pos = target_pos + tangent_vel.normalized() * surface_speed * delta
		var dir_from_planet = (new_pos - planet_pos).normalized()
		target_pos = planet_pos + dir_from_planet * altitude

	if abs(radial_component) > 0.01:
		altitude += radial_component * surface_speed * delta
		var dir_from_planet = (target_pos - planet_pos).normalized()
		target_pos = planet_pos + dir_from_planet * altitude
	return target_pos


## Inside the hull: the ship's own down. Outside: a pull that fades to zero at gravity_radius.
func get_gravity_force(target_position: Vector3) -> Vector3:
	var distance = global_position.distance_to(target_position)

	if distance > gravity_radius:
		return Vector3.ZERO

	if _is_inside_interior(target_position):
		var ship_down = -global_transform.basis.y
		return ship_down * gravity_strength

	var direction = (global_position - target_position).normalized()
	var falloff = 1.0 - (distance / gravity_radius)
	return direction * gravity_strength * max(falloff, 0.0)


func get_surface_normal(target_position: Vector3) -> Vector3:
	if _is_inside_interior(target_position):
		return global_transform.basis.y
	return (target_position - global_position).normalized()


func is_on_surface(target_position: Vector3) -> bool:
	return _is_inside_interior(target_position)


func get_gravity_priority() -> int:
	return 10


## Never shrinks interior_radius.
func _auto_calculate_interior_radius():
	var max_extent := 0.0
	for child in get_children():
		max_extent = maxf(max_extent, _child_extent(child))

	if max_extent > interior_radius:
		interior_radius = max_extent
		print("Auto-calculated interior_radius: ", interior_radius)


func _child_extent(child) -> float:
	var extent := 0.0
	if child is CollisionShape3D and child.shape:
		extent = maxf(extent, _shape_extent(child))

	if child is Area3D:
		extent = maxf(extent, child.position.length() + BOARD_MARGIN)

	if child is MeshInstance3D and child.mesh:
		var mesh_extent = child.mesh.get_aabb().size.length() * 0.5
		mesh_extent *= child.transform.basis.get_scale().length()
		extent = maxf(extent, mesh_extent + child.position.length())

	# Instanced scenes such as the GLB model.
	for grandchild in child.get_children():
		if grandchild is MeshInstance3D and grandchild.mesh:
			var s = grandchild.mesh.get_aabb().size.length() * 0.5
			s *= grandchild.global_transform.basis.get_scale().length()
			extent = maxf(extent, child.position.length() + s)
	return extent


func _shape_extent(child) -> float:
	var s = child.shape
	var r := 0.0
	if s is BoxShape3D:
		r = s.size.length() * 0.5
	elif s is SphereShape3D:
		r = s.radius
	elif s is CapsuleShape3D:
		r = max(s.radius, s.height * 0.5)
	return r + child.position.length()


func _is_inside_interior(world_pos: Vector3) -> bool:
	if not interior:
		return false
	var local_pos = to_local(world_pos)
	return local_pos.length() < interior_radius


## Reparents without moving and tells the network if it is the local player.
func board(character: CharacterBody3D) -> bool:
	if character in passengers:
		return false

	var global_xform = character.global_transform
	character.reparent(interior, false)
	character.global_transform = global_xform

	passengers.append(character)
	character.add_collision_exception_with(self)

	var walker = character.get("planet")
	if walker != null:
		walker.set_planet(self, ship_name)

	character.set_meta("boarded_ship", self)

	passenger_boarded.emit(character)

	if not character.get("is_remote_player"):
		var network = _get_network_controller()
		if network and network.get("objects") != null:
			network.objects.send_ship_board(self)

	print("Player boarded ship: ", ship_name)
	return true


## Reparents to Players (or the scene root) without moving; tells the network for the local player.
func depart(character: CharacterBody3D) -> bool:
	if character not in passengers:
		return false

	var global_xform = character.global_transform

	var scene_root = get_tree().current_scene
	var target_parent = scene_root
	var players_node = scene_root.find_child("Players", true, false)
	if players_node:
		target_parent = players_node

	character.reparent(target_parent, false)
	character.global_transform = global_xform

	passengers.erase(character)
	character.remove_collision_exception_with(self)
	character.remove_meta("boarded_ship")

	if character == pilot:
		pilot = null
		pilot_changed.emit(null)

	passenger_departed.emit(character)

	if not character.get("is_remote_player"):
		var network = _get_network_controller()
		if network and network.get("objects") != null:
			network.objects.send_ship_depart(self)

	print("Player departed ship: ", ship_name)
	return true


func set_pilot(character: CharacterBody3D):
	if character not in passengers:
		board(character)
	pilot = character
	pilot_changed.emit(character)
	print("Pilot set: ", character.name)


func clear_pilot():
	var old_pilot = pilot
	pilot = null
	pilot_changed.emit(null)
	if old_pilot:
		print("Pilot cleared: ", old_pilot.name)


func apply_thrust(direction: Vector3, delta: float):
	var world_direction = (global_transform.basis * direction).normalized()
	ship_velocity += world_direction * thrust_force * delta
	ship_velocity = ship_velocity.limit_length(max_speed)


func apply_rotation(axis: Vector3, amount: float, delta: float):
	rotate_object_local(axis, amount * rotation_speed * delta)


func apply_brake(delta: float):
	ship_velocity = ship_velocity.lerp(Vector3.ZERO, delta * 2.0)


func toggle_planet_align():
	align_to_planet = not align_to_planet
	if align_to_planet:
		_align_target_planet = _find_nearest_planet()
		if _align_target_planet:
			print("Planet alignment: ON — locked to: ", _align_target_planet.name)
		else:
			print("Planet alignment: ON — WARNING: no planet found!")
	else:
		_align_target_planet = null
		print("Planet alignment: OFF")


## One global_transform write: move and turn up toward the surface normal, keeping the heading.
func _align_to_nearest_planet_at(delta: float, target_pos: Vector3):
	if not _align_target_planet or not is_instance_valid(_align_target_planet):
		_align_target_planet = _find_nearest_planet()
	if not _align_target_planet:
		global_position = target_pos
		return

	var target_up = (target_pos - _align_target_planet.global_position).normalized()
	var current_scale = global_transform.basis.get_scale()
	var current_up = global_transform.basis.y.normalized()
	var current_forward = (-global_transform.basis.z).normalized()

	var speed_factor = clampf(ship_velocity.length() / 10.0, 1.0, 5.0)
	var slerp_factor = clampf(delta * align_speed * speed_factor, 0.0, 0.95)
	var new_up = current_up.slerp(target_up, slerp_factor).normalized()

	var right = current_forward.cross(new_up)
	if right.length() < 0.01:
		right = global_transform.basis.x.normalized()
	right = right.normalized()
	var forward = new_up.cross(right).normalized()

	var new_basis = Basis(right, new_up, -forward).orthonormalized()
	global_transform = Transform3D(new_basis.scaled(current_scale), target_pos)


func _find_nearest_planet() -> Node3D:
	var root = get_tree().current_scene
	if not root:
		return null
	var planets = _collect_nearby_planets(root)
	var best: Node3D = null
	var best_dist := INF
	for p in planets:
		var dist = global_position.distance_to(p.global_position)
		if dist < best_dist:
			best_dist = dist
			best = p
	return best


## Skips ships (anything with apply_thrust) and everything under them.
func _collect_nearby_planets(node: Node) -> Array:
	var result := []
	if node.has_method("apply_thrust"):
		return result
	if node.has_method("get_gravity_force") and node.has_method("get_surface_normal"):
		result.append(node)
	elif node is StaticBody3D and node.has_node("CollisionShape3D"):
		if node.name.to_lower().contains("planet"):
			result.append(node)
	for child in node.get_children():
		result.append_array(_collect_nearby_planets(child))
	return result


func _setup_ship_camera():
	if ship_camera:
		return
	_ship_cam_pivot = Node3D.new()
	_ship_cam_pivot.name = "ShipCamPivot"
	add_child(_ship_cam_pivot)

	ship_camera = Camera3D.new()
	ship_camera.name = "ShipCamera"
	ship_camera.far = 10000.0
	_ship_cam_pivot.add_child(ship_camera)
	_update_ship_camera()


func _update_ship_camera():
	if not _ship_cam_pivot or not ship_camera:
		return
	_ship_cam_pivot.rotation = Vector3(_ship_cam_pitch, _ship_cam_yaw, 0)
	ship_camera.position = Vector3(0, 0, _ship_cam_zoom)
	ship_camera.rotation = Vector3.ZERO


func activate_ship_camera():
	_setup_ship_camera()
	ship_camera.current = true


func deactivate_ship_camera():
	if ship_camera:
		ship_camera.current = false


func ship_camera_input(event: InputEvent):
	if not ship_camera or not ship_camera.current:
		return
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_ship_cam_yaw -= event.relative.x * 0.005
		_ship_cam_pitch -= event.relative.y * 0.005
		_ship_cam_pitch = clamp(_ship_cam_pitch, -PI / 2.2, PI / 2.2)
		_update_ship_camera()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_ship_cam_zoom = max(_ship_cam_zoom - _ship_cam_zoom * 0.1, camera_min_zoom)
			_update_ship_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_ship_cam_zoom = min(_ship_cam_zoom + _ship_cam_zoom * 0.1, camera_max_zoom)
			_update_ship_camera()


func land_on_planet(planet: Node3D):
	is_landed = true
	landed_planet = planet
	ship_velocity = Vector3.ZERO
	print("Ship landed on: ", planet.name)


func take_off():
	is_landed = false
	landed_planet = null
	print("Ship taking off")


func _on_boarding_zone_entered(body: Node):
	if _boarding_cooldown > 0:
		return
	if not (body is CharacterBody3D and body.get("planet") != null):
		return
	if body not in passengers:
		_boarding_cooldown = BOARDING_COOLDOWN
		if body.get("ship") != null:
			body.ship.board(self)


func _on_boarding_zone_exited(_body: Node):
	pass


## Called each physics frame by an aboard character; a passenger outside the hull departs.
func check_passenger_exit(character: CharacterBody3D):
	if character not in passengers:
		return
	if character == pilot:
		return
	if _boarding_cooldown > 0:
		return
	var local_pos = to_local(character.global_position)
	if local_pos.length() > interior_radius + BOARD_MARGIN:
		_boarding_cooldown = BOARDING_COOLDOWN
		if character.get("ship") != null:
			character.ship.depart()


func get_net_id() -> String:
	return net_id


func get_sync_data() -> Dictionary:
	var xf = global_transform
	return {
		"net_id": net_id,
		"ship_name": ship_name,
		"origin": _vec_to_dict(xf.origin),
		"basis_x": _vec_to_dict(xf.basis.x),
		"basis_y": _vec_to_dict(xf.basis.y),
		"basis_z": _vec_to_dict(xf.basis.z),
		"velocity": _vec_to_dict(ship_velocity)
	}


func apply_sync_data(data: Dictionary):
	var origin = _dict_to_vec(data.origin)
	var bx = _dict_to_vec(data.basis_x)
	var by = _dict_to_vec(data.basis_y)
	var bz = _dict_to_vec(data.basis_z)
	global_transform = Transform3D(Basis(bx, by, bz), origin)
	if "velocity" in data:
		ship_velocity = _dict_to_vec(data.velocity)


static func _vec_to_dict(v: Vector3) -> Dictionary:
	return {"x": v.x, "y": v.y, "z": v.z}


static func _dict_to_vec(d) -> Vector3:
	return Vector3(d.x, d.y, d.z)


func _get_network_controller() -> Node:
	return get_node_or_null("/root/NetworkController")


func _setup_turrets():
	_turret_positions.clear()
	_turret_fire_timers.clear()
	var hull_half_x := 5.0
	var hull_half_z := 9.0
	var hull_top_y := 2.5
	for i in turret_count:
		var t: float = float(i) / float(max(turret_count - 1, 1))
		var side := 1.0 if i % 2 == 0 else -1.0
		var z_pos := lerpf(-hull_half_z, hull_half_z * 0.5, t)
		_turret_positions.append(Vector3(side * hull_half_x * 0.8, hull_top_y, z_pos))
		_turret_fire_timers.append(t * turret_fire_rate)


func _process_combat(delta: float):
	if shield_hp < max_shield_hp:
		_shield_regen_timer += delta
		if _shield_regen_timer >= shield_regen_delay:
			shield_hp = min(shield_hp + shield_regen_rate * delta, max_shield_hp)

	if _fire_active:
		if not _current_target or not is_instance_valid(_current_target):
			_current_target = _find_nearest_enemy()

		if _current_target and is_instance_valid(_current_target):
			var dist = global_position.distance_to(_current_target.global_position)
			if dist > turret_range:
				_current_target = _find_nearest_enemy()

		if _current_target and is_instance_valid(_current_target):
			_update_turrets(delta, false)

	if _manual_fire:
		_update_turrets(delta, true)


func _update_turrets(delta: float, manual: bool):
	var fire: Callable = _fire_turret_manual if manual else _fire_turret
	for i in _turret_fire_timers.size():
		_turret_fire_timers[i] -= delta
		if _turret_fire_timers[i] <= 0.0:
			_turret_fire_timers[i] = turret_fire_rate
			fire.call(i)


func _fire_turret_manual(turret_index: int):
	var world_pos = to_global(_turret_positions[turret_index])
	var target_point = world_pos + _manual_fire_dir * 500.0
	var direction = (target_point - world_pos).normalized()
	direction += Vector3(randf_range(-0.02, 0.02), randf_range(-0.02, 0.02), randf_range(-0.02, 0.02))
	_launch_bolt(world_pos, direction)


func _fire_turret(turret_index: int):
	if not _current_target or not is_instance_valid(_current_target):
		return

	var world_pos = to_global(_turret_positions[turret_index])
	var target_pos = _current_target.global_position
	var spread = Vector3(
		randf_range(-2.0, 2.0),
		randf_range(-1.0, 1.0),
		randf_range(-2.0, 2.0)
	)
	var direction = (target_pos + spread - world_pos).normalized()
	_launch_bolt(world_pos, direction)


func _launch_bolt(world_pos: Vector3, direction: Vector3):
	var bolt = _create_ship_bolt()
	get_tree().current_scene.add_child(bolt)
	bolt.fire(world_pos, direction)

	var nc = _get_network_controller()
	if nc and nc.has_method("combat_sync") and nc.combat_sync():
		nc.combat_sync().send_bolt_fired(world_pos, direction, turret_bolt_color, turret_bolt_speed)


func _create_ship_bolt() -> BlasterBolt:
	var bolt = BlasterBolt.new()
	bolt.speed = turret_bolt_speed
	bolt.bolt_color = turret_bolt_color
	bolt.bolt_length = 4.0
	bolt.bolt_radius = 0.25
	bolt.lifetime = 8.0
	bolt.proximity_deflect_radius = 0.0
	bolt.set_meta("source_ship", self)
	bolt.set_meta("bolt_damage", turret_bolt_damage)
	return bolt


func start_firing():
	_fire_active = true


func stop_firing():
	_fire_active = false
	_current_target = null


func manual_fire(direction: Vector3):
	_manual_fire = true
	_manual_fire_dir = direction


func stop_manual_fire():
	_manual_fire = false


## Shields absorb damage first; broadcasts the new values and destroys the ship at 0 hull.
func take_ship_damage(amount: float):
	if _is_destroyed:
		return

	_shield_regen_timer = 0.0

	if shield_hp > 0:
		shield_hp -= amount
		if shield_hp < 0:
			hull_hp += shield_hp
			shield_hp = 0
	else:
		hull_hp -= amount

	ship_damaged.emit(hull_hp, shield_hp)

	var nc = _get_network_controller()
	if nc and nc.connected:
		nc.send_json({
			"type": "combat_ship_damage",
			"net_id": net_id,
			"hull_hp": hull_hp,
			"shield_hp": shield_hp
		})

	if hull_hp <= 0:
		hull_hp = 0
		_destroy_ship()


## Ejects every passenger and hides the ship two seconds later.
func _destroy_ship():
	_is_destroyed = true
	ship_destroyed.emit()
	_spawn_explosion()

	for passenger in passengers.duplicate():
		depart(passenger)

	var timer = get_tree().create_timer(2.0)
	timer.timeout.connect(func():
		visible = false
		set_physics_process(false)
	)
	print("Ship destroyed: ", ship_name)


## Freed after 3 s.
func _spawn_explosion():
	var particles = GPUParticles3D.new()
	particles.name = "Explosion"
	particles.emitting = true
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.amount = 64
	particles.lifetime = 2.0
	particles.process_material = _explosion_material()

	var mesh = SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	particles.draw_pass_1 = mesh

	get_tree().current_scene.add_child(particles)
	particles.global_position = global_position

	var light = OmniLight3D.new()
	light.light_color = Color(1.0, 0.5, 0.1)
	light.light_energy = 10.0
	light.omni_range = 50.0
	particles.add_child(light)

	var cleanup_timer = get_tree().create_timer(3.0)
	cleanup_timer.timeout.connect(func():
		if is_instance_valid(particles):
			particles.queue_free()
	)


func _explosion_material() -> ParticleProcessMaterial:
	var mat = ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 0, 0)
	mat.spread = 180.0
	mat.initial_velocity_min = 5.0
	mat.initial_velocity_max = 20.0
	mat.gravity = Vector3.ZERO
	mat.scale_min = 2.0
	mat.scale_max = 6.0
	mat.color = Color(1.0, 0.6, 0.1)

	var color_ramp = GradientTexture1D.new()
	var gradient = Gradient.new()
	gradient.set_color(0, Color(1.0, 0.8, 0.2, 1.0))
	gradient.set_color(1, Color(1.0, 0.2, 0.0, 0.0))
	color_ramp.gradient = gradient
	mat.color_ramp = color_ramp
	return mat


func _find_nearest_enemy() -> Node3D:
	var root = get_tree().current_scene
	if not root:
		return null
	var best: Node3D = null
	var best_dist := turret_range
	var ships = _find_all_ships(root)
	for ship in ships:
		if ship == self:
			continue
		if ship.get("_is_destroyed"):
			continue
		var dist = global_position.distance_to(ship.global_position)
		if dist < best_dist:
			best_dist = dist
			best = ship
	return best


func _find_all_ships(node: Node) -> Array:
	var result := []
	if node.has_method("take_ship_damage") and node != self:
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_all_ships(child))
	return result
