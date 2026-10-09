extends Node
## Controller actions that keep working while locomotion is paused (car, lift floor).

var player: Node3D
var _pressed := {}

func _ready() -> void:
	player = get_parent() as Node3D

func _process(_delta: float) -> void:
	if player.get("is_remote_player") != false or player.get("is_vr_mode") != true:
		_pressed.clear()
		return
	var movement = player.get("vr_movement")
	if movement == null:
		return
	var left = movement.left_hand
	var right = movement.right_hand
	var interact := _edge("interact", _button(left, "ax_button"))
	var chat := _edge("chat_left", _button(left, "by_button"))
	chat = _edge("chat_right", _button(right, "by_button")) or chat
	var horn := _edge("horn", _button(left, "primary_click"))
	var doors := _edge("doors", _button(right, "primary_click"))
	# Close the floor selector first; never toggle chat behind a modal panel.
	var holder = player.get("key_holder")
	if is_instance_valid(holder):
		if (interact or chat) and holder.has_method("vr_close"):
			holder.vr_close()
		return
	if chat:
		movement._toggle_chat_panel()
	if player.has_method("_typing") and player._typing():
		return
	var network := get_node_or_null("/root/NetworkController")
	var vehicles = network.vehicle_manager() if network != null and network.has_method("vehicle_manager") else null
	if is_instance_valid(vehicles) and is_instance_valid(vehicles.riding()):
		if interact:
			vehicles._toggle_ride(player)
		elif doors:
			vehicles._toggle_doors(player)
		elif horn and vehicles.riding().driver == player:
			vehicles.riding().honk()
			vehicles.broadcast_horn(vehicles.riding())
		return
	if interact:
		interact_nearest()

func interact_nearest() -> void:
	var nearest: Node = null
	var distance := INF
	for target in get_tree().get_nodes_in_group("vr_interactable"):
		var d: float = target.vr_interaction_distance(player)
		if d < distance:
			distance = d
			nearest = target
	if nearest != null:
		nearest.vr_interact(player)

func _edge(action: String, down: bool) -> bool:
	var just := down and not bool(_pressed.get(action, false))
	_pressed[action] = down
	return just

static func _button(hand, action: String) -> bool:
	return is_instance_valid(hand) and hand.get_has_tracking_data() and hand.is_button_pressed(action)
