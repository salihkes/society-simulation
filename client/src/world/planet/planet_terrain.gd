@tool
class_name PlanetTerrain
extends Node3D
## Chunked cube-sphere planet terrain: LOD chunks, runtime colliders, grass, holes and designer brushes.

signal field_changed

const LOD_QUADS: Array[int] = [32, 16, 8, 4]
## A chunk nearer than LOD_RATIOS[i] times its arc size gets LOD i.
const LOD_RATIOS: Array[float] = [2.0, 5.0, 12.0]
const COLLISION_QUADS := 16

@export var data: PlanetData:
	set(v):
		data = v
		if is_inside_tree():
			_full_reload()
@export var chunks_per_face := 8
@export var terrain_material: Material
@export var collision_enabled := true
## Metres (plus chunk size); generous so fast craft never outrun the colliders.
@export var collision_distance := 900.0
@export var grass_material: Material

var _base_field: PlanetHeightField
## _base_field plus the road and pad stamps; meshes sample this, brushes edit _base_field.
var _field: PlanetHeightField
## key:int -> chunk dict {node, lod, dir, arc, body, grass}
var _chunks := {}
var _rebuild_queue: Array[int] = []
var _collision_timer := 0.0
var _loaded := false
## Surface holes: [{dir: Vector3, cos_r: float, radius_m: float}]
var _holes: Array = []
var _hole_watch := 0.0


func _ready() -> void:
	# Deferred: chunks cannot be added while the parent is still setting up.
	_full_reload.call_deferred()
	set_process(true)


func _process(delta: float) -> void:
	if not _loaded or _field == null:
		return
	var cam_pos := _observer_local_position()
	if cam_pos != Vector3.INF:
		_update_lods(cam_pos)
	var budget := 6 if Engine.is_editor_hint() else 3
	while budget > 0 and not _rebuild_queue.is_empty():
		var key: int = _rebuild_queue.pop_front()
		if _chunks.has(key):
			_build_chunk_mesh(key)
		budget -= 1
	if collision_enabled and not Engine.is_editor_hint():
		_collision_timer -= delta
		if _collision_timer <= 0.0:
			_collision_timer = 0.35
			if cam_pos != Vector3.INF:
				_update_collision(cam_pos)
	if Engine.is_editor_hint():
		_watch_holes(delta)


func _watch_holes(delta: float) -> void:
	_hole_watch -= delta
	if _hole_watch <= 0.0:
		_hole_watch = 0.4
		var fresh := _collect_holes()
		if not _holes_equal(fresh, _holes):
			_holes = fresh
			_push_hole_uniforms()


## The rebake waits, deferred, until the stamping siblings are ready.
func _full_reload() -> void:
	_loaded = false
	for key in _chunks:
		var c: Dictionary = _chunks[key]
		if is_instance_valid(c.node):
			c.node.queue_free()
	_chunks.clear()
	_rebuild_queue.clear()
	if data == null:
		return
	_base_field = _load_field()
	if _base_field == null:
		return
	_field = _base_field.duplicate_field()
	_ensure_material()
	_create_chunks()
	_loaded = true
	call_deferred("rebake")


## base.res, else raw height faces, else generated; the last two are saved as base.res.
func _load_field() -> PlanetHeightField:
	var dir := data.data_dir
	if dir != "" and ResourceLoader.exists(dir.path_join("base.res")):
		var f: PlanetHeightField = ResourceLoader.load(dir.path_join("base.res"), "", ResourceLoader.CACHE_MODE_IGNORE)
		if f != null and f.is_valid():
			return f
	if dir != "":
		var raw := PlanetHeightField.load_raw_folder(dir.path_join("height"))
		if raw != null and raw.is_valid():
			print("PlanetTerrain: imported raw DEM faces from ", dir.path_join("height"))
			_save_field_as(raw, dir.path_join("base.res"))
			return raw
	print("PlanetTerrain: no height data in '%s' — generating fallback terrain" % dir)
	var gen := PlanetHeightField.new()
	gen.generate(data.face_resolution, data.generator_seed, data.max_height, data.ocean_depth)
	if dir != "":
		_save_field_as(gen, dir.path_join("base.res"))
	return gen


func _save_field_as(field: PlanetHeightField, path: String) -> void:
	var base_dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(base_dir):
		DirAccess.make_dir_recursive_absolute(base_dir)
	var err := ResourceSaver.save(field, path)
	if err != OK:
		push_error("PlanetTerrain: failed to save %s (%s)" % [path, error_string(err)])


func save_base() -> bool:
	if data == null or data.data_dir == "" or _base_field == null:
		push_error("PlanetTerrain: set data.data_dir before saving")
		return false
	_save_field_as(_base_field, data.data_dir.path_join("base.res"))
	return true


func get_base_field() -> PlanetHeightField:
	return _base_field


func get_field() -> PlanetHeightField:
	return _field


func height_at_dir(dir: Vector3) -> float:
	return _field.sample_dir(dir) if _field else 0.0


func base_height_at_dir(dir: Vector3) -> float:
	return _base_field.sample_dir(dir) if _base_field else 0.0


## Also refreshes the holes and queues every chunk for rebuilding.
func rebake() -> void:
	# A deferred rebake can arrive after the planet left the tree.
	if not _loaded or not is_inside_tree():
		return
	var baked := PlanetBaker.bake(self)
	if baked == null:
		return
	_field = baked
	_holes = _collect_holes()
	_push_hole_uniforms()
	_queue_rebuild_all()
	field_changed.emit()


func _queue_rebuild_all() -> void:
	_rebuild_queue.clear()
	for key in _chunks:
		_rebuild_queue.append(key)


## Updates the shader and recuts the colliders around the PlanetHoles.
func refresh_holes() -> void:
	if not _loaded:
		return
	_holes = _collect_holes()
	_push_hole_uniforms()
	for h in _holes:
		refresh_collision_region(h.dir, h.radius_m * 2.0)


## Up to 32 PlanetHoles, as direction and angular size.
func _collect_holes() -> Array:
	var out: Array = []
	var planet_root := get_parent()
	if planet_root == null or not is_inside_tree() or data == null:
		return out
	for hole in get_tree().get_nodes_in_group("planet_holes"):
		if not (hole is Node3D) or not hole.is_inside_tree():
			continue
		if not PlanetBaker.under_planet(hole, planet_root):
			continue
		var dir := to_local(hole.global_position).normalized()
		if dir.length_squared() < 0.5:
			continue
		out.append({
			"dir": dir,
			"cos_r": cos(hole.radius / data.radius),
			"radius_m": hole.radius,
		})
		if out.size() >= 32:
			break
	return out


func _push_hole_uniforms() -> void:
	if not (terrain_material is ShaderMaterial):
		return
	var arr := PackedVector4Array()
	arr.resize(32)
	for i in _holes.size():
		var h: Dictionary = _holes[i]
		arr[i] = Vector4(h.dir.x, h.dir.y, h.dir.z, h.cos_r)
	terrain_material.set_shader_parameter("hole_count", _holes.size())
	terrain_material.set_shader_parameter("holes", arr)


func _holes_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not a[i].dir.is_equal_approx(b[i].dir) or a[i].cos_r != b[i].cos_r:
			return false
	return true


func _in_hole(dir: Vector3) -> bool:
	for h in _holes:
		if dir.dot(h.dir) > h.cos_r:
			return true
	return false


## Immediately, not queued (brush feedback).
func rebuild_region(center_dir: Vector3, radius_m: float) -> void:
	if not _loaded:
		return
	var ang := radius_m / data.radius
	for key in _chunks:
		var c: Dictionary = _chunks[key]
		if CubeSphere.angle_between(c.dir, center_dir) <= ang + c.arc:
			_build_chunk_mesh(key)


func _chunk_key(face: int, cx: int, cy: int) -> int:
	return (face * 256 + cy) * 256 + cx


func _create_chunks() -> void:
	var cpf := chunks_per_face
	for face in CubeSphere.FACE_COUNT:
		for cy in cpf:
			for cx in cpf:
				_add_chunk(face, cx, cy)


func _add_chunk(face: int, cx: int, cy: int) -> void:
	var cpf := chunks_per_face
	var u0 := float(cx) / cpf
	var v0 := float(cy) / cpf
	var u1 := float(cx + 1) / cpf
	var v1 := float(cy + 1) / cpf
	var center := CubeSphere.face_uv_to_dir(face, (u0 + u1) * 0.5, (v0 + v1) * 0.5)
	var corner := CubeSphere.face_uv_to_dir(face, u0, v0)
	var arc := CubeSphere.angle_between(center, corner)
	var mi := MeshInstance3D.new()
	mi.name = "chunk_%d_%d_%d" % [face, cx, cy]
	add_child(mi)
	var key := _chunk_key(face, cx, cy)
	_chunks[key] = {
		"node": mi, "face": face, "cx": cx, "cy": cy,
		"dir": center, "arc": arc, "lod": -1, "body": null, "grass": null,
	}
	_set_chunk_lod(key, LOD_QUADS.size() - 1)


func _set_chunk_lod(key: int, lod: int) -> void:
	var c: Dictionary = _chunks[key]
	if c.lod == lod:
		return
	c.lod = lod
	if not _rebuild_queue.has(key):
		_rebuild_queue.append(key)


func _update_lods(cam_local: Vector3) -> void:
	var r := data.radius
	for key in _chunks:
		var c: Dictionary = _chunks[key]
		var chunk_size: float = c.arc * r
		var dist: float = cam_local.distance_to(c.dir * (r + _field.sample_dir(c.dir)))
		var lod := LOD_QUADS.size() - 1
		for i in LOD_RATIOS.size():
			if dist < chunk_size * LOD_RATIOS[i]:
				lod = i
				break
		_set_chunk_lod(key, lod)


func _build_chunk_mesh(key: int) -> void:
	var c: Dictionary = _chunks[key]
	var q: int = LOD_QUADS[maxi(c.lod, 0)]
	var mesh := _make_patch_mesh(c.face, c.cx, c.cy, q, true)
	var node: MeshInstance3D = c.node
	node.mesh = mesh
	if terrain_material:
		node.material_override = terrain_material
	_update_chunk_grass(c)


## cut_holes drops triangles inside holes, for colliders (the shader hides them visually).
func _make_patch_mesh(face: int, cx: int, cy: int, q: int, skirt: bool, cut_holes := false) -> ArrayMesh:
	var cpf := chunks_per_face
	var r := data.radius
	# About one texel in metres.
	var res_arc := (PI * 0.5) * r / _field.resolution
	var side := q + 1
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(side * side)
	normals.resize(side * side)
	uvs.resize(side * side)
	for j in side:
		var v := (float(cy) + float(j) / q) / cpf
		for i in side:
			var u := (float(cx) + float(i) / q) / cpf
			var d := CubeSphere.face_uv_to_dir(face, u, v)
			var h := _field.sample_dir(d)
			var idx := j * side + i
			verts[idx] = d * (r + h)
			normals[idx] = _field.normal_dir(d, r, maxf(res_arc, 0.5))
			uvs[idx] = Vector2(u, v)
	var indices := _patch_indices(q, side)
	if cut_holes and not _holes.is_empty():
		indices = _without_holes(indices, verts)
	if skirt:
		_append_skirt(verts, normals, uvs, indices, side, r)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _patch_indices(q: int, side: int) -> PackedInt32Array:
	var indices := PackedInt32Array()
	indices.resize(q * q * 6)
	var k := 0
	for j in q:
		for i in q:
			var a := j * side + i
			var b := a + 1
			var cc := a + side
			var dd := cc + 1
			# u x v points into the sphere on every face, so clockwise faces outward.
			indices[k] = a
			indices[k + 1] = b
			indices[k + 2] = dd
			indices[k + 3] = a
			indices[k + 4] = dd
			indices[k + 5] = cc
			k += 6
	return indices


## One degenerate triangle if every triangle is inside a hole.
func _without_holes(indices: PackedInt32Array, verts: PackedVector3Array) -> PackedInt32Array:
	var kept := PackedInt32Array()
	for t in range(0, indices.size(), 3):
		var centroid := (verts[indices[t]] + verts[indices[t + 1]] + verts[indices[t + 2]]).normalized()
		if not _in_hole(centroid):
			kept.append(indices[t])
			kept.append(indices[t + 1])
			kept.append(indices[t + 2])
	if kept.is_empty():
		kept.append(0)
		kept.append(0)
		kept.append(0)
	return kept


func _append_skirt(verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array, side: int, r: float) -> void:
	var depth := maxf(2.0, (PI * 0.5) * r / (chunks_per_face * 8.0))
	var edge: Array[int] = []
	# Top row, right column, bottom row reversed, left column reversed.
	for i in side:
		edge.append(i)
	for j in range(1, side):
		edge.append(j * side + (side - 1))
	for i in range(side - 2, -1, -1):
		edge.append((side - 1) * side + i)
	for j in range(side - 2, 0, -1):
		edge.append(j * side)
	var base := verts.size()
	for e in edge.size():
		var src := edge[e]
		var p := verts[src]
		verts.append(p - p.normalized() * depth)
		normals.append(normals[src])
		uvs.append(uvs[src])
	var n := edge.size()
	for e in n:
		var a := edge[e]
		var b := edge[(e + 1) % n]
		var a2 := base + e
		var b2 := base + (e + 1) % n
		indices.append_array(PackedInt32Array([a, a2, b, b, a2, b2]))


func _ensure_material() -> void:
	if terrain_material != null:
		return
	var shader: Shader = load("res://src/world/planet/shaders/planet_terrain.gdshader")
	if shader == null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("planet_radius", data.radius)
	mat.set_shader_parameter("beach_top", data.beach_top)
	mat.set_shader_parameter("rock_slope_deg", data.rock_slope_deg)
	mat.set_shader_parameter("snow_start", data.snow_start)
	var grass_tex: Texture2D = load("res://assets/world/terrain/grass.jpg")
	if grass_tex:
		mat.set_shader_parameter("grass_tex", grass_tex)
	terrain_material = mat


func _update_collision(cam_local: Vector3) -> void:
	var r := data.radius
	for key in _chunks:
		var c: Dictionary = _chunks[key]
		var dist: float = cam_local.distance_to(c.dir * r)
		var want: bool = dist < collision_distance + c.arc * r
		var has: bool = c.body != null and is_instance_valid(c.body)
		if want and not has:
			c.body = _make_collider(key, c)
		elif has and not want:
			c.body.queue_free()
			c.body = null


func _make_collider(key: int, c: Dictionary) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "col_%d" % key
	var shape := CollisionShape3D.new()
	var mesh := _make_patch_mesh(c.face, c.cx, c.cy, COLLISION_QUADS, false, true)
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	add_child(body)
	return body


func refresh_collision_region(center_dir: Vector3, radius_m: float) -> void:
	var ang := radius_m / data.radius
	for key in _chunks:
		var c: Dictionary = _chunks[key]
		if c.body != null and is_instance_valid(c.body) \
				and CubeSphere.angle_between(c.dir, center_dir) <= ang + c.arc:
			var mesh := _make_patch_mesh(c.face, c.cx, c.cy, COLLISION_QUADS, false, true)
			var shape: CollisionShape3D = c.body.get_child(0)
			shape.shape = mesh.create_trimesh_shape()


func _update_chunk_grass(c: Dictionary) -> void:
	var want: bool = data.grass_enabled and c.lod <= 1
	if c.grass != null and is_instance_valid(c.grass):
		c.grass.queue_free()
		c.grass = null
	if not want:
		return
	var r := data.radius
	# Roughly the chunk's area in square metres.
	var chunk_area := pow(c.arc * r * 1.6, 2.0)
	var count := mini(int(chunk_area * data.grass_density * 0.02), 2000)
	if count <= 0:
		return
	var xforms := _grass_transforms(c, count)
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _grass_blade_mesh()
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = c.node.name + "_grass"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if grass_material:
		mmi.material_override = grass_material
	elif _default_grass_material():
		mmi.material_override = _default_grass_material()
	add_child(mmi)
	c.grass = mmi


func _grass_transforms(c: Dictionary, count: int) -> Array[Transform3D]:
	var r := data.radius
	var frame := CubeSphere.tangent_frame(c.dir)
	var rng := RandomNumberGenerator.new()
	rng.seed = _chunk_key(c.face, c.cx, c.cy) * 7919 + data.generator_seed
	var xforms: Array[Transform3D] = []
	var max_slope := cos(deg_to_rad(data.rock_slope_deg))
	for i in count:
		var off: Vector3 = (frame[0] * rng.randf_range(-1.0, 1.0) + frame[1] * rng.randf_range(-1.0, 1.0)) * c.arc
		var d: Vector3 = (c.dir + off).normalized()
		var h := _field.sample_dir(d)
		if h < data.beach_top or h > data.snow_start:
			continue
		if _in_hole(d):
			continue
		var n := _field.normal_dir(d, r, 1.0)
		if n.dot(d) < max_slope:
			continue
		var up := d
		var fwd: Vector3 = frame[0].rotated(up, rng.randf() * TAU)
		var basis := Basis(up.cross(fwd).normalized(), up, fwd).scaled(Vector3.ONE * rng.randf_range(0.7, 1.3))
		# Roots sink below the surface so blades never float over coarse LODs.
		xforms.append(Transform3D(basis, d * (r + h - 0.5)))
	return xforms


static var _blade_mesh: ArrayMesh


## Two crossed quads, shared by every chunk.
func _grass_blade_mesh() -> ArrayMesh:
	if _blade_mesh:
		return _blade_mesh
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for plane in 2:
		var dirv := Vector3.RIGHT if plane == 0 else Vector3.BACK
		var b := verts.size()
		verts.append_array(PackedVector3Array([-dirv * 0.9, dirv * 0.9,
			dirv * 0.9 + Vector3.UP * 1.8, -dirv * 0.9 + Vector3.UP * 1.8]))
		uvs.append_array(PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]))
		for t in [0, 1, 2, 0, 2, 3]:
			indices.append(b + t)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	_blade_mesh = ArrayMesh.new()
	_blade_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _blade_mesh


static var _grass_mat: Material


func _default_grass_material() -> Material:
	if _grass_mat:
		return _grass_mat
	var shader: Shader = load("res://src/world/planet/shaders/planet_grass.gdshader")
	if shader == null:
		return null
	var m := ShaderMaterial.new()
	m.shader = shader
	_grass_mat = m
	return _grass_mat


## Planet-local ray against the height field, no colliders: {position, normal, dir, height} or {}.
func raycast_surface(from_local: Vector3, ray_dir: Vector3, max_dist := 1.0e6) -> Dictionary:
	if not _loaded:
		return {}
	var r := data.radius
	var outer := r + data.max_height + 5.0
	var inner := r - data.ocean_depth - 5.0
	ray_dir = ray_dir.normalized()
	# Start where the ray enters the outer bounding sphere.
	var t0 := 0.0
	if from_local.length() > outer:
		var oc := from_local
		var b := oc.dot(ray_dir)
		var det := b * b - (oc.length_squared() - outer * outer)
		if det < 0.0:
			return {}
		t0 = -b - sqrt(det)
		if t0 < 0.0 or t0 > max_dist:
			return {}
	var step := maxf(r * 0.002, 0.75)
	var t := t0
	var prev_t := t0
	var prev_f := _shell_f(from_local + ray_dir * t)
	var limit := minf(max_dist, t0 + outer * 2.5)
	while t < limit:
		t += step
		var p := from_local + ray_dir * t
		var pl := p.length()
		if pl < inner:
			break
		# Left the shell outwards without a hit.
		if pl > outer and t > t0 + step and prev_f > 0.0:
			return {}
		var f := _shell_f(p)
		if f <= 0.0 and prev_f > 0.0:
			return _surface_hit(from_local + ray_dir * _bisect(from_local, ray_dir, prev_t, t))
		prev_f = f
		prev_t = t
	return {}


## lo is above the surface, hi below.
func _bisect(from_local: Vector3, ray_dir: Vector3, lo: float, hi: float) -> float:
	for i in 14:
		var mid := (lo + hi) * 0.5
		if _shell_f(from_local + ray_dir * mid) <= 0.0:
			hi = mid
		else:
			lo = mid
	return hi


func _surface_hit(hit: Vector3) -> Dictionary:
	var r := data.radius
	var d := hit.normalized()
	return {
		"position": d * (r + _field.sample_dir(d)),
		"normal": _field.normal_dir(d, r, 1.0),
		"dir": d,
		"height": _field.sample_dir(d),
	}


## Height of p above the surface under it (negative below).
func _shell_f(p: Vector3) -> float:
	var d := p.normalized()
	return p.length() - (data.radius + _field.sample_dir(d))


## kind: raise, lower, smooth or flatten. Returns [{face, x, y, before}] for undo; rebake() after the stroke.
func apply_brush(kind: String, center_dir: Vector3, radius_m: float,
		strength: float, flatten_to := 0.0) -> Array:
	if not _loaded:
		return []
	var undo: Array = []
	var res := _base_field.resolution
	var ang := radius_m / data.radius
	var texel_ang := (PI * 0.5) / res
	var win := int(ceil(ang / texel_ang)) + 2
	var mean := 0.0
	if kind == "smooth":
		mean = _region_mean(center_dir, ang)
	var target := mean if kind == "smooth" else flatten_to
	for face in CubeSphere.FACE_COUNT:
		var uv := CubeSphere.dir_uv_on_face(face, center_dir)
		if uv.is_empty():
			continue
		var cx := int(round(uv[0] * (res - 1)))
		var cy := int(round(uv[1] * (res - 1)))
		if cx < -win or cy < -win or cx >= res + win or cy >= res + win:
			continue
		var rect := Rect2i(Vector2i(maxi(cx - win, 0), maxi(cy - win, 0)), Vector2i.ZERO)
		rect.end = Vector2i(mini(cx + win + 1, res), mini(cy + win + 1, res))
		_brush_face(kind, face, rect, center_dir, ang, strength, target, undo)
	if not undo.is_empty():
		rebuild_region(center_dir, radius_m * 1.5)
	return undo


func _brush_face(kind: String, face: int, rect: Rect2i, center_dir: Vector3, ang: float,
		strength: float, target: float, undo: Array) -> void:
	var res := _base_field.resolution
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var d := CubeSphere.face_uv_to_dir(face, float(x) / (res - 1), float(y) / (res - 1))
			var a := CubeSphere.angle_between(d, center_dir)
			if a > ang:
				continue
			var w := smoothstep(1.0, 0.0, a / ang)
			var h := _base_field.get_px(face, x, y)
			var nh := _brushed(kind, h, w, strength, target)
			if nh == h:
				continue
			undo.append({"face": face, "x": x, "y": y, "before": h})
			_base_field.set_px(face, x, y, nh)
			_field.set_px(face, x, y, _field.get_px(face, x, y) + (nh - h))


## target is the smoothing mean or the flatten height.
static func _brushed(kind: String, h: float, w: float, strength: float, target: float) -> float:
	match kind:
		"raise":
			return h + strength * w
		"lower":
			return h - strength * w
		"smooth", "flatten":
			return lerpf(h, target, clampf(strength * 0.08, 0.0, 1.0) * w)
	return h


## Undo/redo: restores the recorded base heights, then rebakes.
func apply_pixel_snapshot(snapshot: Array) -> void:
	for e in snapshot:
		var cur: float = _base_field.get_px(e.face, e.x, e.y)
		_base_field.set_px(e.face, e.x, e.y, e.before)
		_field.set_px(e.face, e.x, e.y, _field.get_px(e.face, e.x, e.y) + (e.before - cur))
	rebake()


func _region_mean(center_dir: Vector3, ang: float) -> float:
	var total := 0.0
	var n := 0
	var frame := CubeSphere.tangent_frame(center_dir)
	for j in 5:
		for i in 5:
			var off: Vector3 = (frame[0] * (i - 2) + frame[1] * (j - 2)) * (ang * 0.5)
			var d: Vector3 = (center_dir + off).normalized()
			total += _base_field.sample_dir(d)
			n += 1
	return total / n


func _observer_local_position() -> Vector3:
	var cam := get_viewport().get_camera_3d() if get_viewport() else null
	if cam == null:
		return Vector3.INF
	return to_local(cam.global_position)
