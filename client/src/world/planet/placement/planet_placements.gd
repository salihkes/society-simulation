@tool
class_name PlanetPlacements
extends Node3D
## Planet props and buildings: anchors re-derived after every bake, plus hand-placed children settled in the editor.

## [{scene, dir, yaw (rad), h_off (m), align (0 plumb, 1 normal), scale, pad_radius, pad_falloff, local_offset, collision}]
@export var anchors: Array[Dictionary] = []
@export var auto_collision := true
## In the editor, a hand-placed child settles 0.6 s after it stops moving and the terrain rebakes.
@export var manage_manual_children := true
## Per child: meta "curve" overrides this, meta "pad" sets the pad radius (0 disables).
@export var curve_children := false

var _placeholder_mesh: BoxMesh
## instance_id -> {xf, settle}
var _manual := {}
var _manual_pads := {}
## Editor bend preview: child -> {mesh or shape node: flat original}.
var _bent := {}


func _enter_tree() -> void:
	add_to_group("planet_height_stampers")
	add_to_group("planet_bake_listeners")


func _process(delta: float) -> void:
	if not Engine.is_editor_hint() or not manage_manual_children:
		return
	var terrain := _find_terrain()
	if terrain == null:
		return
	for child in get_children():
		if not (child is Node3D) or child.has_meta("anchor_index"):
			continue
		_track_manual_child(child, terrain, delta)


func _track_manual_child(child: Node3D, terrain: PlanetTerrain, delta: float) -> void:
	var id := child.get_instance_id()
	if not _manual.has(id):
		_manual[id] = {"xf": child.transform, "settle": 0.6}
		return
	var entry: Dictionary = _manual[id]
	if child.transform != entry["xf"]:
		entry["xf"] = child.transform
		entry["settle"] = 0.6
		# Its scale may have changed.
		_manual_pads.erase(id)
	elif entry["settle"] > 0.0:
		entry["settle"] -= delta
		if entry["settle"] <= 0.0:
			_settle_manual_child(child, terrain)


## Also bends it if curved and rebakes the terrain.
func _settle_manual_child(child: Node3D, terrain: PlanetTerrain) -> void:
	var dir := child.position.normalized()
	if dir.length_squared() < 0.5:
		return
	# The z column is forward, as in resolve_transform.
	var up := dir
	var fwd := child.basis.z
	fwd = fwd - up * fwd.dot(up)
	if fwd.length_squared() < 1.0e-6:
		fwd = CubeSphere.tangent_frame(dir)[0]
	fwd = fwd.normalized()
	var scale_v := child.basis.get_scale()
	var rot := Basis(up.cross(fwd).normalized(), up, fwd)
	child.transform = Transform3D(
		rot.scaled(scale_v),
		dir * (terrain.data.radius + terrain.base_height_at_dir(dir)))
	_manual[child.get_instance_id()] = {"xf": child.transform, "settle": 0.0}
	_bend_child_editor(child)
	terrain.rebake()


func _bend_child_editor(child: Node3D) -> void:
	if _bent.has(child):
		PlanetMeshBender.unbend_node(child, _bent[child])
		_bent.erase(child)
	if not _should_curve(child):
		return
	var ground_dist := child.position.length()
	var child_scale := child.basis.get_scale().x
	if ground_dist <= 1.0 or child_scale <= 0.0:
		return
	var rec := {}
	PlanetMeshBender.bend_node(child, ground_dist / child_scale, rec)
	if not rec.is_empty():
		_bent[child] = rec


## Saves flat meshes: unbends before an editor save, rebends after.
func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		for child in _bent:
			if is_instance_valid(child):
				PlanetMeshBender.unbend_node(child, _bent[child])
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		var flat := _bent.keys()
		_bent.clear()
		for child in flat:
			if is_instance_valid(child):
				_bend_child_editor(child)


func _find_terrain() -> PlanetTerrain:
	var parent := get_parent()
	if parent:
		for sibling in parent.get_children():
			if sibling is PlanetTerrain:
				return sibling
	return null


## Pads flatten to the base ground height at their centre; h_off never moves a pad.
func get_height_stamps(terrain: PlanetTerrain) -> Array:
	var out: Array = []
	_anchor_stamps(terrain, out)
	_manual_stamps(terrain, out)
	return out


## Planar pads, so wide flat buildings do not float at their edges.
func _anchor_stamps(terrain: PlanetTerrain, out: Array) -> void:
	for a in anchors:
		var pad := float(a.get("pad_radius", 0.0))
		if pad <= 0.0:
			continue
		var dir: Vector3 = a["dir"]
		out.append({
			"dir": dir,
			"target": terrain.base_height_at_dir(dir),
			"half": pad,
			"falloff": float(a.get("pad_falloff", pad * 0.8)),
			"planar": true,
		})


## Planar for flat children, constant elevation for curved ones.
func _manual_stamps(terrain: PlanetTerrain, out: Array) -> void:
	for child in get_children():
		if not (child is Node3D) or child.has_meta("anchor_index"):
			continue
		var dir2: Vector3 = child.position.normalized()
		if dir2.length_squared() < 0.5:
			continue
		var pad2 := _manual_pad(child)
		if child.has_meta("pad"):
			pad2 = float(child.get_meta("pad"))
		if pad2 <= 0.0:
			continue
		out.append({
			"dir": dir2,
			"target": terrain.base_height_at_dir(dir2),
			"half": pad2,
			"falloff": pad2 * 0.8,
			"planar": not _should_curve(child),
		})


func _should_curve(child: Node) -> bool:
	if child.has_meta("curve"):
		return bool(child.get_meta("curve"))
	return curve_children


## Cached: half the scaled footprint plus 5, clamped to 3..300.
func _manual_pad(child: Node3D) -> float:
	var id := child.get_instance_id()
	if _manual_pads.has(id):
		return _manual_pads[id]
	var box: Array = [AABB(), false]
	_merge_mesh_aabb(child, Transform3D(child.basis, Vector3.ZERO), box)
	var pad := 0.0
	if box[1]:
		var ab: AABB = box[0]
		pad = clampf(maxf(ab.size.x, ab.size.z) * 0.5 + 5.0, 3.0, 300.0)
	_manual_pads[id] = pad
	return pad


func _merge_mesh_aabb(node: Node, xf: Transform3D, box: Array) -> void:
	if node is MeshInstance3D and node.mesh != null:
		var ab: AABB = xf * node.mesh.get_aabb()
		box[0] = box[0].merge(ab) if box[1] else ab
		box[1] = true
	for child in node.get_children():
		_merge_mesh_aabb(child, xf * child.transform if child is Node3D else xf, box)


func on_field_baked(terrain: PlanetTerrain, field: PlanetHeightField) -> void:
	rebuild(terrain, field)


## Anchor nodes are never saved; at runtime also bends hand-placed children and adds their collision.
func rebuild(terrain: PlanetTerrain, field: PlanetHeightField = null) -> void:
	for child in get_children():
		if child.has_meta("anchor_index"):
			child.queue_free()
		elif child is Node3D and not Engine.is_editor_hint():
			_prepare_manual_child(child)
	if terrain == null or terrain.data == null:
		return
	if field == null:
		field = terrain.get_field()
	if field == null:
		return
	var r: float = terrain.data.radius
	for i in anchors.size():
		var a := anchors[i]
		var node := _instantiate_anchor(a)
		if node == null:
			continue
		node.set_meta("anchor_index", i)
		add_child(node)
		node.transform = resolve_transform(a, r, field, terrain.get_base_field())
		if auto_collision and not Engine.is_editor_hint() \
				and bool(a.get("collision", true)) and not _has_collision(node):
			_generate_collision.call_deferred(node)


## Bends before collision is generated, so the trimeshes come from the bent meshes.
func _prepare_manual_child(child: Node3D) -> void:
	if _should_curve(child) and not child.has_meta("planet_bent"):
		var ground_dist: float = child.position.length()
		var child_scale: float = child.basis.get_scale().x
		if ground_dist > 1.0 and child_scale > 0.0:
			PlanetMeshBender.bend_node(child, ground_dist / child_scale)
	if auto_collision and not _has_collision(child):
		_generate_collision.call_deferred(child)


## Anchors with a pad sit on the base ground, others on the baked field.
func resolve_transform(a: Dictionary, radius: float, field: PlanetHeightField,
		base_field: PlanetHeightField = null) -> Transform3D:
	var dir: Vector3 = a["dir"]
	var ref := field
	if float(a.get("pad_radius", 0.0)) > 0.0 and base_field != null:
		ref = base_field
	var h := ref.sample_dir(dir) + float(a.get("h_off", 0.0))
	var up := dir
	if int(a.get("align", 0)) == 1:
		up = field.normal_dir(dir, radius, 1.0)
	var east: Vector3 = CubeSphere.tangent_frame(dir)[0]
	var fwd := east.rotated(up, float(a.get("yaw", 0.0)))
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var rot := Basis(up.cross(fwd).normalized(), up, fwd)
	var pos := dir * (radius + h)
	var local_off: Vector3 = a.get("local_offset", Vector3.ZERO)
	if local_off != Vector3.ZERO:
		pos += rot * local_off
	var s := float(a.get("scale", 1.0))
	var basis := rot.scaled(Vector3.ONE * s) if s != 1.0 else rot
	return Transform3D(basis, pos)


## A pink placeholder box when the scene is missing.
func _instantiate_anchor(a: Dictionary) -> Node3D:
	var path := str(a.get("scene", ""))
	if path != "" and ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is PackedScene:
			var inst := (res as PackedScene).instantiate()
			if inst is Node3D:
				return inst
			inst.queue_free()
		elif res is Mesh:
			var mi := MeshInstance3D.new()
			mi.mesh = res
			return mi
	if _placeholder_mesh == null:
		_placeholder_mesh = BoxMesh.new()
		_placeholder_mesh.size = Vector3(2, 2, 2)
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(1.0, 0.3, 0.8)
		_placeholder_mesh.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = _placeholder_mesh
	return mi


func _has_collision(node: Node) -> bool:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		return true
	for child in node.get_children():
		if _has_collision(child):
			return true
	return false


## Called deferred.
func _generate_collision(node: Node) -> void:
	if not is_instance_valid(node) or not node.is_inside_tree():
		return
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh != null:
			mi.create_trimesh_collision()


func add_anchor(a: Dictionary) -> int:
	anchors.append(a)
	return anchors.size() - 1


## Removes and returns them.
func remove_anchors_within(center_dir: Vector3, radius_m: float, planet_radius: float) -> Array[Dictionary]:
	var ang := radius_m / planet_radius
	var removed: Array[Dictionary] = []
	var kept: Array[Dictionary] = []
	for a in anchors:
		if CubeSphere.angle_between(a["dir"], center_dir) <= ang:
			removed.append(a)
		else:
			kept.append(a)
	anchors = kept
	return removed
