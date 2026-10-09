extends Node
class_name MapNetworkController
## Syncs ProvinceMap with the server: debounced full-state sends, remote applies without echo.

## Empty: searched for under the parent, then the current scene.
@export var province_map_path: NodePath

## Seconds over which rapid local edits are batched into one message.
@export var debounce_interval: float = 0.15

var _province_map: ProvinceMap
## The NetworkController (has send_json), or null when offline.
var _network_controller: Node

## True while a remote state is applied, so it is not sent back.
var _applying_remote: bool = false

var _pending_send: bool = false
var _debounce_timer: float = 0.0

## Until then local changes are not sent, or the default map would overwrite the server's.
var _initial_state_received: bool = false


func _ready() -> void:
	if not province_map_path.is_empty():
		_province_map = get_node_or_null(province_map_path)
	if not _province_map:
		_province_map = _find_child_of_type(get_parent(), "ProvinceMap")
	if not _province_map:
		_province_map = _find_child_of_type(get_tree().current_scene, "ProvinceMap")

	if _province_map:
		_province_map.data_changed.connect(_on_local_change)
		_province_map.owners_changed.connect(_on_local_change)
		print("MapNetworkController: Connected to ProvinceMap")
	else:
		push_warning("MapNetworkController: ProvinceMap not found — map sync disabled")

	_network_controller = _find_network_controller()
	if _network_controller:
		print("MapNetworkController: NetworkController found — network sync enabled")
	else:
		print("MapNetworkController: NetworkController not found — running offline")


func _process(delta: float) -> void:
	if not _pending_send:
		return
	_debounce_timer += delta
	if _debounce_timer >= debounce_interval:
		_flush_state_to_server()


func _on_local_change() -> void:
	if _applying_remote:
		return
	if not _initial_state_received:
		return
	_pending_send = true
	_debounce_timer = 0.0


func _flush_state_to_server() -> void:
	_pending_send = false
	_debounce_timer = 0.0

	if not _province_map or not _network_controller:
		return

	var state := _province_map.serialize_state()
	_network_controller.send_json({
		"type": "map_full_update",
		"state": state,
	})


## Also cancels any pending local send.
func apply_remote_state(state: Dictionary) -> void:
	if not _province_map:
		push_warning("MapNetworkController: Can't apply remote state — no ProvinceMap")
		return

	_applying_remote = true
	_province_map.apply_state(state)
	_applying_remote = false
	_initial_state_received = true

	_pending_send = false
	_debounce_timer = 0.0
	print("MapNetworkController: Applied remote map state")


func request_state_from_server() -> void:
	if not _network_controller:
		return
	_network_controller.send_json({
		"type": "map_request_state",
	})


## Registers the owner in ProvinceMap first, whose owner setters ignore unknown ids.
func handle_player_owner(data: Dictionary) -> void:
	var owner_id: String = data.get("owner_id", "")
	var color: String = data.get("color", "")
	print("MapNetworkController: Received player owner — %s (#%s)" % [owner_id, color])

	if _province_map and not color.is_empty():
		var c := Color(color)
		_province_map.register_owner(owner_id, owner_id, c)
		print("MapNetworkController: Registered owner in ProvinceMap")

	_tell_main("set_player_owner", [owner_id, color])


func handle_online_owners(data: Dictionary) -> void:
	var online_ids: Array = data.get("online_owner_ids", [])
	var require_online: bool = data.get("require_online", true)
	_tell_main("set_online_owners", [online_ids, require_online])


func handle_treaty_incoming(data: Dictionary) -> void:
	var treaty_id: String = data.get("treaty_id", "")
	var proposer: String = data.get("proposer", "")
	var expires_in: float = float(data.get("expires_in", 30))
	print("MapNetworkController: Incoming treaty %s from %s" % [treaty_id, proposer])
	_tell_main("show_treaty_incoming", [treaty_id, proposer, expires_in])


func handle_treaty_pending(data: Dictionary) -> void:
	var treaty_id: String = data.get("treaty_id", "")
	var target: String = data.get("target", "")
	print("MapNetworkController: Treaty %s pending (target: %s)" % [treaty_id, target])


func handle_treaty_resolved(data: Dictionary) -> void:
	var accepted: bool = data.get("accepted", false)
	var proposer: String = data.get("proposer", "")
	var target: String = data.get("target", "")
	print("MapNetworkController: Treaty resolved — accepted=%s (%s <-> %s)" %
		  [str(accepted), proposer, target])
	_tell_main("show_treaty_resolved", [accepted, proposer, target])


func send_treaty_propose(target_username: String) -> void:
	if not _network_controller:
		return
	_network_controller.send_json({
		"type": "treaty_propose",
		"target": target_username,
	})


func send_treaty_respond(treaty_id: String, accept: bool) -> void:
	if not _network_controller:
		return
	_network_controller.send_json({
		"type": "treaty_respond",
		"treaty_id": treaty_id,
		"accept": accept,
	})


## Calls method on the main script when it is there and has it.
func _tell_main(method: String, args: Array) -> void:
	var main_node := _find_main_gd()
	if main_node and main_node.has_method(method):
		main_node.callv(method, args)


## The parent, when it is the map's main script.
func _find_main_gd() -> Node:
	var p := get_parent()
	if p and p.has_method("set_player_owner"):
		return p
	return null


## A NetworkController under the "workspace" node, else the autoload.
func _find_network_controller() -> Node:
	var workspace := get_tree().get_root().find_child("workspace", true, false)
	if workspace:
		var nc := workspace.find_child("NetworkController", true, false)
		if nc and nc.has_method("send_json"):
			return nc
	var nc := get_node_or_null("/root/NetworkController")
	if nc and nc.has_method("send_json"):
		return nc
	return null


func _find_child_of_type(node: Node, type_name: String) -> ProvinceMap:
	if node == null:
		return null
	if node.get_class() == type_name or (node is ProvinceMap):
		return node as ProvinceMap
	for child in node.get_children():
		var found := _find_child_of_type(child, type_name)
		if found:
			return found
	return null
