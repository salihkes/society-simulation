extends Node3D
class_name VehicleModel

## The visual half of a vehicle: fits the model and animates its parts; it never moves the vehicle.

signal built

const DOOR_SECONDS := 0.55
const PAINT_SHADER := "res://src/vehicles/vehicle_paint.gdshader"

## One per definition; colours are instance uniforms.
static var _paint_materials: Dictionary = {}

## Toggled by the "/vehicle lean" chat command.
static var lean_enabled := true

var definition: VehicleDefinition
var model: Node3D = null
var fit_scale := 1.0
var extent := AABB()
var is_built := false

var wheels: Array[Node3D] = []
var steer_pivots: Array[Node3D] = []
var steering_wheel: Node3D = null
var _rim_rest := Basis()
## Node3D or null, aligned with definition.doors.
var doors: Array = []
var doors_open := 0  # bitmask
var _steer_rest: Array[Basis] = []
var _door_closed: Array[Transform3D] = []
var _door_t: Array[float] = []
var paint_meshes: Array[MeshInstance3D] = []
var lean_pivot: Node3D = null
var _lean := Vector2.ZERO  # x = roll, y = pitch, radians
var _lean_vel := Vector2.ZERO
var _lean_prev_speed := 0.0
var _lean_steer := 0.0
var _lat_reference := 1.0
## Rest pose, so queries ignore lean and open doors.
var _rest_wheels: Array[Vector3] = []
var _rest_doors: Array = []
var _rest_anchors: Dictionary = {}
var body_color := Color.WHITE
var roof_color := Color.WHITE
var _head_mats: Array[StandardMaterial3D] = []
var _tail_mats: Array[StandardMaterial3D] = []
var _head_on := false
var _brake_on := false
var _lights_inited := false
var _wait_key := ""


## `wait_key` names the PCKManager wait on the web build.
func build(p_definition: VehicleDefinition, wait_key := "") -> void:
	definition = p_definition if p_definition != null else VehicleDefinition.new()
	_wait_key = wait_key
	for i in definition.doors.size():
		doors.append(null)
		_door_closed.append(Transform3D.IDENTITY)
		_door_t.append(0.0)
	_try_build()


func _try_build() -> void:
	if is_built:
		return
	var path := definition.model_path
	if path == "":
		_build_placeholder()
		return
	if not ResourceLoader.exists(path):
		var pm = get_node_or_null("/root/PCKManager")
		if pm != null and pm.has_method("when_available"):
			pm.when_available(path, _try_build, _wait_key)
		else:
			push_warning("[VehicleModel] Missing model %s — placeholder" % path)
			_build_placeholder()
		return
	var scene = load(path)
	var inst: Node3D = null
	if scene != null and scene is PackedScene:
		inst = (scene as PackedScene).instantiate() as Node3D
	if inst == null:
		push_warning("[VehicleModel] Cannot load model %s — placeholder" % path)
		_build_placeholder()
		return
	_ensure_pivot()
	lean_pivot.add_child(inst)
	model = inst
	var fit: Dictionary = definition.fit_model(inst)
	fit_scale = float(fit.scale)
	extent = fit.extent
	_find_parts()
	is_built = true
	built.emit()


func _build_placeholder() -> void:
	var length: float = definition.target_length if definition.target_length > 0.0 else 16.0
	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(length * 0.4, length * 0.45, length)
	box.mesh = mesh
	box.position.y = mesh.size.y * 0.5
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.9, 0.85, 0.2)
	box.material_override = paint
	_ensure_pivot()
	lean_pivot.add_child(box)
	model = box
	fit_scale = 1.0
	extent = AABB(Vector3(-mesh.size.x * 0.5, 0.0, -length * 0.5), mesh.size)
	is_built = true
	built.emit()


func _ensure_pivot() -> void:
	if lean_pivot != null:
		return
	lean_pivot = Node3D.new()
	lean_pivot.name = "Lean"
	add_child(lean_pivot)


func _find_parts() -> void:
	var who := definition.display_name
	for i in definition.doors.size():
		var spec: Dictionary = definition.doors[i]
		var door: Node3D = model.find_child(str(spec.get("node", "")), true, false) as Node3D
		if door == null:
			push_warning("[VehicleModel] %s: no door node '%s'" % [who, spec.get("node", "")])
			continue
		doors[i] = door
		_door_closed[i] = door.transform
	for wheel_name in definition.wheels:
		var w: Node3D = model.find_child(wheel_name, true, false) as Node3D
		if w != null:
			wheels.append(w)
		else:
			push_warning("[VehicleModel] %s: no wheel node '%s'" % [who, wheel_name])
	for pivot_name in definition.steer_pivots:
		var p: Node3D = model.find_child(pivot_name, true, false) as Node3D
		if p != null:
			steer_pivots.append(p)
			_steer_rest.append(p.transform.basis)
		else:
			push_warning("[VehicleModel] %s: no steering pivot '%s'" % [who, pivot_name])
	if definition.steering_wheel != "":
		steering_wheel = model.find_child(definition.steering_wheel, true, false) as Node3D
		if steering_wheel != null:
			_rim_rest = steering_wheel.transform.basis
		else:
			push_warning("[VehicleModel] %s: no steering wheel '%s'" %
				[who, definition.steering_wheel])
	_head_mats = _lamp_materials(definition.headlights, Color(1.0, 0.93, 0.78))
	_tail_mats = _lamp_materials(definition.tail_lights, Color(1.0, 0.12, 0.08))
	_find_paint()
	_measure_rest()


func _measure_rest() -> void:
	for w in wheels:
		_rest_wheels.append(_walk_local(w))
	for d in doors:
		_rest_doors.append(_walk_local(d) if d != null else null)
	for anchor_name in definition.seat_names():
		var n := model.find_child(anchor_name, true, false) if model != null else null
		if n is Node3D:
			_rest_anchors[anchor_name] = _walk_local(n as Node3D)
	# fit_scale is workspace units per model unit.
	_lat_reference = maxf(definition.lean_full_g * 9.81 * fit_scale, 0.001)


func _lamp_materials(names: Array[String], glow: Color) -> Array[StandardMaterial3D]:
	var out: Array[StandardMaterial3D] = []
	for lamp_name in names:
		var node := model.find_child(lamp_name, true, false)
		if node == null:
			push_warning("[VehicleModel] %s: no light mesh '%s'" %
				[definition.display_name, lamp_name])
			continue
		for mi in _lamp_meshes(node):
			if mi.mesh == null:
				continue
			for si in mi.mesh.get_surface_count():
				out.append(_lamp_surface(mi, si, glow))
	return out


func _lamp_meshes(node: Node) -> Array:
	var meshes: Array = []
	if node is MeshInstance3D:
		meshes.append(node)
	for c in node.get_children():
		if c is MeshInstance3D:
			meshes.append(c)
	return meshes


func _lamp_surface(mi: MeshInstance3D, si: int, glow: Color) -> StandardMaterial3D:
	var src = mi.get_active_material(si)
	var mat: StandardMaterial3D
	if src is StandardMaterial3D:
		mat = (src as StandardMaterial3D).duplicate()
	else:
		mat = StandardMaterial3D.new()
		mat.albedo_color = glow.darkened(0.4)
	mat.emission_enabled = true
	mat.emission = glow
	mat.emission_energy_multiplier = 0.0
	mi.set_surface_override_material(si, mat)
	return mat


## The mask is in the second UV layer, so it follows the doors.
func _find_paint() -> void:
	if not definition.paintable():
		return
	var stack: Array = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.append(c)
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if _paint_surfaces(mi):
			paint_meshes.append(mi)
	if paint_meshes.is_empty():
		push_warning("[VehicleModel] %s: no surfaces use paint material '%s'" %
			[definition.display_name, definition.paint_material])


func _paint_surfaces(mi: MeshInstance3D) -> bool:
	var painted := false
	for si in mi.mesh.get_surface_count():
		var src := mi.get_active_material(si) as StandardMaterial3D
		if src == null or src.resource_name != definition.paint_material:
			continue
		var mat := _paint_material(src)
		if mat == null:
			continue
		mi.set_surface_override_material(si, mat)
		painted = true
	return painted


func _paint_material(src: StandardMaterial3D) -> ShaderMaterial:
	var key: String = definition.resource_path + "|" + definition.paint_material
	var cached = _paint_materials.get(key)
	if cached != null and is_instance_valid(cached):
		return cached
	var shader = load(PAINT_SHADER)
	if shader == null:
		push_warning("[VehicleModel] paint shader missing: " + PAINT_SHADER)
		return null
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("base_texture", src.albedo_texture)
	mat.set_shader_parameter("normal_texture", src.normal_texture)
	mat.set_shader_parameter("orm_texture", src.metallic_texture)
	mat.set_shader_parameter("vehicle_kind", definition.paint_kind)
	_paint_materials[key] = mat
	return mat


func has_paint() -> bool:
	return not paint_meshes.is_empty()


## `amount` 0 keeps the delivered livery, 1 is full repaint.
func set_paint(body: Color, roof: Color, amount := 1.0) -> void:
	body_color = body
	roof_color = roof
	for mi in paint_meshes:
		mi.set_instance_shader_parameter("body_color", body)
		mi.set_instance_shader_parameter("roof_color", roof)
		mi.set_instance_shader_parameter("recolor_amount", amount)


func paint_from_id(id: String) -> void:
	if not has_paint():
		return
	var pick: Dictionary = definition.paint_for(id)
	set_paint(pick.body, pick.roof)


# Queries return positions in this node's space.

func anchor_local(anchor_name: String):
	if _rest_anchors.has(anchor_name):
		return _rest_anchors[anchor_name]
	if model == null:
		return null
	var n := model.find_child(anchor_name, true, false)
	if not (n is Node3D):
		return null
	return _walk_local(n as Node3D)


func wheel_positions_local() -> Array[Vector3]:
	if not _rest_wheels.is_empty():
		return _rest_wheels
	var out: Array[Vector3] = []
	for w in wheels:
		out.append(_walk_local(w))
	return out


## The rest pose, not the current (possibly open) one; null if absent.
func door_position_local(i: int):
	if i < 0 or i >= doors.size():
		return null
	if i < _rest_doors.size():
		return _rest_doors[i]
	return _walk_local(doors[i]) if doors[i] != null else null


func _walk_local(n: Node3D) -> Vector3:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != self:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf.origin


## `speed` in workspace units / s, `steer` in radians (+ = left).
func animate(delta: float, speed: float, steer: float) -> void:
	if not is_built:
		return
	var r: float = definition.wheel_radius * fit_scale
	if absf(speed) > 0.01 and r > 0.001 and not wheels.is_empty():
		var spin := speed / r * delta * definition.wheel_spin_sign
		var axis := definition.wheel_axis.normalized()
		for w in wheels:
			w.rotate_object_local(axis, spin)
	_lean_steer = steer
	for i in steer_pivots.size():
		steer_pivots[i].transform.basis = _steer_rest[i] * Basis(Vector3.UP, steer)
	if steering_wheel != null and definition.max_steer_deg > 0.0:
		var wound: float = steer * definition.steering_wheel_deg / definition.max_steer_deg
		var column := definition.steering_wheel_axis.normalized()
		steering_wheel.transform.basis = _rim_rest * Basis(column, wound)
	_update_lean(delta, speed)
	for i in doors.size():
		var target := 1.0 if (doors_open >> i) & 1 else 0.0
		if is_equal_approx(_door_t[i], target):
			continue
		_door_t[i] = move_toward(_door_t[i], target, delta / DOOR_SECONDS)
		_apply_door(i)


func _update_lean(delta: float, speed: float) -> void:
	if lean_pivot == null or delta <= 0.0:
		return
	var d := definition
	var target := Vector2.ZERO
	if lean_enabled and (d.lean_roll_deg != 0.0 or d.lean_pitch_deg != 0.0):
		var wb: float = maxf(d.wheelbase * fit_scale, 0.1)
		# Lateral acceleration of a bicycle model: v² tan(steer) / wheelbase.
		var lateral: float = speed * speed * tan(_lean_steer) / wb
		var roll_ratio: float = clampf(lateral / _lat_reference, -1.0, 1.0)
		var along: float = (speed - _lean_prev_speed) / delta
		var pitch_ratio: float = clampf(along / maxf(d.drive_brake, 1.0), -1.0, 1.0)
		target = Vector2(-roll_ratio * deg_to_rad(d.lean_roll_deg),
			pitch_ratio * deg_to_rad(d.lean_pitch_deg))
	_lean_prev_speed = speed
	_lean_vel += (target - _lean) * d.lean_stiffness * delta
	_lean_vel *= exp(-d.lean_damping * delta)
	_lean += _lean_vel * delta
	lean_pivot.transform.basis = Basis(Vector3.RIGHT, _lean.y) * Basis(Vector3.BACK, _lean.x)


func lean_angles() -> Vector2:
	return _lean


func lean_basis() -> Basis:
	return lean_pivot.transform.basis if lean_pivot != null else Basis.IDENTITY


func _apply_door(i: int) -> void:
	var door = doors[i]
	if door == null:
		return
	var spec: Dictionary = definition.doors[i]
	var closed: Transform3D = _door_closed[i]
	var t: float = _door_t[i]
	var e := t * t * (3.0 - 2.0 * t)
	if str(spec.get("kind", "hinge")) == "slide":
		var off: Vector3 = spec.get("offset", Vector3.ZERO)
		door.transform = Transform3D(closed.basis, closed.origin + off * e)
	else:
		var axis: Vector3 = spec.get("axis", Vector3.UP)
		if axis.length_squared() < 0.0001:
			axis = Vector3.UP
		var ang := deg_to_rad(float(spec.get("angle", 70.0))) * e
		door.transform = Transform3D(closed.basis * Basis(axis.normalized(), ang), closed.origin)


func set_doors_mask(mask: int) -> void:
	doors_open = mask


func all_doors_mask() -> int:
	var m := 0
	for i in doors.size():
		if doors[i] != null:
			m |= 1 << i
	return m


## Tail lights follow the headlights and flare when braking.
func set_lights(head_on: bool, brake: bool) -> void:
	if _lights_inited and head_on == _head_on and brake == _brake_on:
		return
	_lights_inited = true
	_head_on = head_on
	_brake_on = brake
	for m in _head_mats:
		m.emission_energy_multiplier = 3.0 if head_on else 0.0
	var tail := 0.0
	if brake:
		tail = 4.0
	elif head_on:
		tail = 1.2
	for m in _tail_mats:
		m.emission_energy_multiplier = tail
