extends RefCounted
## Decodes one terrain tile on a worker thread: never touches nodes, servers or shared state.


## The file holds (quads + 3)^2 float32 heights: the tile plus a one-sample halo for edge normals.
static func build(path: String, quads: int, tile_size: float, lod: int, offset := 0) -> Dictionary:
	var began := Time.get_ticks_usec()
	var file := FileAccess.open(path, FileAccess.READ)
	var side := quads + 3
	if file == null or file.get_length() < offset + side * side * 4:
		return {"error": "Missing or invalid terrain tile: " + path}
	file.seek(offset)
	var heights := file.get_buffer(side * side * 4).to_float32_array()
	for h in heights:
		if not is_finite(h):
			return {"error": "Non-finite terrain height: " + path}
	var stride := 1 << lod
	var n := quads / stride + 1
	var cell := tile_size / quads
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	_build_grid(heights, side, n, stride, cell, vertices, normals, uvs, indices)
	_add_skirts(n, maxf(160, cell * stride * 2), vertices, normals, uvs, indices)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	return {"arrays": arrays, "heights": _collision_heights(heights, side, quads),
		"worker_usec": Time.get_ticks_usec() - began, "triangles": indices.size() / 3}


## Samples every stride heights, skipping the halo.
static func _build_grid(heights: PackedFloat32Array, side: int, n: int, stride: int,
		cell: float, vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
	vertices.resize(n * n)
	normals.resize(n * n)
	uvs.resize(n * n)
	for z in n:
		for x in n:
			var sample_index := (z * stride + 1) * side + x * stride + 1
			var i := z * n + x
			vertices[i] = Vector3(x * stride * cell, heights[sample_index], z * stride * cell)
			# The halo gives identical normals at shared tile edges, at every LOD.
			normals[i] = Vector3(heights[sample_index - 1] - heights[sample_index + 1],
				2 * cell, heights[sample_index - side] - heights[sample_index + side]).normalized()
			uvs[i] = Vector2(x * stride * cell, z * stride * cell)
	for z in n - 1:
		for x in n - 1:
			var a := z * n + x
			indices.append_array(PackedInt32Array([a, a + 1, a + n, a + 1, a + n + 1, a + n]))


## Skirts hide cracks between tiles of different LOD.
static func _add_skirts(n: int, drop: float, vertices: PackedVector3Array,
		normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
	for edge in 4:
		var row := _edge_row(n, edge)
		var start := vertices.size()
		for i in row:
			vertices.append(vertices[i] - Vector3(0, drop, 0))
			normals.append(normals[i])
			uvs.append(uvs[i])
		for i in n - 1:
			indices.append_array(PackedInt32Array([row[i], start + i, row[i + 1],
				row[i + 1], start + i, start + i + 1]))


## Walks the border in a consistent winding.
static func _edge_row(n: int, edge: int) -> PackedInt32Array:
	var row := PackedInt32Array()
	for i in n:
		match edge:
			0: row.append(i)
			1: row.append(i * n + n - 1)
			2: row.append(n * n - 1 - i)
			3: row.append((n - 1 - i) * n)
	return row


## (quads + 1)^2 heights without the halo.
static func _collision_heights(heights: PackedFloat32Array, side: int, quads: int) -> PackedFloat32Array:
	var collision := PackedFloat32Array()
	collision.resize((quads + 1) * (quads + 1))
	for z in quads + 1:
		for x in quads + 1:
			collision[z * (quads + 1) + x] = heights[(z + 1) * side + x + 1]
	return collision
