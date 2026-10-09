## Networked objects: grabbable and plot objects, who streams which, and ships.
class_name NetObjects
extends RefCounted

const NetworkControllerScript := preload("res://src/net/network_controller.gd")

## Streamed as the `plot_objects` pack on web.
const PLOT_OBJECTS_PATH := "res://assets/assets/Objects/"
const OWNED_UPDATE_INTERVAL := 0.1
const CLAIM_MIN_INTERVAL_MS := 200
const CLAIM_DISTANCE := 3.0

var _nc: NetworkControllerScript = null
var _nodes = {}  # net_id -> Node3D
var _next_object_id = 1
var _owned_objects: Dictionary = {}
var _owned_last_sent: Dictionary = {}
var _owned_timer := 0.0
var _obj_seq: Dictionary = {}
var _obj_is_authority: Dictionary = {}
var _obj_last_update_ms: Dictionary = {}
var _seq_counter := 0
var _known_ships: Dictionary = {}  # net_id -> Spaceship node


func _init(controller: NetworkControllerScript):
	_nc = controller


func register_handlers() -> void:
	_nc.register_handler("object_spawn", _msg_object_spawn)
	_nc.register_handler("object_update", _on_object_update)
	_nc.register_handler("object_despawn", _msg_object_despawn)
	_nc.register_handler("plot_object_spawn", _msg_plot_object_spawn)
	_nc.register_handler("plot_object_update", _msg_plot_object_update)
	_nc.register_handler("plot_object_remove", _msg_plot_object_remove)
	_nc.register_handler("ship_transform", _handle_ship_transform)
	_nc.register_handler("ship_state", _on_ship_state)
	_nc.register_handler("combat_ship_damage", _on_ship_damage)
	_nc.register_handler("ship_board", _msg_ship_board)
	_nc.register_handler("ship_depart", _msg_ship_depart)


## Placed locally before the server confirms it.
func track_object(net_id: String, node: Node3D) -> void:
	_nodes[net_id] = node


func object_by_id(net_id: String):
	return _nodes.get(net_id, null)


## Sleeping or freed objects are released.
func sync_owned(delta):
	_owned_timer += delta
	if _owned_timer < OWNED_UPDATE_INTERVAL:
		return
	_owned_timer = 0.0
	for net_id in _owned_objects.keys():
		var obj: Node3D = _owned_objects.get(net_id, null)
		if not obj or not is_instance_valid(obj) or (obj is RigidBody3D and obj.sleeping):
			_owned_objects.erase(net_id)
			_owned_last_sent.erase(net_id)
			continue
		var xf: Transform3D = obj.global_transform
		var should_send: = true
		if _owned_last_sent.has(net_id):
			var prev: Transform3D = _owned_last_sent[net_id]
			var pos_delta = xf.origin.distance_to(prev.origin)
			var rot_changed = xf.basis.z.dot(prev.basis.z) < 0.999
			should_send = pos_delta > 0.02 or rot_changed
		if should_send:
			notify_object_update_with_path(obj.get_path(), xf)
			_owned_last_sent[net_id] = xf


## Throttled per object.
func claim_nearby():
	if not is_instance_valid(_nc.players.local_player):
		return
	var now_ms: int = Time.get_ticks_msec()
	var my_pos: Vector3 = _nc.players.local_player.global_transform.origin
	for net_id in _nodes.keys():
		if _owned_objects.has(net_id):
			continue
		var obj: Node3D = _nodes.get(net_id, null)
		if not obj or not is_instance_valid(obj):
			continue
		if obj is RigidBody3D and obj.sleeping:
			continue
		if obj.global_transform.origin.distance_to(my_pos) > CLAIM_DISTANCE:
			continue
		var last_ms = int(_obj_last_update_ms.get(net_id, 0))
		if now_ms - last_ms < CLAIM_MIN_INTERVAL_MS:
			continue
		if not bool(_obj_is_authority.get(net_id, false)):
			notify_object_update_with_path(obj.get_path(), obj.global_transform)


func _msg_object_spawn(data) -> void:
	var net_id = str(data.net_id)
	var xf = _parse_transform(data.transform)
	_spawn_or_update_object(net_id, xf)
	_nc.object_spawned.emit(net_id)


## A node_path names a scene node to move instead, without releasing local ownership.
func _on_object_update(data):
	var net_id = str(data.net_id)
	var xf = _parse_transform(data.transform)
	if data.has("node_path") and typeof(data.node_path) == TYPE_STRING and data.node_path != "":
		var node_by_path = _nc.get_tree().root.get_node_or_null(data.node_path)
		if node_by_path and node_by_path is Node3D:
			node_by_path.global_transform = xf
			_nodes[net_id] = node_by_path
			_nc.object_updated.emit(net_id, xf)
			_note_object_update(net_id, data)
			return
	_update_object_transform(net_id, xf)
	_nc.object_updated.emit(net_id, xf)
	_note_object_update(net_id, data)
	_unmark_owned(net_id)


func _note_object_update(net_id: String, data):
	_obj_seq[net_id] = int(data.get("seq", int(_obj_seq.get(net_id, 0)) + 1))
	_obj_is_authority[net_id] = int(data.get("authority", -1)) == _nc.client_id
	_obj_last_update_ms[net_id] = Time.get_ticks_msec()


func _msg_object_despawn(data) -> void:
	var net_id = str(data.net_id)
	_despawn_object(net_id)
	_nc.object_despawned.emit(net_id)


func _msg_plot_object_spawn(data) -> void:
	var net_id = str(data.net_id)
	var plot_id = data.plot_id
	var object_type = data.object_type
	var xf = _parse_transform(data.transform)
	print("Spawning plot object: ", object_type, " (", net_id, ") in plot ", plot_id)
	_spawn_plot_object(net_id, object_type, xf, plot_id)


func _msg_plot_object_update(data) -> void:
	var net_id = str(data.net_id)
	var plot_id = data.plot_id
	var xf = _parse_transform(data.transform)
	print("Updating plot object: ", net_id, " in plot ", plot_id)
	_update_object_transform(net_id, xf)


func _msg_plot_object_remove(data) -> void:
	var net_id = str(data.net_id)
	var plot_id = data.plot_id
	print("Removing plot object: ", net_id, " from plot ", plot_id)
	_despawn_object(net_id)


func _object_parent() -> Node:
	var parent_scene: Node = _nc.get_tree().current_scene
	if parent_scene == null:
		parent_scene = _nc.get_tree().get_root()
	var ws = parent_scene.find_child("workspace", true, false)
	if not ws:
		ws = parent_scene
	return ws


## Unknown objects are not created; only the InteractiveObjects container is.
func _spawn_or_update_object(net_id: String, xf: Transform3D):
	var obj = _nodes.get(net_id, null)
	if obj and is_instance_valid(obj):
		obj.global_transform = xf
		return

	var ws = _object_parent()
	var container = ws.find_child("InteractiveObjects", true, false)
	var existing: Node3D = null
	if container:
		existing = container.find_child("NetObj_" + net_id, true, false)
	if existing and existing is Node3D:
		existing.global_transform = xf
		_nodes[net_id] = existing
		return
	if not container:
		container = Node3D.new()
		container.name = "InteractiveObjects"
		ws.add_child(container)


func _update_object_transform(net_id: String, xf: Transform3D):
	var obj = _nodes.get(net_id, null)
	if obj and is_instance_valid(obj):
		obj.global_transform = xf
		return

	var container = _object_parent().find_child("InteractiveObjects", true, false)
	if not container:
		return
	var found = container.find_child("NetObj_" + net_id, true, false)
	if found and found is Node3D:
		found.global_transform = xf
		_nodes[net_id] = found


func _despawn_object(net_id: String):
	var obj = _nodes.get(net_id, null)
	if obj and is_instance_valid(obj):
		obj.queue_free()
	_nodes.erase(net_id)


func _spawn_plot_object(net_id: String, object_type: String, xf: Transform3D, plot_id: String):
	var obj = _nodes.get(net_id, null)
	if obj and is_instance_valid(obj):
		obj.global_transform = xf
		obj.set_meta("plot_id", plot_id)
		obj.set_meta("object_type", object_type)
		obj.set_meta("is_plot_object", true)
		print("Updated existing plot object with plot_id: ", plot_id)
		return

	var mesh_path = _plot_object_mesh_path(object_type)
	if mesh_path == "":
		# On web the mesh may still be streaming: retry when its pack mounts.
		if _await_plot_object_pack(net_id, object_type, xf, plot_id):
			return
		print("ERROR: Plot object mesh not found for type: ", object_type)
		return

	var loaded_scene = load(mesh_path)
	if not loaded_scene:
		print("ERROR: Failed to load plot object scene: ", mesh_path)
		return

	var new_object = loaded_scene.instantiate()
	new_object.name = net_id
	new_object.set_meta("object_type", object_type)
	new_object.set_meta("plot_id", plot_id)
	new_object.set_meta("is_plot_object", true)

	_object_parent().add_child(new_object)
	new_object.global_transform = xf
	_nodes[net_id] = new_object

	print("Spawned plot object: ", object_type, " (", net_id, ") from ", mesh_path)


## "" while it is still streaming in.
func _plot_object_mesh_path(object_type: String) -> String:
	var tscn := PLOT_OBJECTS_PATH + object_type + "/mesh.tscn"
	if FileAccess.file_exists(tscn) or ResourceLoader.exists(tscn):
		return tscn
	var glb := PLOT_OBJECTS_PATH + object_type + "/mesh.glb"
	if FileAccess.file_exists(glb) or ResourceLoader.exists(glb):
		return glb
	return ""


## Whichever of .tscn or .glb arrives first spawns the object; true when the retry was registered.
func _await_plot_object_pack(net_id: String, object_type: String, xf: Transform3D, plot_id: String) -> bool:
	var pm = _nc.get_node_or_null("/root/PCKManager")
	if pm == null or not pm.has_method("when_available"):
		return false
	var retry := func():
		var existing = _nodes.get(net_id, null)
		if existing != null and is_instance_valid(existing):
			return
		if _plot_object_mesh_path(object_type) == "":
			return
		_spawn_plot_object(net_id, object_type, xf, plot_id)
	pm.when_available(PLOT_OBJECTS_PATH + object_type + "/mesh.tscn", retry, "plotobj:" + net_id + ":tscn")
	pm.when_available(PLOT_OBJECTS_PATH + object_type + "/mesh.glb", retry, "plotobj:" + net_id + ":glb")
	print("Plot object ", net_id, " (", object_type, ") waiting for its pack to mount")
	return true


func _serialize_transform(xf: Transform3D) -> Dictionary:
	return {
		"origin": {"x": xf.origin.x, "y": xf.origin.y, "z": xf.origin.z},
		"basis_x": {"x": xf.basis.x.x, "y": xf.basis.x.y, "z": xf.basis.x.z},
		"basis_y": {"x": xf.basis.y.x, "y": xf.basis.y.y, "z": xf.basis.y.z},
		"basis_z": {"x": xf.basis.z.x, "y": xf.basis.z.y, "z": xf.basis.z.z}
	}


func _parse_transform(d: Dictionary) -> Transform3D:
	var b = Basis(
		Vector3(d.basis_x.x, d.basis_x.y, d.basis_x.z),
		Vector3(d.basis_y.x, d.basis_y.y, d.basis_y.z),
		Vector3(d.basis_z.x, d.basis_z.y, d.basis_z.z)
	)
	return Transform3D(b, Vector3(d.origin.x, d.origin.y, d.origin.z))


## Assigns the next free id if it has none.
func _find_or_assign_object_id(obj: Node3D) -> String:
	var id = obj.get_meta("net_id")
	if id != null and typeof(id) == TYPE_STRING and id != "":
		return id
	var new_id = str(_next_object_id)
	_next_object_id += 1
	obj.set_meta("net_id", new_id)
	return new_id


## A fresh id when it is not a Node3D.
func _path_object_id(obj_path: NodePath) -> String:
	var obj: Node = _nc.get_tree().root.get_node_or_null(obj_path)
	if obj and obj is Node3D:
		return _find_or_assign_object_id(obj)
	var net_id = str(_next_object_id)
	_next_object_id += 1
	return net_id


## node_path and velocity are included only when given.
func _object_message(type: String, net_id: String, xf: Transform3D, obj_path = null,
		velocity = null) -> Dictionary:
	_seq_counter += 1
	var msg := {"type": type, "net_id": net_id}
	if obj_path != null:
		msg["node_path"] = str(obj_path)
	msg["transform"] = _serialize_transform(xf)
	if velocity != null:
		msg["velocity"] = {"x": velocity.x, "y": velocity.y, "z": velocity.z}
	msg["seq"] = _seq_counter
	msg["authority"] = _nc.client_id
	return msg


## This client streams the object's transform from now on.
func notify_object_grabbed(obj: Node3D):
	var net_id = _find_or_assign_object_id(obj)
	_nc.send_json(_object_message("object_grab", net_id, obj.global_transform))
	_mark_owned(net_id, obj)


func notify_object_released_with_path(obj_path: NodePath, xf: Transform3D, throw_velocity: Vector3):
	var net_id = _path_object_id(obj_path)
	_nc.send_json(_object_message("object_release", net_id, xf, obj_path, throw_velocity))
	_unmark_owned(net_id)


func notify_object_update_with_path(obj_path: NodePath, xf: Transform3D):
	var net_id = _path_object_id(obj_path)
	_nc.send_json(_object_message("object_update", net_id, xf, obj_path))


func _mark_owned(net_id: String, obj: Node3D):
	_owned_objects[net_id] = obj
	_owned_last_sent.erase(net_id)


func _unmark_owned(net_id: String):
	_owned_objects.erase(net_id)
	_owned_last_sent.erase(net_id)


func register_ship(ship: Node3D):
	if ship.has_method("get_net_id"):
		_known_ships[ship.get_net_id()] = ship


func find_ship(net_id: String) -> Node3D:
	if net_id in _known_ships:
		var ship = _known_ships[net_id]
		if is_instance_valid(ship):
			return ship
		_known_ships.erase(net_id)

	var root = _nc.get_tree().current_scene
	if not root:
		return null
	for ship in _find_ships_recursive(root):
		var sid = ship.get_net_id() if ship.has_method("get_net_id") else ""
		if sid == net_id:
			_known_ships[sid] = ship
			return ship
	return null


func _find_ships_recursive(node: Node) -> Array:
	var result = []
	if node.has_method("get_net_id") and node.has_method("get_sync_data"):
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_ships_recursive(child))
	return result


func send_ship_transform(ship: Node3D):
	if not ship or not ship.has_method("get_sync_data"):
		return
	var sync_data = ship.get_sync_data()
	sync_data["type"] = "ship_transform"
	_nc.send_json(sync_data)


func send_ship_board(ship: Node3D):
	if ship and ship.has_method("get_net_id"):
		_nc.send_json({
			"type": "ship_board",
			"ship_id": ship.get_net_id(),
			"ship_name": ship.ship_name if "ship_name" in ship else "Ship"
		})


func send_ship_depart(ship: Node3D):
	if ship and ship.has_method("get_net_id"):
		_nc.send_json({
			"type": "ship_depart",
			"ship_id": ship.get_net_id()
		})


func _handle_ship_transform(data: Dictionary):
	var net_id = data.get("net_id", "")
	if net_id == "":
		return
	var ship = find_ship(net_id)
	if ship and ship.has_method("apply_sync_data"):
		ship.apply_sync_data(data)


## A late joiner's ship: stored transform plus hull and shield.
func _on_ship_state(data):
	_handle_ship_transform(data)
	var net_id = data.get("net_id", "")
	if net_id == "":
		return
	var ship = find_ship(net_id)
	if ship:
		ship.hull_hp = data.get("hull_hp", 1000.0)
		ship.shield_hp = data.get("shield_hp", 500.0)
		print("Ship state restored: ", net_id, " hull=", ship.hull_hp, " shield=", ship.shield_hp)


func _on_ship_damage(data):
	var net_id = data.get("net_id", "")
	if net_id == "":
		return
	var ship = find_ship(net_id)
	if not ship:
		return
	ship.hull_hp = data.get("hull_hp", 0.0)
	ship.shield_hp = data.get("shield_hp", 0.0)
	ship.ship_damaged.emit(ship.hull_hp, ship.shield_hp)
	if ship.hull_hp <= 0 and not ship._is_destroyed:
		ship._destroy_ship()


func _msg_ship_board(data) -> void:
	var board_player_id = data.get("player_id", -1)
	var board_ship_id = data.get("ship_id", "")
	print("Remote player ", board_player_id, " boarded ship: ", board_ship_id)


func _msg_ship_depart(data) -> void:
	var depart_player_id = data.get("player_id", -1)
	var depart_ship_id = data.get("ship_id", "")
	print("Remote player ", depart_player_id, " departed ship: ", depart_ship_id)

