extends NpcAction
## Runs child actions in sequence; finishes when the last step finishes.

var _steps: Array = []
var _current_step := 0


## Appends a step and returns self so calls can be chained.
func add_step(action: NpcAction) -> NpcAction:
	_steps.append(action)
	return self


func start(npc: CharacterBody3D) -> void:
	_finished = false
	_current_step = 0
	if _steps.size() > 0:
		_steps[0].start(npc)


func process(npc: CharacterBody3D, delta: float) -> void:
	if _current_step >= _steps.size():
		_finished = true
		return

	var step: NpcAction = _steps[_current_step]
	step.process(npc, delta)

	if step.is_finished():
		step.stop(npc)
		_current_step += 1
		if _current_step < _steps.size():
			_steps[_current_step].start(npc)
		else:
			_finished = true


func stop(npc: CharacterBody3D) -> void:
	if _current_step < _steps.size():
		_steps[_current_step].stop(npc)


func reset() -> void:
	_finished = false
	_current_step = 0
	for step in _steps:
		if step.has_method("reset"):
			step.reset()
		step._finished = false
