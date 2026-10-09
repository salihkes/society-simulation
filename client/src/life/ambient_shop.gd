extends Node3D

## A shop residents buy from: aisle, till, out with a snack. Authority-side only.

@export var shop_key := ""  # empty = the parent's name
@export var display_name := ""  # empty = the parent's display_name meta
@export var open_hour := 7.0
@export var close_hour := 23.0
@export var floor_path: NodePath = ^"../Floor"
@export var capacity := 6
@export var browse_secs := Vector2(15.0, 45.0)
@export var pay_secs := 6.0
@export var hunger_relief := 0.45
@export var items: PackedStringArray = ["onigiri", "sandwich", "bread", "yogurt", "melon pan"]

var _manager = null
var _floor = null
var _registering := false
var _registered := false
var _tick := 0.0
var _browse: Array = []
var _till: Node3D = null
## stage: "to_aisle" "browsing" "to_till" "paying" "leaving"
var _visits := {}


func _ready():
	set_process(true)
	for c in get_children():
		if c is Node3D and str(c.name).begins_with("Browse"):
			_browse.append(c)
	_till = get_node_or_null("Till") as Node3D


func key() -> String:
	if shop_key != "":
		return shop_key
	return str(get_parent().name) if get_parent() != null else str(name)


func label() -> String:
	if display_name != "":
		return display_name
	var p := get_parent()
	if p != null and p.has_meta("display_name"):
		return str(p.get_meta("display_name"))
	return key()


## The span may wrap past midnight.
func is_open() -> bool:
	if _manager == null:
		return false
	var h: float = _manager.current_hour()
	if open_hour <= close_hour:
		return h >= open_hour and h < close_hour
	return h >= open_hour or h < close_hour


func place_pos() -> Vector3:
	if _floor != null and _floor.ready_ok:
		return _floor.entrance()
	return _local(self)


func approach_pos() -> Vector3:
	return place_pos()


func _local(n: Node3D) -> Vector3:
	return _manager.world().to_local(n.global_position)


func _process(delta):
	if not _registered:
		_register()
		return
	if not _manager.is_authority():
		return
	_tick += delta
	if _tick < 0.25:
		return
	_run_visits(_tick)
	_tick = 0.0


func _register():
	if _registering:
		return
	var root := get_tree().current_scene
	if root == null:
		return
	var mgr = root.find_child("AmbientManager", true, false)
	if mgr == null or mgr.world() == null:
		return
	_registering = true
	_manager = mgr
	_floor = get_node_or_null(floor_path)
	if _floor != null:
		await _prepare_floor(mgr)
	else:
		print("[Shop %s] %s: no Floor — customers are stepped between spots" % [key(), label()])
	_manager.places.register_shop(self)
	_registered = true


## World geometry keeps settling after boot, so an incomplete floor is resampled, up to ten times.
func _prepare_floor(mgr) -> void:
	await _floor.prepare(mgr.world(), mgr.nav)
	var ok := _floor_reaches_spots()
	for attempt in 10:
		if ok:
			break
		await get_tree().create_timer(3.0).timeout
		await _floor.prepare(mgr.world(), mgr.nav)
		ok = _floor_reaches_spots()
	print("[Shop %s] %s: floor %s, %d aisle spot(s), till %s" % [key(), label(),
		"reaches every spot" if ok else "CANNOT reach every spot (customers will be stepped)",
		_browse.size(), "yes" if _till != null else "no"])


func _floor_reaches_spots() -> bool:
	if _floor == null or not _floor.ready_ok:
		return false
	var door: Vector3 = _floor.entrance()
	var spots: Array = _browse.duplicate()
	if _till != null:
		spots.append(_till)
	for s in spots:
		if _floor.nav.route(door, _local(s)).is_empty():
			return false
	return true


## {} means "not mine".
func route_between(from: Vector3, to: Vector3) -> Dictionary:
	return _floor.route_between(from, to) if _floor != null else {}


## False when closed or full.
func request_visit(body) -> bool:
	if not is_open() or body == null or not is_instance_valid(body):
		return false
	var pid := str(body.ped_id)
	if _visits.has(pid):
		return true
	if _visits.size() >= capacity or (_browse.is_empty() and _till == null):
		return false
	var item := "something"
	if not items.is_empty():
		item = items[_manager.rng().randi_range(0, items.size() - 1)]
	_visits[pid] = {"body": body, "stage": "to_aisle", "timer": 0.0, "item": item}
	var spot: Node3D = _till
	if not _browse.is_empty():
		spot = _browse[_manager.rng().randi_range(0, _browse.size() - 1)]
	_send(pid, spot, "shop:aisle")
	return true


func _send(pid: String, spot: Node3D, tag: String):
	var v: Dictionary = _visits[pid]
	var body = v.body
	var dest := _local(spot)
	if tag == "shop:aisle":
		dest += Vector3(_manager.rng().randf_range(-0.6, 0.6), 0.0, _manager.rng().randf_range(-0.6, 0.6))
	v["dest"] = dest
	body.assign_errand(self, dest, tag)


func errand_arrival_radius(_tag: String) -> float:
	return 1.5


## On a failed walk the visitor is stepped to the spot and the visit goes on.
func errand_finished(ped, tag: String, ok: bool):
	var pid := str(ped.ped_id)
	if not _visits.has(pid):
		return
	var v: Dictionary = _visits[pid]
	if not ok:
		ped.position = Vector3(v.get("dest", place_pos())) + Vector3.UP * 2.0
		ped.velocity = Vector3.ZERO
		_manager.observe({"who": pid, "did": "travel_recovered", "place": key(),
			"reason": "shop walk failed (%s); stepped" % tag})
	match tag:
		"shop:aisle":
			v.stage = "browsing"
			v.timer = _manager.rng().randf_range(browse_secs.x, browse_secs.y)
		"shop:till":
			v.stage = "paying"
			v.timer = pay_secs
		"shop:out":
			_finish(pid, true)


func _run_visits(step: float):
	for pid in _visits.keys():
		var v: Dictionary = _visits[pid]
		var body = v.body
		if body == null or not is_instance_valid(body):
			_visits.erase(pid)
			continue
		if not (v.stage in ["browsing", "paying"]):
			continue
		v.timer = float(v.timer) - step
		if float(v.timer) <= 0.0:
			_next_stage(pid, v, body)


func _next_stage(pid: String, v: Dictionary, body) -> void:
	if v.stage == "browsing":
		v.stage = "to_till"
		if _till != null:
			_send(pid, _till, "shop:till")
		else:
			v.stage = "paying"
			v.timer = pay_secs
		return
	v.stage = "leaving"
	if _floor != null and _floor.ready_ok:
		v["dest"] = _floor.entrance()
		body.assign_errand(self, _floor.entrance(), "shop:out")
	else:
		_finish(pid, true)


func _finish(pid: String, ok: bool):
	var v: Dictionary = _visits.get(pid, {})
	_visits.erase(pid)
	var body = v.get("body")
	if body != null and is_instance_valid(body) and body.has_method("shop_over"):
		body.shop_over(ok, str(v.get("item", "")), {"hunger": hunger_relief} if ok else {})


func place_entry() -> Dictionary:
	var pos := place_pos()
	return {"id": key(), "kind": "shop", "name": label() + " (shop)",
		"pos": [snappedf(pos.x, 0.01), snappedf(pos.y, 0.01), snappedf(pos.z, 0.01)],
		"open": [open_hour, close_hour], "verbs": ["buy"], "sells": Array(items)}
