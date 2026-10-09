extends Node
## On mobile GPUs, lets only the nearest, widest `budget` shadowed lights cast shadows at once.

## Shadow-casting positional lights allowed at once.
var budget := 8
## World-space range beyond which a light never casts.
var max_distance := 40.0
## Seconds between re-rankings.
var refresh := 0.2

## Positional lights authored with shadows.
var _lights: Array[Light3D] = []
## This pass's winners, best first.
var _best: Array[Light3D] = []
var _best_score := PackedFloat32Array()
var _started := false
var _t := 0.0


func _ready() -> void:
	# "mobile" covers Android (Quest) and iOS/iPadOS.
	if OS.has_feature("mobile"):
		start()
	else:
		set_process(false)


## Runs by itself on mobile; tests call it directly on desktop.
func start() -> void:
	if _started:
		return
	_started = true
	set_process(true)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_best.resize(budget)
	_best_score.resize(budget)
	get_tree().node_added.connect(_on_node_added)
	# Lights added later arrive through node_added.
	_scan(get_tree().root)
	print("[ShadowBudget] active; budget=%d, cutoff=%.0fm, tracking %d lights" % [
		budget, max_distance, _lights.size()])


func _scan(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children():
		_scan(child)


## Directional lights have their own shadow map and are left alone.
func _on_node_added(node: Node) -> void:
	if not (node is OmniLight3D or node is SpotLight3D):
		return
	var light := node as Light3D
	# Checked first, so a tracked light this node switched off stays tracked.
	if _lights.has(light):
		return
	if not light.shadow_enabled:
		return
	_lights.append(light)


func _process(delta: float) -> void:
	_t += delta
	if _t < refresh:
		return
	_t = 0.0
	apply_now()


func apply_now() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye := cam.global_position
	var cutoff := max_distance * max_distance

	if _best.size() != budget:
		_best.resize(budget)
		_best_score.resize(budget)
	for i in _best.size():
		_best[i] = null
		_best_score[i] = 0.0

	# Insertion into a short fixed list: no sort, no allocation.
	for i in range(_lights.size() - 1, -1, -1):
		var light := _lights[i]
		if not is_instance_valid(light) or not light.is_inside_tree():
			_lights.remove_at(i)
			continue
		if not light.is_visible_in_tree():
			continue
		# A casting light keeps a margin in range and rank so near-ties do not flicker.
		var casting := light.shadow_enabled
		var d2 := eye.distance_squared_to(light.global_position)
		if d2 > (cutoff * 1.44 if casting else cutoff):
			continue
		# Reach over distance: a wide light outranks a small one equally far.
		var reach: float = light.omni_range if light is OmniLight3D else light.spot_range
		var score := reach * reach / maxf(d2, 0.01)
		_consider(light, score * 1.25 if casting else score)

	for light in _lights:
		_set_shadow(light, _best.has(light))


## Inserts light into _best (ordered best first) if it beats an entry.
func _consider(light: Light3D, score: float) -> void:
	var at := -1
	for i in _best.size():
		if _best[i] == null or score > _best_score[i]:
			at = i
			break
	if at < 0:
		return
	for i in range(_best.size() - 1, at, -1):
		_best[i] = _best[i - 1]
		_best_score[i] = _best_score[i - 1]
	_best[at] = light
	_best_score[at] = score


func _set_shadow(light: Light3D, on: bool) -> void:
	# Writing an unchanged value still dirties the light on the server.
	if light.shadow_enabled != on:
		light.shadow_enabled = on
