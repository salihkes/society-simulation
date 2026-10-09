extends RefCounted
## One household: the people who share a home and the objects in it they can use. Authority only.

const OBJECTS_DIR := "res://assets/assets/Objects"
const UNITS_PER_M := 5.0
const NavScript := preload("res://src/life/interior_nav.gd")
const ARRIVE := 2.5  # workspace units from a standing spot before the pose
const ARRIVE_SEAT := 6.0  # a seat sits inside its furniture: the last step is onto it
const WALK_TRIES := 3  # routes asked for before a spot is given up
const WALK_CAP_S := 90.0  # real seconds
const INSIDE_MARGIN := 20.0  # units around the house bounds that still count as inside
const IDLE_PICK_MIN := 8.0  # seconds
const IDLE_PICK_MAX := 25.0
const COOK_S := 45.0  # real seconds
const EAT_S := 60.0  # real seconds
const CARE_EVERY_S := 150.0
const GUEST_LEAVES_S := 30.0  # a welcomed guest out of the house this long has left
const TABLE_M := 0.76  # bowl height above the object base, metres
const BOWL_SCENE := OBJECTS_DIR + "/prop_bowl/mesh.tscn"

static var _object_meta: Dictionary = {}  # object folder -> object.json

var id := ""
var def: Dictionary = {}
var _manager
var _house: Node3D = null
# {id, object, kind, verb, label, pose, how, prop, seconds, hours, restores, hold, seat_near, only, weight, pos, yaw, ped, node, centre, table_y}
var _spots: Array = []
var _markers: Dictionary = {}  # marker name -> workspace-local position
var _door := Vector3.INF
var _bounds := AABB()
# pid -> {spot, use, phase, left, since, life, entry_seq, hold, tries, [patient]}
var _using: Dictionary = {}
var _meal: Dictionary = {}
var _done: Dictionary = {}  # "day|meal name", "day|expect pid", "day|pantry" -> true
var _away: Dictionary = {}  # expected pid -> true after the guardians were told they are late
var _guests: Dictionary = {}  # pid -> {knocked, welcomed, since, out}
var _idle_t: Dictionary = {}  # pid -> seconds until the next autonomous pick
var _ill: Dictionary = {}
var _care_t := CARE_EVERY_S * 0.3
var _scan_t := 0.0
var pantry := 0
var _bowls: Array = []
var _rng := RandomNumberGenerator.new()
var nav = null  # interior_nav.gd, built from the flat's geometry
var lift = null  # simple_lift.gd in the house, if any: the way in and out
var _nav_warned := false


func _init(manager, household_id: String, definition: Dictionary):
	_manager = manager
	id = household_id
	def = definition
	pantry = int(def.get("pantry", 6))
	_rng.seed = hash(id)


## False if it has no usable object.
func bind(house: Node3D) -> bool:
	_house = house
	_spots = []
	_markers = {}
	if house == null or _manager == null or _manager.world() == null:
		return false
	_collect_markers(house)
	_door = _markers.get(str(def.get("door", "")), Vector3.INF)
	_scan_objects(house)
	if not _fit_bounds():
		return false
	return not _spots.is_empty()


## Skips markers inside a lift shaft: shaft stops are public circulation, not rooms.
func _collect_markers(house: Node3D):
	for m in house.find_children("*", "Marker3D", true, false):
		if _in_lift(m, house):
			continue
		_markers[str(m.name)] = _to_local(m.global_position)


static func _in_lift(m: Node, house: Node3D) -> bool:
	var parent := m.get_parent()
	while parent != null and parent != house:
		if parent.is_in_group("elevators"):
			return true
		parent = parent.get_parent()
	return false


## Excludes the door; false if there are none.
func _fit_bounds() -> bool:
	var pts: Array = []
	for name in _markers:
		if name != str(def.get("door", "")):
			pts.append(_markers[name])
	for s in _spots:
		pts.append(s.pos)
	if pts.is_empty():
		_bounds = AABB()
		return false
	_bounds = AABB(pts[0], Vector3.ZERO)
	for p in pts:
		_bounds = _bounds.expand(p)
	return true


func _to_local(global_pos: Vector3) -> Vector3:
	return _manager.world().to_local(global_pos)


## `exclude` are the bodies standing in it.
func build_nav(space: PhysicsDirectSpaceState3D, exclude: Array = []) -> bool:
	nav = NavScript.new()
	nav.cell_size = 0.5
	nav.body_radius = 1.52
	# The humanoid is 5.09 units tall; these doorways are lower than larger interiors' 8 units.
	nav.headroom = 6.0
	var ok: bool = nav.build(space, _manager.world(), _bounds, exclude,
			_bounds.position.y + 4.0)
	if ok:
		print("[Household %s] floor sampled: %d cells of floor in a %dx%d grid"
				% [id, nav.floor_cells, nav.cols, nav.rows])
	else:
		push_warning("[Household %s] no floor found under %s — nobody can walk indoors here"
				% [id, str(def.get("house", ""))])
	return ok


## False when there is no way; without a sampled floor only a spot one step away is reachable.
func _walk_to(b, target: Vector3) -> bool:
	b.steer_to = Vector3.INF
	b.steer_speed = 0.0
	if nav == null or not nav.built:
		if not _nav_warned:
			_nav_warned = true
			push_warning("[Household %s] walking without a sampled floor" % id)
		var flat: Vector3 = target - b.position
		flat.y = 0.0
		if flat.length() > ARRIVE_SEAT:
			return false
		b.steer_to = target
		return true
	var route: PackedVector3Array = nav.route(b.position, target)
	if route.is_empty():
		return false
	b.walk_route(route)
	if "precise_route" in b:
		b.precise_route = true
	if b.has_method("reset_progress"):
		b.reset_progress()
	return true


static func _walking(b) -> bool:
	return b.is_walking() or b.steer_to != Vector3.INF


## object.json "uses": [{"verb", "label", "pose", "at", "face", "seconds", "hours", "restores", "hold", ...}]
func _scan_objects(node: Node):
	for child in node.get_children():
		if not (child is Node3D):
			continue
		var kind := _object_kind(child)
		if kind == "":
			_scan_objects(child)  # a plain container; objects may sit under it
			continue
		var meta := _meta(kind)
		var uses = meta.get("uses", [])
		if typeof(uses) != TYPE_ARRAY or uses.is_empty():
			continue
		var box := _box_of(child)
		var base_y: float = box.position.y  # object space: the bottom of its collider
		var centre: Vector3 = _to_local(child.to_global(box.get_center()))
		for use in uses:
			if typeof(use) != TYPE_DICTIONARY or str(use.get("verb", "")) == "":
				continue
			_add_use_spots(child, kind, meta, use, base_y, centre)


func _add_use_spots(child: Node3D, kind: String, meta: Dictionary, use: Dictionary,
		base_y: float, centre: Vector3):
	var ats := _use_positions(use)
	var face_deg := float(use.get("face", 0.0))
	for i in ats.size():
		var a: Array = ats[i]
		if a.size() < 3:
			continue
		var local := Vector3(float(a[0]) * UNITS_PER_M, base_y + float(a[1]) * UNITS_PER_M,
				float(a[2]) * UNITS_PER_M)
		var pos: Vector3 = _to_local(child.to_global(local))
		var face_here: float = float(a[3]) if a.size() >= 4 else face_deg
		var verb := str(use.verb)
		var spot := {
			"id": "%s#%s%s" % [child.name, verb, ("." + str(i)) if ats.size() > 1 else ""],
			"object": str(child.name), "kind": kind, "verb": verb,
			"label": str(use.get("label", verb + " at the " + str(meta.get("label", kind)))),
			"pose": str(use.get("pose", "stand")), "how": str(use.get("how", "chair")),
			"prop": str(use.get("prop", "")), "seconds": float(use.get("seconds", 60.0)),
			"hours": use.get("hours", []), "restores": use.get("restores", {}),
			"hold": bool(use.get("hold", false)), "seat_near": bool(use.get("seat_near", false)),
			"only": str(use.get("only", "")), "weight": float(use.get("weight", 1.0)),
			"pos": pos, "yaw": _spot_yaw(child, face_here), "ped": "", "node": child,
			"centre": centre,
			"table_y": _to_local(child.to_global(
					Vector3(0.0, base_y + TABLE_M * UNITS_PER_M, 0.0))).y,
		}
		_spots.append(spot)


## "at" in object-space metres (+Z front): one [x, y, z(, yaw)], a list of them, or the centre.
static func _use_positions(use: Dictionary) -> Array:
	var ats: Array = []
	var at = use.get("at", null)
	if typeof(at) == TYPE_ARRAY and at.size() == 3 and typeof(at[0]) != TYPE_ARRAY:
		ats.append(at)
	elif typeof(at) == TYPE_ARRAY and not at.is_empty() and typeof(at[0]) == TYPE_ARRAY:
		ats = at
	else:
		ats.append([0.0, 0.0, 0.0])
	return ats


func _spot_yaw(child: Node3D, face_deg: float) -> float:
	var fwd_obj := Vector3(sin(deg_to_rad(face_deg)), 0.0, cos(deg_to_rad(face_deg)))
	var fwd_ws: Vector3 = _manager.world().global_transform.affine_inverse().basis \
			* (child.global_transform.basis * fwd_obj)
	fwd_ws.y = 0.0
	var yaw := 0.0
	if fwd_ws.length_squared() > 0.0001:
		yaw = atan2(fwd_ws.x, fwd_ws.z) + PI  # model forward is -Z
	return yaw


## "boho_bed", else "".
static func _object_kind(n: Node) -> String:
	var path := str(n.scene_file_path)
	if not path.begins_with(OBJECTS_DIR + "/"):
		return ""
	var rest := path.trim_prefix(OBJECTS_DIR + "/")
	var parts := rest.split("/")
	if parts.size() != 2 or not (parts[1].begins_with("mesh.")):
		return ""
	return parts[0]


## Cached; {} when missing or invalid.
static func _meta(kind: String) -> Dictionary:
	if _object_meta.has(kind):
		return _object_meta[kind]
	var out := {}
	var path := OBJECTS_DIR + "/" + kind + "/object.json"
	var f: FileAccess = FileAccess.open(path, FileAccess.READ) \
			if FileAccess.file_exists(path) else null
	if f != null:
		var parsed = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			out = parsed
	_object_meta[kind] = out
	return out


## Its bottom is the floor the object stands on; a 1 m cube when it has none.
static func _box_of(obj: Node3D) -> AABB:
	var shape := obj.get_node_or_null("Body/Shape") as CollisionShape3D
	if shape != null and shape.shape is BoxShape3D:
		var size: Vector3 = (shape.shape as BoxShape3D).size
		return AABB(shape.position - size * 0.5, size)
	return AABB(Vector3(-0.5, -0.5, -0.5) * UNITS_PER_M, Vector3.ONE * UNITS_PER_M)


## "r_<id>"
static func _key(rid: String) -> String:
	return rid if rid.begins_with("r_") else "r_" + rid


func members() -> Array:
	var out := []
	for rid in def.get("members", {}):
		out.append(_key(str(rid)))
	return out


func member(pid: String) -> bool:
	return def.get("members", {}).has(pid.trim_prefix("r_"))


func role(pid: String) -> String:
	return str(def.get("members", {}).get(pid.trim_prefix("r_"), ""))


func guardians() -> Array:
	var out := []
	for rid in def.get("members", {}):
		if str(def.members[rid]) in ["parent", "guardian"]:
			out.append(_key(str(rid)))
	return out


func allowed_in(pid: String) -> bool:
	return member(pid) or bool(_guests.get(pid, {}).get("welcomed", false))


func inside(pos: Vector3) -> bool:
	if _bounds.size == Vector3.ZERO and _bounds.position == Vector3.ZERO:
		return false
	return _bounds.grow(INSIDE_MARGIN).has_point(pos)


func at_home(pid: String) -> bool:
	var b = _body(pid)
	return b != null and inside(b.position)


func present() -> Array:
	var out := []
	for pid in members():
		if at_home(pid):
			out.append(pid)
	return out


func marker_pos(name: String) -> Vector3:
	return _markers.get(name, Vector3.INF)


func door_pos() -> Vector3:
	return _door


## INF with no spots.
func shared_room_pos() -> Vector3:
	for name in def.get("rooms", {}):
		if str(def.rooms[name]) == "shared" and _markers.has(name):
			return _markers[name]
	return _bounds.get_center() if _spots.size() > 0 else Vector3.INF


func room_pos(pid: String) -> Vector3:
	for name in def.get("rooms", {}):
		var who := str(def.rooms[name])
		if who != "shared" and who != "threshold" and _markers.has(name) \
				and _listed(who, pid):
			return _markers[name]
	return shared_room_pos()


## `ids` is comma-separated.
static func _listed(ids: String, pid: String) -> bool:
	for rid in ids.split(","):
		if _key(rid.strip_edges()) == pid:
			return true
	return false


func _body(pid: String):
	var b = _manager.residents().get(pid)
	return b if b != null and is_instance_valid(b) else null


func _hour() -> float:
	return float(_manager.current_hour())


func _day() -> int:
	return int(_manager.current_day()) if _manager.has_method("current_day") else 0


func _controlled(pid: String) -> bool:
	var lc = _manager.get("life_controller") if _manager != null else null
	return lc != null and lc.has_method("controlled") and lc.controlled(pid)


## [from, to) wrapping midnight; true without hours.
static func _in_hours(hours, hour: float) -> bool:
	if typeof(hours) != TYPE_ARRAY or hours.size() != 2:
		return true
	var a := float(hours[0])
	var b := float(hours[1])
	if a <= b:
		return hour >= a and hour < b
	return hour >= a or hour < b


## An ill member goes to bed at any hour.
func _hours_ok(pid: String, s: Dictionary, hour: float) -> bool:
	if s.verb == "sleep" and _ill.get(pid, false):
		return true
	return _in_hours(s.hours, hour)


## Owned objects only by their owners (except "only" uses); care only while an ill member lies there.
func _may_use(pid: String, s: Dictionary) -> bool:
	var own = def.get("own", {}).get(s.object, null)
	if typeof(own) == TYPE_ARRAY and s.only == "" and not _owns(own, pid):
		return false
	if s.only == "ill":
		return _ill_member_on(str(s.object))
	return true


static func _owns(own: Array, pid: String) -> bool:
	var ok := false
	for rid in own:
		if _key(str(rid)) == pid:
			ok = true
	return ok


func _ill_member_on(object: String) -> bool:
	for other in _using:
		var u: Dictionary = _using[other]
		if u.spot.object == object and _ill.get(other, false):
			return true
	return false


func _free(s: Dictionary, pid: String) -> bool:
	return s.ped == "" or s.ped == pid


## {"<object>#<verb>": {"use", "label", "restores", "free"}}; empty when not allowed in the house.
func objects_for(pid: String) -> Dictionary:
	var out := {}
	if not allowed_in(pid) or not at_home(pid):
		return out
	var hour := _hour()
	for s in _spots:
		if not _hours_ok(pid, s, hour) or not _may_use(pid, s) or not _free(s, pid):
			continue
		var key := "%s#%s" % [s.object, s.verb]
		if not out.has(key):
			out[key] = {"use": s.verb, "label": s.label, "restores": s.restores, "free": 0}
		out[key]["free"] = int(out[key]["free"]) + 1
	return out


## "" when none.
func activity(pid: String) -> String:
	if _using.has(pid):
		var u: Dictionary = _using[pid]
		if not _meal.is_empty() and (u.spot.verb in ["cook", "eat"]):
			return "meal at home: " + str(_meal.get("name", ""))
		return ("going to " if u.phase == "going" else "") + str(u.spot.label)
	return ""


func knocking() -> Array:
	var out := []
	for pid in _guests:
		if bool(_guests[pid].knocked) and not bool(_guests[pid].welcomed):
			out.append(pid)
	return out


func place_entry() -> Dictionary:
	var pos := _door if _door != Vector3.INF else shared_room_pos()
	var mem := []
	for pid in members():
		mem.append(pid)
	return {"id": "household:" + id, "kind": "household", "name": str(def.get("name", id)),
		"pos": [snappedf(pos.x, 0.1), snappedf(pos.y, 0.1), snappedf(pos.z, 0.1)],
		"members": mem, "house": str(def.get("house", "")), "verbs": ["visit"]}


## "" on success, else why not. A non-empty `life_id` is an order from the mind.
func start_use(pid: String, object_verb: String, seconds: float = 0.0,
		life_id: String = "") -> String:
	var b = _body(pid)
	if b == null:
		return "body missing"
	if not allowed_in(pid):
		return "not welcome in this house"
	if not inside(b.position):
		return "not in the house"
	var parts := object_verb.split("#")
	if parts.size() != 2:
		return "unknown object"
	var spot := _usable_spot(pid, parts[0], parts[1])
	if spot.is_empty():
		return "nothing free to use there"
	var seat: Dictionary = spot
	if spot.seat_near:
		var best := _seat_facing(spot, pid)
		if not best.is_empty():
			seat = best
	release(pid)
	seat.ped = pid
	if str(seat.id) != str(spot.id):
		spot.ped = pid
	var entry_seq := -1
	if b.has_method("current_entry"):
		entry_seq = int(b.current_entry(true).get("seq", -1))
	_using[pid] = {"spot": seat, "use": spot, "phase": "going",
		"left": seconds if seconds > 0.0 else float(spot.seconds),
		"since": 0.0, "life": life_id, "entry_seq": entry_seq,
		"hold": spot.hold and life_id == ""}
	if b.sitting:
		b.stand_up()
	b.errand_owner = null
	b.errand_dest = Vector3.INF
	b.personal_space = false
	_using[pid]["tries"] = 1
	if not _walk_to(b, seat.pos):
		release(pid)
		return "no way to walk there"
	return ""


## {} if none.
func _usable_spot(pid: String, object: String, verb: String) -> Dictionary:
	var hour := _hour()
	for s in _spots:
		if s.object == object and s.verb == verb and _free(s, pid) and _may_use(pid, s) \
				and _hours_ok(pid, s, hour):
			return s
	return {}


## A TV is watched from a seat; {} if none, and the spot itself is used.
func _seat_facing(spot: Dictionary, pid: String) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for s in _spots:
		if s.pose != "sit" or s.seat_near or not _free(s, pid) or not _may_use(pid, s):
			continue
		var d: float = s.pos.distance_to(spot.centre)
		if d > 4.0 * UNITS_PER_M:
			continue
		var fwd := Vector3(-sin(float(s.yaw)), 0.0, -cos(float(s.yaw)))  # model forward
		var to: Vector3 = spot.centre - s.pos
		to.y = 0.0
		if to.length_squared() > 0.01 and fwd.dot(to.normalized()) < 0.3:
			continue
		if d < best_d:
			best_d = d
			best = s
	return best


func release(pid: String):
	var u = _using.get(pid)
	if u != null:
		u.spot.ped = ""
		u.use.ped = ""
		_using.erase(pid)
		if not _meal.is_empty() and _meal.get("eaters", []).has(pid) \
				and str(_meal.get("phase", "")) == "eating":
			_meal.eaters.erase(pid)  # left the table: no meal for them
	var b = _body(pid)
	if b == null or u == null:
		return
	b.steer_to = Vector3.INF
	b.steer_speed = 0.0
	if b.sitting:
		b.stand_up()
	if b.has_method("set_prop"):
		b.set_prop("")
	if b.character_model != null:
		b.character_model.rotation.x = 0.0
	b.personal_space = true
	b.hold_idle(0.5)


## "going", "using", or "".
func use_phase(pid: String) -> String:
	return str(_using[pid].phase) if _using.has(pid) else ""


func _take_spot(pid: String, u: Dictionary):
	var b = _body(pid)
	var s: Dictionary = u.spot
	b.steer_to = Vector3.INF
	b.steer_speed = 0.0
	b.velocity = Vector3.ZERO
	if s.pose in ["sit", "lie"]:
		b.position = s.pos + Vector3.UP * 1.0
		b.sit_at(s.pos, float(s.yaw), "lie" if s.pose == "lie" else str(s.how))
	else:
		if b.character_model != null:
			b.character_model.rotation.y = float(s.yaw)
		b.hold_idle(999999.0)
	if b.has_method("set_prop"):
		b.set_prop(str(u.use.prop))
	u.phase = "using"
	u.since = 0.0
	_manager.observe({"who": pid, "did": str(u.use.verb), "object": str(u.use.object),
		"household": id, "at": _manager.places.district_names_at(b.position)})


func _give_up(pid: String, u: Dictionary, why: String):
	_manager.observe({"who": pid, "failed": "use", "object": str(u.use.object), "reason": why,
		"household": id})
	_report_to_mind(pid, u, false, why)
	release(pid)
	_idle_t[pid] = _rng.randf_range(IDLE_PICK_MIN, IDLE_PICK_MAX)


func _finish_use(pid: String, u: Dictionary):
	if u.has("patient"):
		_care_done(pid, u)
	_manager.observe({"who": pid, "did": "use", "use": str(u.use.verb),
		"object": str(u.use.object), "restores": u.use.restores, "household": id})
	_report_to_mind(pid, u, true, "used " + str(u.use.label))
	release(pid)
	_idle_t[pid] = _rng.randf_range(IDLE_PICK_MIN, IDLE_PICK_MAX)


func _report_to_mind(pid: String, u: Dictionary, ok: bool, why: String):
	if str(u.life) == "":
		return
	var lc = _manager.get("life_controller")
	if lc != null and lc.has_method("finish"):
		lc.finish(pid, ok, why)


func _drive_uses(delta: float):
	for pid in _using.keys():
		var u: Dictionary = _using[pid]
		var b = _body(pid)
		if b == null:
			_using.erase(pid)
			continue
		if _routine_moved_on(pid, u, b):
			release(pid)
			continue
		if u.phase == "going":
			_drive_going(pid, u, b, delta)
		elif u.phase == "using":
			_drive_using(pid, u, delta)


func _routine_moved_on(pid: String, u: Dictionary, b) -> bool:
	if str(u.life) != "" or not b.has_method("current_entry") or int(u.entry_seq) == -1:
		return false
	return int(b.current_entry(true).get("seq", -1)) != int(u.entry_seq) and not _in_meal(pid)


## A walk that ends short is retried, then given up: never a teleport.
func _drive_going(pid: String, u: Dictionary, b, delta: float):
	var flat: Vector3 = u.spot.pos - b.position
	flat.y = 0.0
	u.since = float(u.since) + delta
	var reach: float = ARRIVE_SEAT if u.spot.pose in ["sit", "lie"] else ARRIVE
	if flat.length() <= reach and not (b.is_walking() and flat.length() > ARRIVE):
		_take_spot(pid, u)
	elif not _walking(b):
		if int(u.tries) >= WALK_TRIES or float(u.since) > WALK_CAP_S \
				or not _walk_to(b, u.spot.pos):
			_give_up(pid, u, "could not walk there")
		else:
			u.tries = int(u.tries) + 1
	elif float(u.since) > WALK_CAP_S:
		_give_up(pid, u, "took too long to get there")


## Meals and held uses end elsewhere.
func _drive_using(pid: String, u: Dictionary, delta: float):
	if _in_meal(pid):
		return
	if bool(u.hold):
		return
	u.left = float(u.left) - delta
	if float(u.left) <= 0.0:
		_finish_use(pid, u)


## Its explicit "use", else words in its name.
static func _hint(entry: Dictionary) -> String:
	if str(entry.get("use", "")) != "":
		return str(entry.use)
	var name := str(entry.get("name", "")).to_lower()
	if str(entry.get("do", "")) == "sleep" or "sleep" in name or "bed" in name or "night" in name:
		return "sleep"
	if "tv" in name or "television" in name:
		return "watch"
	if "study" in name or "homework" in name or "write" in name or "letter" in name:
		return "write"
	if "read" in name:
		return "read"
	if "bath" in name or "wash" in name:
		return "bathe"
	if "tea" in name:
		return "tea"
	if "radio" in name or "music" in name:
		return "listen"
	return ""


## {} unless the active entry is a household one at one of this house's markers.
func _home_entry(b) -> Dictionary:
	var entry: Dictionary = b.get("active_entry") if b.get("active_entry") is Dictionary else {}
	if entry.is_empty():
		return {}
	if entry.has("life_id"):
		return {}
	var where := str(entry.get("marker", entry.get("place", "")))
	if _markers.has(where):
		return entry
	return {}


func _autonomy(delta: float):
	for pid in members():
		var b = _body(pid)
		if b == null or _using.has(pid) or not inside(b.position):
			_idle_t.erase(pid)
			continue
		if _controlled(pid) or b.errand_owner != null \
				or (b.sitting and b.get("routine_seated") == true):
			continue
		var entry := _home_entry(b)
		if entry.is_empty():
			continue
		_idle_t[pid] = float(_idle_t.get(pid, _rng.randf_range(2.0, IDLE_PICK_MIN))) - delta
		if float(_idle_t[pid]) > 0.0:
			continue
		_idle_t[pid] = _rng.randf_range(IDLE_PICK_MIN, IDLE_PICK_MAX)
		var hint := _hint(entry)
		if _ill.get(pid, false):
			hint = "sleep"
		var choice := _pick(pid, hint)
		if choice != "":
			start_use(pid, choice)


## Never a meal or a care use, and no sleep without a hint; "" if none.
func _pick(pid: String, hint: String) -> String:
	var hour := _hour()
	var options: Array = []
	var total := 0.0
	for s in _spots:
		if not _free(s, pid) or not _may_use(pid, s) or not _hours_ok(pid, s, hour) \
				or s.only != "":
			continue
		if s.verb in ["cook", "eat"]:
			continue  # meals are shared, not solo
		if hint != "" and s.verb != hint:
			continue
		if hint == "" and s.verb == "sleep":
			continue  # nobody naps on a whim; the routine's night says when
		var w := float(s.weight)
		if w <= 0.0:
			continue
		options.append([s, w])
		total += w
	if options.is_empty():
		if hint != "" and hint != "sleep":
			return _pick(pid, "")  # the named thing is taken: anything else
		return ""
	var r := _rng.randf() * total
	for o in options:
		r -= float(o[1])
		if r <= 0.0:
			return "%s#%s" % [o[0].object, o[0].verb]
	return "%s#%s" % [options[-1][0].object, options[-1][0].verb]


func _in_meal(pid: String) -> bool:
	return not _meal.is_empty() \
			and (_meal.get("cook", "") == pid or _meal.get("eaters", []).has(pid))


## {} if none.
func _spot_by(verb: String, pid: String = "") -> Dictionary:
	for s in _spots:
		if s.verb == verb and (pid == "" or _free(s, pid)):
			return s
	return {}


## Needs a stove, a table, someone home to cook, and food in the pantry.
func _meals(hour: float, day: int):
	if not _meal.is_empty():
		return
	for m in def.get("meals", []):
		var key := "%d|%s" % [day, str(m.get("name", ""))]
		if _done.has(key):
			continue
		var start := float(m.get("hour", 0.0))
		var window := float(m.get("window", 1.5))
		if not (hour >= start and hour < start + window):
			continue
		var stove := _spot_by("cook")
		var table := _spot_by("eat")
		if stove.is_empty() or table.is_empty():
			_done[key] = true
			continue
		var cook := _choose_cook(m)
		if cook == "":
			continue  # nobody home yet; the window is still open
		if pantry <= 0:
			_report_empty_pantry(cook, m, day)
			_done[key] = true
			continue
		_meal = {"name": str(m.get("name", "")), "cook": cook, "phase": "cooking", "t": COOK_S,
			"eaters": [], "served": [], "stove": stove, "table": table}
		var err := start_use(cook, "%s#cook" % stove.object)
		if err != "":
			_meal = {}
			continue
		_done[key] = true
		_manager.observe({"who": cook, "did": "cook", "meal": str(m.get("name", "")),
			"household": id})
		print("[Household %s] %s cooks %s" % [id, cook, _meal.name])
		return


## "" if none.
func _choose_cook(m: Dictionary) -> String:
	var named := str(m.get("cook", "any"))
	var home := present()
	if named != "any" and home.has(_key(named)) and not _controlled(_key(named)):
		return _key(named)
	for pid in home:
		if not _controlled(pid) and not _ill.get(pid, false):
			return pid
	return ""


func _report_empty_pantry(cook: String, m: Dictionary, day: int):
	if _done.has("%d|pantry" % day):
		return
	_done["%d|pantry" % day] = true
	_manager.observe({"who": cook, "pantry_empty": true, "household": id,
		"meal": str(m.get("name", ""))})


func _run_meal(delta: float):
	var cook := str(_meal.cook)
	var cb = _body(cook)
	if cb == null:
		_end_meal()
		return
	match str(_meal.phase):
		"cooking":
			_meal_cooking(cook, cb, delta)
		"serving":
			_meal_serving(cook, cb, delta)
		"eating":
			_seat_eaters()  # latecomers join while food is on the table
			_meal.t = float(_meal.t) - delta
			if float(_meal.t) > 0.0:
				return
			_end_meal()


func _meal_cooking(cook: String, cb, delta: float):
	if use_phase(cook) != "using":
		return  # still walking to the stove
	_meal.t = float(_meal.t) - delta
	if float(_meal.t) > 0.0:
		return
	release(cook)
	cb.set_prop("bowl")
	cb.personal_space = false
	if not _walk_to(cb, _table_approach()):
		print("[Household %s] %s cannot reach the table from the stove" % [id, cook])
		_end_meal()
		return
	_meal.phase = "serving"
	_meal.t = WALK_CAP_S
	_meal.tries = 1


## Ends the meal if the food never arrives.
func _meal_serving(cook: String, cb, delta: float):
	var flat: Vector3 = _table_approach() - cb.position
	flat.y = 0.0
	_meal.t = float(_meal.t) - delta
	if flat.length() > ARRIVE * 1.5:
		if _walking(cb) and float(_meal.t) > 0.0:
			return
		if int(_meal.tries) < WALK_TRIES and float(_meal.t) > 0.0 \
				and _walk_to(cb, _table_approach()):
			_meal.tries = int(_meal.tries) + 1
			return
		print("[Household %s] %s could not carry the food to the table" % [id, cook])
		_end_meal()
		return
	cb.steer_to = Vector3.INF
	cb.set_prop("")
	_seat_eaters()
	_meal.phase = "eating"
	_meal.t = EAT_S


## On the stove's side, where the food is set down.
func _table_approach() -> Vector3:
	var t: Dictionary = _meal.table
	var c: Vector3 = t.centre
	var d: Vector3 = _meal.stove.pos - c
	d.y = 0.0
	if d.length_squared() < 0.01:
		d = Vector3.FORWARD
	var p: Vector3 = c + d.normalized() * (1.1 * UNITS_PER_M)
	p.y = t.pos.y
	return p


## The first call of a meal takes one meal from the pantry.
func _seat_eaters():
	for pid in members():
		if _meal.eaters.has(pid) or not at_home(pid) or _controlled(pid) \
				or _ill.get(pid, false):
			continue
		if _using.has(pid) and pid != _meal.cook:
			release(pid)
		var seat := _spot_by("eat", pid)
		if seat.is_empty():
			continue
		if start_use(pid, "%s#eat" % seat.object) == "":
			_meal.eaters.append(pid)
			_place_bowl(_using[pid].spot)
	if pantry > 0 and not _meal.get("cooked", false):
		_meal.cooked = true
		pantry -= 1


func _place_bowl(seat: Dictionary):
	if _house == null or not ResourceLoader.exists(BOWL_SCENE):
		return
	var scene: PackedScene = load(BOWL_SCENE)
	if scene == null:
		return
	var bowl: Node3D = scene.instantiate()
	_house.add_child(bowl)
	var to: Vector3 = seat.centre - seat.pos
	to.y = 0.0
	var at: Vector3 = seat.pos + (to.normalized() * 0.35 * UNITS_PER_M \
			if to.length_squared() > 0.01 else Vector3.ZERO)
	at.y = float(seat.table_y)
	bowl.global_position = _manager.world().to_global(at)
	_bowls.append(bowl)


func _end_meal():
	var name := str(_meal.get("name", ""))
	var cook := str(_meal.get("cook", ""))
	# Copy: release() trims a meal's eaters.
	var ate: Array = _meal.get("eaters", []).duplicate()
	_meal = {}
	for pid in ate:
		var b = _body(pid)
		_manager.observe({"who": pid, "did": "ate", "place": "household:" + id, "meal": name,
			"with": ate.filter(func(o): return o != pid),
			"at": _manager.places.district_names_at(b.position) if b != null else []})
		release(pid)
		_idle_t[pid] = _rng.randf_range(IDLE_PICK_MIN, IDLE_PICK_MAX)
	var missed: Array = []
	for pid in members():
		if not ate.has(pid):
			missed.append(pid)
	if not missed.is_empty() and cook != "":
		_manager.observe({"who": cook, "missed_meal": missed, "meal": name, "household": id})
	if cook != "" and not ate.has(cook):
		release(cook)
	for bowl in _bowls:
		if bowl != null and is_instance_valid(bowl):
			bowl.queue_free()
	_bowls = []
	print("[Household %s] %s over: %d ate, %d missed it" % [id, name, ate.size(), missed.size()])


## Also when they come home; only within three hours of home_by + grace.
func _expectations(hour: float, day: int):
	for rid in def.get("expects", {}):
		var pid := _key(str(rid))
		var e: Dictionary = def.expects[rid]
		var by := float(e.get("home_by", 19.0))
		var grace := float(e.get("grace", 0.5))
		var key := "%d|expect|%s" % [day, pid]
		var home := at_home(pid)
		if _away.get(pid, false) and home:
			_away.erase(pid)
			_tell_guardians(pid, {"came_home": pid, "hour": snappedf(hour, 0.1),
				"household": id})
			continue
		if _done.has(key) or home:
			continue
		if hour >= by + grace and hour < by + grace + 3.0:
			_done[key] = true
			_away[pid] = true
			_tell_guardians(pid, {"worried": pid, "expected_by": by, "household": id})


func _tell_guardians(pid: String, fields: Dictionary):
	for g in guardians():
		if g != pid:
			var obs := {"who": g}
			obs.merge(fields)
			_manager.observe(obs)


## Recovery ends a held use.
func set_ill(pid: String, ill: bool):
	if ill:
		_ill[pid] = true
	else:
		_ill.erase(pid)
	for m in members():
		if m != pid:
			_manager.observe({"who": m, ("ill" if ill else "recovered"): pid, "household": id})
	if not ill and _using.has(pid) and bool(_using[pid].hold):
		release(pid)


func _care(delta: float):
	var patients: Array = []
	for pid in _ill:
		if _using.has(pid) and _using[pid].phase == "using":
			patients.append(pid)
	if patients.is_empty():
		return
	_care_t -= delta
	if _care_t > 0.0:
		return
	_care_t = CARE_EVERY_S
	for patient in patients:
		_send_carer(patient)


func _send_carer(patient: String):
	var bed: String = _using[patient].use.object
	for carer in members():
		if carer == patient or _using.has(carer) or _controlled(carer) or not at_home(carer) \
				or _ill.get(carer, false):
			continue
		if start_use(carer, "%s#care" % bed) == "":
			_using[carer]["patient"] = patient
			return


func _care_done(carer: String, u: Dictionary):
	var patient := str(u.get("patient", ""))
	if patient != "":
		_manager.observe({"who": patient, "cared_by": carer, "household": id})
		_manager.observe({"who": carer, "did": "care", "for": patient, "household": id})


## False when the house is empty.
func knock(pid: String) -> bool:
	var home := present()
	if home.is_empty():
		return false
	_guests[pid] = {"knocked": true, "welcomed": false, "since": 0.0, "out": 0.0}
	for m in home:
		_manager.observe({"who": m, "knock": pid, "household": id})
	return true


func welcome(host: String, guest: String) -> bool:
	if not member(host) or not at_home(host):
		return false
	var g = _guests.get(guest)
	if g == null or not bool(g.knocked):
		return false
	g.welcomed = true
	var b = _body(guest)
	var room := shared_room_pos()
	if b != null and room != Vector3.INF:
		b.position = room + Vector3.UP * 2.0
		b.velocity = Vector3.ZERO
		if b.has_method("play_door_sound"):
			b.play_door_sound()
		b.hold_idle(999999.0)
	_manager.observe({"who": guest, "welcomed_by": host, "household": id})
	_manager.observe({"who": host, "did": "welcome", "guest": guest, "household": id})
	return true


func leave(pid: String):
	release(pid)
	_guests.erase(pid)


func welcomed(pid: String) -> bool:
	return bool(_guests.get(pid, {}).get("welcomed", false))


## Unanswered knocks are forgotten after ten minutes.
func _guests_tick(delta: float):
	for pid in _guests.keys():
		var g: Dictionary = _guests[pid]
		g.since = float(g.since) + delta
		var b = _body(pid)
		if b == null:
			_guests.erase(pid)
			continue
		if bool(g.welcomed):
			g.out = (float(g.out) + delta) if not inside(b.position) else 0.0
			if float(g.out) > GUEST_LEAVES_S:
				release(pid)
				_guests.erase(pid)
		elif float(g.since) > 600.0:
			_guests.erase(pid)


func _groceries():
	for pid in members():
		var b = _body(pid)
		if b == null or not inside(b.position):
			continue
		if str(b.get("held_prop")) == "tote_bag" and not _using.has(pid):
			b.set_prop("")
			restock(int(def.get("groceries", 4)))
			_manager.observe({"who": pid, "did": "carry", "object": "groceries", "household": id,
				"pantry": pantry})


func restock(n: int):
	pantry = maxi(0, pantry + n)


## Uses and meals every frame, the rest every 2 s.
func tick(delta: float):
	if _house == null or not is_instance_valid(_house):
		return
	_drive_uses(delta)
	if not _meal.is_empty():
		_run_meal(delta)
	_scan_t -= delta
	if _scan_t > 0.0:
		return
	_scan_t = 2.0
	var hour := _hour()
	var day := _day()
	_meals(hour, day)
	_autonomy(2.0)
	_expectations(hour, day)
	_care(2.0)
	_guests_tick(2.0)
	_groceries()
