extends CharacterBody3D
## A placed NPC: wanders, follows its schedule, talks and drives; only the authority runs the AI, others interpolate.

@export var wander_speed := 2.0
@export var travel_speed := 3.0
@export var wander_radius := 150.0
@export var min_walk_time := 2.0
@export var max_walk_time := 4.0
@export var min_idle_time := 1.0
@export var max_idle_time := 3.0
@export var arrival_threshold := 2.0
## Degrees; above Godot's 45 so beveled curb edges (50-55) do not read as walls.
@export var max_floor_angle_deg := 60.0

## World metres.
@export var max_step_height := 0.45
## World metres; a little over the body's radius so the probe clears the lip.
@export var step_forward := 0.4
@export var debug_steps := false

## Empty keeps it on foot; the server can override it with set_vehicle().
@export var vehicle_scene: PackedScene
## Seconds off the road before it stops driving.
@export var vehicle_exit_grace := 1.5

@export var arm_swing_amount := 1.2
@export var leg_swing_amount := 0.8
@export var animation_speed := 10.0

## For rigged characters: folder of the clip FBXs; blank derives it from the scene path.
@export_group("Skeletal Animation")
@export var custom_character_dir := ""
@export_group("")

@export var npc_id := ""

@export var schedule: Array[NpcScheduleEntry] = []

enum State { WANDERING, TRAVELING, AT_WAYPOINT }

var _state: State = State.WANDERING
var _is_authority := true
var _spawn_position := Vector3.ZERO
var _gravity: float

var _chatting := false
var _chat_target: Node3D = null

var _wander_dir := Vector3.ZERO
var _wander_timer := 0.0
var _wander_walking := false

var _route: Array[Vector3] = []
var _route_idx := 0

var _path_network = null               # NpcPathNetwork (set by NpcManager)
var _nav_agent: NavigationAgent3D = null
var _target_waypoint_pos := Vector3.ZERO
var _target_waypoint_name := ""

var _active_schedule_idx := -1
var _schedule_check_timer := 0.0
var _env_controller = null

var _current_action: NpcAction = null
var _pending_action_name := ""

var _stuck_check_pos := Vector3.ZERO
var _stuck_timer := 0.0
var _avoidance_dir := Vector3.ZERO
var _avoidance_timer := 0.0
const STUCK_CHECK_INTERVAL := 0.4
const STUCK_DISTANCE_THRESHOLD := 0.3
const AVOIDANCE_DURATION := 0.6

var _walk_cycle := 0.0

var _custom_anim = null
var _uses_custom_anim := false
# Read by CustomCharacterAnimation to match clip speed.
var walk_speed: float
var run_speed: float

var _remote_target_pos := Vector3.ZERO
var _remote_model_rot_y := 0.0
var _remote_speed := 0.0
var _prev_remote_pos := Vector3.ZERO

const LimbRigScript := preload("res://src/character/limb_rig.gd")

var character_model: Node3D

# Box-humanoid limbs, also found inside an instanced model scene.
var rig := LimbRigScript.new()
var has_limbs := false

var _vehicle_scene: PackedScene = null   # active vehicle (export or server)
var _in_vehicle := false
var _vehicle_zone = null
var _vehicle_car: Node3D = null
var _vehicle_exit_timer := 0.0   # >0 = exit pending (grace countdown)
var _vehicle_check_timer := 0.0  # throttles the road-detection raycast
const VEHICLE_RAY_INTERVAL := 0.15

# Chat label (screen-space, shown above the head)
var _npc_label: Label = null
var _npc_label_layer: CanvasLayer = null
var _label_active := false  # true while text should be shown
var _npc_manager_ref = null  # set by NpcManager for event broadcasting

var _remote_talking := false
var _remote_talk_timer := 0.0
var _remote_talk_elapsed := 0.0

const AUDIO_CACHE_DIR := "user://npc_audio_cache/"
const BUNDLED_AUDIO_DIR := "res://assets/entities/pedestrians/audio/"


func _ready():
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity") * 2.5

	for child_name in ["CamOrigin", "XROrigin3D"]:
		var child = get_node_or_null(child_name)
		if child:
			child.queue_free()

	# Text is drawn by a screen label, so hide the 3D bubble sprite.
	var bubble = get_node_or_null("CharacterModel/ChatBubble/Sprite3D")
	if bubble:
		bubble.visible = false

	var sound = get_node_or_null("SoundPlayer")
	if sound and sound is AudioStreamPlayer3D:
		sound.max_distance = 20.0
		sound.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE

	character_model = $CharacterModel
	has_limbs = rig.resolve(character_model)

	walk_speed = wander_speed
	run_speed = travel_speed
	if not has_limbs:
		_setup_custom_animation()

	_nav_agent = get_node_or_null("NavigationAgent3D")
	if _nav_agent:
		_nav_agent.path_desired_distance = arrival_threshold
		_nav_agent.target_desired_distance = arrival_threshold

	floor_max_angle = deg_to_rad(max_floor_angle_deg)

	_vehicle_scene = vehicle_scene

	if npc_id == "":
		npc_id = name

	_spawn_position = position
	_remote_target_pos = position
	_prev_remote_pos = position

	await get_tree().process_frame
	_cache_env_controller()
	_enter_wandering()


func _physics_process(delta):
	if not _is_authority:
		_process_remote(delta)
		return

	if not is_on_floor():
		velocity.y -= _gravity * delta

	if _chatting:
		_process_chatting(delta)
		return

	_schedule_check_timer -= delta
	if _schedule_check_timer <= 0.0:
		_schedule_check_timer = 1.0
		_check_schedule()

	match _state:
		State.WANDERING:
			_process_wandering(delta)
		State.TRAVELING:
			_process_traveling(delta)
		State.AT_WAYPOINT:
			_process_at_waypoint(delta)

	_update_avoidance(delta)
	move_and_slide()
	_try_step_up()
	_finish_frame(delta)


## Non-authority: ease toward the last replicated transform.
func _process_remote(delta: float) -> void:
	position = position.lerp(_remote_target_pos, delta * 10.0)
	if character_model:
		character_model.rotation.y = lerp_angle(
			character_model.rotation.y, _remote_model_rot_y, delta * 10.0
		)
	_finish_frame(delta)


func _process_chatting(delta: float) -> void:
	_damp_horizontal(delta)
	if is_instance_valid(_chat_target) and character_model:
		var to_player: Vector3 = _chat_target.global_position - global_position
		to_player.y = 0.0
		if to_player.length() > 0.1:
			var rot: float = atan2(to_player.x, to_player.z) + PI
			character_model.rotation.y = lerp_angle(character_model.rotation.y, rot, delta * 5.0)
	move_and_slide()
	_finish_frame(delta)


func _finish_frame(delta: float) -> void:
	_animate(delta)
	_update_vehicle(delta)
	_update_label_screen_pos()


func _damp_horizontal(delta: float) -> void:
	velocity.x = lerp(velocity.x, 0.0, delta * 10.0)
	velocity.z = lerp(velocity.z, 0.0, delta * 10.0)


func _check_schedule():
	if schedule.is_empty():
		if _state != State.WANDERING:
			_enter_wandering()
		return

	var best_idx := _schedule_index_for(_get_current_hour())
	if best_idx == _active_schedule_idx:
		return

	_active_schedule_idx = best_idx

	if best_idx < 0:
		_stop_action()
		_enter_wandering()
		return

	var entry: NpcScheduleEntry = schedule[best_idx]
	if entry.waypoint_name == "":
		_stop_action()
		_enter_at_waypoint(entry.action_name)
		return

	var wp_pos = _find_waypoint_position(entry.waypoint_name)
	if wp_pos == null:
		push_warning("[NPC %s] Waypoint '%s' not found" % [npc_id, entry.waypoint_name])
		_enter_wandering()
		return

	_target_waypoint_name = entry.waypoint_name
	_target_waypoint_pos = wp_pos
	_enter_traveling(entry.action_name)


## -1 before the first entry; the day does not wrap.
func _schedule_index_for(hour: float) -> int:
	var best_idx := -1
	var best_hour := -1.0
	for i in schedule.size():
		var entry: NpcScheduleEntry = schedule[i]
		if entry.hour <= hour and entry.hour > best_hour:
			best_hour = entry.hour
			best_idx = i
	return best_idx


## Game hour from the EnvironmentController, else the system clock.
func _get_current_hour() -> float:
	if _env_controller and is_instance_valid(_env_controller):
		return _env_controller.current_time * 24.0
	var t = Time.get_time_dict_from_system()
	return float(t.hour) + float(t.minute) / 60.0


func _cache_env_controller():
	var workspace = _get_workspace()
	if workspace:
		_env_controller = workspace.find_child("EnvironmentController", true, false)


## `entries` is the server's [{hour, waypoint, action}] list.
func apply_server_schedule(entries: Array):
	schedule.clear()
	for entry_dict in entries:
		var entry := NpcScheduleEntry.new()
		entry.hour = float(entry_dict.get("hour", 0))
		entry.waypoint_name = str(entry_dict.get("waypoint", ""))
		entry.action_name = str(entry_dict.get("action", ""))
		schedule.append(entry)
	_active_schedule_idx = -1
	_schedule_check_timer = 0.0
	print("[NPC %s] Schedule overridden with %d entries" % [npc_id, schedule.size()])


func _enter_wandering():
	_state = State.WANDERING
	_wander_walking = false
	_route.clear()
	_route_idx = 0
	_wander_timer = randf_range(min_idle_time, max_idle_time)


func _process_wandering(delta):
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		if _wander_walking:
			_wander_walking = false
			_route.clear()
			_route_idx = 0
			_wander_timer = randf_range(min_idle_time, max_idle_time)
		else:
			_wander_walking = true
			_wander_timer = randf_range(min_walk_time, max_walk_time)
			_pick_wander_target()

	if _wander_walking:
		_follow_route_or_direction(delta, wander_speed)
	else:
		_damp_horizontal(delta)


## Without paths, a random heading that turns back once far from the spawn.
func _pick_wander_target():
	if _path_network and _path_network.has_paths():
		var target_pos: Vector3 = _path_network.random_point_near(
			_spawn_position, wander_radius
		)
		_route = _path_network.find_route(position, target_pos)
		_route_idx = 0
		return

	_route.clear()
	_route_idx = 0
	var offset = position - _spawn_position
	offset.y = 0.0
	if offset.length() > wander_radius * 0.7:
		_wander_dir = (-offset.normalized() + _random_dir() * 0.3).normalized()
	else:
		_wander_dir = _random_dir()

	if character_model and _wander_dir.length() > 0.1:
		character_model.rotation.y = atan2(_wander_dir.x, _wander_dir.z) + PI


func _enter_traveling(action_name: String):
	_state = State.TRAVELING
	_pending_action_name = action_name
	_route.clear()
	_route_idx = 0
	print("[NPC %s] Traveling to waypoint '%s'" % [npc_id, _target_waypoint_name])

	if _path_network and _path_network.has_paths():
		_route = _path_network.find_route(position, _target_waypoint_pos)
		_route_idx = 0
		return

	if _nav_agent:
		_nav_agent.target_position = _target_waypoint_pos


func _process_traveling(delta):
	var flat_dist := Vector2(
		position.x - _target_waypoint_pos.x,
		position.z - _target_waypoint_pos.z
	).length()

	if flat_dist <= arrival_threshold:
		_enter_at_waypoint(_pending_action_name)
		return

	_follow_route_or_direction(delta, travel_speed)


func _follow_route_or_direction(delta: float, speed: float):
	var direction := Vector3.ZERO

	if _route.size() > 0 and _route_idx < _route.size():
		var route_dir = _route_direction(delta)
		if route_dir == null:
			return
		direction = route_dir
	elif _nav_agent and not _nav_agent.is_navigation_finished():
		direction = _flat_direction_to(_nav_agent.get_next_path_position())
	elif _state == State.TRAVELING:
		direction = _flat_direction_to(_target_waypoint_pos)
	elif _wander_dir.length() > 0.01:
		direction = _wander_dir

	if direction.length() > 0.01:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		if character_model:
			var target_rot = atan2(direction.x, direction.z) + PI
			character_model.rotation.y = lerp_angle(
				character_model.rotation.y, target_rot, delta * 10.0
			)
	else:
		_damp_horizontal(delta)


## Null when the route has just ended; advances past reached points.
func _route_direction(delta: float) -> Variant:
	var to_target: Vector3 = _route[_route_idx] - position
	to_target.y = 0.0

	if to_target.length() <= arrival_threshold:
		_route_idx += 1
		if _route_idx >= _route.size():
			if _state == State.WANDERING:
				_wander_walking = false
				_wander_timer = randf_range(min_idle_time, max_idle_time)
				_damp_horizontal(delta)
			return null
		to_target = _route[_route_idx] - position
		to_target.y = 0.0

	if to_target.length() > 0.01:
		return to_target.normalized()
	return Vector3.ZERO


func _flat_direction_to(target: Vector3) -> Vector3:
	var direction := target - position
	direction.y = 0.0
	if direction.length() > 0.01:
		direction = direction.normalized()
	return direction


func _enter_at_waypoint(action_name: String):
	_state = State.AT_WAYPOINT
	_route.clear()
	_route_idx = 0
	velocity.x = 0.0
	velocity.z = 0.0
	print("[NPC %s] Arrived at waypoint '%s'" % [npc_id, _target_waypoint_name])
	if action_name != "":
		_start_action(action_name)


func _process_at_waypoint(delta):
	if _current_action:
		# The action drives movement itself.
		_current_action.process(self, delta)
	else:
		_damp_horizontal(delta)


func _start_action(action_name: String):
	_stop_action()
	_current_action = NpcAction.create(action_name)
	_current_action.start(self)


func _stop_action():
	if _current_action:
		_current_action.stop(self)
		_current_action = null


## Under the workspace's "Waypoints", or null.
func _find_waypoint_position(waypoint_name: String) -> Variant:
	var workspace = _get_workspace()
	if not workspace:
		return null
	var waypoints = workspace.get_node_or_null("Waypoints")
	if not waypoints:
		return null
	var marker = waypoints.get_node_or_null(waypoint_name)
	if not marker:
		return null
	return marker.position


func _get_workspace() -> Node:
	var parent = get_parent()
	if parent:
		return parent.get_parent()
	return null


## Sidesteps a walking NPC that barely moved for STUCK_CHECK_INTERVAL.
func _update_avoidance(delta: float):
	if _avoidance_timer > 0.0:
		_avoidance_timer -= delta
		velocity.x += _avoidance_dir.x * wander_speed * 1.2
		velocity.z += _avoidance_dir.z * wander_speed * 1.2
		return

	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	if horiz_speed < 0.1:
		_stuck_check_pos = position
		_stuck_timer = 0.0
		return

	_stuck_timer += delta
	if _stuck_timer < STUCK_CHECK_INTERVAL:
		return

	var flat_moved := Vector2(
		position.x - _stuck_check_pos.x,
		position.z - _stuck_check_pos.z
	).length()
	if flat_moved < STUCK_DISTANCE_THRESHOLD:
		_log_stuck(horiz_speed, flat_moved)
		var forward := Vector2(velocity.x, velocity.z).normalized()
		var side := 1.0 if randf() > 0.5 else -1.0
		_avoidance_dir = Vector3(-forward.y * side, 0.0, forward.x * side)
		_avoidance_timer = AVOIDANCE_DURATION

	_stuck_check_pos = position
	_stuck_timer = 0.0


func _log_stuck(horiz_speed: float, flat_moved: float) -> void:
	print("──[STUCK %s]── tried_speed=%.2f flat_moved=%.3f vel=%s" % [
		npc_id, horiz_speed, flat_moved, str(velocity)])
	print("   on_floor=%s on_wall=%s on_ceiling=%s last_motion=%s gscale=%s" % [
		is_on_floor(), is_on_wall(), is_on_ceiling(),
		str(get_last_motion()), str(global_transform.basis.get_scale())])
	print("   slide_collisions=%d" % get_slide_collision_count())
	for ci in get_slide_collision_count():
		var col := get_slide_collision(ci)
		var other = col.get_collider()
		print("     #%d normal=%s angle=%.1f° collider=%s" % [
			ci, str(col.get_normal()),
			rad_to_deg(col.get_normal().angle_to(Vector3.UP)),
			other.name if other else "?"])


## Probes with move_and_collide because test_move can ignore the body's scale.
func _try_step_up() -> void:
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	if horiz.length() < 0.1:
		return
	if velocity.y > 1.0:
		return  # airborne or rising

	var dir := horiz.normalized()
	if not _pushing_into_wall(dir):
		return

	var saved := global_position

	move_and_collide(Vector3.UP * max_step_height)
	move_and_collide(dir * step_forward)
	var landing := move_and_collide(Vector3.DOWN * (max_step_height + 0.05))

	var gained := Vector2(global_position.x - saved.x,
						  global_position.z - saved.z).length()
	var walkable: bool = landing != null and landing.get_normal().y >= 0.7

	if debug_steps:
		var ln := "no-ground"
		if landing:
			ln = "n.y=%.2f" % landing.get_normal().y
		print("[NPC %s] step try: gained=%.3f landed=%s -> %s" % [
			npc_id, gained, ln,
			"CLIMB" if (walkable and gained > 0.02) else "revert"])

	if walkable and gained > 0.02:
		velocity.y = 0.0
	else:
		global_position = saved


## Brushing a wall alongside does not count, or stepping would jump forward on flat ground.
func _pushing_into_wall(dir: Vector3) -> bool:
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		if n.y <= 0.3 and n.dot(dir) < -0.3:
			return true
	return false


## "" clears the vehicle; a scene path assigns a car.
func set_vehicle(path: String) -> void:
	if path == "":
		_vehicle_scene = null
		if _in_vehicle:
			_finish_vehicle_exit()
		return
	var res = load(path)
	if res is PackedScene:
		_vehicle_scene = res
	else:
		push_warning("[NPC %s] vehicle path is not a scene: %s" % [npc_id, path])


## Reuses a parked car; runs on every client from the replicated transform.
func enter_vehicle_mode(zone) -> void:
	_vehicle_exit_timer = 0.0
	if _in_vehicle:
		return
	if _vehicle_scene == null:
		return
	_in_vehicle = true
	_vehicle_zone = zone
	if character_model:
		character_model.visible = false
	if is_instance_valid(_vehicle_car):
		zone.release_slot(_vehicle_car)
		_vehicle_car.visible = true
	else:
		_vehicle_car = zone.spawn_car(_vehicle_scene)
	if not is_instance_valid(_vehicle_car):
		# Spawn failed: show the NPC again.
		_in_vehicle = false
		_vehicle_zone = null
		if character_model:
			character_model.visible = true
		return
	# Place it now so it does not flash at the origin for a frame.
	var yaw0: float = character_model.global_rotation.y if character_model else global_rotation.y
	zone.update_driving_car(_vehicle_car, global_position, yaw0)


func _check_vehicle_zone(delta: float) -> void:
	if _vehicle_scene == null and not _in_vehicle:
		return
	_vehicle_check_timer -= delta
	if _vehicle_check_timer > 0.0:
		return
	_vehicle_check_timer = VEHICLE_RAY_INTERVAL

	var zone = _raycast_vehicle_zone()
	if zone != null:
		enter_vehicle_mode(zone)
	elif _in_vehicle and _vehicle_exit_timer <= 0.0:
		_vehicle_exit_timer = vehicle_exit_grace


## Rays, because body overlap flickers on concave road meshes; checks up to four stacked areas.
func _raycast_vehicle_zone():
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * 3.0
	var to := global_position + Vector3.DOWN * 4.0
	var exclude: Array[RID] = [get_rid()]
	for _i in 4:
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.collide_with_areas = true
		q.collide_with_bodies = false
		q.exclude = exclude
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return null
		if hit.collider and hit.collider.is_in_group("vehicle_zone"):
			return hit.collider
		exclude.append(hit.rid)
	return null


func _update_vehicle(delta: float) -> void:
	_check_vehicle_zone(delta)
	if not _in_vehicle:
		return

	if _vehicle_exit_timer > 0.0:
		_vehicle_exit_timer -= delta
		if _vehicle_exit_timer <= 0.0:
			_finish_vehicle_exit()
			return

	if _vehicle_zone == null or not is_instance_valid(_vehicle_car):
		return
	var yaw: float = character_model.global_rotation.y if character_model else global_rotation.y
	_vehicle_zone.update_driving_car(_vehicle_car, global_position, yaw)


## Frees the car if every slot is taken.
func _finish_vehicle_exit() -> void:
	_in_vehicle = false
	_vehicle_exit_timer = 0.0
	if character_model:
		character_model.visible = true
	if is_instance_valid(_vehicle_car) and _vehicle_zone:
		if not _vehicle_zone.park_car(_vehicle_car):
			_vehicle_car.queue_free()
			_vehicle_car = null
	_vehicle_zone = null


## Box limbs only; rigged characters go through _animate_custom().
func _animate(delta):
	if _uses_custom_anim and _custom_anim:
		_animate_custom(delta)
		return

	var speed: float
	if _is_authority:
		speed = Vector2(velocity.x, velocity.z).length()
	else:
		speed = _remote_speed

	var max_spd = max(travel_speed, wander_speed)
	var intensity = clamp(speed / max(max_spd, 0.01), 0.0, 1.0)

	if not is_on_floor() and _is_authority:
		rig.pitch_toward(rig.left_arm, PI, delta * 5.0)
		rig.pitch_toward(rig.right_arm, PI, delta * 5.0)
		rig.pitch_toward(rig.left_leg, 0.0, delta * 5.0)
		rig.pitch_toward(rig.right_leg, 0.0, delta * 5.0)
		return

	if _remote_talking:
		_animate_talk(delta)
		return

	if intensity > 0.01:
		_walk_cycle += animation_speed * intensity * delta
		_walk_cycle = fmod(_walk_cycle, TAU)
		var arm_sw  = sin(_walk_cycle) * arm_swing_amount * intensity
		var leg_sw  = sin(_walk_cycle) * leg_swing_amount * intensity
		var opp_sw  = sin(_walk_cycle + PI) * leg_swing_amount * intensity
		rig.pitch(rig.left_arm, opp_sw)
		rig.pitch(rig.right_arm, arm_sw)
		rig.pitch(rig.left_leg, leg_sw)
		rig.pitch(rig.right_leg, opp_sw)
	else:
		rig.relax(delta * 5.0)


func _animate_talk(delta) -> void:
	_remote_talk_elapsed += delta
	_remote_talk_timer -= delta
	if _remote_talk_timer <= 0.0:
		_remote_talking = false
		return
	var t := _remote_talk_elapsed
	var wave_a := (sin(t * 0.8) + 1.0) * 0.5
	var wave_b := (sin(t * 2.3) + 1.0) * 0.5
	var talk: float = clampf((wave_a * 0.4 + wave_b * 0.6) * 1.5 - 0.2, 0.0, 1.0)
	rig.pitch(rig.right_arm, sin(t * 1.4) * 0.3 * talk)
	rig.pitch(rig.left_arm, sin(t * 0.7) * 0.08 * talk)
	rig.pitch_toward(rig.left_leg, 0.0, delta * 5.0)
	rig.pitch_toward(rig.right_leg, 0.0, delta * 5.0)


func _setup_custom_animation():
	var sp = get_node_or_null("SoundPlayer")
	_custom_anim = CustomCharacterAnimation.new()
	_custom_anim.setup(self, character_model, sp)
	_uses_custom_anim = true
	print("[NPC %s] Using custom skeletal animation" % npc_id)


func _animate_custom(delta):
	if _remote_talking:
		_remote_talk_timer -= delta
		if _remote_talk_timer <= 0.0:
			_remote_talking = false
	_custom_anim.talking = _remote_talking

	var on_floor := is_on_floor() if _is_authority else true
	var speed: float = Vector2(velocity.x, velocity.z).length() if _is_authority else _remote_speed
	var running := speed > walk_speed + 0.5
	_custom_anim.animate(delta, speed, Vector3.ZERO, running, on_floor)


func show_chat_bubble(message: String):
	_broadcast_event("show_text", {"message": message})
	_show_label(message)


func hide_chat_bubble():
	_broadcast_event("hide_text", {})
	_label_active = false
	if _npc_label:
		_npc_label.visible = false


func _auto_hide_bubble(duration: float):
	await get_tree().create_timer(duration).timeout
	hide_chat_bubble()
	_chatting = false
	_chat_target = null


func start_chatting(player: Node3D):
	_chatting = true
	_chat_target = player


## Hidden when the head is behind the camera or occluded.
func _update_label_screen_pos():
	if _npc_label == null or not _label_active:
		return
	var camera = get_viewport().get_camera_3d()
	if camera == null:
		return
	var head_world = global_position + Vector3(0, 0.6, 0)
	if camera.is_position_behind(head_world):
		_npc_label.visible = false
		return

	var space = get_world_3d().direct_space_state
	var from = camera.global_position
	var query = PhysicsRayQueryParameters3D.create(from, head_world)
	query.exclude = [get_rid()]
	var result = space.intersect_ray(query)
	if result and result.position.distance_to(from) < head_world.distance_to(from) - 0.1:
		_npc_label.visible = false
		return

	_npc_label.visible = true
	var screen_pos = camera.unproject_position(head_world)
	var viewport_size = get_viewport().get_visible_rect().size
	var label_x = screen_pos.x - _npc_label.size.x * 0.5
	label_x = clampf(label_x, 10.0, viewport_size.x - _npc_label.size.x - 10.0)
	var label_y = screen_pos.y - _npc_label.size.y - 10.0
	label_y = maxf(label_y, 10.0)
	_npc_label.position = Vector2(label_x, label_y)


## Authority only.
func _broadcast_event(event: String, data: Dictionary):
	if _is_authority and _npc_manager_ref and _npc_manager_ref.has_method("broadcast_npc_event"):
		_npc_manager_ref.broadcast_npc_event(npc_id, event, data)


## Also broadcasts it.
func start_talk_animation(duration: float):
	_remote_talking = true
	_remote_talk_timer = duration
	_remote_talk_elapsed = 0.0
	_broadcast_event("talk_start", {"duration": duration})


func stop_talk_animation():
	_remote_talking = false
	_remote_talk_timer = 0.0
	_broadcast_event("talk_stop", {})


## Replays an authority's action event on this client without rebroadcasting.
func handle_remote_event(event: String, data: Dictionary):
	match event:
		"show_text":
			_show_label(data.get("message", ""))
		"hide_text":
			_label_active = false
			if _npc_label:
				_npc_label.visible = false
		"talk_start":
			_remote_talking = true
			_remote_talk_timer = float(data.get("duration", 3.0))
			_remote_talk_elapsed = 0.0
		"talk_stop":
			_remote_talking = false
		"audio_play":
			var apath: String = str(data.get("path", ""))
			var adur: float = float(data.get("duration", 3.0))
			_play_remote_audio(apath, adur)
		"audio_stop":
			var sp := _speech_player()
			if sp and sp.playing:
				sp.stop()


## Requests the clip from the server when it is not cached.
func _play_remote_audio(audio_path: String, duration: float):
	if audio_path == "":
		return

	var sp := _speech_player()
	if sp == null:
		return
	_reset_speech_player(sp)

	var cache_path = AUDIO_CACHE_DIR + audio_path
	var local_path = BUNDLED_AUDIO_DIR + audio_path

	if FileAccess.file_exists(cache_path):
		var stream = _load_cached_audio(cache_path)
		if stream:
			sp.stream = stream
			sp.play()
			print("[NPC %s] Remote audio from cache: %s" % [npc_id, audio_path])
			return
	elif ResourceLoader.exists(local_path):
		var stream = load(local_path)
		if stream:
			sp.stream = stream
			sp.play()
			print("[NPC %s] Remote audio from local: %s" % [npc_id, local_path])
			return

	_request_audio(audio_path)
	print("[NPC %s] Remote audio not cached, requested from server" % npc_id)


## For a client joining mid-clip: plays from `offset` and talks for the rest.
func play_audio_from_server(audio_path: String, offset: float, duration: float):
	if audio_path == "":
		return
	var sp := _speech_player()
	if sp == null:
		return
	_reset_speech_player(sp)

	var cache_path = AUDIO_CACHE_DIR + audio_path
	var local_path = BUNDLED_AUDIO_DIR + audio_path
	var stream = null

	if FileAccess.file_exists(cache_path):
		stream = _load_cached_audio(cache_path)
	elif ResourceLoader.exists(local_path):
		stream = load(local_path)

	if stream:
		sp.stream = stream
		sp.play(offset)
		_remote_talking = true
		_remote_talk_timer = duration - offset
		_remote_talk_elapsed = offset
		print("[NPC %s] Mid-join audio at offset %.1fs: %s" % [npc_id, offset, audio_path])
	else:
		_request_audio(audio_path)


## Called by NpcManager; hands the clip to a waiting PlayAudioAction or a running remote talk.
func _on_audio_cached(path: String):
	print("[NPC %s] Audio cached: %s" % [npc_id, path])
	var cache_path = AUDIO_CACHE_DIR + path

	var pending = get_meta("_pending_audio_action", null)
	if pending and pending.has_method("late_play"):
		pending.late_play(self, cache_path)
		return

	if _remote_talking:
		_late_play_remote(path, cache_path)


func _late_play_remote(path: String, cache_path: String) -> void:
	var sp := _speech_player()
	if sp == null:
		return
	var stream = _load_cached_audio(cache_path)
	if stream:
		_reset_speech_player(sp)
		sp.stream = stream
		sp.play()
		print("[NPC %s] Late-loaded remote audio: %s" % [npc_id, path])


## Returns seconds (3.0 when unplayable); assumes the PCM starts at byte 44.
func play_inline_audio(audio_b64: String) -> float:
	var sp := _speech_player()
	if sp == null:
		start_talk_animation(3.0)
		return 3.0

	var raw = Marshalls.base64_to_raw(audio_b64)
	if raw.is_empty():
		start_talk_animation(3.0)
		return 3.0

	var stream = AudioStreamWAV.new()
	if raw.size() < 44:
		start_talk_animation(3.0)
		return 3.0

	var channels = raw.decode_u16(22)
	var sample_rate = raw.decode_u32(24)
	var bits = raw.decode_u16(34)

	stream.format = AudioStreamWAV.FORMAT_16_BITS if bits == 16 else AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = sample_rate
	stream.stereo = channels == 2
	stream.data = raw.slice(44)

	_reset_speech_player(sp)
	sp.stream = stream
	sp.play()

	var duration = float(stream.data.size()) / float(sample_rate * channels * (bits / 8))
	start_talk_animation(duration)
	print("[NPC %s] Playing TTS audio (%.1fs)" % [npc_id, duration])
	return duration


func _speech_player() -> AudioStreamPlayer3D:
	return get_node_or_null("SoundPlayer") as AudioStreamPlayer3D


## Footsteps share the player and leave random pitch and volume, which would make speech slow and thick.
func _reset_speech_player(sp: AudioStreamPlayer3D) -> void:
	sp.pitch_scale = 1.0
	sp.volume_db = 0.0


func _request_audio(audio_path: String) -> void:
	if _npc_manager_ref and _npc_manager_ref.has_method("request_npc_audio"):
		_npc_manager_ref.request_npc_audio(audio_path)


## load() cannot read user:// files; null for types other than mp3 or ogg.
func _load_cached_audio(path: String):
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var data = file.get_buffer(file.get_length())
	file.close()
	if path.ends_with(".mp3"):
		var stream = AudioStreamMP3.new()
		stream.data = data
		return stream
	elif path.ends_with(".ogg"):
		return AudioStreamOggVorbis.load_from_buffer(data)
	return null


## Does not broadcast.
func _show_label(message: String):
	if _npc_label == null:
		_npc_label_layer = CanvasLayer.new()
		_npc_label_layer.layer = 100
		add_child(_npc_label_layer)

		_npc_label = Label.new()
		_npc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_npc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_npc_label.custom_minimum_size = Vector2(400, 0)
		_npc_label.size = Vector2(400, 0)
		_npc_label.add_theme_font_size_override("font_size", 16)
		_npc_label.add_theme_color_override("font_color", Color.WHITE)
		_npc_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_npc_label.add_theme_constant_override("outline_size", 6)
		_npc_label_layer.add_child(_npc_label)

	_npc_label.text = message
	_npc_label.visible = true
	_label_active = true


func _random_dir() -> Vector3:
	var angle = randf() * TAU
	return Vector3(cos(angle), 0.0, sin(angle))


func set_path_network(network) -> void:
	_path_network = network


func set_npc_manager(manager) -> void:
	_npc_manager_ref = manager


## Becoming authority makes the current position the spawn point and re-checks the schedule.
func set_authority(is_auth: bool):
	_is_authority = is_auth
	if is_auth:
		_spawn_position = position
		_active_schedule_idx = -1
		_schedule_check_timer = 0.0
		_route.clear()
		_route_idx = 0
		if schedule.is_empty():
			_enter_wandering()


func apply_remote_transform(pos: Vector3, model_rot_y: float):
	_prev_remote_pos = _remote_target_pos
	_remote_target_pos = pos
	_remote_model_rot_y = model_rot_y
	# Transforms arrive every NpcManager.SEND_INTERVAL (0.1 s).
	_remote_speed = _prev_remote_pos.distance_to(pos) / 0.1


func get_model_rotation_y() -> float:
	if character_model:
		return character_model.rotation.y
	return 0.0
