extends "res://src/life/ambient_pedestrian.gd"

## A restaurant's waiter: walks where his ambient_restaurant sends him; the restaurant owns the service state.

const TASK_STALL_SECS := 60.0

## From the residents JSON: "voice", "home", "home_marker".
var resident_def: Dictionary = {}
var restaurant = null  # ambient_restaurant.gd
var station := Vector3.INF  # workspace-local idle spot
var _task_pos := Vector3.INF
var _task_tag := ""
var _task_age := 0.0
var _home := Vector3.INF
var _home_resolved := false


func voice_id() -> String:
	var v := str(resident_def.get("voice", ""))
	return v if v != "" else super()


## "home": [x, y, z], or "home_marker": a Node3D name. Vector3.INF when none.
func _home_pos() -> Vector3:
	if _home_resolved:
		return _home
	_home_resolved = true
	var h = resident_def.get("home", null)
	if typeof(h) == TYPE_ARRAY and h.size() >= 3:
		_home = Vector3(float(h[0]), float(h[1]), float(h[2]))
	elif resident_def.has("home_marker"):
		var root := get_tree().current_scene
		if root != null:
			var node := root.find_child(str(resident_def.home_marker), true, false)
			if node is Node3D and manager != null and manager.world() != null:
				_home = manager.world().to_local((node as Node3D).global_position)
	return _home


func _ready():
	super()
	walk_speed = 5.4
	idle_min = 0.5
	idle_max = 1.5
	personal_space = false  # guests flow around him


## restaurant.waiter_task_done(tag) fires on arrival, or after he is stepped there.
func waiter_goto(pos: Vector3, tag: String):
	_task_pos = pos
	_task_tag = tag
	_task_age = 0.0
	enter_idle()
	idle_timer = 0.1


func has_task() -> bool:
	return _task_pos != Vector3.INF


## Inside the restaurant's floor a blocked route steps him to the task.
func _request_route() -> PackedVector3Array:
	precise_route = false
	var goal := _task_pos
	if goal == Vector3.INF:
		if restaurant != null and is_instance_valid(restaurant) and not restaurant.is_open():
			var home := _home_pos()
			if home == Vector3.INF:
				return manager.request_ped_route(self)
			if position.distance_to(home) < 12.0:
				idle_timer = 8.0
				return PackedVector3Array()
			goal = home
		else:
			if station == Vector3.INF or position.distance_to(station) < 6.0:
				idle_timer = 2.0
				return PackedVector3Array()
			goal = station
	if restaurant != null and is_instance_valid(restaurant):
		var dining: Dictionary = restaurant.route_between(position, goal)
		if not dining.is_empty():
			if dining.route.is_empty() and _task_pos != Vector3.INF:
				# Asking again would return the same empty route forever.
				print("[Waiter %s] no way to %s for %s; stepping there"
					% [ped_id, _task_pos.snapped(Vector3.ONE * 0.1), _task_tag])
				_step_to_task()
				_finish_task()
				return PackedVector3Array()
			precise_route = true
			return dining.route
	return _street_route(goal)


func _street_route(goal: Vector3) -> PackedVector3Array:
	var route: PackedVector3Array = manager.nav.find_route(position, goal)
	if route.is_empty():
		# Terrace spots can sit just off the walk zones.
		for i in 4:
			var near: Vector3 = manager.nav.random_point_near(goal, 25.0, manager.rng())
			route = manager.nav.find_route(position, near)
			if not route.is_empty():
				break
	if route.is_empty():
		route.append(goal)  # stuck detection backstops
	return route


func _step_to_task() -> void:
	position = _task_pos + Vector3.UP * 2.0
	velocity = Vector3.ZERO


func _on_route_arrived():
	if _task_pos == Vector3.INF:
		return
	var flat := _task_pos - position
	flat.y = 0.0
	if flat.length() > (0.8 if precise_route else 12.0):
		idle_timer = 0.3
		return
	_finish_task()


## Indoors an abandoned route fails the task; outdoors he is stepped to it.
func _on_route_abandoned():
	if precise_route:
		var tag := _task_tag
		_task_pos = Vector3.INF
		_task_tag = ""
		if tag != "" and restaurant != null:
			restaurant.waiter_task_failed(tag)
		return
	if _task_pos == Vector3.INF:
		return
	_step_to_task()
	_finish_task()


func _physics_process(delta):
	super(delta)
	if not _is_authority or _task_pos == Vector3.INF:
		return
	_task_age += delta
	if _task_age < TASK_STALL_SECS:
		return
	_log_stall()
	steer_to = Vector3.INF
	_step_to_task()
	enter_idle()
	_finish_task()


func _log_stall() -> void:
	var r = restaurant if restaurant != null and is_instance_valid(restaurant) else null
	print(("[Waiter %s] stalled %.0fs on %s: at %s, task %s (%.1f away), state %d, idle %.1f, "
		+ "route %d/%d precise %s, steer_to %s, sitting %s, engaged %s, errand %s, lift_wait %s, "
		+ "hold %s, queue %s") % [
		ped_id, _task_age, _task_tag, position.snapped(Vector3.ONE * 0.1),
		_task_pos.snapped(Vector3.ONE * 0.1),
		Vector2(_task_pos.x - position.x, _task_pos.z - position.z).length(), _state, idle_timer,
		_route_idx, _route.size(), precise_route, steer_to, sitting, _engaged,
		errand_owner != null, _lift_wait,
		r._waiter_hold if r != null else -1.0, r._task_queue if r != null else []])


func _finish_task():
	var tag := _task_tag
	_task_pos = Vector3.INF
	_task_tag = ""
	_task_age = 0.0
	if restaurant != null and is_instance_valid(restaurant):
		restaurant.waiter_task_done(tag)
