extends NpcAction
## Waits `duration` seconds, then finishes.

var duration: float = 3.0
var _timer: float = 0.0


func start(npc: CharacterBody3D) -> void:
	_finished = false
	_timer = 0.0


func process(npc: CharacterBody3D, delta: float) -> void:
	_timer += delta
	if _timer >= duration:
		_finished = true
