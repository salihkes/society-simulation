@tool
extends RefCounted
## Decodes one baked road chunk into mesh arrays on a worker thread: never touches nodes, renderer or physics.

## Row: centre xyz, lateral xz, width, station, bridge flag, ground y, grade (float32 each).
const STRIDE := 10


## {"error": ...} on failure.
static func build(path: String, count: int, lod: int, road_length := 1.0e12) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() != count * STRIDE * 4 or count < 2:
		return {"error": "Invalid road chunk: " + path}
	var rows := file.get_buffer(file.get_length()).to_float32_array()
	for value in rows:
		if not is_finite(value):
			return {"error": "Non-finite road chunk: " + path}
	var selected: Array[int] = []
	for i in range(0, count - 1, 1 if lod == 0 else 4 if lod == 1 else 12):
		selected.append(i)
	selected.append(count - 1)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var indices := PackedInt32Array()
	var signs: Array[Dictionary] = []
	_add_deck(rows, selected, vertices, normals, uvs, uv2, indices)
	_add_bridges(rows, selected, lod, vertices, normals, uvs, indices)
	if lod < 2:
		for row in selected.size() - 1:
			var i: int = selected[row] * STRIDE
			var j: int = selected[row + 1] * STRIDE
			_add_rails(rows, i, j, lod, road_length, vertices, normals, uvs, indices)
			_add_signs(rows, i, j, road_length, signs)
	while uv2.size() < vertices.size():
		uv2.append(Vector2.ZERO)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = indices
	var collision := PackedVector3Array()
	if lod == 0:
		collision = _collision_faces(rows, selected, vertices, indices)
	return {"arrays": arrays, "collision": collision, "signs": signs, "triangles": indices.size() / 3}


## UV is (across, station); UV2.x is the width.
static func _add_deck(rows: PackedFloat32Array, selected: Array[int], vertices: PackedVector3Array,
		normals: PackedVector3Array, uvs: PackedVector2Array, uv2: PackedVector2Array,
		indices: PackedInt32Array) -> void:
	for sample in selected:
		var i: int = sample * STRIDE
		var center := Vector3(rows[i], rows[i + 1], rows[i + 2])
		var lateral := Vector3(rows[i + 3], 0, rows[i + 4])
		var tangent := Vector3(lateral.z, 0, -lateral.x)
		var normal := (Vector3.UP - tangent * rows[i + 9]).normalized()
		var width: float = rows[i + 5]
		# Shared station UVs and the baked grade and lateral make chunk seams exact.
		for fraction in [-4.0 / width, 0.0, 1.0, 1.0 + 4.0 / width]:
			var shoulder_drop := 4.6 if (fraction < 0 or fraction > 1) and int(rows[i + 7]) != 1 else 0.0
			vertices.append(center + lateral * ((fraction - 0.5) * width) - Vector3.UP * shoulder_drop)
			normals.append(normal)
			uvs.append(Vector2(fraction, rows[i + 6]))
			uv2.append(Vector2(width, 0))
	for row in selected.size() - 1:
		for column in 3:
			var a := row * 4 + column
			indices.append_array(PackedInt32Array([a, a + 4, a + 1, a + 1, a + 4, a + 5]))


## Bridges ignore the terrain below.
static func _add_bridges(rows: PackedFloat32Array, selected: Array[int], lod: int,
		vertices: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array,
		indices: PackedInt32Array) -> void:
	for row in selected.size() - 1:
		var i: int = selected[row] * STRIDE
		var j: int = selected[row + 1] * STRIDE
		if int(rows[i + 7]) != 1 and int(rows[j + 7]) != 1:
			continue
		for column in [0, 3]:
			var a: Vector3 = vertices[row * 4 + column]
			var b: Vector3 = vertices[(row + 1) * 4 + column]
			_quad(vertices, normals, uvs, indices, a, b, b - Vector3.UP * 2, a - Vector3.UP * 2)
		if lod == 0 and floori(rows[i + 6] / 64) != floori(rows[j + 6] / 64):
			_add_pier(rows, j, vertices, normals, uvs, indices)


static func _add_pier(rows: PackedFloat32Array, j: int, vertices: PackedVector3Array,
		normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
	var top := Vector3(rows[j], rows[j + 1] - 2, rows[j + 2])
	var bottom := Vector3(top.x, minf(top.y - 1, rows[j + 8] - 1), top.z)
	for side in 4:
		var angle := side * PI * 0.5 + PI * 0.25
		var next_angle := angle + PI * 0.5
		var a := Vector3(cos(angle), 0, sin(angle)) * 2.5
		var b := Vector3(cos(next_angle), 0, sin(next_angle)) * 2.5
		_quad(vertices, normals, uvs, indices, top + a, bottom + a, bottom + b, top + b)


## +lateral is the driver's right; median rails shrink away near the road's ends.
static func _add_rails(rows: PackedFloat32Array, i: int, j: int, lod: int, road_length: float,
		vertices: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array,
		indices: PackedInt32Array) -> void:
	var s: float = rows[i + 6]
	var sn: float = rows[j + 6]
	var a := Vector3(rows[i], rows[i + 1], rows[i + 2])
	var b := Vector3(rows[j], rows[j + 1], rows[j + 2])
	var la := Vector3(rows[i + 3], 0, rows[i + 4])
	var lb := Vector3(rows[j + 3], 0, rows[j + 4])
	var wa: float = rows[i + 5]
	var wb: float = rows[j + 5]
	var fade_a := smoothstep(40.0, 160.0, minf(s, road_length - s))
	var fade_b := smoothstep(40.0, 160.0, minf(sn, road_length - sn))
	for rail in 4:
		var outer := rail == 0 or rail == 3
		var side := -1.0 if rail < 2 else 1.0
		var aa := a + la * side * (wa * 0.5 - 0.7 if outer else 0.85)
		var bb := b + lb * side * (wb * 0.5 - 0.7 if outer else 0.85)
		var fa := fade_a if not outer else 1.0
		var fb := fade_b if not outer else 1.0
		if maxf(fa, fb) < 0.01:
			continue
		_add_rail_face(aa, bb, la, lb, fa, fb, lod, vertices, normals, uvs, indices)
		if lod == 0:
			_add_posts(aa, bb, la, s, sn, fa, fb, vertices, normals, uvs, indices)


static func _add_rail_face(aa: Vector3, bb: Vector3, la: Vector3, lb: Vector3, fa: float,
		fb: float, lod: int, vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
	var levels := [0.0, 0.2, 0.5, 0.8, 1.0] if lod == 0 else [0.0, 1.0]
	var folds := [0.0, 0.14, -0.14, 0.14, 0.0] if lod == 0 else [0.0, 0.0]
	for band in levels.size() - 1:
		var a0: Vector3 = aa + Vector3.UP * (1.4 + levels[band] * 0.9) * fa + la * folds[band]
		var a1: Vector3 = aa + Vector3.UP * (1.4 + levels[band + 1] * 0.9) * fa + la * folds[band + 1]
		var b0: Vector3 = bb + Vector3.UP * (1.4 + levels[band] * 0.9) * fb + lb * folds[band]
		var b1: Vector3 = bb + Vector3.UP * (1.4 + levels[band + 1] * 0.9) * fb + lb * folds[band + 1]
		_quad(vertices, normals, uvs, indices, a0, b0, b1, a1, -2.0)


## Spaced on global station so posts continue across chunks.
static func _add_posts(aa: Vector3, bb: Vector3, la: Vector3, s: float, sn: float, fa: float,
		fb: float, vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
	for post in range(floori(s / 12.0) + 1, floori(sn / 12.0) + 1):
		var t := (post * 12.0 - s) / (sn - s)
		var p := aa.lerp(bb, t)
		var top := p + Vector3.UP * 2.15 * lerpf(fa, fb, t)
		_quad(vertices, normals, uvs, indices, p - la * 0.25, p + la * 0.25, top + la * 0.25, top - la * 0.25, -2.0)
		var tangent := Vector3(la.z, 0, -la.x) * 0.25
		_quad(vertices, normals, uvs, indices, p - tangent, p + tangent, top + tangent, top - tangent, -2.0)


## Every 4096 m of station from 320 m, kept 250 m clear of the road's ends.
static func _add_signs(rows: PackedFloat32Array, i: int, j: int, road_length: float,
		signs: Array[Dictionary]) -> void:
	var s: float = rows[i + 6]
	var sn: float = rows[j + 6]
	for gantry in range(floori((s - 320) / 4096.0) + 1, floori((sn - 320) / 4096.0) + 1):
		var station := 320.0 + gantry * 4096.0
		if station < 250 or station > road_length - 250:
			continue
		var t := (station - s) / (sn - s)
		var a := Vector3(rows[i], rows[i + 1], rows[i + 2])
		var b := Vector3(rows[j], rows[j + 1], rows[j + 2])
		var la := Vector3(rows[i + 3], 0, rows[i + 4])
		var lb := Vector3(rows[j + 3], 0, rows[j + 4])
		signs.append({"position": a.lerp(b, t), "lateral": la.lerp(lb, t).normalized(),
			"width": lerpf(rows[i + 5], rows[j + 5], t)})


## End rows are pushed 0.1 m outward: bodies at large coordinates leave sub-millimetre seam gaps.
static func _collision_faces(rows: PackedFloat32Array, selected: Array[int],
		vertices: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var physical_vertices := vertices.duplicate()
	for endpoint in [0, selected.size() - 1]:
		var i: int = selected[endpoint] * STRIDE
		var direction := Vector3(rows[i + 4], rows[i + 9], -rows[i + 3])
		var extension := direction * (-0.1 if endpoint == 0 else 0.1)
		for column in 4:
			physical_vertices[endpoint * 4 + column] += extension
	var collision := PackedVector3Array()
	collision.resize(indices.size())
	for i in indices.size():
		collision[i] = physical_vertices[indices[i]]
	return collision


static func _quad(v: PackedVector3Array, n: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3, material_id := -1.0) -> void:
	var base := v.size()
	var normal := (c - a).cross(b - a).normalized()
	v.append_array(PackedVector3Array([a, b, c, d]))
	for i in 4:
		n.append(normal)
		uv.append(Vector2(material_id, 0))
	idx.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
