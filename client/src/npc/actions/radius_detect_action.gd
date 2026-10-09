extends NpcAction
## Waits for a player within `radius` (world units), stores it in the "detected_player" meta, then finishes.

var radius: float = 15.0


func start(npc: CharacterBody3D) -> void:
	_finished = false
	print("[RadiusDetect] Watching for players within %.1f global units of %s" % [radius, npc.name])


func process(npc: CharacterBody3D, delta: float) -> void:
	var player = _find_nearest_player(npc)
	if player == null:
		return

	var dist: float = _flat_distance(npc.global_position, player.global_position)
	if dist <= radius:
		npc.set_meta("detected_player", player)
		print("[RadiusDetect] Player '%s' detected by %s (dist=%.2f)" % [player.name, npc.name, dist])
		_finished = true


## Returns the nearest player on the XZ plane, local player first, or null.
func _find_nearest_player(npc: CharacterBody3D) -> Node3D:
	var workspace = npc.get_parent().get_parent()  # NPCs -> workspace
	if not workspace:
		return null

	var best: Node3D = null
	var best_dist := INF
	for child in _player_candidates(workspace, npc):
		var d: float = _flat_distance(npc.global_position, child.global_position)
		if d < best_dist:
			best_dist = d
			best = child
	return best


## Local player (workspace child with a LocalPlayer node) plus every remote player under "Players".
func _player_candidates(workspace: Node, npc: CharacterBody3D) -> Array:
	var out: Array = []
	for child in workspace.get_children():
		if child is CharacterBody3D and child != npc and child.get_node_or_null("LocalPlayer"):
			out.append(child)
	var players_node = workspace.get_node_or_null("Players")
	if players_node:
		for child in players_node.get_children():
			if child is CharacterBody3D:
				out.append(child)
	return out


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
