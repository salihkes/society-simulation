## Road traffic of a workspace: cars and trams on their lanes, crossings, and their amb_state sections.
class_name AmbientTraffic
extends RefCounted

const CAR_SCRIPT := "res://src/life/ambient_car.gd"
const TRAM_SCRIPT := "res://src/life/ambient_tram.gd"
const LaneGraphScript := preload("res://src/life/lane_graph.gd")

var lane_graph := LaneGraphScript.new()
var tram_graph := LaneGraphScript.new()  # sampling only, no links
var cars: Dictionary = {}
var trams: Dictionary = {}
var car_sim: Dictionary = {}  # id -> {lane, dist, speed, cruise, ...}
# Traffic keeps its gap behind borrowable vehicles; driven ones run in car_sim.
var ext_vehicles: Dictionary = {}  # net_id -> {"node", "points": [Node3D]}

var _m: AmbientManager = null
var _ext_cars: Dictionary = {}  # net_id -> node currently lane-driven
var _crossing_claim: Dictionary = {}  # crossing id -> {"car": id, "t": seconds held}
var _tram_sim: Dictionary = {}  # id -> {line, dist, dir, speed, pause}
var _ground_off: Dictionary = {}  # car id -> lane height mismatch reported
var _car_ground_y: Dictionary = {}  # car id -> last road height found


func _init(manager: AmbientManager):
	_m = manager


func build(lanes: Array, signals: Array):
	lane_graph.build(lanes, signals)
	tram_graph.build(tram_lines())


func tram_lines() -> Array:
	if _m.world() == null:
		return []
	var node = _m.world().get_node_or_null("AmbientLayout")
	if node != null and node.has_method("trams"):
		return node.trams()
	return []


func is_empty() -> bool:
	return cars.is_empty() and trams.is_empty()


func populate():
	var want_cars: int = _m.car_count if not lane_graph.is_empty() else 0
	for i in want_cars:
		var id := "c%d" % i
		if not cars.has(id) or not is_instance_valid(cars[id]):
			_spawn_car(id, _pick_car_kind())
			_seat_car_spread(id, i, maxi(want_cars, 1))
	_trim("c", cars, want_cars)

	var want_trams: int = tram_graph.lane_count() if _m.trams_enabled else 0
	for i in want_trams:
		var id := "t%d" % i
		if not trams.has(id) or not is_instance_valid(trams[id]):
			_spawn_tram(id)
	_trim("t", trams, want_trams)
	seat_trams()


func reseat():
	for id in cars.keys():
		_seat_car_on_network(id)
	seat_trams()


## Promoted mid-game: cars keep their spot; dead bodies are dropped.
func adopt():
	for id in cars.keys():
		if not is_instance_valid(cars[id]):
			cars.erase(id)
			continue
		_seat_car_on_network(id)
	for id in trams.keys():
		if not is_instance_valid(trams[id]):
			trams.erase(id)


func _trim(prefix: String, pool: Dictionary, want: int):
	for id in _m.trim_pool(prefix, pool, want):
		car_sim.erase(id)
		_tram_sim.erase(id)


func _car_weight(i: int) -> float:
	return maxf(_m.car_weights[i] if i < _m.car_weights.size() else 1.0, 0.0)


func _pick_car_kind() -> int:
	var paths: Array[String] = _m.car_model_paths
	if paths.is_empty():
		return _m.rng().randi_range(0, 6)  # placeholder palette index
	if _m.car_weights.is_empty():
		return _m.rng().randi_range(0, paths.size() - 1)
	var total := 0.0
	for i in paths.size():
		total += _car_weight(i)
	var pick: float = _m.rng().randf() * maxf(total, 0.0001)
	for i in paths.size():
		pick -= _car_weight(i)
		if pick <= 0.0:
			return i
	return paths.size() - 1


## Outside the normal pool, driven by the event director; its model path replicates as "mp".
func spawn_event_car(id: String, model_path: String, yaw_deg := 0.0, length := 18.0):
	if cars.has(id) and is_instance_valid(cars.get(id)):
		return cars[id]
	var container: Node3D = _m.container()
	if container == null or not container.is_inside_tree():
		return null
	var car = Node3D.new()
	car.set_script(load(CAR_SCRIPT))
	car.name = "Amb_" + id
	car.car_id = id
	car.kind = 0
	car.model_path = model_path
	car.model_yaw_deg = yaw_deg
	car.target_len = length
	container.add_child(car)
	car.set_authority(_m.is_authority())
	cars[id] = car
	return car


func remove_event_car(id: String):
	var car = cars.get(id)
	if car != null and is_instance_valid(car):
		car.queue_free()
	cars.erase(id)
	car_sim.erase(id)


## Traffic scans its `points` like a car's; pedestrians steer clear of them.
func register_vehicle(node: Node3D, points: Array) -> void:
	if node == null:
		return
	var pts: Array = []
	for p in points:
		if p is Node3D:
			pts.append(p)
	if pts.is_empty():
		pts.append(node)
	ext_vehicles[str(node.net_id)] = {"node": node, "points": pts}


## NPC mode: drives straight to the nearest lane, then like a pool car. False when there is no road near.
func drive_external(node: Node3D) -> bool:
	if node == null or lane_graph.is_empty() or _m.world() == null:
		return false
	var id := str(node.net_id)
	if car_sim.has(id):
		return true
	var local_pos: Vector3 = _m.world().to_local(node.global_position)
	var hit: Dictionary = lane_graph.nearest_on_network(local_pos)
	if int(hit.lane) < 0 or float(hit.err) > 400.0 * 400.0:
		return false
	_ext_cars[id] = node
	var sim: Dictionary = new_sim(int(hit.lane), float(hit.dist))
	var entry: Transform3D = lane_graph.sample(int(hit.lane), float(hit.dist))
	if local_pos.distance_to(entry.origin) > 2.0:
		sim["merge"] = {"from": local_pos, "to": entry.origin}
	sim.speed = 0.0
	car_sim[id] = sim
	return true


func release_external(node: Node3D) -> void:
	if node == null:
		return
	var id := str(node.net_id)
	if _ext_cars.has(id):
		_ext_cars.erase(id)
		car_sim.erase(id)
		_car_ground_y.erase(id)


## Every valid scan point of every borrowable vehicle.
func external_points() -> Array:
	var out := []
	for id in ext_vehicles:
		out.append_array(_valid_points(ext_vehicles[id]))
	return out


func _car_node(id: String):
	if cars.has(id):
		return cars[id]
	return _ext_cars.get(id)


## A definition's model_path, or the raw path itself.
func _car_stream_path(kind: int) -> String:
	var wanted: String = _m.car_model_paths[kind % _m.car_model_paths.size()]
	if wanted.ends_with(".tres") or wanted.ends_with(".res"):
		var definition = load(wanted) if ResourceLoader.exists(wanted) else null
		wanted = str(definition.model_path) if definition != null else ""
	return wanted


func _spawn_car(id: String, kind: int):
	var container: Node3D = _m.container()
	if container == null or not container.is_inside_tree():
		return
	var paths: Array[String] = _m.car_model_paths
	if not paths.is_empty():
		var wanted := _car_stream_path(kind)
		if wanted != "" and not ResourceLoader.exists(wanted) \
				and _m.defer_until_mounted(wanted, "car:" + id, cars, id, _spawn_car.bind(id, kind)):
			return
	var car = Node3D.new()
	car.set_script(load(CAR_SCRIPT))
	car.name = "Amb_" + id
	car.car_id = id
	car.kind = kind
	if not paths.is_empty():
		car.model_path = paths[kind % paths.size()]
		if kind < _m.car_model_yaw_deg.size():
			car.model_yaw_deg = _m.car_model_yaw_deg[kind]
	container.add_child(car)
	car.set_authority(_m.is_authority())
	cars[id] = car


func _spawn_tram(id: String):
	var container: Node3D = _m.container()
	if container == null or not container.is_inside_tree():
		return
	var model: String = _m.tram_model_path
	if model != "" and not ResourceLoader.exists(model) \
			and _m.defer_until_mounted(model, "tram:" + id, trams, id, _spawn_tram.bind(id)):
		return
	var tram = Node3D.new()
	tram.set_script(load(TRAM_SCRIPT))
	tram.name = "Amb_" + id
	tram.tram_id = id
	tram.model_path = model
	tram.model_yaw_deg = _m.tram_model_yaw_deg
	tram.car_len = _m.tram_length
	container.add_child(tram)
	tram.set_authority(_m.is_authority())
	trams[id] = tram


## Car length + coupling.
func _tram_sep() -> float:
	return _m.tram_length + 3.0


## Round-robin over lanes, golden-ratio spread along each, so cars start scattered.
func _seat_car_spread(id: String, index: int, _total: int):
	if lane_graph.is_empty():
		return
	var lane := index % lane_graph.lane_count()
	var frac: float = fmod(0.618034 * float(index / lane_graph.lane_count() + 1), 1.0)
	car_sim[id] = new_sim(lane, lane_graph.lane_length(lane) * frac)
	_apply_car_sim(id, 0.0)


func _seat_car_on_network(id: String):
	if lane_graph.is_empty() or not cars.has(id):
		return
	var car = cars[id]
	if not is_instance_valid(car):
		return
	var hit: Dictionary = lane_graph.nearest_on_network(car.position)
	if hit.lane < 0:
		return
	car_sim[id] = new_sim(hit.lane, hit.dist)


## Clamped so both cars stay on the track.
func seat_trams():
	for id in trams.keys():
		var idx := int(str(id).substr(1))
		if idx >= tram_graph.lane_count():
			continue
		var lo: float = minf(_tram_sep() * 0.5, tram_graph.lane_length(idx) * 0.5)
		if not _tram_sim.has(id):
			_tram_sim[id] = {"line": idx, "dist": lo, "dir": 1, "speed": 0.0, "pause": 0.0}
		else:
			var sim: Dictionary = _tram_sim[id]
			sim.line = idx
			sim.dist = clampf(float(sim.dist), lo, tram_graph.lane_length(idx) - lo)
		_apply_tram_sim(id)


func new_sim(lane: int, dist: float) -> Dictionary:
	return {
		"lane": lane,
		"dist": dist,
		"speed": 0.0,
		"cruise": _m.rng().randf_range(_m.car_speed_min, _m.car_speed_max),
	}


func simulate(delta):
	_simulate_cars(delta)
	_simulate_trams(delta)


func _simulate_cars(delta):
	if lane_graph.is_empty():
		return
	var people: Array = _m.people_positions_global()
	_resolve_crossings(delta)
	for id in car_sim:
		var sim: Dictionary = car_sim[id]
		var car = _car_node(id)
		if car == null or not is_instance_valid(car):
			continue
		if sim.has("merge"):
			_merge_toward_lane(id, car, sim, people, delta)
			continue
		_drive_car(id, car, sim, people, delta)


func _drive_car(id: String, car, sim: Dictionary, people: Array, delta: float):
	var on_bridge: bool = sim.has("bridge")
	var gap := _car_gap(id, car, sim, people, on_bridge)
	var target := _car_target_speed(sim, gap, on_bridge)
	_tow_if_stuck(id, sim, on_bridge, gap, delta)
	target = _turn_slowdown(sim, target)
	if target > sim.speed:
		sim.speed = move_toward(sim.speed, target, _m.car_accel * delta)
	else:
		sim.speed = move_toward(sim.speed, target, _m.car_brake * delta)

	_driver_temper(car, sim, people, delta)

	var was_dist: float = float(sim.dist)
	sim.dist += sim.speed * delta
	_take_crossings(id, sim, was_dist)
	if on_bridge and sim.has("bridge"):  # a tow may have taken it off the bridge
		_leave_bridge(sim)
	elif sim.dist >= lane_graph.lane_length(sim.lane):
		_leave_lane_end(sim)
	_apply_car_sim(id, sim.speed)


## An obstacle ahead, a red light's stop line, or a crossing not granted.
func _car_gap(id: String, car, sim: Dictionary, people: Array, on_bridge: bool) -> float:
	var gap := frontal_gap(car.global_transform, [car], people)
	# A car already past the stop line, or on a connector, clears the junction instead of stopping in it.
	if not on_bridge:
		var stop: Dictionary = lane_graph.next_signal_stop(sim.lane, sim.dist)
		if not stop.is_empty() and _m.green_group(int(stop.sig)) != int(stop.group):
			var remaining: float = float(stop.dist) - sim.dist
			if remaining > 2.0:
				gap = minf(gap, maxf(remaining - 2.0, 0.0))
	var cross_gap: float = _crossing_gap(id, sim)
	if cross_gap < gap:
		gap = cross_gap
	return gap


func _car_target_speed(sim: Dictionary, gap: float, on_bridge: bool) -> float:
	var target: float = sim.cruise
	var look: float = _m.car_look_ahead
	if gap < look:
		target = sim.cruise * clampf((gap - _m.car_stop_gap) / maxf(look - _m.car_stop_gap, 1.0), 0.0, 1.0)
	if on_bridge:
		return minf(target, float(sim.bridge.get("max_speed", INF)))
	target = minf(target, _junction_approach_limit(sim))
	# A quarter turn or more is taken at car_corner_min of cruise.
	var bend: float = lane_graph.turn_ahead(sim.lane, sim.dist, _m.car_corner_lookahead)
	if bend > 0.06:
		var sharp: float = clampf(bend / (PI * 0.5), 0.0, 1.0)
		target = minf(target, sim.cruise * lerpf(1.0, _m.car_corner_min, sharp))
	return target


## INF when none is near.
func _junction_approach_limit(sim: Dictionary) -> float:
	var soon: Array = lane_graph.outgoing(int(sim.lane))
	var to_end: float = lane_graph.lane_length(int(sim.lane)) - float(sim.dist)
	if soon.is_empty() or to_end >= _m.car_corner_lookahead:
		return INF
	var slowest := INF
	for l in soon:
		var d0: Vector3 = _lane_dir(int(sim.lane), lane_graph.lane_length(int(sim.lane)))
		var d1: Vector3 = _lane_dir(int(l.lane), float(l.dist))
		var turn: float = absf(d0.angle_to(d1))
		if turn > 0.05:
			var ln: float = maxf(float(l.len), 1.0)
			slowest = minf(slowest, deg_to_rad(_m.car_junction_turn_rate) * ln / turn)
	return slowest


## Held 40 s by anything but a red light: moved to a random lane start, so a jam never lasts.
func _tow_if_stuck(id: String, sim: Dictionary, on_bridge: bool, gap: float, delta: float):
	if sim.speed >= 0.4 or _waiting_at_red(sim, on_bridge):
		sim.erase("stuck")
		return
	sim["stuck"] = float(sim.get("stuck", 0.0)) + delta
	if float(sim.stuck) > 40.0:
		print("[Traffic] %s stuck %.0f s on lane %d (gap %.1f) — towed" % [id, float(sim.stuck), int(sim.lane), gap])
		sim.lane = _m.rng().randi_range(0, lane_graph.lane_count() - 1)
		sim.dist = 0.0
		sim.speed = 0.0
		sim.erase("bridge")
		sim.erase("stuck")


func _turn_slowdown(sim: Dictionary, target: float) -> float:
	if not sim.has("turn_at"):
		return target
	var arc: float = _m.car_turn_arc
	var turn_in: float = float(sim.turn_at.dist) - float(sim.dist)
	if turn_in <= -arc or turn_in >= _m.car_corner_lookahead:
		return target
	target = minf(target, float(sim.cruise) * _m.car_turn_speed)
	var into: Vector3 = _lane_dir(int(sim.turn_at.lane), float(sim.turn_at.other_dist))
	var swing: float = absf(_lane_dir(int(sim.lane), float(sim.turn_at.dist)).angle_to(into))
	if swing > 0.05:
		target = minf(target, deg_to_rad(_m.car_junction_turn_rate) * arc / swing)
	return target


func _leave_bridge(sim: Dictionary):
	var b: Dictionary = sim.bridge
	if sim.dist < float(b.len):
		return
	var leftover: float = sim.dist - float(b.len)
	sim.lane = int(b.lane)
	sim.dist = float(b.entry_dist) + leftover
	sim.erase("bridge")


## Respawns on a random lane at a dead end.
func _leave_lane_end(sim: Dictionary):
	var links: Array = lane_graph.outgoing(sim.lane)
	if links.is_empty():
		sim.lane = _m.rng().randi_range(0, lane_graph.lane_count() - 1)
		sim.dist = 0.0
		sim.speed = 0.0
		return
	var overflow: float = sim.dist - lane_graph.lane_length(sim.lane)
	var link: Dictionary = links[_m.rng().randi_range(0, links.size() - 1)]
	# Always drive the connector, even a short one: stepping straight across would shift the car sideways.
	var join: float = float(link.dist)
	var into: int = int(link.lane)
	var leave: float = lane_graph.lane_length(int(sim.lane))
	sim["bridge"] = _connector(
		lane_graph.sample(int(sim.lane), leave).origin, _lane_dir(int(sim.lane), leave),
		lane_graph.sample(into, join).origin, _lane_dir(into, join),
		into, join)
	sim.dist = overflow


## Once per frame, so the outcome never depends on which car the loop reached first.
func _resolve_crossings(delta: float) -> void:
	_age_crossing_claims(delta)
	var approach := _crossing_approaches()
	for cid in approach:
		var best = _crossing_winner(approach[cid])
		if best != null:
			_crossing_claim[int(cid)] = {"car": best.car, "t": 0.0}
			_decide_turn(best.car, car_sim[best.car], best.c)


func _age_crossing_claims(delta: float):
	for cid in _crossing_claim.keys():
		var claim: Dictionary = _crossing_claim[cid]
		claim.t = float(claim.t) + delta
		var holder = car_sim.get(claim.car)
		if holder == null or float(claim.t) > _m.crossing_claim_timeout:
			_crossing_claim.erase(cid)
			continue
		if not _still_at(holder, int(cid)):
			_crossing_claim.erase(cid)


## crossing id -> [candidate]
func _crossing_approaches() -> Dictionary:
	var approach: Dictionary = {}
	for id in car_sim:
		var sim: Dictionary = car_sim[id]
		if sim.has("merge") or sim.has("bridge"):
			continue
		for c in lane_graph.crossings_near(int(sim.lane), float(sim.dist), _m.crossing_watch):
			var cid := int(c.id)
			if _crossing_claim.has(cid):
				continue
			var to_go: float = float(c.dist) - float(sim.dist)
			var xf: Transform3D = lane_graph.sample(int(sim.lane), float(sim.dist))
			approach.get_or_add(cid, []).append({
				"car": id, "to_go": to_go,
				"eta": to_go / maxf(float(sim.speed), 1.0),
				"dir": -xf.basis.z, "pos": xf.origin, "c": c,
			})
	return approach


## The soonest to arrive, but a car gives way to anyone arriving about as soon from its left.
func _crossing_winner(cands: Array):
	var best = null
	var best_eta := INF
	for a in cands:
		var eta: float = float(a.eta)
		for other in cands:
			if other == a:
				continue
			if float(other.eta) > eta + 1.2:
				continue
			if _on_left(a, other):
				eta += 1.0
				break
		if eta < best_eta:
			best_eta = eta
			best = a
	return best


## Left of a heading (x, z) is (z, -x).
func _on_left(a: Dictionary, other: Dictionary) -> bool:
	var fwd: Vector3 = a.dir
	var left := Vector3(fwd.z, 0.0, -fwd.x)
	var to_other: Vector3 = other.pos - a.pos
	to_other.y = 0.0
	return left.dot(to_other) > 0.0


func _still_at(sim: Dictionary, cid: int) -> bool:
	for c in lane_graph.crossings_near(int(sim.lane), float(sim.dist), _m.crossing_watch, _m.crossing_box):
		if int(c.id) == cid:
			return true
	return false


## INF to carry on.
func _crossing_gap(id: String, sim: Dictionary) -> float:
	if sim.has("merge") or sim.has("bridge"):
		return INF
	var box: float = _m.crossing_box
	for c in lane_graph.crossings_near(int(sim.lane), float(sim.dist), _m.crossing_watch):
		var cid := int(c.id)
		var claim = _crossing_claim.get(cid)
		if claim != null and str(claim.car) == id:
			continue  # ours: drive on through
		var to_go: float = float(c.dist) - float(sim.dist)
		if to_go < -box:
			continue
		# Stop short of the box, not in it.
		return maxf(to_go - box * 0.6, 0.0)
	return INF


## Decided early, so the car has room to slow down for the turn.
func _decide_turn(id: String, sim: Dictionary, c: Dictionary) -> void:
	if sim.has("turn_at") or sim.has("bridge") or sim.has("merge"):
		return
	var arc: float = _m.car_turn_arc
	if float(c.dist) - float(sim.dist) < arc * 0.75:
		return
	if float(c.dist) < arc:
		return
	if _m.rng().randf() > _m.car_turn_chance:
		return
	var other := int(c.lane)
	var at: float = float(c.other_dist)
	# Leave room on the new road to finish the turn.
	if at < arc or at > lane_graph.lane_length(other) - arc * 1.5:
		return
	sim["turn_at"] = {"dist": float(c.dist), "lane": other, "other_dist": at}


## A turn passed without triggering is forgotten.
func _take_crossings(id: String, sim: Dictionary, was_dist: float) -> void:
	if not sim.has("turn_at"):
		return
	var plan: Dictionary = sim.turn_at
	var at: float = float(plan.dist)
	var half: float = _m.car_turn_arc * 0.5
	var trigger: float = maxf(at - half, 0.0)
	if was_dist > trigger or float(sim.dist) < trigger:
		if float(sim.dist) > at:
			sim.erase("turn_at")
		return
	var leave_at: float = maxf(at - half, 0.0)
	var join_at: float = float(plan.other_dist) + half
	var overflow: float = maxf(float(sim.dist) - leave_at, 0.0)
	sim["bridge"] = _connector(
		lane_graph.sample(int(sim.lane), leave_at).origin, _lane_dir(int(sim.lane), leave_at),
		lane_graph.sample(int(plan.lane), join_at).origin, _lane_dir(int(plan.lane), join_at),
		int(plan.lane), join_at)
	sim.dist = overflow
	sim.erase("turn_at")
	sim.erase("stuck")


## A car moved further than a frame's travel (a tow, a respawn) takes the new heading at once.
func _rate_limit(car, want_yaw: float, to: Vector3, speed: float) -> float:
	var delta: float = _m.get_process_delta_time()
	if car.position.distance_to(to) > absf(speed) * delta + 2.0:
		return want_yaw
	var step: float = deg_to_rad(_m.car_max_turn_rate) * delta
	var diff: float = wrapf(want_yaw - car.rotation.y, -PI, PI)
	return car.rotation.y + clampf(diff, -step, step)


## Never below 0.
func _person_gap_ahead(car, people: Array) -> float:
	var inv: Transform3D = car.global_transform.affine_inverse()
	var half_width: float = _m.car_lane_half_width
	var person_gap := INF
	for p in people:
		var local: Vector3 = inv * p
		if absf(local.x) <= half_width and local.z < 0.0 and absf(local.y) < 12.0:
			person_gap = minf(person_gap, -local.z - 4.0)
	for id in ext_vehicles:
		var ent: Dictionary = ext_vehicles[id]
		if ent.get("node") == car:
			continue
		for pt in ent.get("points", []):
			if pt == null or not is_instance_valid(pt):
				continue
			var local: Vector3 = inv * pt.global_position
			if absf(local.x) <= half_width + 2.0 and local.z < 0.0 and absf(local.y) < 12.0:
				person_gap = minf(person_gap, -local.z - 6.0)
	return maxf(person_gap, 0.0)


## Stepping in front earns a double honk and a yell; pinned at walking pace, one short honk. Replicated "h"/"yc".
func _driver_temper(car, sim: Dictionary, people: Array, delta: float):
	var person_gap := _person_gap_ahead(car, people)
	sim["honk_cd"] = maxf(float(sim.get("honk_cd", 0.0)) - delta, 0.0)
	sim["yell_cd"] = maxf(float(sim.get("yell_cd", 0.0)) - delta, 0.0)
	if person_gap < 12.0 and float(sim.speed) > 6.0 and float(sim.yell_cd) <= 0.0:
		sim.yell_cd = 18.0
		sim.honk_cd = maxf(float(sim.honk_cd), 6.0)
		sim["yl"] = _m.rng().randi_range(0, 2)
		sim["yc"] = int(sim.get("yc", 0)) + 1
		sim["hd"] = 1
		sim["hn"] = int(sim.get("hn", 0)) + 1
		sim["blocked_t"] = 0.0
		car.honk(true)
		car.yell(int(sim.yl))
	elif float(sim.speed) < 0.8 and person_gap < _m.car_stop_gap + 3.0:
		sim["blocked_t"] = float(sim.get("blocked_t", 0.0)) + delta
		if float(sim.blocked_t) > 2.5 and float(sim.honk_cd) <= 0.0:
			sim.honk_cd = 25.0
			sim["hd"] = 0
			sim["hn"] = int(sim.get("hn", 0)) + 1
			car.honk(false)
	else:
		sim["blocked_t"] = 0.0


func _waiting_at_red(sim: Dictionary, on_bridge: bool) -> bool:
	if on_bridge:
		return false
	var stop: Dictionary = lane_graph.next_signal_stop(int(sim.lane), float(sim.dist))
	if stop.is_empty() or _m.green_group(int(stop.sig)) == int(stop.group):
		return false
	return float(stop.dist) - float(sim.dist) < _m.car_look_ahead + 4.0


## Static bodies only; with nothing within 6 units (a bridge over a street) the last or lane height is kept.
func road_y(id: String, local_pos: Vector3) -> float:
	var world: Node3D = _m.world()
	if world == null or not _m.is_inside_tree():
		return local_pos.y
	var space: PhysicsDirectSpaceState3D = _m.get_viewport().world_3d.direct_space_state
	if space == null:
		return local_pos.y
	var hit := _static_hit_below(space, local_pos)
	var last: float = float(_car_ground_y.get(id, local_pos.y))
	if hit.is_empty():
		return last if absf(last - local_pos.y) <= 6.0 else local_pos.y
	var y: float = world.to_local(hit.position).y
	if absf(y - local_pos.y) > 6.0:
		return last if absf(last - local_pos.y) <= 6.0 else local_pos.y
	if absf(y - local_pos.y) > 0.5 and not _ground_off.has(id):
		_ground_off[id] = true
		print("[Traffic] %s: lane %.1f above/below the road, snapped" % [id, local_pos.y - y])
	_car_ground_y[id] = y
	return y


## Looks past up to four bodies in the way; {} when there is none.
func _static_hit_below(space: PhysicsDirectSpaceState3D, local_pos: Vector3) -> Dictionary:
	var world: Node3D = _m.world()
	var from: Vector3 = world.to_global(local_pos + Vector3.UP * 6.0)
	var to: Vector3 = world.to_global(local_pos - Vector3.UP * 10.0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	var hit: Dictionary = {}
	var excluded: Array[RID] = []
	for _try in 4:
		q.exclude = excluded
		hit = space.intersect_ray(q)
		if hit.is_empty() or hit.collider is StaticBody3D:
			break
		excluded.append(hit.rid)
		hit = {}
	return hit


## Arrival hands over to the normal lane sim.
func _merge_toward_lane(id: String, car, sim: Dictionary, people: Array, delta: float):
	var world: Node3D = _m.world()
	var m: Dictionary = sim.merge
	var to: Vector3 = m.to
	var here: Vector3 = world.to_local(car.global_position)
	var fwd: Vector3 = to - here
	fwd.y = 0.0
	var remaining := fwd.length()
	if remaining < 1.0:
		sim.erase("merge")
		return
	fwd = fwd.normalized()
	# Workspace units, so the corridor thresholds match pool cars.
	var frame: Transform3D = world.global_transform * Transform3D(Basis.looking_at(fwd, Vector3.UP), here)
	var gap := frontal_gap(frame, [car], people)
	var target: float = minf(float(sim.cruise), _m.car_speed_min)
	var look: float = _m.car_look_ahead
	if gap < look:
		target *= clampf((gap - _m.car_stop_gap) / maxf(look - _m.car_stop_gap, 1.0), 0.0, 1.0)
	if target > float(sim.speed):
		sim.speed = move_toward(float(sim.speed), target, _m.car_accel * delta)
	else:
		sim.speed = move_toward(float(sim.speed), target, _m.car_brake * delta)
	var step: float = minf(float(sim.speed) * delta, remaining)
	var next: Vector3 = here + fwd * step
	next.y = road_y(id, next)
	var want_yaw: float = atan2(fwd.x, fwd.z) + PI
	var yaw: float = lerp_angle(car.rotation.y, want_yaw, minf(delta * 3.0, 1.0))
	car.set_driven_state(next, yaw, float(sim.speed))


func _lane_dir(lane: int, d: float) -> Vector3:
	return -lane_graph.sample(lane, d).basis.z


## Its top speed turns no faster than car_junction_turn_rate.
func _connector(from: Vector3, d0: Vector3, to: Vector3, d1: Vector3,
		lane: int, at: float) -> Dictionary:
	var turn: float = absf(d0.angle_to(d1))
	var length: float = LaneGraphScript.hermite_length(from, d0, to, d1)
	var comfortable := INF
	if turn > 0.05:
		comfortable = deg_to_rad(_m.car_junction_turn_rate) * length / turn
	return {"lane": lane, "entry_dist": at, "exit": from, "entry": to,
		"d0": d0, "d1": d1, "len": length, "turn": turn, "max_speed": comfortable}


## Headings are rate-limited in yaw space.
func _apply_car_sim(id: String, speed: float):
	var car = _car_node(id)
	var sim: Dictionary = car_sim.get(id, {})
	if car == null or not is_instance_valid(car) or sim.is_empty():
		return
	if sim.has("bridge"):
		var b: Dictionary = sim.bridge
		var t: float = clampf(float(sim.dist) / maxf(float(b.len), 0.001), 0.0, 1.0)
		var on: Dictionary = LaneGraphScript.hermite(b.exit, b.d0, b.entry, b.d1, t)
		var bp: Vector3 = on.pos
		bp.y = road_y(id, bp)
		var fwd: Vector3 = on.tan
		car.set_driven_state(bp, _rate_limit(car, atan2(fwd.x, fwd.z) + PI, bp, speed), speed)
		return

	var xf: Transform3D = lane_graph.sample(sim.lane, sim.dist)
	var fwd2: Vector3 = -xf.basis.z
	var yaw2: float = atan2(fwd2.x, fwd2.z) + PI
	var origin: Vector3 = xf.origin
	origin.y = road_y(id, origin)
	car.set_driven_state(origin, _rate_limit(car, yaw2, origin, speed), speed)


## Pause at each terminus before reversing.
func _simulate_trams(delta):
	if tram_graph.is_empty():
		return
	var people: Array = _m.people_positions_global()
	var top: float = _m.tram_speed
	var look: float = _m.car_look_ahead
	for id in _tram_sim:
		var sim: Dictionary = _tram_sim[id]
		var tram = trams.get(id)
		if tram == null or not is_instance_valid(tram):
			continue
		if float(sim.pause) > 0.0:
			sim.pause = float(sim.pause) - delta
			sim.speed = 0.0
			continue
		var gap := frontal_gap(tram.lead_frame(int(sim.dir)), tram.units(), people)
		var target: float = top
		if gap < look:
			target = top * clampf((gap - _m.car_stop_gap) / maxf(look - _m.car_stop_gap, 1.0), 0.0, 1.0)
		if target > sim.speed:
			sim.speed = move_toward(sim.speed, target, _m.tram_accel * delta)
		else:
			sim.speed = move_toward(sim.speed, target, _m.car_brake * delta)
		_advance_tram(sim, delta)
		_apply_tram_sim(id)


## Turns round half a car separation before each terminus, so both cars stay on the track.
func _advance_tram(sim: Dictionary, delta: float):
	var line := int(sim.line)
	var lo: float = minf(_tram_sep() * 0.5, tram_graph.lane_length(line) * 0.5)
	var hi: float = maxf(tram_graph.lane_length(line) - lo, lo)
	sim.dist = float(sim.dist) + sim.speed * delta * float(sim.dir)
	if float(sim.dist) >= hi:
		sim.dist = hi
		sim.dir = -1
		sim.pause = _m.tram_pause
		sim.speed = 0.0
	elif float(sim.dist) <= lo:
		sim.dist = lo
		sim.dir = 1
		sim.pause = _m.tram_pause
		sim.speed = 0.0


## Unit 1 faces backwards (cab to cab).
func _apply_tram_sim(id: String):
	var tram = trams.get(id)
	var sim: Dictionary = _tram_sim.get(id, {})
	if tram == null or not is_instance_valid(tram) or sim.is_empty():
		return
	var line := int(sim.line)
	if line >= tram_graph.lane_count():
		return
	var half := _tram_sep() * 0.5
	var len := tram_graph.lane_length(line)
	var xf0: Transform3D = tram_graph.sample(line, clampf(float(sim.dist) + half, 0.0, len))
	var xf1: Transform3D = tram_graph.sample(line, clampf(float(sim.dist) - half, 0.0, len))
	var f0: Vector3 = -xf0.basis.z
	var f1: Vector3 = xf1.basis.z
	tram.set_driven_units(
		xf0.origin, atan2(f0.x, f0.z) + PI,
		xf1.origin, atan2(f1.x, f1.z) + PI,
		float(sim.speed))


## Cars, each tram's two units (not the tram container), and borrowable vehicles' scan points.
func _vehicle_nodes() -> Array:
	var out := []
	for id in cars:
		var car = cars[id]
		if car != null and is_instance_valid(car):
			out.append(car)
	for id in trams:
		var tram = trams[id]
		if tram != null and is_instance_valid(tram):
			out.append_array(tram.units())
	for id in ext_vehicles:
		var ent: Dictionary = ext_vehicles[id]
		var node = ent.get("node")
		if node == null or not is_instance_valid(node):
			continue
		out.append_array(_valid_points(ent))
	return out


func _valid_points(ent: Dictionary) -> Array:
	var out := []
	for p in ent.get("points", []):
		if p != null and is_instance_valid(p):
			out.append(p)
	return out


## Workspace units: the frame's inverse undoes the world root's scale.
func frontal_gap(frame: Transform3D, exclude: Array, people: Array) -> float:
	var gap := INF
	var inv := frame.affine_inverse()
	var half_width: float = _m.car_lane_half_width

	for other in _vehicle_nodes():
		if other in exclude or (other.get_parent() in exclude and other.get_parent() != null):
			continue
		var local: Vector3 = inv * other.global_position
		if absf(local.x) <= half_width + 3.0 and local.z < -4.0:
			gap = minf(gap, -local.z - 8.0)

	for p in people:
		var local: Vector3 = inv * p
		if absf(local.x) <= half_width and local.z < 0.0 and absf(local.y) < 12.0:
			gap = minf(gap, -local.z - 4.0)
	return maxf(gap, 0.0)


## "yc", since "y" is the height.
func car_states() -> Dictionary:
	var out := {}
	for id in cars:
		var car = cars[id]
		if car == null or not is_instance_valid(car):
			continue
		var st: Dictionary = _m.replication.snap_pos(car, {})
		st["r"] = snappedf(car.rotation.y, 0.01)
		st["k"] = car.kind
		if car.model_path != "" and not _m.car_model_paths.has(car.model_path):
			st["mp"] = car.model_path
			st["ml"] = car.target_len
		var sim: Dictionary = car_sim.get(id, {})
		if int(sim.get("hn", 0)) > 0:
			st["h"] = int(sim.hn)
			st["hd"] = int(sim.get("hd", 0))
		if int(sim.get("yc", 0)) > 0:
			st["yc"] = int(sim.yc)
			st["yl"] = int(sim.get("yl", 0))
		out[id] = st
	return out


func tram_states() -> Dictionary:
	var out := {}
	for id in trams:
		var tram = trams[id]
		if tram == null or not is_instance_valid(tram):
			continue
		var u: Array = tram.units()
		if u.size() < 2:
			continue
		var st: Dictionary = _m.replication.snap_pos(u[0], {})
		st["r"] = snappedf(u[0].rotation.y, 0.01)
		st["x2"] = snappedf(u[1].position.x, 0.01)
		st["y2"] = snappedf(u[1].position.y, 0.01)
		st["z2"] = snappedf(u[1].position.z, 0.01)
		st["r2"] = snappedf(u[1].rotation.y, 0.01)
		out[id] = st
	return out


func apply_remote_cars(states: Dictionary, now: int):
	for id in states:
		var t: Dictionary = states[id]
		if not cars.has(id) or not is_instance_valid(cars[id]):
			var mp := str(t.get("mp", ""))
			if mp != "":
				spawn_event_car(id, mp, 0.0, float(t.get("ml", 18.0)))
			else:
				_spawn_car(id, int(t.get("k", 0)))
		if not cars.has(id):
			continue
		var car = cars[id]
		car.apply_remote_state(Vector3(t.x, t.y, t.z), float(t.get("r", 0.0)))
		car.apply_events(int(t.get("h", 0)), int(t.get("hd", 0)),
			int(t.get("yc", 0)), int(t.get("yl", 0)))
		car.last_seen_msec = now


func apply_remote_trams(states: Dictionary, now: int):
	for id in states:
		var t: Dictionary = states[id]
		if not trams.has(id) or not is_instance_valid(trams[id]):
			_spawn_tram(id)
		if not trams.has(id):
			continue
		var tram = trams[id]
		tram.apply_remote_units(
			Vector3(t.x, t.y, t.z), float(t.get("r", 0.0)),
			Vector3(float(t.get("x2", t.x)), float(t.get("y2", t.y)), float(t.get("z2", t.z))),
			float(t.get("r2", 0.0)))
		tram.last_seen_msec = now
