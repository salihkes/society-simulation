extends Node
## The borrowable vehicles of a workspace: building, authority, getting in and out, and vehicle_* messages.

## Network messages this module handles: type -> method (see protocol/messages.json).
const MESSAGES := {
	"vehicle_transform": "handle_transform",
	"vehicle_enter": "handle_enter",
	"vehicle_exit": "handle_exit",
	"vehicle_mode": "handle_mode",
	"vehicle_doors": "handle_doors",
	"vehicle_paint": "handle_paint",
	"vehicle_horn": "handle_horn",
	"vehicle_reset": "handle_reset",
}

const VEHICLE_SCRIPT := preload("res://src/vehicles/drivable_vehicle.gd")
const SEND_INTERVAL := 0.05          # transform sync period (20 Hz)
const ENTER_RANGE := 3.5             # world metres from a door or the body's side
const LOCKED_RANGE := 3.0            # world metres for the "Doors locked." hint
const FALL_RESET := 40.0             # world metres below its spot: put back

## Off: no bodies are built from the spots.
@export var enabled := true

var _nc = null
var _world: Node3D = null
var _ambient = null
var _chat = null
var _vehicles: Dictionary = {}       # net_id -> DrivableVehicle
var _spawn_xform: Dictionary = {}    # net_id -> Transform3D (the spot)
var _registered: Dictionary = {}     # net_id -> true once traffic knows it
var _riding = null                   # the vehicle the local player is in
var _send_timer := 0.0
var _spawned := false
var _need_snap := false


func _ready() -> void:
	add_to_group("vr_interactable")
	_nc = get_node_or_null("/root/NetworkController")
	_world = get_parent() as Node3D
	if _nc != null and _nc.has_signal("player_disconnected"):
		_nc.player_disconnected.connect(_on_player_disconnected)
	call_deferred("_spawn_from_spots")


func _spawn_from_spots() -> void:
	if _spawned or _world == null:
		return
	_spawned = true
	if not enabled:
		print("[VehicleManager] disabled — no vehicles placed")
		return
	for spot in get_tree().get_nodes_in_group("vehicle_spot"):
		if not (spot is Node3D) or not _world.is_ancestor_of(spot):
			continue
		var definition = spot.get("definition")
		if definition == null:
			push_warning("[VehicleManager] Spot '%s' has no definition" % spot.name)
			continue
		var nid := "wveh_" + str(spot.name)
		if not _vehicles.has(nid):
			_place_vehicle(spot, definition, nid)
	_need_snap = not _vehicles.is_empty()
	print("[VehicleManager] %d vehicle(s) placed from spots" % _vehicles.size())


func _place_vehicle(spot: Node3D, definition, nid: String) -> void:
	var v = VEHICLE_SCRIPT.new()
	v.name = "Vehicle_" + str(spot.name)
	v.setup(definition, nid, self)
	_world.add_child(v)
	v.global_position = spot.global_position
	v.global_rotation = Vector3(0.0, spot.global_rotation.y, 0.0)
	if bool(spot.get("npc_driven")):
		v.mode = v.Mode.NPC
	_vehicles[nid] = v
	_spawn_xform[nid] = v.global_transform


func _physics_process(_delta: float) -> void:
	if not _need_snap:
		return
	# First physics tick after placement: the ground exists now.
	_need_snap = false
	for nid in _vehicles:
		var v = _vehicles[nid]
		if is_instance_valid(v):
			v.snap_to_ground()
			_spawn_xform[nid] = v.global_transform


func _process(delta: float) -> void:
	if _ambient == null and _world != null:
		_ambient = _world.find_child("AmbientManager", true, false)
	for nid in _vehicles.keys():
		var v = _vehicles[nid]
		if not is_instance_valid(v):
			_vehicles.erase(nid)
			continue
		_update_vehicle(nid, v)
	if not _connected():
		return
	_send_timer -= delta
	if _send_timer > 0.0:
		return
	_send_timer = SEND_INTERVAL
	_send_transforms()


func _update_vehicle(nid: String, v) -> void:
	refresh_authority(v)
	_reconcile_sim(v)
	if _ambient != null and not _registered.has(nid) and v.is_ready():
		_ambient.traffic.register_vehicle(v, v.scan_points())
		_registered[nid] = true
	var spawn: Transform3D = _spawn_xform.get(nid, v.global_transform)
	if v.is_authority() and v.global_position.y < spawn.origin.y - FALL_RESET:
		print("[VehicleManager] %s fell out of the world — back to its spot" % nid)
		v.reset_to(spawn)


func _send_transforms() -> void:
	var me := my_id()
	for nid in _vehicles:
		var v = _vehicles[nid]
		if is_instance_valid(v) and v.is_authority() and v.is_ready():
			var d: Dictionary = v.get_sync_data()
			d["type"] = "vehicle_transform"
			d["pid"] = me
			_send(d)


## The stand-in driver figure shows on every peer.
func _reconcile_sim(v) -> void:
	var want: bool = v.mode == v.Mode.NPC and v.is_authority() and v.is_ready() \
		and _ambient != null
	if want and not v.is_sim_driven():
		if _ambient.traffic.drive_external(v):
			v.set_sim_driven(true)
		else:
			_say("No road near the %s for a driver to take it." % v.definition.display_name)
			v.mode = v.Mode.IDLE
			_send({"type": "vehicle_mode", "net_id": v.net_id, "mode": v.mode})
	elif not want and v.is_sim_driven():
		if _ambient != null:
			_ambient.traffic.release_external(v)
		v.set_sim_driven(false)
	v.set_npc_figure(v.mode == v.Mode.NPC)


func my_id() -> int:
	if _connected():
		return int(_nc.client_id)
	return 0


func _connected() -> bool:
	return _nc != null and bool(_nc.connected)


## The traffic sim's authority, or without a traffic sim the lowest client id.
func ambient_authority() -> bool:
	if not _connected():
		return true
	if _ambient != null:
		return bool(_ambient.is_authority())
	var me := my_id()
	for pid in _nc.players.remote_players.keys():
		if int(pid) < me:
			return false
	return true


func _ambient_authority_id() -> int:
	if _ambient != null and "authority_client_id" in _ambient:
		return int(_ambient.authority_client_id)
	return -1


func is_vehicle_authority(v) -> bool:
	if not _connected():
		return true
	if v.driver_id != v.NO_ONE:
		return v.driver_id == my_id()
	return ambient_authority()


func refresh_authority(v) -> void:
	v.set_authority(is_vehicle_authority(v))


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var lp = local_player()
	if lp == null:
		return
	if lp.has_method("_typing") and lp._typing():
		return
	if event.keycode == KEY_F:
		_toggle_ride(lp)
	elif event.keycode == KEY_O:
		_toggle_doors(lp)


func _toggle_ride(lp) -> void:
	var pid := my_id()
	if _riding != null and is_instance_valid(_riding):
		_leave_ride(lp, pid)
		return
	if _riding != null:
		_riding = null

	var v = _nearest_vehicle(lp.global_position, ENTER_RANGE)
	if v == null:
		if _near_locked_car(lp.global_position):
			_say("Doors locked.")
		return
	if v.mode == v.Mode.NPC:
		_say("Doors locked — someone is driving the %s." % v.definition.display_name)
		return
	var seat: String = v.free_seat(true)
	if seat == "":
		_say("The %s is full." % v.definition.display_name)
		return
	var as_driver: bool = seat == v.definition.driver_seat
	v.board(lp, pid, seat, as_driver)
	_riding = v
	_send({"type": "vehicle_enter", "net_id": v.net_id, "player_id": pid,
		"driver": as_driver, "seat": seat})
	_say_controls(v, lp, as_driver)


func _leave_ride(lp, pid: int) -> void:
	var v = _riding
	var seat: String = v.seat_of(pid)
	var pos: Vector3 = v.exit_position(seat, [lp])
	v.depart(lp, pid, pos)
	_riding = null
	_send({"type": "vehicle_exit", "net_id": v.net_id, "player_id": pid,
		"x": pos.x, "y": pos.y, "z": pos.z})


func _say_controls(v, lp, as_driver: bool) -> void:
	var vr: bool = lp.get("is_vr_mode") == true
	var vname: String = v.definition.display_name
	if not as_driver:
		_say("You ride along in the %s — %s to get out." % [vname, "X" if vr else "F"])
	elif vr:
		_say("%s — left stick drives and steers; right grip brakes; left stick click horn; right stick click doors; X gets out." % vname)
	else:
		_say("You take the wheel of the %s — W/S drive, A/D steer, Space brake, H horn, O doors, wheel/Numpad 0 camera, F out." % vname)


func vr_interaction_distance(player: Node3D) -> float:
	var v = _nearest_vehicle(player.global_position, ENTER_RANGE)
	return v.door_distance(player.global_position) if v != null else INF


func vr_interact(player: Node3D) -> void:
	_toggle_ride(player)


## NPC-driven vehicles stay locked from outside.
func _toggle_doors(lp) -> void:
	var v = _riding if _riding != null and is_instance_valid(_riding) \
			else _nearest_vehicle(lp.global_position, ENTER_RANGE)
	if v == null:
		return
	if v.mode == v.Mode.NPC and v != _riding:
		_say("Doors locked.")
		return
	var all_open: int = v.all_doors_mask()
	var mask: int = 0 if v.doors_mask() == all_open else all_open
	v.set_doors_mask(mask)
	_send({"type": "vehicle_doors", "net_id": v.net_id, "mask": mask})


func _nearest_vehicle(from: Vector3, range_m: float):
	var best = null
	var best_d := range_m
	for nid in _vehicles:
		var v = _vehicles[nid]
		if not is_instance_valid(v) or not v.is_ready():
			continue
		var d: float = v.door_distance(from)
		if d < best_d:
			best_d = d
			best = v
	return best


func _near_locked_car(from: Vector3) -> bool:
	if _ambient != null:
		for id in _ambient.traffic.cars:
			var car = _ambient.traffic.cars[id]
			if car != null and is_instance_valid(car) and car is Node3D \
					and from.distance_to(car.global_position) < LOCKED_RANGE + 1.5:
				return true
	return _nearest_vehicle(from, ENTER_RANGE + 1.0) != null


## Returns the line to show.
func chat_command(parts: PackedStringArray) -> String:
	var verb: String = parts[1].to_lower() if parts.size() > 1 else "help"
	var lp = local_player()
	match verb:
		"list":
			return _chat_list(lp)
		"npc", "park":
			return _chat_set_mode(lp, parts, verb)
		"paint":
			return _chat_paint(lp, parts)
		"lean":
			return _chat_lean(parts)
		"reset":
			return _chat_reset(lp, parts)
		_:
			return "Usage: /vehicle list | npc [name] | park [name] | paint [name] | lean [on|off] | reset [name]"


func _chat_list(lp) -> String:
	if _vehicles.is_empty():
		return "No vehicles in this workspace."
	var lines: PackedStringArray = []
	for nid in _vehicles:
		var v = _vehicles[nid]
		if not is_instance_valid(v):
			continue
		var state := "parked"
		if v.mode == v.Mode.NPC:
			state = "NPC driving"
		elif v.mode == v.Mode.PLAYER:
			state = "driven by player %d" % v.driver_id
		var dist := ""
		if lp != null:
			dist = " (%.0f m away)" % lp.global_position.distance_to(v.global_position)
		lines.append("%s — %s%s" % [v.definition.display_name, state, dist])
	return "\n".join(lines)


func _chat_set_mode(lp, parts: PackedStringArray, verb: String) -> String:
	var v = _pick_vehicle(lp, parts, verb == "park")
	if v == null:
		return "No vehicle nearby."
	var want_npc: bool = verb == "npc" and v.mode != v.Mode.NPC
	if want_npc and v.driver_id != v.NO_ONE:
		return "Someone is at the wheel of the %s." % v.definition.display_name
	if not want_npc and v.mode != v.Mode.NPC:
		return "The %s is already parked." % v.definition.display_name
	v.mode = v.Mode.NPC if want_npc else v.Mode.IDLE
	_send({"type": "vehicle_mode", "net_id": v.net_id, "mode": v.mode})
	if want_npc:
		return "A driver takes the %s out." % v.definition.display_name
	return "The %s pulls over and parks." % v.definition.display_name


func _chat_paint(lp, parts: PackedStringArray) -> String:
	var v = _pick_vehicle(lp, parts, false)
	if v == null:
		return "No vehicle nearby."
	if not v.paintable():
		return "The %s came with its livery painted on." % v.definition.display_name
	var idx: Vector2i = v.next_paint()
	_send({"type": "vehicle_paint", "net_id": v.net_id, "body": idx.x, "roof": idx.y})
	return "The %s is repainted." % v.definition.display_name


func _chat_lean(parts: PackedStringArray) -> String:
	var want: bool = not VehicleModel.lean_enabled
	if parts.size() > 2:
		want = parts[2].to_lower() in ["on", "1", "true", "yes"]
	VehicleModel.lean_enabled = want
	return "Body lean %s." % ("on" if want else "off")


func _chat_reset(lp, parts: PackedStringArray) -> String:
	var v = _pick_vehicle(lp, parts, false)
	if v == null:
		return "No vehicle nearby."
	if _riding == v:
		_toggle_ride(lp)
	handle_reset({"net_id": v.net_id})
	_send({"type": "vehicle_reset", "net_id": v.net_id})
	return "The %s is back on its spot." % v.definition.display_name


## Named after the verb, else ridden, else nearest within 300 m, else nearest door within 60 m.
func _pick_vehicle(lp, parts: PackedStringArray, prefer_npc: bool):
	if parts.size() > 2:
		return _vehicle_named(" ".join(parts.slice(2)).to_lower())
	if _riding != null and is_instance_valid(_riding):
		return _riding
	if lp == null:
		return null
	var best = null
	var best_d := 300.0
	for nid in _vehicles:
		var v = _vehicles[nid]
		if not is_instance_valid(v):
			continue
		if prefer_npc and v.mode != v.Mode.NPC:
			continue
		var d: float = lp.global_position.distance_to(v.global_position)
		if d < best_d:
			best_d = d
			best = v
	if best != null:
		return best
	return _nearest_vehicle(lp.global_position, 60.0)


## Display name prefix or net_id suffix match on `want` (lower case).
func _vehicle_named(want: String):
	for nid in _vehicles:
		var v = _vehicles[nid]
		if is_instance_valid(v) and (v.definition.display_name.to_lower().begins_with(want) \
				or str(nid).to_lower().ends_with(want)):
			return v
	return null


## Only from the authority: the driver, a peer claiming the wheel, or with no driver the traffic authority.
func handle_transform(data: Dictionary) -> void:
	var v = _vehicle_for(data)
	if v == null:
		return
	var pid := int(data.get("pid", -1))
	if pid == my_id():
		return
	if v.driver_id != v.NO_ONE:
		if pid != v.driver_id and int(data.get("d", v.NO_ONE)) != pid:
			return
	elif int(data.get("d", v.NO_ONE)) != pid:
		var aid := _ambient_authority_id()
		if aid >= 0 and pid != aid:
			return
	v.apply_sync_data(data)


func handle_enter(data: Dictionary) -> void:
	var pid := int(data.get("player_id", -1))
	if pid == my_id():
		return
	var v = _vehicle_for(data)
	if v == null:
		return
	v.board(_remote_player(pid), pid, str(data.get("seat", "")), bool(data.get("driver", false)))


func handle_exit(data: Dictionary) -> void:
	var pid := int(data.get("player_id", -1))
	if pid == my_id():
		return
	var v = _vehicle_for(data)
	if v == null:
		return
	var pos: Vector3
	if data.has("x"):
		pos = Vector3(float(data.x), float(data.y), float(data.z))
	else:
		pos = v.exit_position(v.seat_of(pid))
	v.depart(_remote_player(pid), pid, pos)


## Ignores NPC while someone drives and IDLE while a player has the wheel.
func handle_mode(data: Dictionary) -> void:
	var v = _vehicle_for(data)
	if v == null:
		return
	var mode := int(data.get("mode", v.Mode.IDLE))
	if mode == v.Mode.NPC and v.driver_id != v.NO_ONE:
		return
	if v.mode == v.Mode.PLAYER and mode == v.Mode.IDLE:
		return
	v.mode = mode


func handle_doors(data: Dictionary) -> void:
	var v = _vehicle_for(data)
	if v != null:
		v.set_doors_mask(int(data.get("mask", 0)))


func handle_horn(data: Dictionary) -> void:
	if int(data.get("pid", -1)) == my_id():
		return
	var v = _vehicle_for(data)
	if v != null:
		v.honk(false)


func handle_paint(data: Dictionary) -> void:
	var v = _vehicle_for(data)
	if v != null:
		v.set_paint_indices(int(data.get("body", -1)), int(data.get("roof", -1)))


## Only the vehicle's authority moves it.
func handle_reset(data: Dictionary) -> void:
	var nid := str(data.get("net_id", ""))
	var v = _vehicle_for(data)
	if v == null:
		return
	if v.is_authority() and _spawn_xform.has(nid):
		v.reset_to(_spawn_xform[nid])


func _vehicle_for(data: Dictionary):
	var v = _vehicles.get(str(data.get("net_id", "")))
	if v == null or not is_instance_valid(v):
		return null
	return v


## Our own seat is never touched.
func reconcile_occupants(v, occ: Array) -> void:
	var me := my_id()
	var ids: Array[int] = []
	for pid in occ:
		ids.append(int(pid))
	for pid in ids:
		if pid == me or v.occupants.has(pid):
			continue
		var is_driver: bool = pid == v.driver_id
		v.board(_remote_player(pid), pid, v.definition.driver_seat if is_driver else "", is_driver)
	for pid in v.occupants.keys():
		if int(pid) == me or ids.has(int(pid)):
			continue
		var node = v.occupants[pid]
		v.depart(node if is_instance_valid(node) else null, int(pid),
				v.exit_position(v.seat_of(int(pid))))


func broadcast_horn(v) -> void:
	_send({"type": "vehicle_horn", "net_id": v.net_id, "pid": my_id()})


func _on_player_disconnected(pid) -> void:
	for nid in _vehicles:
		var v = _vehicles[nid]
		if is_instance_valid(v) and v.occupants.has(int(pid)):
			v.remove_occupant(int(pid))


func local_player():
	if _nc != null:
		return _nc.players.local_player
	return null


func _remote_player(pid: int):
	if _nc != null and _nc.players.remote_players.has(pid):
		return _nc.players.remote_players[pid]
	return null


func vehicles() -> Dictionary:
	return _vehicles


func riding():
	return _riding


func _say(text: String) -> void:
	if _chat == null or not is_instance_valid(_chat):
		_chat = get_tree().root.find_child("ChatUI", true, false)
	if _chat != null and _chat.has_method("add_message"):
		_chat.add_message("System", text, true)
	else:
		print("[Vehicle] " + text)


func _send(d: Dictionary) -> void:
	if _connected() and _nc.has_method("send_json"):
		_nc.send_json(d)
