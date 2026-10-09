extends SceneTree
## The client's message handlers (NetworkController plus module MESSAGES) match protocol/messages.json.

const NetworkControllerScript = preload("res://src/net/network_controller.gd")
const MODULES := [
	"res://src/vehicles/vehicle_manager.gd",
	"res://src/npc/npc_manager.gd",
	"res://src/combat/combat_sync.gd",
	"res://src/minigames/pocketmonsters/monster_controller.gd",
	"res://src/life/ambient_manager.gd",
	"res://src/life/engagement.gd",
]


func _initialize() -> void:
	var path := ProjectSettings.globalize_path("res://").path_join("../protocol/messages.json")
	var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var messages: Dictionary = contract.messages
	var nc: Node = NetworkControllerScript.new()
	var handled: PackedStringArray = nc.handled_types()
	nc.free()
	for module_path in MODULES:
		var table: Dictionary = load(module_path).get_script_constant_map().get("MESSAGES", {})
		for type in table:
			if handled.has(type):
				push_error("FAIL: %s is handled twice" % type)
			handled.append(type)
	var failures := 0
	for type in messages:
		if bool(messages[type].client) != handled.has(type):
			failures += 1
			push_error("FAIL: %s: contract says client=%s" % [type, messages[type].client])
	for type in handled:
		if not messages.has(type):
			failures += 1
			push_error("FAIL: %s is handled but missing from the contract" % type)
	print("PROTOCOL: %d types, %d failures" % [messages.size(), failures])
	quit(1 if failures > 0 else 0)
