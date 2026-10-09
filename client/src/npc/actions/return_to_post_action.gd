extends NpcAction
## Walks the NPC back to its current waypoint (its post), then finishes.

var walk_speed: float = 3.0
var arrival_threshold: float = 2.0


func start(npc: CharacterBody3D) -> void:
	_finished = false
	print("[ReturnToPost] %s returning to post" % npc.name)


func process(npc: CharacterBody3D, delta: float) -> void:
	# _target_waypoint_pos is in workspace-local space.
	var post_local: Vector3 = npc.get("_target_waypoint_pos")
	var workspace: Node3D = npc.get_parent().get_parent()
	var post_global: Vector3 = workspace.to_global(post_local) if workspace else post_local

	var to_post: Vector3 = post_global - npc.global_position
	to_post.y = 0.0
	var dist: float = to_post.length()

	if dist <= arrival_threshold:
		npc.velocity.x = 0.0
		npc.velocity.z = 0.0
		_finished = true
		return

	var dir: Vector3 = to_post.normalized()
	npc.velocity.x = dir.x * walk_speed
	npc.velocity.z = dir.z * walk_speed

	if npc.character_model:
		var target_rot: float = atan2(dir.x, dir.z) + PI
		npc.character_model.rotation.y = lerp_angle(
			npc.character_model.rotation.y, target_rot, delta * 10.0
		)
