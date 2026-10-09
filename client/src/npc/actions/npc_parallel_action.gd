extends NpcAction
## Runs child actions at the same time; finishes when all children finish.

var _steps: Array = []


## Appends a step and returns self so calls can be chained.
func add_step(action: NpcAction) -> NpcAction:
	_steps.append(action)
	return self


func start(npc: CharacterBody3D) -> void:
	_finished = false
	for step in _steps:
		step.start(npc)


func process(npc: CharacterBody3D, delta: float) -> void:
	var all_done := true
	for step in _steps:
		if not step.is_finished():
			step.process(npc, delta)
			if not step.is_finished():
				all_done = false
	if all_done:
		_finished = true


func stop(npc: CharacterBody3D) -> void:
	for step in _steps:
		step.stop(npc)


func reset() -> void:
	_finished = false
	for step in _steps:
		if step.has_method("reset"):
			step.reset()
		step._finished = false
