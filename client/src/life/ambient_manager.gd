class_name AmbientManager
extends Node

## Network messages this module handles: type -> method (see protocol/messages.json).
const MESSAGES := {
	"school_req": "handle_school_req",
	"life_cmd": "handle_life_cmd",
	"school_cmd": "handle_school_cmd",
	"household_cmd": "handle_household_cmd",
	"par": "handle_par",
	"res_plan": "handle_res_plan",
	"world_residents": "handle_world_residents",
	"world_clock": "handle_world_clock",
	"npc_say": "handle_npc_say",
	"rest_req": "handle_rest_req",
}

## Ambient life of a workspace: pedestrians, residents, traffic, trams, signals and places; the authority streams amb_state.

const PED_SCRIPT := "res://src/life/ambient_pedestrian.gd"
const RESIDENT_SCRIPT := "res://src/life/resident_npc.gd"

const DialogRegistry := preload("res://src/life/dialog/dialog_registry.gd")
const LayoutScript := preload("res://src/life/ambient_layout.gd")
const ZoneNavScript := preload("res://src/life/zone_nav.gd")
const WorldGeo := preload("res://src/world/region/world_geo.gd")
const ScheduleScript := preload("res://src/life/resident_schedule.gd")
const HOUSEHOLD_SCRIPT := preload("res://src/life/ambient_household.gd")

## Off: no people at all. Cars and trams have their own switches.
@export var npcs_enabled := true
@export var ped_count := 24
@export var car_count := 12
## The plain countryball is left out: it needs a texture that is not provided.
@export var ped_scene_paths: Array[String] = [
	"res://assets/entities/character/humanoid.tscn",
	"res://assets/entities/countryball/countryballoneside.tscn",
	"res://assets/entities/countryball_quincyform/countryball.tscn",
]
@export var ped_scene_weights: Array[float] = [3.0, 1.5, 1.5]
## Every .svg, .png or .tga in this folder.
@export var flag_dir := "res://assets/assets/flags/ambient"
## Workspace-local units, per leg.
@export var ped_wander_radius := 140.0
## The replicated `kind` indexes it: VehicleDefinition resources or .glb paths; empty = placeholders.
@export var car_model_paths: Array[String] = [
	"res://assets/entities/vehicles/definitions/red_sedan.tres",
	"res://assets/entities/vehicles/definitions/rooftop_glide.tres",
	"res://assets/entities/vehicles/definitions/silver_mercedes.tres",
	"res://assets/entities/vehicles/definitions/jpn_taxi.tres",
	"res://assets/entities/vehicles/definitions/luxury_sedan.tres",
	"res://assets/entities/vehicles/definitions/mint_mini.tres",
]
## Empty = equally likely; missing entries count as 1.
@export var car_weights: Array[float] = [5.0, 4.0, 1.0, 1.5, 1.0, 1.0]
## Degrees, for raw .glb entries only.
@export var car_model_yaw_deg: Array[float] = []
@export var car_speed_min := 9.0
@export var car_speed_max := 16.0
@export var car_accel := 8.0
@export var car_brake := 20.0
@export var car_look_ahead := 45.0
@export var car_lane_half_width := 5.5
@export var car_stop_gap := 10.0
## How far ahead a driver reads a bend, and the slowest fraction of cruise a sharp one allows.
@export var car_corner_lookahead := 34.0
@export var car_corner_min := 0.48
## One car holds the box, the others wait; ties go to the car closing from the left.
@export var crossing_box := 13.0
@export var crossing_watch := 42.0
## So a wedged car cannot lock a junction.
@export var crossing_claim_timeout := 9.0
@export var car_turn_chance := 0.28
## How far a turning car eases its heading round, and how much it slows.
@export var car_turn_arc := 18.0
@export var car_turn_speed := 0.38
## Degrees per second.
@export var car_max_turn_rate := 200.0
## Degrees per second; sets the speed limit on short, sharp connectors.
@export var car_junction_turn_rate := 75.0
@export var junction_dist := 45.0
## Seconds; phases are offset per intersection.
@export var green_time := 8.0
@export var all_red_time := 2.0
## Off when the scene places trafficlight props.
@export var spawn_signal_poles := false
@export var trams_enabled := true
@export var tram_model_path := "res://assets/art/models/vehicles/ambient_tram.glb"
@export var tram_model_yaw_deg := 0.0
@export var tram_length := 66.0
@export var tram_speed := 12.0
@export var tram_accel := 5.0
@export var tram_pause := 4.0
@export var scripted_greetings := false
## Answers "brain": "shisho" residents when offline.
@export var shisho_npc_url := "http://127.0.0.1:8765"
@export var npc_talk_radius := 12.0

var layout := LayoutScript.new()
var nav := ZoneNavScript.new()
var traffic := AmbientTraffic.new(self)
var places := AmbientPlaces.new(self)
var engagement := AmbientEngagement.new(self)
var replication := AmbientReplication.new(self)
## -1 = unknown / offline.
var authority_client_id := -1
var life_controller = null
var school_nav: BuildingNav = null  # once rooms are known

var _world: Node3D = null
var _container: Node3D = null
var _nc = null
var _is_authority := true
var _congestion_timer := 0.0
var _schedule_timer := 0.0
var _rng := RandomNumberGenerator.new()

var _peds: Dictionary = {}
var _residents: Dictionary = {}  # "r_<id>" -> body node
var _resident_defs: Dictionary = {}  # "r_<id>" -> JSON definition
var _flag_codes: Array = []
var _flag_sizes: Dictionary = {}  # flag code -> ball scale (flag_dir/sizes.json)
var _env_controller = null  # game clock
var _ped_scenes: Array = []
var _no_loiter: Array = []  # {"pos", "r"}: discs peds never pick as wander targets

var _scene_signals: Array = []  # {"pos","radius"} from the AmbientLayout node
var _sig_lamp_mats: Array = []  # per signal: [group0 material, group1 material]
var _sig_visual_root: Node3D = null
var _sig_visual_timer := 0.0

# Sorted smallest first, so the most specific name comes first.
var _district_timer := 0.0
var _district_current := ""
var _district_label: Label = null
var _district_tween: Tween = null

# Each place's state rides amb_state in its own section:
var _event_director = null  # "evt"
var _households: Dictionary = {}
var _household_defs: Dictionary = {}

# One break's kickabout goes to one room; one bell rings for all rooms.
var _pitch_turn := -1
var _pitch_turn_msec := -1000000
var _bell_msec := -100000

var _clock_weekday := -1
var _clock_day := -1
var _clock_mode := ""
var _obs_queue: Array = []  # observations for the mind, flushed once a second
var _obs_timer := 0.0
var _obs_near: Dictionary = {}  # resident key -> "player:<name>" in talk radius
var _obs_company: Dictionary = {}  # resident key -> joined ids of residents beside them
var _reported_client_id := -1  # world_places sent for this connection
var _report_dirty := false  # something registered after the report
var _report_timer := 0.0

# Replicated as "pc"/"pl".
var _call: Dictionary = {}
var _call_timer := 45.0

# Derived from replicated positions on every peer.
var _greet_cd: Dictionary = {}
var _greet_scan := 0.0
var _greet_pending: Array = []

# Refreshed at most every 100 ms.
var _people_global: Array = []
var _people_local: Array = []
var _vehicle_points_local: Array = []
var _people_cache_ms := 0

var _shisho_http: HTTPRequest = null
var _shisho_busy := false
var _shisho_pending_id := ""


func _ready():
	_rng.randomize()
	life_controller = preload("res://src/life/resident_life.gd").new(self)
	_world = get_parent() as Node3D
	if _world == null:
		push_warning("[AmbientManager] Parent is not a Node3D — disabled")
		set_process(false)
		set_physics_process(false)
		return

	for path in ped_scene_paths:
		var scene = load(path)
		if scene:
			_ped_scenes.append(scene)

	_container = Node3D.new()
	_container.name = "AmbientBodies"
	_world.add_child.call_deferred(_container)

	_flag_codes = _scan_flags()
	_flag_sizes = _load_flag_sizes()
	_resident_defs = _load_resident_defs()
	_household_defs = _load_household_defs()

	layout.load_from(workspace_name())
	_refresh_from_scene()
	traffic.lane_graph.junction_dist = junction_dist
	_build_from_layout()

	call_deferred("_find_schools")
	places.find_parliaments.call_deferred()
	call_deferred("_find_households")
	_nc = get_node_or_null("/root/NetworkController")
	if _nc == null:
		print("[AmbientManager] No NetworkController — offline, local authority")
		_set_authority(true)
	else:
		_set_authority(not _nc.connected)

	if _is_authority:
		call_deferred("_populate")

	print("[AmbientManager] zones=%d lanes=%d trams=%d signals=%d (layout '%s')" %
		[layout.zones.size(), layout.lanes.size(), traffic.tram_lines().size(),
		_scene_signals.size(), workspace_name()])


func world() -> Node3D:
	return _world


## Where ambient bodies are parented.
func container() -> Node3D:
	return _container


func is_authority() -> bool:
	return _is_authority


## Shared by everything ambient, so the draw order stays fixed.
func rng() -> RandomNumberGenerator:
	return _rng


func workspace_name() -> String:
	return str(_world.name) if _world else "workspace"


## Wins over the JSON layout. False when the scene has none.
func _refresh_from_scene() -> bool:
	if _world == null:
		return false
	var node = _world.get_node_or_null("AmbientLayout")
	if node != null and node.has_method("zones"):
		layout.zones = node.zones()
		layout.lanes = node.lanes()
		if node.has_method("signals_data"):
			_scene_signals = node.signals_data()
		return true
	return false


## From sizes.json beside the flags.
func _load_flag_sizes() -> Dictionary:
	var f := FileAccess.open(flag_dir.path_join("sizes.json"), FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var out := {}
	for k in parsed.get("sizes", {}):
		out[str(k)] = float(parsed.sizes[k])
	return out


## Reads .import stubs too, for exported builds.
func _scan_flags() -> Array:
	var out := []
	var dir := DirAccess.open(flag_dir)
	if dir == null:
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir():
			_add_flag_code(out, f)
		f = dir.get_next()
	return out


func _add_flag_code(out: Array, file_name: String):
	var name := file_name.trim_suffix(".import")
	if not (name.get_extension() in ["svg", "png", "tga"]):
		return
	var code := name.get_basename()
	if not out.has(code):
		out.append(code)


## user:// first, then the bundled copy; "" when there is none.
func _residents_json_path() -> String:
	var path := "user://ambient_residents/%s.json" % workspace_name()
	if not FileAccess.file_exists(path):
		path = "res://assets/entities/ambient/residents/%s.json" % workspace_name()
	if not FileAccess.file_exists(path):
		return ""
	return path


## Keyed "r_<id>".
func _load_resident_defs() -> Dictionary:
	var out := {}
	var path := _residents_json_path()
	if path == "":
		return out
	var fh := FileAccess.open(path, FileAccess.READ)
	if fh == null:
		return out
	var parsed = JSON.parse_string(fh.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[AmbientManager] Bad residents JSON: " + path)
		return out
	for entry in parsed.get("residents", []):
		if typeof(entry) == TYPE_DICTIONARY and str(entry.get("id", "")) != "":
			out["r_" + str(entry.id)] = entry
	return out


## "households" in the residents JSON: the seed and the offline fallback.
func _load_household_defs() -> Dictionary:
	var path := _residents_json_path()
	if path == "":
		return {}
	var fh := FileAccess.open(path, FileAccess.READ)
	if fh == null:
		return {}
	var parsed = JSON.parse_string(fh.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return _household_defs_from(parsed.get("households", {}))


## From {id: def} or a list of defs carrying "id".
static func _household_defs_from(raw) -> Dictionary:
	var out := {}
	if typeof(raw) == TYPE_DICTIONARY:
		for id in raw:
			if typeof(raw[id]) == TYPE_DICTIONARY:
				out[str(id)] = raw[id]
	elif typeof(raw) == TYPE_ARRAY:
		for def in raw:
			if typeof(def) == TYPE_DICTIONARY and str(def.get("id", "")) != "":
				out[str(def.id)] = def
	return out


func _find_households():
	if _world == null:
		return
	var before: Array = _households.keys()
	before.sort()
	for hh in _households.values():
		for pid in hh._using.keys():
			hh.release(pid)
	_households = {}
	for id in _household_defs:
		_bind_household(str(id), _household_defs[id])
	# Report the places again only when the set of homes changed.
	var after: Array = _households.keys()
	after.sort()
	if after != before:
		mark_report_dirty(2.0)


func _bind_household(id: String, def: Dictionary):
	var house_name := str(def.get("house", ""))
	var house = _world.find_child(house_name, true, false) if house_name != "" else null
	if house == null or not (house is Node3D):
		push_warning("[AmbientManager] household '%s': house '%s' is not in the world" % [id, house_name])
		return
	var hh = HOUSEHOLD_SCRIPT.new(self, id, def)
	if not hh.bind(house):
		push_warning("[AmbientManager] household '%s': '%s' has no usable furniture (object.json uses)" % [id, house_name])
		return
	_households[id] = hh
	# A lift in the house is the way in and out for everyone.
	for elevator in get_tree().get_nodes_in_group("elevators"):
		if house.is_ancestor_of(elevator) and "FLOORS" in elevator:
			hh.lift = elevator
	print("[AmbientManager] household '%s' in %s: %d members, %d uses, door %s, lift %s" %
		[id, house_name, hh.members().size(), hh._spots.size(), "ok" if hh.door_pos() != Vector3.INF else "MISSING",
		str(hh.lift.elevator_id) if hh.lift != null else "none"])


func mark_report_dirty(delay: float):
	_report_dirty = true
	_report_timer = delay


## The bodies standing in it are left out.
func _build_interior_nav(hh):
	if _world == null or not _world.is_inside_tree():
		return
	var space := _world.get_world_3d().direct_space_state
	if space == null:
		return
	var exclude: Array = []
	for pool in [_residents, _peds]:
		for body in pool.values():
			if body != null and is_instance_valid(body) and body is CollisionObject3D:
				exclude.append(body.get_rid())
	hh.build_nav(space, exclude)


## Empty unless both ends are on it; the caller falls back to the street or the door.
func interior_route(from_local: Vector3, to_local: Vector3) -> PackedVector3Array:
	for hh in _households.values():
		var nav = hh.nav
		if nav == null or not nav.built or not nav.covers(from_local) or not nav.covers(to_local) \
				or absf(from_local.y - nav.floor_y) > 8 or absf(to_local.y - nav.floor_y) > 8:
			continue
		if not nav.walkable(from_local) and nav.snap_pos(from_local).distance_to(from_local) > 6.0:
			continue
		return nav.route(from_local, to_local)
	return PackedVector3Array()


func household_ground_route(from: Vector3, to: Vector3) -> Dictionary:
	for hh in _households.values():
		if hh.lift != null and is_instance_valid(hh.lift) and hh.lift.has_method("ground_route"):
			var result: Dictionary = hh.lift.ground_route(_world, nav, from, to)
			if not result.is_empty():
				return result
	return {}


func restaurant_route(from: Vector3, to: Vector3) -> Dictionary:
	for place in places.restaurants + places.shops:
		if is_instance_valid(place) and place.has_method("route_between"):
			var result: Dictionary = place.route_between(from, to)
			if not result.is_empty(): return result
	return {}


## {"pos": approach, "ride": "<lift>/<floor>"}, or {} when no lift applies.
func household_lift_leg(body, dest: Vector3) -> Dictionary:
	if _world == null:
		return {}
	for hh in _households.values():
		var lift = hh.lift
		if lift == null or not is_instance_valid(lift) or lift.FLOORS.size() < 2:
			continue
		var dest_in: bool = hh.inside(dest)
		var body_in: bool = hh.inside(body.position)
		if dest_in == body_in:
			continue
		var to: int = lift.nearest_floor(lift.to_local(_world.to_global(dest)).y)
		var from: int = lift.nearest_floor(lift.to_local(_world.to_global(body.position)).y)
		if from == to:
			continue
		return {"pos": _world.to_local(lift.approach_global(from)), "ride": str(lift.elevator_id) + "/" + str(to)}
	return {}


func interior_snap(pos_local: Vector3) -> Vector3:
	for hh in _households.values():
		if hh.nav != null and hh.nav.built and absf(pos_local.y - hh.nav.floor_y) < 8 \
				and hh.nav.covers(pos_local) and not hh.nav.walkable(pos_local):
			return hh.nav.snap_pos(pos_local)
	return pos_local


func household_of(pid: String):
	for hh in _households.values():
		if hh.member(pid):
			return hh
	return null


func households() -> Array:
	return _households.values()


func household_release(pid: String):
	for hh in _households.values():
		if hh._using.has(pid):
			hh.release(pid)


## {"cmd": "ill"|"well"|"restock", "id": "r_…" | "household": id, "n": meals}
func handle_household_cmd(data: Dictionary):
	if not _is_authority:
		return
	match str(data.get("cmd", "")):
		"ill", "well":
			var pid := str(data.get("id", ""))
			var hh = household_of(pid)
			if hh != null:
				hh.set_ill(pid, str(data.cmd) == "ill")
		"restock":
			var hh = _households.get(str(data.get("household", "")))
			if hh != null:
				hh.restock(int(data.get("n", 4)))


func _find_env_controller():
	if _env_controller == null or not is_instance_valid(_env_controller):
		_env_controller = _world.find_child("EnvironmentController", true, false) if _world else null


## 0-24 from the EnvironmentController, OS clock fallback.
func current_hour() -> float:
	_find_env_controller()
	if _env_controller != null:
		return float(_env_controller.current_time) * 24.0
	var t := Time.get_time_dict_from_system()
	return float(t.hour) + float(t.minute) / 60.0


func weather_controller():
	return _world.find_child("WeatherController", true, false) if is_instance_valid(_world) else null


func current_weather() -> String:
	var weather = weather_controller()
	return weather.current_type() if weather != null else "clear"


func weather_at(global_point: Vector3) -> String:
	var weather = weather_controller()
	if weather != null and weather.has_method("type_at"):
		return weather.type_at(global_point)
	return current_weather()


static func _is_flagged_path(path: String) -> bool:
	return path.contains("countryballoneside") or path.contains("countryball_quincyform")


func _build_from_layout():
	nav.build(layout.zones)
	traffic.build(layout.lanes, _scene_signals)
	_rebuild_signal_visuals()
	places.build_districts()


func _update_district_popup(delta):
	if places.districts.is_empty():
		return
	_district_timer -= delta
	if _district_timer > 0.0:
		return
	_district_timer = 0.5
	if _nc == null or not is_instance_valid(_nc.players.local_player):
		return
	var names := places.district_names_at(_world.to_local(_nc.players.local_player.global_position))
	var display := ""
	if not names.is_empty():
		display = names[0] if names.size() == 1 else "%s, %s" % [names[0], names[names.size() - 1]]
	if display == _district_current:
		return
	_district_current = display
	if display == "":
		return
	_ensure_district_label()
	_district_label.text = display
	if _district_tween != null and _district_tween.is_valid():
		_district_tween.kill()
	_district_label.modulate.a = 0.0
	_district_label.visible = true
	_district_tween = create_tween()
	_district_tween.tween_property(_district_label, "modulate:a", 1.0, 0.5)
	_district_tween.tween_interval(3.0)
	_district_tween.tween_property(_district_label, "modulate:a", 0.0, 1.0)


func _ensure_district_label():
	if _district_label != null and is_instance_valid(_district_label):
		return
	var layer := CanvasLayer.new()
	layer.layer = 60
	add_child(layer)
	_district_label = Label.new()
	_district_label.anchor_top = 1.0
	_district_label.anchor_bottom = 1.0
	_district_label.anchor_left = 0.0
	_district_label.anchor_right = 1.0
	_district_label.offset_top = -140.0
	_district_label.offset_bottom = -80.0
	_district_label.offset_left = 40.0
	_district_label.offset_right = -40.0
	_district_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_district_label.add_theme_font_size_override("font_size", 42)
	_district_label.add_theme_color_override("font_color", Color(1.0, 0.98, 0.9))
	_district_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_district_label.add_theme_constant_override("outline_size", 10)
	layer.add_child(_district_label)


func rebuild():
	_refresh_from_scene()
	_build_from_layout()
	if _is_authority:
		_populate()
		for id in _peds:
			var ped = _peds[id]
			if is_instance_valid(ped):
				ped.enter_idle()
		traffic.reseat()


func _populate():
	if _container == null or not is_instance_valid(_container):
		return
	var want_peds: int = ped_count if npcs_enabled and not nav.is_empty() else 0
	for i in want_peds:
		var id := "p%d" % i
		if not _peds.has(id) or not is_instance_valid(_peds[id]):
			spawn_ped(id, _pick_ped_kind(), nav.random_point(_rng))
	trim_pool("p", _peds, want_peds)
	traffic.populate()
	_sync_residents()


## Bodies whose definition is gone are freed.
func _sync_residents():
	var hour := current_hour()
	var day := current_day()
	var weekday := current_weekday()
	for id in _resident_defs:
		var def: Dictionary = _resident_defs[id]
		var present: bool = _residents.has(id) and is_instance_valid(_residents[id])
		var wanted: bool = npcs_enabled and ScheduleScript.on_the_map(def, str(id), hour, day, weekday)
		if wanted and not present:
			_spawn_resident(id, def)
		elif present and not wanted:
			_residents[id].queue_free()
			_residents.erase(id)
	for id in _residents.keys():
		if not _resident_defs.has(id):
			if is_instance_valid(_residents[id]):
				_residents[id].queue_free()
			_residents.erase(id)


## Replaces every person definition except scripted ones (staff, event cast); bodies re-plan in place.
func handle_world_residents(data: Dictionary):
	if not _is_authority:
		return
	var incoming = data.get("residents", [])
	if typeof(incoming) != TYPE_ARRAY:
		return
	var defs := {}
	for key in _resident_defs:
		if str(_resident_defs[key].get("script", "")) != "":
			defs[key] = _resident_defs[key]
	var changed := 0
	for entry in incoming:
		if typeof(entry) != TYPE_DICTIONARY or str(entry.get("id", "")) == "":
			continue
		var key := "r_" + str(entry.id)
		defs[key] = entry
		if _redefine_body(_residents.get(key), entry):
			changed += 1
	_resident_defs = defs
	_sync_residents()
	# Rebind only on change: each rebind re-reports, and the server answers a report with residents again.
	if data.has("households"):
		var incoming_hh := _household_defs_from(data.get("households"))
		if incoming_hh != _household_defs:
			_household_defs = incoming_hh
			call_deferred("_find_households")
	print("[AmbientManager] residents from server: %d persons (%d updated in place), %d households" % [incoming.size(), changed, _household_defs.size()])


## True when it differed.
func _redefine_body(body, entry: Dictionary) -> bool:
	if body == null or not is_instance_valid(body) or body.get("resident_def") == null:
		return false
	if body.resident_def == entry:
		return false
	body.resident_def = entry
	if entry.has("speed"):
		body.walk_speed = float(entry.speed)
	if "arms_pose" in body:
		body.arms_pose = str(entry.get("pose", ""))
	if body.has_method("set_outfit"):
		body.set_outfit(str(entry.get("skin", "")), entry.get("accessories", []))
	if body.has_method("replan_today"):
		body.replan_today()
	return true


## Steering separates ambient bodies, so a jam can always dissolve; they still hit the world and players.
func _no_collide(body):
	if not (body is PhysicsBody3D):
		return
	for pool in [_peds, _residents]:
		for id in pool:
			var other = pool[id]
			if other == null or not is_instance_valid(other) or other == body \
					or not (other is PhysicsBody3D):
				continue
			body.add_collision_exception_with(other)
			other.add_collision_exception_with(body)


## Frees the bodies numbered `want` and up; returns their ids.
func trim_pool(prefix: String, pool: Dictionary, want: int) -> Array:
	var removed := []
	for id in pool.keys():
		var idx := int(str(id).substr(prefix.length()))
		if idx >= want:
			if is_instance_valid(pool[id]):
				pool[id].queue_free()
			pool.erase(id)
			removed.append(id)
	return removed


func _pick_ped_kind() -> int:
	var total := 0.0
	for i in _ped_scenes.size():
		total += _weight(i)
	var roll := _rng.randf() * maxf(total, 0.001)
	for i in _ped_scenes.size():
		roll -= _weight(i)
		if roll <= 0.0:
			return i
	return 0


func _weight(i: int) -> float:
	return ped_scene_weights[i] if i < ped_scene_weights.size() else 1.0


func _random_flag() -> String:
	return _flag_codes[_rng.randi_range(0, _flag_codes.size() - 1)]


## Web builds stream packs: retry once `path` is mounted. True when deferred.
func defer_until_mounted(path: String, tag: String, pool: Dictionary, id: String,
		retry: Callable) -> bool:
	var pm = get_node_or_null("/root/PCKManager")
	if pm == null or not pm.has_method("when_available"):
		return false
	pm.when_available(path, func():
		if not pool.has(id) or not is_instance_valid(pool.get(id)):
			retry.call(), tag)
	return true


func _init_ped_body(body, id: String, kind: int, flag: String):
	body.name = "Amb_" + id
	body.ped_id = id
	body.kind = kind
	body.manager = self
	body.flag_code = flag
	body.flag_dir = flag_dir
	body.flag_scale = float(_flag_sizes.get(flag, 1.0)) if flag != "" else 1.0


func _place_body(body, pos: Vector3, authority: bool, pool: Dictionary, id: String):
	_container.add_child(body)
	body.position = pos
	body.set_authority(authority)
	pool[id] = body
	_no_collide(body)


func spawn_ped(id: String, kind: int, pos: Vector3, flag := "", skin := ""):
	if not npcs_enabled:
		return
	if _ped_scenes.is_empty() or _container == null or not _container.is_inside_tree():
		return
	var scene: PackedScene = _ped_scenes[kind % _ped_scenes.size()]
	var scene_path: String = ped_scene_paths[kind % ped_scene_paths.size()]
	var body = scene.instantiate()
	body.set_script(load(PED_SCRIPT))
	# The authority picks the flag; it replicates so every peer shows the same.
	if flag == "" and _is_authority and _is_flagged_path(scene_path) and not _flag_codes.is_empty():
		flag = _random_flag()
	_init_ped_body(body, id, kind, flag)
	# Only residents carry clothing; anonymous pedestrians mirror theirs.
	body.skin_path = skin
	_place_body(body, pos + Vector3.UP * 2.0, _is_authority, _peds, id)


## Its own scene (waiting for the pack when streamed), else a pedestrian scene.
func _spawn_resident(id: String, def: Dictionary):
	if not npcs_enabled:
		return
	if _container == null or not _container.is_inside_tree():
		return
	var scene_path := str(def.get("scene", ""))
	var scene: PackedScene = null
	if scene_path != "":
		if not ResourceLoader.exists(scene_path) and defer_until_mounted(scene_path,
				"resident:" + id, _residents, id, _spawn_resident.bind(id, def)):
			return
		scene = load(scene_path)
		if scene == null:
			push_warning("[AmbientManager] Resident scene missing: " + scene_path)
	var kind := int(def.get("kind", 0))
	if scene == null:
		if _ped_scenes.is_empty():
			return
		scene = _ped_scenes[kind % _ped_scenes.size()]
		scene_path = ped_scene_paths[kind % ped_scene_paths.size()]
	var body = scene.instantiate()
	# Service peds (restaurant waiters) bring their own script.
	body.set_script(load(str(def.get("script", RESIDENT_SCRIPT))))
	var flag := str(def.get("flag", ""))
	if flag == "" and _is_flagged_path(scene_path) and not _flag_codes.is_empty():
		flag = _random_flag()
	_init_ped_body(body, id, kind, flag)
	body.resident_def = def
	body.custom_character_dir = str(def.get("anim_dir", ""))
	body.skin_path = str(def.get("skin", ""))
	var acc = def.get("accessories", [])
	if typeof(acc) == TYPE_ARRAY:
		body.accessory_paths = acc
	body.arms_pose = str(def.get("pose", ""))
	_place_body(body, _resident_start_pos(def) + Vector3.UP * 2.0, _is_authority, _residents, id)


## spawn_pos, an extra's home spot, the first routine entry, else a random walkable point.
func _resident_start_pos(def: Dictionary) -> Vector3:
	var sp = def.get("spawn_pos", null)
	if typeof(sp) == TYPE_ARRAY and sp.size() >= 3:
		return Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
	if ScheduleScript.is_extra(def):
		var home: Vector3 = ScheduleScript.home_pos(def)
		if home != Vector3.INF:
			return home
	var routine = def.get("routine", [])
	if typeof(routine) == TYPE_ARRAY and routine.size() > 0:
		var p = routine[0].get("pos", null)
		if typeof(p) == TYPE_ARRAY and p.size() >= 3:
			return Vector3(float(p[0]), float(p[1]), float(p[2]))
	return nav.random_point(_rng) if not nav.is_empty() else Vector3.ZERO


## True when a shop took them in.
func request_shop(body, place: String) -> bool:
	for s in places.shops:
		if s != null and is_instance_valid(s) and (place == "" or s.key() == place):
			if s.request_visit(body):
				return true
	return false


## A resident definition with the same key wins; the defaults only fill what it lacks.
func add_service_ped(key: String, defaults: Dictionary):
	var def: Dictionary = _resident_defs.get(key, {})
	for k in defaults:
		if not def.has(k):
			def[k] = defaults[k]
	_resident_defs[key] = def
	if not _is_authority:
		return
	# A body spawned before the service registered has the wrong script.
	var existing = _residents.get(key)
	if existing != null and is_instance_valid(existing):
		var scr = existing.get_script()
		if scr == null or scr.resource_path != str(def.get("script", RESIDENT_SCRIPT)):
			existing.queue_free()
			_residents.erase(key)
	if not _residents.has(key) or not is_instance_valid(_residents.get(key)):
		_spawn_resident(key, def)


func register_event_director(d):
	_event_director = d


## Walking through the disc is fine.
func add_no_loiter(pos_local: Vector3, radius: float):
	_no_loiter.append({"pos": pos_local, "r": radius})


func _in_no_loiter(p: Vector3) -> bool:
	for d in _no_loiter:
		var dp: Vector3 = p - d.pos
		dp.y = 0.0
		if dp.length() <= float(d.r):
			return true
	return false


func remove_service_ped(key: String):
	_resident_defs.erase(key)
	var body = _residents.get(key)
	if body != null and is_instance_valid(body):
		body.queue_free()
	_residents.erase(key)


func vehicle_positions_local() -> Array:
	_refresh_people_cache()
	return _vehicle_points_local


## The plain pedestrian script: no routine logic runs off-authority.
func spawn_resident_remote(id: String, scene_path: String, kind: int, flag: String, pos: Vector3):
	if not npcs_enabled:
		return
	var scene: PackedScene = null
	if scene_path != "":
		scene = load(scene_path)
	if scene == null:
		if _ped_scenes.is_empty():
			return
		scene = _ped_scenes[kind % _ped_scenes.size()]
		scene_path = ped_scene_paths[kind % ped_scene_paths.size()]
	if _container == null or not _container.is_inside_tree():
		return
	var body = scene.instantiate()
	body.set_script(load(PED_SCRIPT))
	_init_ped_body(body, id, kind, flag)
	_place_body(body, pos, false, _residents, id)


func _physics_process(delta):
	engagement.addressee_tick(delta)
	# Demoted and disconnected: nobody will stream to us, so take over.
	if not _is_authority and (_nc == null or not _nc.connected):
		_set_authority(true)
		if _peds.is_empty() and traffic.is_empty():
			_populate()
		else:
			_adopt_bodies()

	if _is_authority:
		_authority_tick(delta)
	else:
		replication.receive_tick(delta)

	_sig_visual_timer += delta
	if _sig_visual_timer >= 0.25:
		_sig_visual_timer = 0.0
		_update_signal_visuals()

	_update_district_popup(delta)
	_run_greetings(delta)


func _authority_tick(delta):
	engagement.scan(delta)
	life_controller.tick(delta)
	for hh in _households.values():
		if hh.nav == null:
			_build_interior_nav(hh)
		hh.tick(delta)
	_schedule_timer += delta
	if _schedule_timer >= 5.0:
		_schedule_timer = 0.0
		_sync_residents()
	traffic.simulate(delta)
	_run_phone_calls(delta)
	_congestion_timer += delta
	if _congestion_timer >= 0.5:
		_congestion_timer = 0.0
		nav.update_congestion(people_positions_local())
	replication.send_tick(delta)
	_obs_timer += delta
	if _obs_timer >= 1.0:
		_obs_timer = 0.0
		_obs_scan()
		_flush_observations()
	_tick_world_report(delta)


func _tick_world_report(delta):
	if not _report_dirty:
		return
	_report_timer -= delta
	if _report_timer <= 0.0:
		_report_dirty = false
		if _reported_client_id >= 0:
			_report_world()


## At most every 100 ms, so one gather serves every query of the frame.
func _refresh_people_cache():
	var now := Time.get_ticks_msec()
	if now - _people_cache_ms < 100:
		return
	_people_cache_ms = now
	_people_global = _gather_people_positions()
	_people_local = []
	_vehicle_points_local = []
	if _world:
		for p in _people_global:
			_people_local.append(_world.to_local(p))
		for pt in traffic.external_points():
			_vehicle_points_local.append(_world.to_local(pt.global_position))


func people_positions_global() -> Array:
	_refresh_people_cache()
	return _people_global


func people_positions_local() -> Array:
	_refresh_people_cache()
	return _people_local


## A player in a vehicle counts as the vehicle (register_vehicle).
func _gather_people_positions() -> Array:
	var out := []
	for pool in [_peds, _residents]:
		for id in pool:
			var ped = pool[id]
			if ped != null and is_instance_valid(ped):
				out.append(ped.global_position)
	if _nc and is_instance_valid(_nc.players.local_player) and not _in_vehicle(_nc.players.local_player):
		out.append(_nc.players.local_player.global_position)
	for p in remote_player_nodes():
		if not _in_vehicle(p):
			out.append(p.global_position)
	return out


func remote_player_nodes() -> Array:
	var out := []
	if _world == null:
		return out
	var players = _world.get_node_or_null("Players")
	if players == null:
		return out
	for p in players.get_children():
		if p is Node3D:
			out.append(p)
	return out


func _in_vehicle(p: Node) -> bool:
	return bool(p.get("_in_vehicle")) if "_in_vehicle" in p else false


## 0 = group 0 go, 1 = group 0 amber, 2 = group 1 go, 3 = group 1 amber; offset per signal.
func computed_phase(sig: int) -> int:
	var period := 2.0 * (green_time + all_red_time)
	var t := fposmod(Time.get_ticks_msec() / 1000.0 + float(sig) * 3.7, period)
	if t < green_time:
		return 0
	if t < green_time + all_red_time:
		return 1
	if t < 2.0 * green_time + all_red_time:
		return 2
	return 3


## Remote peers use the replicated phases, so lamps and traffic agree.
func _current_phase(sig: int) -> int:
	if not _is_authority and sig < replication.remote_sigs.size():
		return int(replication.remote_sigs[sig])
	return computed_phase(sig)


## 0, 1, or -1 during amber (cars treat it as stop).
func green_group(sig: int) -> int:
	match _current_phase(sig):
		0:
			return 0
		2:
			return 1
	return -1


## Else -1.
func nearest_signal(pos_local: Vector3) -> int:
	var best := -1
	var best_d := INF
	for s in _scene_signals.size():
		var sig: Dictionary = _scene_signals[s]
		var d: float = pos_local.distance_to(sig.get("pos", Vector3.ZERO))
		if d <= float(sig.get("radius", 60.0)) * 1.25 and d < best_d:
			best_d = d
			best = s
	return best


## `dir` is workspace-local and flat.
func group_for_facing(sig: int, dir: Vector3) -> int:
	return traffic.lane_graph.group_for_heading(sig, dir)


## 0 = go, 1 = prepare/amber, 2 = stop.
func signal_phase_for_group(sig: int, group: int) -> int:
	var phase := _current_phase(sig)
	if phase == group * 2:
		return 0
	if phase == group * 2 + 1:
		return 1
	return 2


## Left lamp for group 0, right for group 1.
func _rebuild_signal_visuals():
	if _sig_visual_root != null and is_instance_valid(_sig_visual_root):
		_sig_visual_root.queue_free()
	_sig_visual_root = null
	_sig_lamp_mats = []
	if not spawn_signal_poles or _scene_signals.is_empty() or _world == null:
		return
	_sig_visual_root = Node3D.new()
	_sig_visual_root.name = "AmbientSignals"
	_world.add_child.call_deferred(_sig_visual_root)

	var pole_mesh := BoxMesh.new()
	pole_mesh.size = Vector3(1.0, 24.0, 1.0)
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.2, 0.2, 0.22)
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(3.0, 3.0, 3.0)

	for s in _scene_signals.size():
		var sig: Dictionary = _scene_signals[s]
		var pos: Vector3 = sig.get("pos", Vector3.ZERO)
		var pole := MeshInstance3D.new()
		pole.mesh = pole_mesh
		pole.material_override = pole_mat
		pole.position = pos + Vector3.UP * 12.0
		_sig_visual_root.add_child(pole)
		var mats := []
		for g in 2:
			mats.append(_add_signal_lamp(lamp_mesh, pos + Vector3.UP * 26.0 + Vector3(-2.0 + 4.0 * g, 0, 0)))
		_sig_lamp_mats.append(mats)


func _add_signal_lamp(mesh: Mesh, pos: Vector3) -> StandardMaterial3D:
	var lamp := MeshInstance3D.new()
	lamp.mesh = mesh
	var m := StandardMaterial3D.new()
	m.emission_enabled = true
	lamp.material_override = m
	lamp.position = pos
	_sig_visual_root.add_child(lamp)
	return m


func _update_signal_visuals():
	for s in _sig_lamp_mats.size():
		var green := green_group(s)
		var mats: Array = _sig_lamp_mats[s]
		for g in 2:
			var m: StandardMaterial3D = mats[g]
			var lit: bool = green == g
			var color := Color(0.15, 0.9, 0.2) if lit else Color(0.9, 0.12, 0.1)
			m.albedo_color = color
			m.emission = color
			m.emission_energy_multiplier = 2.5 if lit else 1.2


## Authority only; a new call every 90-240 s.
func _run_phone_calls(delta):
	if not _call.is_empty():
		_advance_call(delta)
		return
	_call_timer -= delta
	if _call_timer > 0.0:
		return
	_call_timer = _rng.randf_range(90.0, 240.0)
	var ids := []
	for id in _peds:
		var p = _peds[id]
		if p != null and is_instance_valid(p) and not p.sitting \
				and p.errand_owner == null and not p.calling:
			ids.append(id)
	if ids.is_empty():
		return
	var chosen: String = ids[_rng.randi_range(0, ids.size() - 1)]
	_call = {"ped": chosen, "conv": "phone_walk_1", "idx": -1, "t": 1.5}
	_peds[chosen].set_call("phone_walk_1", -1)


func _advance_call(delta):
	var ped = _peds.get(str(_call.ped))
	if ped == null or not is_instance_valid(ped) or ped.sitting:
		_end_call()
		return
	_call.t = float(_call.t) - delta
	if float(_call.t) > 0.0:
		return
	var entries: Array = DialogRegistry.conv(str(_call.conv))
	var idx := int(_call.idx) + 1
	if idx >= entries.size():
		_end_call()
		return
	_call.idx = idx
	_call.t = float(entries[idx].get("gap", 4.0))
	ped.set_call(str(_call.conv), idx)


func _end_call():
	var ped = _peds.get(str(_call.get("ped", "")))
	if ped != null and is_instance_valid(ped):
		ped.set_call("", -1)
	_call = {}


## Within 9 units, at most once per pair every 4 minutes.
func _run_greetings(delta):
	if not scripted_greetings:
		return
	for i in range(_greet_pending.size() - 1, -1, -1):
		var g: Dictionary = _greet_pending[i]
		g.t = float(g.t) - delta
		if float(g.t) <= 0.0:
			var reply_body = g.body
			if reply_body != null and is_instance_valid(reply_body):
				reply_body.say_line("greet_a", 4.0)
			_greet_pending.remove_at(i)
	_greet_scan += delta
	if _greet_scan < 0.7:
		return
	_greet_scan = 0.0
	var now := Time.get_ticks_msec()
	var keys: Array = _residents.keys()
	for i in keys.size():
		var a = _residents[keys[i]]
		if not _can_greet(a):
			continue
		for j in range(i + 1, keys.size()):
			_greet_pair(a, keys[i], keys[j], now)


func _can_greet(body) -> bool:
	return body != null and is_instance_valid(body) and not body.sitting \
			and not off_map(body) and not in_classroom(body)


func _greet_pair(a, key_a, key_b, now: int):
	var b = _residents[key_b]
	if not _can_greet(b) or a.position.distance_to(b.position) > 9.0:
		return
	var pair := "%s|%s" % [key_a, key_b]
	if now - int(_greet_cd.get(pair, -1000000)) < 240000:
		return
	_greet_cd[pair] = now
	a.say_line("greet_q", 4.0)
	_greet_pending.append({"body": b, "t": 1.8})


## {"id", "line", "secs"} plays a registry line; with "text" (optional base64 WAV "audio", "to") free text.
func handle_npc_say(data: Dictionary):
	var id := str(data.get("id", ""))
	var body = _peds.get(id)
	if body == null:
		body = _residents.get(id)
	if body == null:
		body = _residents.get("r_" + id)
	if body == null or not is_instance_valid(body):
		return
	var raw := str(data.get("text", ""))
	if raw != "":
		_say_free_text(body, raw, data)
		return
	body.say_line(str(data.get("line", "")), float(data.get("secs", 5.0)))


## A teacher in class also writes it on the board.
func _say_free_text(body, raw: String, data: Dictionary):
	var secs: float = clampf(3.0 + raw.length() * 0.12, 4.0, 20.0)
	var wav: AudioStreamWAV = null
	if body.has_method("play_voice_stream"):
		wav = _decode_voice(str(data.get("audio", "")))
	if wav != null:
		secs = maxf(secs, wav.get_length() + 2.0)
	body.say(raw, secs)
	for sch in places.schools:
		if sch != null and is_instance_valid(sch) and not sch.in_break \
				and str(body.ped_id) == str(sch.teacher_pid()):
			sch.board.write(raw)
	if wav != null:
		body.play_voice_stream(wav)
	var who := player_by_id("u:" + str(data.get("to", "")))
	if who != null and body.get("character_model") != null and _world != null:
		var d: Vector3 = _world.to_local(who.global_position) - body.position
		if d.length_squared() > 0.01:
			body.character_model.rotation.y = atan2(d.x, d.z) + PI
	if body.has_method("hold_idle"):
		body.hold_idle(maxf(secs, clampf(raw.length() * 0.07, 6.0, 20.0)))
	engagement.reply_arrived(str(body.ped_id))


## Null when there is none or it is too short.
func _decode_voice(audio_b64: String) -> AudioStreamWAV:
	if audio_b64 == "":
		return null
	var bytes := Marshalls.base64_to_raw(audio_b64)
	if bytes.size() <= 44:
		return null
	return AudioStreamWAV.load_from_buffer(bytes)


func _find_schools():
	if _world == null:
		return
	places.find_schools()
	if school_nav == null and not places.schools.is_empty():
		school_nav = BuildingNav.new()
		school_nav.name = "SchoolNav"
		_world.add_child(school_nav)
		school_nav.setup(self, _world)


## Workspace units; {} when the walking model is not ready or covers neither end.
func school_route(from: Vector3, to: Vector3) -> Dictionary:
	if school_nav == null or not school_nav.ready_ok:
		return {}
	if not school_nav.covers(from) and not school_nav.covers(to):
		return {}
	return school_nav.route(from, to)


## Also near a sitting chamber: no passing greetings, no small talk.
func in_classroom(body) -> bool:
	for s in places.schools:
		if s != null and is_instance_valid(s) and s.contains_position(body.position):
			return not s.in_break
	for p in places.parliaments:
		if p != null and is_instance_valid(p) and p.sitting and body.position.distance_to(p.centre_pos()) < 70.0:
			return true
	return false


func in_match(body) -> bool:
	for s in places.schools:
		if s != null and is_instance_valid(s) and s.match_.playing(str(body.ped_id)):
			return true
	return false


## Rooms a student names, plus "School" when none does; in scene order so every peer agrees.
func class_rooms() -> Array:
	var names := {}
	var unnamed := false
	for key in _resident_defs:
		var def: Dictionary = _resident_defs[key]
		if not bool(def.get("student", false)):
			continue
		var c := str(def.get("class", ""))
		if c == "":
			unnamed = true
		else:
			names[c] = true
	var out: Array = []
	for s in places.schools:
		if s == null or not is_instance_valid(s):
			continue
		if names.has(str(s._room.get_meta("class_name", ""))) or (unnamed and s.key() == "School"):
			out.append(s)
	return out


## The first room to ring within 4 s plays it, the rest stay silent.
func school_bell_gate() -> bool:
	var now := Time.get_ticks_msec()
	if now - _bell_msec < 4000:
		return false
	_bell_msec = now
	return true


## The draw is renewed after 90 s without a call, so one break sees one draw.
func pitch_turn(sch) -> bool:
	if places.schools.size() <= 1:
		return true
	var now := Time.get_ticks_msec()
	if now - _pitch_turn_msec > 90000:
		_pitch_turn = _rng.randi() % places.schools.size()
	_pitch_turn_msec = now
	return places.schools[_pitch_turn] == sch


## Event cast excluded.
func _report_world():
	if _nc == null or not _nc.connected or _world == null:
		return
	var entries: Array = places.collect_places()
	var residents: Array = []
	for key in _resident_defs:
		var def: Dictionary = _resident_defs[key]
		if str(def.get("id", "")).begins_with("evt_"):
			continue
		var entry: Dictionary = def.duplicate(true)
		entry["key"] = key
		residents.append(entry)
	_nc.send_json({"type": "world_places", "workspace": workspace_name(),
		"places": entries, "residents": residents})
	print("[AmbientManager] world_places sent: %d places (%d restaurants, %d districts, %d plots), %d residents" %
		[entries.size(), places.restaurants.size(), places.districts.size(), BuildPlots.all_plots(_world).size(), residents.size()])


## {hour, rate, day, weekday, utc, mode}; `rate` game seconds per real second (0 = pinned).
func handle_world_clock(data: Dictionary):
	var before := current_hour()
	var mode := str(data.get("mode", _clock_mode))
	_clock_day = int(data.get("day", _clock_day))
	_set_clock_weekday(int(data.get("weekday", -1)))
	_find_env_controller()
	if _env_controller == null:
		return
	var hour := fmod(float(data.get("hour", 0.0)), 24.0)
	var rate := float(data.get("rate", 1.0))
	if _env_controller.has_method("set_time_of_day_hours"):
		_env_controller.set_time_of_day_hours(hour)
	if rate > 0.0 and "time_speed_multiplier" in _env_controller:
		_env_controller.time_speed_multiplier = rate
		_env_controller.accelerated_time_offset = hour / 24.0
		_env_controller.time_mode = _env_controller.TimeMode.ACCELERATED
	_apply_clock_date(data)
	var jumped := absf(wrapf(hour - before, -12.0, 12.0)) > 0.25 or mode != _clock_mode
	_clock_mode = mode
	if jumped and _is_authority:
		_on_clock_jump(hour)


func _set_clock_weekday(wd: int):
	if wd == _clock_weekday:
		return
	_clock_weekday = wd
	for r in _residents.values():
		if r != null and is_instance_valid(r) and r.has_method("replan_today"):
			r.replan_today()


## From `utc`, else from `day` (a proleptic Gregorian ordinal).
func _apply_clock_date(data: Dictionary):
	if not ("current_day_unix" in _env_controller):
		return
	if data.has("utc"):
		_env_controller.current_day_unix = WorldGeo.local_day(float(data.utc), WorldGeo.home_id())
	elif data.has("day"):
		_env_controller.current_day_unix = int(data.day) - 719163


## Extras follow on the next schedule tick.
func _on_clock_jump(hour: float):
	var n := 0
	for body in _residents.values():
		if body != null and is_instance_valid(body) and body.has_method("reset_day"):
			body.reset_day()
			n += 1
	_schedule_timer = 5.0
	print("[AmbientManager] the clock jumped to %.2f (%s): %d residents start the hour over" % [hour, _clock_mode, n])


## 0 = Monday … 6 = Sunday.
func current_weekday() -> int:
	if _clock_weekday >= 0:
		return _clock_weekday
	return (int(Time.get_unix_time_from_system() / 86400.0) + 3) % 7


func current_day() -> int:
	if _clock_day >= 0:
		return _clock_day
	return int(Time.get_unix_time_from_system() / 86400.0)


## {"who": <resident key>, ...} goes to that resident's memory; {"world": ...} to the world's.
func observe(obs: Dictionary):
	if not _is_authority:
		return
	_obs_queue.append(obs)


func _flush_observations():
	if _obs_queue.is_empty() or _nc == null or not _nc.connected:
		_obs_queue = []
		return
	_nc.send_json({"type": "world_obs", "hour": snappedf(current_hour(), 0.01),
		"day": current_day(), "obs": _obs_queue})
	_obs_queue = []


func _obs_scan():
	var keys: Array = _residents.keys()
	for key in keys:
		var body = _residents[key]
		if body == null or not is_instance_valid(body):
			continue
		var hidden := off_map(body)
		_observe_player_near(key, body, hidden)
		var company: Array = []
		# in_classroom is costly: decide it once per body, not per pair.
		if not (hidden or in_classroom(body) or in_match(body)):
			company = _company_of(key, body, keys)
		company.sort()
		var joined := ",".join(company)
		if joined != str(_obs_company.get(key, "<none>")):
			_obs_company[key] = joined
			observe({"who": key, "with": company, "at": places.district_names_at(body.position)})


func _observe_player_near(key, body, hidden: bool):
	var near: Node3D = null if hidden else nearest_player_node(body.position, npc_talk_radius)
	var who := ("player:" + str(near.name)) if near != null else ""
	var prev := str(_obs_near.get(key, ""))
	if who == prev:
		return
	if prev != "":
		observe({"who": key, "lost": prev})
	if who != "":
		observe({"who": key, "saw": who,
			"d": snappedf(_world.to_local(near.global_position).distance_to(body.position), 0.1),
			"at": places.district_names_at(body.position)})
	_obs_near[key] = who


## Within 8 units.
func _company_of(key, body, keys: Array) -> Array:
	var company: Array = []
	for other in keys:
		if other == key:
			continue
		var ob = _residents[other]
		if ob != null and is_instance_valid(ob) and not off_map(ob) and ob.position.distance_to(body.position) <= 8.0:
			company.append(other)
	return company




func _unhandled_input(event):
	engagement.unhandled_input(event)


func peds() -> Dictionary:
	return _peds


func residents() -> Dictionary:
	return _residents


func resident_def(pid: String) -> Dictionary:
	return _resident_defs.get(pid, {})


func resident_defs() -> Dictionary:
	return _resident_defs


## May be a freed instance; callers check.
func local_player():
	return _nc.players.local_player if _nc != null else null


func has_network() -> bool:
	return _nc != null


func is_online() -> bool:
	return _nc != null and _nc.connected


func event_director():
	if _event_director != null and is_instance_valid(_event_director):
		return _event_director
	return null


func send_to_server(msg: Dictionary):
	if _nc != null:
		_nc.send_json(msg)


## resident_npc.gd home_hidden: the body goes on, but for everyone else it is not there.
static func off_map(body) -> bool:
	return body != null and body.get("home_hidden") == true


## "r_<id>" or "<id>".
func resident_body(key: String) -> Node3D:
	var b = _residents.get(key)
	if b == null:
		b = _residents.get("r_" + key)
	return b if b != null and is_instance_valid(b) else null


## teach / attend / dismiss.
func request_teach(body, place: String) -> bool:
	var sch = places.school(place)
	return sch != null and sch.take_lectern(body)


func request_attend(body, place: String) -> bool:
	var sch = places.school(place)
	return sch != null and sch.request_seat(body)


## {"landing", "ride": "<lift>/<floor>"}, or {} when on the body's level, no lift serves it, or assembly.
func school_lift_leg(body, place: String) -> Dictionary:
	var sch = places.school(place)
	if sch == null or _world == null or sch.assembly_.active():
		return {}
	var door: Vector3 = sch.place_pos()
	if door == Vector3.INF:
		return {}
	for elevator in get_tree().get_nodes_in_group("elevators"):
		if not elevator.has_method("nearest_floor") or not ("FLOORS" in elevator):
			continue
		if not elevator.has_node("Landing0/Approach"):
			continue  # a home's plain lift (simple_lift.gd)
		var floors: Array = elevator.FLOORS
		var room_y: float = elevator.to_local(_world.to_global(door)).y
		var to: int = elevator.nearest_floor(room_y)
		if absf(float(floors[to]) - room_y) > 8.0:
			continue
		var here_y: float = elevator.to_local(_world.to_global(body.position)).y
		var from: int = elevator.nearest_floor(here_y)
		if from == to:
			return {}
		var landing: Node3D = elevator.get_node_or_null("Landing%d/Approach" % from)
		if landing == null:
			continue
		return {"landing": _world.to_local(landing.global_position), "ride": str(elevator.elevator_id) + "/" + str(to)}
	return {}


## "<lift id>/<floor>"; false when the place is not one or refused.
func request_elevator_ride(body, place: String, entry = null) -> bool:
	var parts := place.rsplit("/", true, 1)
	if parts.size() != 2 or not parts[1].is_valid_int():
		return false
	for elevator in get_tree().get_nodes_in_group("elevators"):
		if elevator.elevator_id == parts[0]:
			return elevator.request_ride(body, int(parts[1]), entry)
	return false


## The teacher dismisses it; anyone else is released.
func school_leave(body, place: String):
	var sch = places.school(place)
	if sch == null:
		return
	var pid := str(body.ped_id)
	if sch.teacher_pid() == pid:
		sch.dismiss()
	else:
		sch._release_pid(pid)
		sch.enrolled.erase(pid)
		sch.outside.erase(pid)
		sch.match_.forget(pid)
		body.class_over()


## "enter", "yard" and "leave" teleport locally; the rest go to the authority ("leave" too).
func player_school_request(op: String, seat: int = -1):
	var sch = places.school("")
	if sch == null:
		return
	if op == "enter":
		sch.enter()
		return
	if op == "yard":
		sch.enter_yard()
		return
	if op == "leave":
		sch.leave()
	var msg := {"type": "school_req", "school": sch.key(), "op": op, "pid": "u:" + local_username()}
	if seat >= 0:
		msg["seat"] = seat
	if _is_authority:
		sch.handle_player_request(msg)
	if _nc != null and _nc.connected:
		_nc.send_json(msg)


func handle_school_req(data: Dictionary):
	if not _is_authority:
		return
	var sch = places.school(str(data.get("school", "")))
	if sch != null:
		sch.handle_player_request(data)


func handle_life_cmd(data: Dictionary):
	if _is_authority:
		life_controller.handle(data)


## {"type": "school_cmd", "school", "cmd"}
func handle_school_cmd(data: Dictionary):
	if not _is_authority:
		return
	var sch = places.school(str(data.get("school", "")))
	if sch == null:
		return
	match str(data.get("cmd", "")):
		"life", "life_cancel", "life_control":
			sch.life_controller.handle(data)
		"bell":
			sch.ring_bell()
		"break":
			sch.break_time()
		"class":
			sch.class_time()
		"free":
			sch.free_period()
		"lunch":
			sch.lunch()
		"pe":
			sch.match_.pe_time()
		"gather":
			sch.assembly_.gather("am")
		"assembly_am":
			sch.assembly_.start("am")
		"assembly_pm":
			sch.assembly_.start("pm")
		"rite_end":
			sch.assembly_.rite("end")
		"closed":
			sch.closed = true
		"open":
			sch.closed = false


## {"op": "seat"|"open"|"rise"|"sit"|"result"|"adjourn", ...}; bodies move on the authority only.
func handle_par(data: Dictionary):
	for p in places.parliaments:
		if p != null and is_instance_valid(p):
			p.on_par(data)


## "submit" and "adjourn" go to the server; the rest teleport locally.
func player_parliament_request(op: String, matter: String = ""):
	var par = places.parliament()
	if par == null:
		return
	match op:
		"enter", "gallery", "box", "leave":
			par.player_request(op)
		"submit", "adjourn":
			_send_parliament_req(op, matter)


func _send_parliament_req(op: String, matter: String):
	if _nc != null and _nc.connected:
		_nc.send_json({"type": "parliament_req", "op": op, "matter": matter,
			"house": "both", "pid": "u:" + local_username()})


## False = closed or full.
func request_meal(body, place: String) -> bool:
	for r in places.restaurants:
		if r == null or not is_instance_valid(r):
			continue
		if place != "" and r.rest_key() != place:
			continue
		if r.has_method("request_seat") and r.request_seat(body):
			return true
	return false


## Refuses everyone not invited.
func request_course(body, place: String, role: String = "") -> bool:
	for c in places.courses:
		if c == null or not is_instance_valid(c):
			continue
		if place != "" and c.course_key() != place:
			continue
		if c.request_seat(body, role):
			return true
	return false


## {"id", "intents": [...], "replace": bool}
func handle_res_plan(data: Dictionary):
	if not _is_authority:
		return
	var id := str(data.get("id", ""))
	var body = _residents.get(id)
	if body == null:
		body = _residents.get("r_" + id)
	if body == null or not is_instance_valid(body) or not body.has_method("set_plan"):
		print("[AmbientManager] res_plan for unknown resident: ", id)
		return
	var intents = data.get("intents", [])
	if typeof(intents) != TYPE_ARRAY:
		return
	body.set_plan(intents, bool(data.get("replace", false)))


## Shown here and sent as npc_say, so every player sees and hears the same.
func resident_say(body, intent: Dictionary):
	var msg := {"id": str(body.ped_id)}
	if str(intent.get("text", "")) != "":
		msg["text"] = str(intent.text)
		if str(intent.get("audio", "")) != "":
			msg["audio"] = str(intent.audio)  # generated voice (base64 WAV)
	elif str(intent.get("line", "")) != "":
		msg["line"] = str(intent.line)
		msg["secs"] = float(intent.get("secs", 5.0))
	else:
		return
	handle_npc_say(msg)
	if _is_authority and _nc != null and _nc.connected:
		var out: Dictionary = msg.duplicate()
		out["type"] = "npc_say"
		_nc.send_json(out)


# "brain": "shisho" residents answer chat: via the server online, POSTing to shisho_npc_url offline.

func shisho_npc_near_player() -> String:
	if _nc == null or _nc.players.local_player == null \
			or not is_instance_valid(_nc.players.local_player) or _world == null:
		return ""
	var pl: Vector3 = _world.to_local(_nc.players.local_player.global_position)
	for key in _resident_defs:
		var def: Dictionary = _resident_defs[key]
		if str(def.get("brain", "")) != "shisho":
			continue
		var body = _residents.get(key)
		if body != null and is_instance_valid(body) \
				and body.position.distance_to(pl) <= npc_talk_radius:
			return str(def.get("id", ""))
	return ""


## True when the words were also addressed to a brained resident.
func route_player_chat(text: String) -> bool:
	var id := shisho_npc_near_player()
	if id == "" or text.strip_edges() == "":
		return false
	if _nc != null and _nc.connected:
		_nc.send_json({"type": "npc_dialog", "action": "say", "target": id, "text": text})
	else:
		_shisho_direct(id, text)
	return true


## One request at a time.
func _shisho_direct(npc_id: String, text: String):
	if _shisho_busy:
		return
	if _shisho_http == null:
		_shisho_http = HTTPRequest.new()
		_shisho_http.timeout = 90.0
		add_child(_shisho_http)
		_shisho_http.request_completed.connect(_on_shisho_response)
	_shisho_busy = true
	_shisho_pending_id = npc_id
	var body := JSON.stringify({
		"npc": npc_id, "user": local_username(), "text": text, "speak": true})
	var err := _shisho_http.request(shisho_npc_url.rstrip("/") + "/npc/chat",
		["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		_shisho_busy = false


func _on_shisho_response(_result: int, code: int, _headers: PackedStringArray, resp_body: PackedByteArray):
	_shisho_busy = false
	if code != 200:
		print("[AmbientManager] Shisho reply HTTP ", code)
		return
	var parsed = JSON.parse_string(resp_body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	handle_npc_say({"id": _shisho_pending_id, "text": str(parsed.get("text", "")),
		"audio": str(parsed.get("audio_wav_b64", "")), "to": local_username()})


func handle_rest_req(data: Dictionary):
	for r in places.restaurants:
		if r != null and is_instance_valid(r) and r.rest_key() == str(data.get("rest", "")):
			r.handle_player_request(data)


## Username online, "local" off.
func local_username() -> String:
	if _nc != null and str(_nc.local_username) != "":
		return str(_nc.local_username)
	return "local"


func nearest_player_node(pos_local: Vector3, max_dist: float) -> Node3D:
	var best: Node3D = null
	var best_d := max_dist
	var cands: Array = []
	if _nc != null and _nc.players.local_player != null and is_instance_valid(_nc.players.local_player):
		cands.append(_nc.players.local_player)
	cands.append_array(remote_player_nodes())
	for c in cands:
		var d: float = _world.to_local((c as Node3D).global_position).distance_to(pos_local)
		if d < best_d:
			best_d = d
			best = c
	return best


## "u:<username>"
func player_by_id(pid: String) -> Node3D:
	if not pid.begins_with("u:"):
		return null
	var uname := pid.substr(2)
	if uname == local_username() and _nc != null \
			and _nc.players.local_player != null and is_instance_valid(_nc.players.local_player):
		return _nc.players.local_player
	if _world != null:
		var players = _world.get_node_or_null("Players")
		if players != null:
			var node = players.get_node_or_null(uname)
			if node is Node3D:
				return node
	return null


## Avoids no-loiter discs and spots where more than two people already stand.
func request_ped_route(ped) -> PackedVector3Array:
	if nav.is_empty():
		return PackedVector3Array()
	var dest := _pick_wander_dest(ped)
	var dining := restaurant_route(ped.position, dest)
	if not dining.is_empty():
		ped.precise_route = true
		return dining.route
	var route := nav.find_route(ped.position, dest)
	if route.is_empty() and not nav.is_walkable(Vector2(ped.position.x, ped.position.z)):
		# Off the zones (pushed, bad spawn): head straight for the destination.
		route.append(dest)
	return route


func _pick_wander_dest(ped) -> Vector3:
	var dest: Vector3 = nav.random_point(_rng)
	var people := people_positions_local()
	for attempt in 6:
		var cand: Vector3
		if _rng.randf() < 0.75:
			cand = nav.random_point_near(ped.position, ped_wander_radius, _rng)
		else:
			cand = nav.random_point(_rng)
		dest = cand
		if _in_no_loiter(cand):
			continue
		var crowd := 0
		for pp in people:
			if pp.distance_to(cand) < 7.0:
				crowd += 1
		if crowd <= 2:
			break
	return dest


## Reports the world once per connection, and again 30 s later for scenes still loading.
func handle_npc_authority(data: Dictionary):
	var authority_id := int(data.get("authority_client_id", -1))
	authority_client_id = authority_id
	var is_me: bool = _nc != null and authority_id == _nc.client_id
	var was := _is_authority
	_set_authority(is_me if _nc != null else true)
	if _is_authority and not was:
		if _peds.is_empty() and traffic.is_empty():
			_populate()
		else:
			_adopt_bodies()
	if _is_authority and _nc != null and _nc.connected \
			and _reported_client_id != int(_nc.client_id):
		_reported_client_id = int(_nc.client_id)
		call_deferred("_report_world")
		mark_report_dirty(30.0)




## Promoted mid-game: keep every body where the old authority left it.
func _adopt_bodies():
	for id in _peds.keys():
		if not is_instance_valid(_peds[id]):
			_peds.erase(id)
			continue
		# Dining starts fresh: nobody stays on the old authority's chair.
		if _peds[id].sitting:
			_peds[id].stand_up()
	traffic.adopt()
	for id in _residents.keys():
		_respawn_resident_here(id)
	traffic.seat_trams()
	_populate()


## Remote resident bodies carry no routine logic.
func _respawn_resident_here(id):
	var pos := Vector3.ZERO
	var had := false
	if is_instance_valid(_residents[id]):
		pos = _residents[id].position
		had = true
		_residents[id].queue_free()
	_residents.erase(id)
	if not _resident_defs.has(id):
		return
	_spawn_resident(id, _resident_defs[id])
	if had and _residents.has(id) and is_instance_valid(_residents[id]):
		_residents[id].position = pos


func _set_authority(is_auth: bool):
	_is_authority = is_auth
	for pool in [_peds, traffic.cars, traffic.trams, _residents]:
		for id in pool:
			if is_instance_valid(pool[id]):
				pool[id].set_authority(is_auth)
	places.set_authority(is_auth)
	print("[AmbientManager] Authority: ", is_auth)


## {"op": "event", "id"}, "event_stop", or {"op": "populate", "npcs", "peds", "cars", "trams"}.
func handle_world_cmd(data: Dictionary):
	if not _is_authority:
		return
	match str(data.get("op", "")):
		"event":
			if _event_director != null and is_instance_valid(_event_director):
				_event_director.start_event(str(data.get("id", "safiye")))
		"event_stop":
			if _event_director != null and is_instance_valid(_event_director) \
					and str(_event_director.get("_event_id")) != "":
				_event_director._end_event()
		"populate":
			_studio_populate(data)
		_:
			print("[AmbientManager] unknown world_cmd: ", data)


func _studio_populate(data: Dictionary):
	if data.has("npcs"):
		npcs_enabled = bool(data.npcs)
	if data.has("peds"):
		ped_count = int(data.peds)
	if data.has("cars"):
		car_count = int(data.cars)
	if data.has("trams"):
		trams_enabled = bool(data.trams)
	_populate()
	print("[AmbientManager] studio populate: people %s, %d peds, %d cars, trams %s"
		% [npcs_enabled, ped_count, car_count, trams_enabled])
