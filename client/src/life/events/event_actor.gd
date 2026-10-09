extends "res://src/life/ambient_pedestrian.gd"

## A cast member of a scripted event: walks to marks the director sets and reports arrival.

var resident_def: Dictionary = {}
var director = null
var actor_id := ""

var _goal := Vector3.INF
var _retries := 0


func _ready():
	super()
	idle_min = 2.0
	idle_max = 4.0
	personal_space = false


func goto(pos: Vector3, speed := -1.0):
	if speed > 0.0:
		walk_speed = speed
	_goal = pos
	_retries = 0
	enter_idle()
	idle_timer = 0.05


## Falls back to a reachable point near the mark, then a straight line.
func _request_route() -> PackedVector3Array:
	if _goal == Vector3.INF:
		idle_timer = 1.0
		return PackedVector3Array()
	var route: PackedVector3Array = manager.nav.find_route(position, _goal)
	if route.is_empty():
		route = _route_beside_goal()
	if route.is_empty():
		route.append(_goal)  # unreachable; the retry teleport keeps the schedule
	return route


func _route_beside_goal() -> PackedVector3Array:
	var route := PackedVector3Array()
	for i in 5:
		var near: Vector3 = manager.nav.random_point_near(_goal, 20.0, manager.rng())
		route = manager.nav.find_route(position, near)
		if not route.is_empty():
			break
	return route


## Arrived within 24 m; otherwise re-route, teleporting onto the mark after four tries.
func _on_route_arrived():
	if _goal == Vector3.INF:
		return
	var flat := _goal - position
	flat.y = 0.0
	if flat.length() <= 24.0:
		_finish_goal()
		return
	_retries += 1
	if _retries >= 4:
		position = _goal + Vector3.UP * 2.0
		velocity = Vector3.ZERO
		_finish_goal()


func _on_route_abandoned():
	_retries += 1
	if _goal != Vector3.INF and _retries < 3:
		return
	if _goal != Vector3.INF:
		position = _goal + Vector3.UP * 2.0
		velocity = Vector3.ZERO
	_finish_goal()


func _finish_goal():
	if _goal == Vector3.INF:
		return
	var reached := _goal
	_goal = Vector3.INF
	if director != null and is_instance_valid(director):
		director.actor_arrived(actor_id, reached)
