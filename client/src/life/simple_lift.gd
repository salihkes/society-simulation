extends Node3D
## A passenger lift built from Floor<i>, Landing<i> and Platform markers; the authority schedules trips.

signal trip_finished(body: Node3D, floor_index: int, success: bool)

@export var elevator_id := "Lift"
@export var speed := 10.0
@export var acceleration := 12.0
@export var dwell_seconds := 3.0
@export var door_seconds := 1.0
@export var platform_size := Vector3(9.4, 0.4, 8.8)
@export var reach := 14.0

## Seconds an NPC trip may take before it is given up.
const JOB_TIMEOUT := 180.0
## Point indices into a sill's 8-point convex box.
const BOX_FACES := [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4],
	[1, 5, 7, 3]]

var FLOORS: Array = []  # lift-local y, from Floor<i>
var floor_index := 0
var target_floor := 0
var phase := "closed"
var door_open := 0.0
var queue: Array[int] = []
var _speed := 0.0
var _dwell := 0.0
var _manager = null
var _nc = null
var _jobs: Dictionary = {}  # instance id -> NPC trip
var _platform: AnimatableBody3D
var _prompt: Label3D
var _remote_y := INF
var _remote_door := 0.0
var _platform_layers: Dictionary = {}  # carried body -> its saved platform_floor_layers
var _panel: CanvasLayer
var _menu: PanelContainer
var _ui_player = null
var _old_mouse_mode: int
var _vr_panel: Node3D
var _lobby_nav = null
var _street_seam := Vector3.INF


func _ready() -> void:
	add_to_group("elevators")
	add_to_group("vr_interactable")
	process_physics_priority = -10
	_nc = get_node_or_null("/root/NetworkController")
	var i := 0
	while has_node("Floor%d" % i):
		FLOORS.append(float(get_node("Floor%d" % i).position.y))
		i += 1
	_platform = get_node("Platform")
	_prompt = get_node("Prompt")
	_platform.position.y = float(FLOORS[0]) - platform_size.y * 0.5
	_build_ui()
	_build_sill_meshes()
	_update_doors()


func floor_label(index: int) -> String:
	return "G" if index == 0 else str(index)


func _floor_name(index: int) -> String:
	return "Ground floor" if index == 0 else "Floor %d" % index


func _find_manager() -> void:
	if _manager == null and get_tree().current_scene != null:
		_manager = get_tree().current_scene.find_child("AmbientManager", true, false)


func is_authority() -> bool:
	return _manager == null or bool(_manager.is_authority())


func _local_player():
	return _nc.get_indexed("players:local_player") if _nc != null else null


func platform_top() -> float:
	return _platform.position.y + platform_size.y * 0.5


func nearest_floor(y: float) -> int:
	var best := 0
	for i in FLOORS.size():
		if absf(y - float(FLOORS[i])) < absf(y - float(FLOORS[best])):
			best = i
	return best


## Within its footprint, feet about its top.
func in_cabin(body: Node3D) -> bool:
	var p := to_local(body.global_position)
	var top := platform_top()
	return absf(p.x) < platform_size.x * 0.5 - 0.15 \
		and absf(p.z) < platform_size.z * 0.5 - 0.15 \
		and p.y > top - 0.4 and p.y < top + 8.7


## Lift-local: the "Approach<i>" marker, or a spot in front of the landing.
func approach_local(i: int) -> Vector3:
	var m := get_node_or_null("Approach%d" % i) as Node3D
	if m != null:
		return m.position
	return Vector3(8.2, float(FLOORS[i]) + 3.0, 0)


func approach_global(i: int) -> Vector3:
	return to_global(approach_local(i))


func _bodies() -> Array:
	var out: Array = []
	_add_ambient_bodies(out)
	_add_player_bodies(out)
	var me = _local_player()
	if me != null and is_instance_valid(me) and not out.has(me):
		out.append(me)
	for job in _jobs.values():
		if is_instance_valid(job.body) and not out.has(job.body):
			out.append(job.body)
	return out


func _add_ambient_bodies(out: Array) -> void:
	if _manager == null:
		return
	for bodies in [_manager.residents(), _manager.peds()]:
		if not (bodies is Dictionary):
			continue
		for b in bodies.values():
			if is_instance_valid(b) and b is Node3D:
				out.append(b)


func _add_player_bodies(out: Array) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var players = _nc.get_indexed("players:container") if _nc != null else null
	if not is_instance_valid(players):
		players = scene.get_node_or_null("Players")
	if players == null:
		return
	for b in players.get_children():
		if b is Node3D and not out.has(b):
			out.append(b)


func _can_carry(body: Node3D) -> bool:
	if body == _local_player():
		return true
	return is_authority() and body.get("ped_id") != null


## Carried CharacterBody3Ds lose their platform layers until they leave.
func _move_platform(top: float) -> void:
	var dy := top - platform_top()
	if is_zero_approx(dy):
		_release_platform_layers()
		return
	for body in _bodies():
		if not (in_cabin(body) and _can_carry(body)):
			continue
		if body is CharacterBody3D and not _platform_layers.has(body):
			_platform_layers[body] = body.platform_floor_layers
			body.platform_floor_layers = 0
		body.global_position += global_basis * Vector3(0, dy, 0)
		if body is CharacterBody3D:
			body.velocity.y = 0.0
	_platform.position.y = top - platform_size.y * 0.5
	_release_platform_layers()


func _release_platform_layers() -> void:
	for body in _platform_layers.keys():
		if not is_instance_valid(body):
			_platform_layers.erase(body)
		elif not in_cabin(body):
			body.platform_floor_layers = _platform_layers[body]
			_platform_layers.erase(body)


## Authority only; false when refused. Reopens the doors when already there.
func request_floor(index: int) -> bool:
	if not is_authority() or index < 0 or index >= FLOORS.size():
		return false
	if index == floor_index and phase != "moving":
		if phase in ["closed", "closing"]:
			phase = "opening"
		_dwell = dwell_seconds
	elif not queue.has(index) and not (phase == "moving" and target_floor == index):
		queue.append(index)
	return true


func _door_blocked() -> bool:
	var y := float(FLOORS[floor_index])
	for body in _bodies():
		var p := to_local(body.global_position)
		if p.x > 2.7 and p.x < 7.3 and absf(p.z) < 3.7 and p.y > y - 0.5 and p.y < y + 9:
			return true
	return false


func _physics_process(delta: float) -> void:
	_find_manager()
	if is_authority():
		_step(delta)
		_tick_jobs(delta)
	elif _remote_y != INF:
		var rate := maxf(speed * 1.8, absf(_remote_y - platform_top()) * 12)
		_move_platform(move_toward(platform_top(), _remote_y, rate * delta))
		door_open = move_toward(door_open, _remote_door, delta / door_seconds)
	_release_platform_layers()
	_update_doors()


func _step(delta: float) -> void:
	match phase:
		"closed":
			if not queue.is_empty():
				target_floor = queue.pop_front()
				phase = "opening" if target_floor == floor_index else "moving"
		"opening":
			door_open = move_toward(door_open, 1.0, delta / door_seconds)
			if door_open >= 1.0:
				phase = "open"
				_dwell = dwell_seconds
		"open":
			_dwell -= delta
			if _dwell <= 0 and not _door_blocked():
				phase = "closing"
		"closing":
			_step_closing(delta)
		"moving":
			_step_moving(delta)


func _step_closing(delta: float) -> void:
	if _door_blocked():
		phase = "opening"
		return
	door_open = move_toward(door_open, 0.0, delta / door_seconds)
	if door_open <= 0:
		phase = "closed"


## Closes the doors first.
func _step_moving(delta: float) -> void:
	if door_open > 0:
		_speed = 0
		phase = "closing"
		queue.push_front(target_floor)
		return
	var dist := float(FLOORS[target_floor]) - platform_top()
	var cap := minf(speed, sqrt(2 * acceleration * absf(dist)))
	_speed = move_toward(_speed, cap, acceleration * delta)
	_move_platform(platform_top() + signf(dist) * minf(absf(dist), _speed * delta))
	if absf(platform_top() - float(FLOORS[target_floor])) < 0.002:
		_move_platform(float(FLOORS[target_floor]))
		_speed = 0
		floor_index = target_floor
		phase = "opening"


## Only the current landing opens, and only while the cabin is level with it.
func _update_doors() -> void:
	var aligned := phase != "moving" \
		and absf(platform_top() - float(FLOORS[floor_index])) < 0.05
	for i in FLOORS.size():
		var landing := get_node("Landing%d" % i)
		_set_leaves(landing, door_open if aligned and i == floor_index else 0.0)
		landing.get_node("Indicator").text = floor_label(nearest_floor(platform_top()))
	_set_leaves(_platform, door_open if aligned else 0.0)
	_platform.get_node("CabinIndicator").text = floor_label(nearest_floor(platform_top()))


func _set_leaves(holder: Node, amount: float) -> void:
	for j in 2:
		var door := holder.get_node("Door%d" % j) as Node3D
		var z := (-1 if j == 0 else 1) * (1.1 + 2.3 * amount)
		if door.position.z != z:
			door.position.z = z


func snapshot() -> Dictionary:
	return {"y": platform_top(), "floor": floor_index, "target": target_floor,
		"phase": phase, "door": door_open, "queue": queue.duplicate()}


## The platform eases toward the snapshot each frame.
func apply_snapshot(data: Dictionary) -> void:
	if is_authority() or FLOORS.is_empty():
		return
	var first := _remote_y == INF
	_remote_y = clampf(float(data.get("y", FLOORS[0])), float(FLOORS[0]), float(FLOORS[-1]))
	_remote_door = clampf(float(data.get("door", 0)), 0, 1)
	floor_index = clampi(int(data.get("floor", 0)), 0, FLOORS.size() - 1)
	target_floor = clampi(int(data.get("target", 0)), 0, FLOORS.size() - 1)
	phase = str(data.get("phase", "closed"))
	queue.assign(data.get("queue", []))
	if first:
		_move_platform(_remote_y)
		door_open = _remote_door
	_update_doors()


func _at_landing(body: Node3D, index: int) -> bool:
	var p := to_local(body.global_position)
	var ap := approach_local(index)
	return Vector2(p.x - ap.x, p.z - ap.z).length() < 5.0 and absf(p.y - ap.y) < 4.0 \
		and p.x > 5.8


## Honoured when that player is in the cabin or at the requested landing.
func handle_request(data: Dictionary) -> void:
	if not is_authority() or str(data.get("id", "")) != elevator_id:
		return
	var index := int(data.get("floor", -1))
	if index < 0 or index >= FLOORS.size():
		return
	var body = _manager.player_by_id("u:" + str(data.get("username", ""))) \
		if _manager != null else _local_player()
	if body != null and (in_cabin(body) or _at_landing(body, index)):
		request_floor(index)


func _send_request(index: int) -> void:
	if is_authority():
		request_floor(index)
	elif _nc != null and bool(_nc.get("connected")):
		_nc.send_json({"type": "elevator_req", "id": elevator_id, "floor": index})


func _process(_delta: float) -> void:
	var me = _local_player()
	if me == null or not is_instance_valid(me):
		_prompt.hide()
		_close_ui()
		return
	var inside := in_cabin(me)
	var nearby := nearest_floor(to_local(me.global_position).y)
	var near := inside or _at_landing(me, nearby)
	if (_menu.visible or is_instance_valid(_vr_panel)) and not inside:
		_close_ui()
	_prompt.visible = near and not _menu.visible and not is_instance_valid(_vr_panel)
	_prompt.position = Vector3(0 if inside else 8.2,
		(platform_top() if inside else float(FLOORS[nearby])) + 7.5, 0)
	var vr: bool = me.get("is_vr_mode") == true
	var prompt_text := ("X" if vr else "E") \
		+ (" · Select floor" if inside else " · Call elevator")
	if _prompt.text != prompt_text:
		_prompt.text = prompt_text
	if vr:
		return  # VRInteractions routes one controller press to one nearby target.
	if me.has_method("_typing") and me._typing() and not _menu.visible:
		return
	if Input.is_action_just_pressed("interact") and near:
		_interact(me, inside, nearby)
	if _menu.visible and Input.is_action_just_pressed("ui_cancel"):
		_close_ui()


func _interact(me, inside: bool, nearby: int) -> void:
	if not inside:
		_send_request(nearby)
	elif _menu.visible:
		_close_ui()
	else:
		_open_ui(me)


func _build_ui() -> void:
	_panel = CanvasLayer.new()
	add_child(_panel)
	var center := CenterContainer.new()
	_panel.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu = PanelContainer.new()
	center.add_child(_menu)
	var scroll := ScrollContainer.new()
	var height := minf(420, get_viewport().get_visible_rect().size.y - 32)
	scroll.custom_minimum_size = Vector2(300, height)
	_menu.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	var heading := Label.new()
	heading.text = _building_name()
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	list.add_child(heading)
	var home_floor := int(Identity.value("lift_home_floor"))
	var home_label := str(Identity.value("lift_home_label"))
	for i in range(FLOORS.size() - 1, -1, -1):
		var button := Button.new()
		button.text = _floor_name(i)
		if i == home_floor:
			button.text += " · " + home_label
		button.custom_minimum_size.y = 36
		button.pressed.connect(func(): _send_request(i); _close_ui())
		list.add_child(button)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(_close_ui)
	list.add_child(close)
	_menu.hide()


func _building_name() -> String:
	return str(Identity.value("lift_building_name"))


## A spatial panel in VR, else the 2D menu.
func _open_ui(me) -> void:
	_ui_player = me
	if me.get("is_vr_mode") == true:
		var labels: Array = []
		for i in FLOORS.size():
			labels.append(_floor_name(i))
		_vr_panel = preload("res://src/ui/vr/vr_floor_panel.gd").new()
		_platform.add_child(_vr_panel)
		me.key_holder = self
		_vr_panel.open(me, _building_name(), labels, _vr_choose, _close_ui)
		return
	_old_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if "key_holder" in me:
		me.key_holder = self
	_menu.show()


func _close_ui() -> void:
	var spatial := is_instance_valid(_vr_panel)
	if not spatial and (_menu == null or not _menu.visible):
		return
	if is_instance_valid(_ui_player) and _ui_player.get("key_holder") == self:
		_ui_player.key_holder = null
	if spatial:
		_vr_panel.dismiss()
		_vr_panel = null
	else:
		Input.mouse_mode = _old_mouse_mode
	_menu.hide()
	_ui_player = null


func vr_close() -> void:
	_close_ui()


## 0 in the cabin, the distance to the landing when at one, else INF.
func vr_interaction_distance(body: Node3D) -> float:
	if in_cabin(body):
		return 0.0
	var floor_near := nearest_floor(to_local(body.global_position).y)
	if not _at_landing(body, floor_near):
		return INF
	return body.global_position.distance_to(approach_global(floor_near))


func vr_interact(body: Node3D) -> void:
	if in_cabin(body):
		_open_ui(body)
	elif vr_interaction_distance(body) < INF:
		_send_request(nearest_floor(to_local(body.global_position).y))


func _vr_choose(index: int) -> void:
	_send_request(index)
	_close_ui()


## Authority only. One trip at a time; `entry` (default: active intent) is marked done at the end.
func request_ride(body: Node3D, destination: int, entry = null) -> bool:
	if not is_authority() or destination < 0 or destination >= FLOORS.size() \
			or body.get("steer_to") == null:
		return false
	var p := to_local(body.global_position)
	var from := nearest_floor(p.y)
	var ap := approach_local(from)
	if Vector2(p.x - ap.x, p.z - ap.z).length() > reach or absf(p.y - ap.y) > 4:
		return false
	var id := str(body.get_instance_id())
	if _jobs.has(id):
		return true
	_jobs[id] = {"body": body, "from": from, "to": destination, "stage": "approach",
		"time": 0.0, "entry": entry if entry != null else body.get("active_entry"),
		"personal_space": body.get("personal_space")}
	if "personal_space" in body:
		body.personal_space = false
	return true


func _steer(body: Node3D, at_local: Vector3) -> bool:
	var parent := body.get_parent() as Node3D
	var target := to_global(at_local)
	body.steer_to = parent.to_local(target) if parent != null else target
	body.steer_speed = 2.0
	var p := to_local(body.global_position)
	return Vector2(p.x - at_local.x, p.z - at_local.z).length() < 0.65


func _tick_jobs(delta: float) -> void:
	var busy := false
	for id in _jobs.keys():
		var job: Dictionary = _jobs[id]
		var body = job.body
		if not is_instance_valid(body):
			_jobs.erase(id)
			continue
		job.time += delta
		if job.time > JOB_TIMEOUT:
			_finish_job(id, false)
			continue
		if busy:
			_steer(body, approach_local(job.from) + Vector3(0, 0, 3.3))
			continue
		busy = true
		_advance_job(id, job, body)


func _advance_job(id: String, job: Dictionary, body) -> void:
	var centre := Vector3(0, platform_top() + 3, 0)
	match str(job.stage):
		"approach":
			if _steer(body, approach_local(job.from)):
				job.stage = "wait"
				request_floor(job.from)
		"wait":
			_steer(body, approach_local(job.from))
			if phase == "open" and floor_index == job.from:
				job.stage = "board"
				_dwell = dwell_seconds
			elif phase == "closed":
				request_floor(job.from)
		"board":
			_dwell = dwell_seconds
			if _steer(body, centre) and in_cabin(body):
				job.stage = "ride"
				request_floor(job.to)
		"ride":
			_steer(body, centre)
			if floor_index == job.to and phase == "open":
				job.stage = "exit"
		"exit":
			_dwell = dwell_seconds
			if _steer(body, approach_local(job.to)):
				_finish_job(id, true)


func _finish_job(id: String, success: bool) -> void:
	var job: Dictionary = _jobs[id]
	var body = job.body
	body.steer_to = Vector3.INF
	body.steer_speed = 0.0
	if "personal_space" in body:
		body.personal_space = bool(job.personal_space)
	if body.has_method("hold_idle"):
		body.hold_idle(0.3)
	if job.entry is Dictionary:
		job.entry["done"] = true
		job.entry["ride_success"] = success
	var pid := str(body.get("ped_id"))
	print("[Lift %s] %s %s floor %d" % [elevator_id, pid,
		"reached" if success else "failed to reach", int(job.to)])
	if _manager != null and _manager.has_method("observe"):
		_manager.observe({"who": pid, "did": "ride" if success else "ride_failed",
			"place": elevator_id + "/" + str(job.to)})
	trip_finished.emit(body, int(job.to), success)
	_jobs.erase(id)
	if body.has_method("lift_trip_done"):
		body.lift_trip_done(int(job.to), success)


func place_entries(world: Node3D) -> Array:
	var out: Array = []
	for i in FLOORS.size():
		var p: Vector3 = world.to_local(approach_global(i))
		out.append({"id": elevator_id + "/" + str(i), "kind": "elevator",
			"name": "%s, floor %d" % [elevator_id, i], "floor": i,
			"pos": [p.x, p.y, p.z], "verbs": ["ride"]})
	return out


func _exit_tree() -> void:
	_close_ui()
	for body in _platform_layers:
		if is_instance_valid(body):
			body.platform_floor_layers = _platform_layers[body]
	for id in _jobs.keys():
		if is_instance_valid(_jobs[id].body):
			_finish_job(id, false)


## World-local. {} when neither end is in the lobby; {"route": []} when there is no way.
func ground_route(world: Node3D, street, from: Vector3, to: Vector3) -> Dictionary:
	var a := to_local(world.to_global(from))
	var b := to_local(world.to_global(to))
	var landing := approach_local(0)
	var from_lobby := absf(a.y - landing.y) < 5 and a.x > 5.8 and a.x < 14.3 and absf(a.z) < 5
	var to_lobby := absf(b.y - landing.y) < 5 \
		and Vector2(b.x - landing.x, b.z).length() < 2
	if not from_lobby and not to_lobby:
		return {}
	if _lobby_nav == null:
		_build_lobby_nav(world, street)
	var route := PackedVector3Array()
	if _lobby_nav.covers(from) and _lobby_nav.covers(to) and absf(from.y - to.y) < 6:
		route = _lobby_nav.route(from, to)
	if route.is_empty() and _street_seam != Vector3.INF:
		route = _route_via_seam(street, from, to, to_lobby)
	return {"route": route}


func _build_lobby_nav(world: Node3D, street) -> void:
	_lobby_nav = preload("res://src/life/interior_nav.gd").new()
	_lobby_nav.cell_size = 0.5
	_lobby_nav.body_radius = 1.52
	_lobby_nav.headroom = 6.0
	var centre := world.to_local(approach_global(0))
	var exclude: Array = []
	for body in _bodies():
		if body is CollisionObject3D:
			exclude.append(body.get_rid())
	_lobby_nav.build(world.get_world_3d().direct_space_state, world,
		AABB(centre - Vector3(16, 0, 16), Vector3(32, 0, 32)), exclude, centre.y + 2)
	var best := INF
	for cell in _lobby_nav.reachable_from(centre):
		var p: Vector3 = _lobby_nav._cell_pos(cell.x, cell.y)
		p.y = _lobby_nav.floor_y
		var d := p.distance_squared_to(centre)
		if d >= best or not street.is_walkable(Vector2(p.x, p.z)):
			continue
		_street_seam = p
		best = d


func _route_via_seam(street, from: Vector3, to: Vector3, to_lobby: bool) -> PackedVector3Array:
	var route: PackedVector3Array
	var rest: PackedVector3Array
	if to_lobby:
		route = street.find_route(from, _street_seam)
		rest = _lobby_nav.route(_street_seam, to)
	else:
		route = _lobby_nav.route(from, _street_seam)
		rest = street.find_route(_street_seam, to)
	if route.is_empty() or rest.is_empty():
		route.clear()
	else:
		route.append_array(rest)
	return route


## So the entrance has a visible threshold where it has a walkable one.
func _build_sill_meshes() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.32, 0.35, 0.38)
	material.metallic = 0.55
	material.roughness = 0.5
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for body in get_children():
		if not str(body.name).contains("Sill"):
			continue
		for shape in body.get_children():
			if not shape is CollisionShape3D or not shape.shape is ConvexPolygonShape3D:
				continue
			var mesh := MeshInstance3D.new()
			mesh.mesh = _box_mesh(shape.shape.points)
			mesh.material_override = material
			body.add_child(mesh)


func _box_mesh(points: PackedVector3Array) -> ArrayMesh:
	var centre := Vector3.ZERO
	for point in points:
		centre += point / float(points.size())
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in BOX_FACES:
		var normal := (points[face[1]] - points[face[0]]) \
			.cross(points[face[2]] - points[face[0]]).normalized()
		if normal.dot(points[face[0]] - centre) < 0:
			normal = -normal
		for index in [face[0], face[1], face[2], face[0], face[2], face[3]]:
			surface.set_normal(normal)
			surface.add_vertex(points[index])
	return surface.commit()
