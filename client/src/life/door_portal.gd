extends Node3D
## A door the local player uses with E: within `use_distance` he is moved to `target`. Use in pairs.

@export var target: NodePath
## Metres.
@export var use_distance := 3.0
## In this node's own units.
@export var prompt_height := 6.0

var _prompt: Label3D = null
var _nc: Node
## Both ends see the same E in one frame; without this you would go through and straight back.
static var _used_at := -1.0


func _ready() -> void:
	_nc = get_node_or_null("/root/NetworkController")
	_prompt = _find_or_make_prompt()
	_size_prompt(_prompt)
	_prompt.visible = false
	if get_node_or_null(target) == null:
		push_warning("[DoorPortal] %s has no target to lead to" % name)


func _find_or_make_prompt() -> Label3D:
	for child in get_children():
		if child is Label3D and str(child.name) == "Prompt":
			return child
	var label := Label3D.new()
	label.name = "Prompt"
	label.text = "E"
	label.font_size = 48
	label.outline_size = 12
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.position = Vector3(0, prompt_height, 0)
	add_child(label)
	_size_prompt(label)
	return label


func _size_prompt(label: Label3D) -> void:
	var s: Vector3 = global_transform.basis.get_scale()
	var unit: float = (absf(s.x) + absf(s.y) + absf(s.z)) / 3.0
	if unit > 0.0001 and not is_equal_approx(unit, 1.0):
		label.scale = Vector3.ONE / unit


func _process(_delta: float) -> void:
	var me := _local_player()
	if me == null:
		_set_prompt(false)
		return
	var near := me.global_position.distance_to(global_position) <= use_distance
	_set_prompt(near)
	if not near:
		return
	if not Input.is_action_just_pressed("interact") or _typing_elsewhere(me):
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - _used_at < 0.4:
		return
	_used_at = now
	use(me)


## False when there is no target or body.
func use(body: Node3D) -> bool:
	var dest := get_node_or_null(target) as Node3D
	if dest == null or body == null or not is_instance_valid(body):
		return false
	body.global_position = _standing_spot(dest.global_position, body)
	if body is CharacterBody3D:
		(body as CharacterBody3D).velocity = Vector3.ZERO
	_set_prompt(false)
	return true


## Puts the feet, not the mid-body origin, on the floor under `at`.
func _standing_spot(at: Vector3, body: Node3D) -> Vector3:
	var space := get_world_3d().direct_space_state if get_world_3d() != null else null
	if space == null:
		return at
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.3, at + Vector3.DOWN * 3.0)
	if body is CollisionObject3D:
		query.exclude = [(body as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return at
	return hit.position + Vector3.UP * (_foot_drop(body) + 0.05)


## World metres.
func _foot_drop(body: Node3D) -> float:
	var lowest := 0.0
	for child in body.get_children():
		if not (child is CollisionShape3D):
			continue
		var col := child as CollisionShape3D
		if col.shape == null or col.disabled:
			continue
		var half := 0.0
		var shape := col.shape
		if shape is CapsuleShape3D:
			half = (shape as CapsuleShape3D).height * 0.5
		elif shape is CylinderShape3D:
			half = (shape as CylinderShape3D).height * 0.5
		elif shape is BoxShape3D:
			half = (shape as BoxShape3D).size.y * 0.5
		elif shape is SphereShape3D:
			half = (shape as SphereShape3D).radius
		else:
			continue
		lowest = minf(lowest, col.position.y - half)
	if lowest >= 0.0:
		return 0.0
	var scale_y: float = absf(body.global_transform.basis.get_scale().y)
	return -lowest * (scale_y if scale_y > 0.0001 else 1.0)


func _local_player() -> Node3D:
	if _nc == null or not is_instance_valid(_nc.get_indexed("players:local_player")):
		return null
	return _nc.players.local_player


func _typing_elsewhere(me: Node) -> bool:
	return me.has_method("_typing") and me._typing()


func _set_prompt(on: bool) -> void:
	if _prompt != null and is_instance_valid(_prompt):
		_prompt.visible = on
