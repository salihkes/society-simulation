extends NpcAction
## Moves the NPC to `target_position` (local space) and finishes at once.

var target_position: Vector3 = Vector3.ZERO


func start(npc: CharacterBody3D) -> void:
	_finished = false
	npc.position = target_position
	print("[Teleport] %s teleported to %s" % [npc.name, target_position])
	_finished = true
