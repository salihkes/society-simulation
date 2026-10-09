extends RefCounted
## One 8 m snow patch; its track texture is r cut + snowfall, g expiry, b ground height, a track id.

const SIZE := 8.0
const TEXTURE_SIZE := 128

var key := Vector2i.ZERO
var origin := Vector2.ZERO
var cells := 32
var sample_cells := 32
var cursor := 0
var _sample_vertices := PackedVector3Array()
var _sample_normals := PackedVector3Array()
var _sample_valid := PackedByteArray()
var vertices := PackedVector3Array()
var normals := PackedVector3Array()
var valid := PackedByteArray()
var image: Image
var texture: ImageTexture
var material: ShaderMaterial
var node: MeshInstance3D
var dirty := false
var painted := 0


func setup(coordinate: Vector2i, resolution: int, parent: Node3D) -> void:
	key = coordinate
	origin = Vector2(key) * SIZE
	rebuild(resolution)
	image = Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBAF)
	image.fill(Color(0, 0, -10000, 0))
	texture = ImageTexture.create_from_image(image)
	material = ShaderMaterial.new()
	material.shader = load("res://src/world/environment/snow_surface.gdshader")
	material.set_shader_parameter("tracks", texture)
	material.set_shader_parameter("tile_origin", origin)
	node = MeshInstance3D.new()
	node.name = "Snow_%d_%d" % [key.x, key.y]
	node.material_override = material
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(node)
	node.position = Vector3(origin.x, 0, origin.y)


## The current mesh stays until sampling at the new resolution completes.
func rebuild(resolution: int) -> void:
	cells = resolution
	sample_cells = mini(cells, 32)
	cursor = 0
	var count := (sample_cells + 1) * (sample_cells + 1)
	_sample_vertices = PackedVector3Array()
	_sample_normals = PackedVector3Array()
	_sample_valid = PackedByteArray()
	_sample_vertices.resize(count)
	_sample_normals.resize(count)
	_sample_valid.resize(count)


## World XZ of the next ground sample to trace.
func next_position() -> Vector2:
	return origin + Vector2(cursor % (sample_cells + 1), cursor / (sample_cells + 1)) * SIZE / sample_cells


## Ground above the sea and not too steep counts; builds the mesh after the last sample.
func sample(hit: Dictionary, sea_level: float) -> void:
	var xz := next_position() - origin
	_sample_vertices[cursor] = Vector3(xz.x, 0, xz.y)
	_sample_normals[cursor] = Vector3.UP
	if not hit.is_empty() and hit.position.y > sea_level + 0.02:
		_sample_vertices[cursor].y = hit.position.y
		_sample_normals[cursor] = hit.normal
		_sample_valid[cursor] = int(hit.normal.y > 0.55)
	cursor += 1
	if complete():
		_build()


func complete() -> bool:
	return cursor == _sample_vertices.size()


func _build() -> void:
	_filter_thin_obstacles()
	_resample_mesh()
	var indices := PackedInt32Array()
	for z in cells:
		for x in cells:
			var a := z * (cells + 1) + x
			var b := a + 1
			var c := a + cells + 1
			var d := c + 1
			_triangle(indices, a, b, c)
			_triangle(indices, b, d, c)
	if indices.is_empty():
		node.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = mesh.get_aabb().grow(0.35)
	node.mesh = mesh


## Retraces samples high above both opposite neighbours: a wire or rail cannot shelter a 25 cm cell.
func _filter_thin_obstacles() -> void:
	var cover = node.get_parent()
	if not cover.has_method("static_hit"):
		return
	var heights := _sample_vertices.duplicate()
	for z in range(1, sample_cells):
		for x in range(1, sample_cells):
			var k := z * (sample_cells + 1) + x
			var y := heights[k].y
			var left := heights[k - 1].y
			var right := heights[k + 1].y
			var back := heights[k - sample_cells - 1].y
			var front := heights[k + sample_cells + 1].y
			var narrow_x := y - maxf(left, right) > 0.5 and absf(left - right) < 0.2 and _sample_valid[k-1] and _sample_valid[k+1]
			var narrow_z := y - maxf(back, front) > 0.5 and absf(back - front) < 0.2 and _sample_valid[k-sample_cells-1] and _sample_valid[k+sample_cells+1]
			if not narrow_x and not narrow_z:
				continue
			var p := heights[k] + Vector3(origin.x, 0, origin.y)
			var below := minf(left, right) if narrow_x else minf(back, front)
			var hit: Dictionary = cover.static_hit(p - Vector3.UP * 0.06, Vector3(p.x, below - 1.0, p.z))
			if not hit.is_empty() and hit.normal.y > 0.55 and hit.position.y > cover._sea_level + 0.02:
				_sample_vertices[k].y = hit.position.y
				_sample_normals[k] = hit.normal
				_sample_valid[k] = 1


## The finer mesh only exists to deform under feet and tyres; cells across a height jump stay gaps.
func _resample_mesh() -> void:
	if cells == sample_cells:
		vertices = _sample_vertices
		normals = _sample_normals
		valid = _sample_valid
		return
	var count := (cells + 1) * (cells + 1)
	vertices.resize(count)
	normals.resize(count)
	valid.resize(count)
	for z in cells + 1:
		for x in cells + 1:
			var p := Vector2(x, z) * float(sample_cells) / cells
			var ix := mini(floori(p.x), sample_cells - 1)
			var iz := mini(floori(p.y), sample_cells - 1)
			var tx := p.x - ix
			var tz := p.y - iz
			var a := iz * (sample_cells + 1) + ix
			var b := a + 1
			var c := a + sample_cells + 1
			var d := c + 1
			var k := z * (cells + 1) + x
			vertices[k] = _sample_vertices[a].lerp(_sample_vertices[b], tx).lerp(_sample_vertices[c].lerp(_sample_vertices[d], tx), tz)
			normals[k] = _sample_normals[a].lerp(_sample_normals[b], tx).lerp(_sample_normals[c].lerp(_sample_normals[d], tx), tz).normalized()
			valid[k] = int(_sample_valid[a] and _sample_valid[b] and _sample_valid[c] and _sample_valid[d])
			var low := minf(minf(_sample_vertices[a].y, _sample_vertices[b].y), minf(_sample_vertices[c].y, _sample_vertices[d].y))
			var high := maxf(maxf(_sample_vertices[a].y, _sample_vertices[b].y), maxf(_sample_vertices[c].y, _sample_vertices[d].y))
			if high - low > SIZE / sample_cells * 1.5 + 0.05:
				valid[k] = 0


## Skips a triangle with an invalid corner or spanning a height jump (building edge, stairwell, hole).
func _triangle(indices: PackedInt32Array, a: int, b: int, c: int) -> void:
	if not valid[a] or not valid[b] or not valid[c]:
		return
	var low := minf(vertices[a].y, minf(vertices[b].y, vertices[c].y))
	var high := maxf(vertices[a].y, maxf(vertices[b].y, vertices[c].y))
	if high - low > SIZE / cells * 1.5 + 0.05:
		return
	indices.append(a)
	indices.append(b)
	indices.append(c)


## Presses a SnowState track record into the texture where it cuts deeper.
func paint(record: PackedFloat32Array, id: int, snowfall: float, now: float, first_id := 1) -> void:
	painted = maxi(painted, id)
	var radius := maxf(record[4], record[5]) * 0.72
	var centre := Vector2(record[0], record[2])
	if centre.x + radius < origin.x or centre.y + radius < origin.y or centre.x - radius > origin.x + SIZE or centre.y - radius > origin.y + SIZE:
		return
	var lo := Vector2i(((centre - Vector2.ONE * radius - origin) / SIZE * TEXTURE_SIZE).floor())
	var hi := Vector2i(((centre + Vector2.ONE * radius - origin) / SIZE * TEXTURE_SIZE).ceil())
	var across := Vector2(cos(record[3]), -sin(record[3]))
	var along := Vector2(sin(record[3]), cos(record[3]))
	for y in range(maxi(0, lo.y), mini(TEXTURE_SIZE - 1, hi.y) + 1):
		for x in range(maxi(0, lo.x), mini(TEXTURE_SIZE - 1, hi.x) + 1):
			var p := origin + (Vector2(x, y) + Vector2.ONE * 0.5) * SIZE / TEXTURE_SIZE - centre
			var u := p.dot(across) / (record[4] * 0.5)
			var v := p.dot(along) / (record[5] * 0.5)
			var shape := maxf(absf(u), absf(v)) if record[9] > 0.5 else Vector2(u, v).length()
			var weight := 1.0 - smoothstep(0.64, 1.0, shape)
			if weight <= 0.0:
				continue
			var tread := 0.94 + 0.06 * sin(p.dot(along) * 105.0)
			var cut := maxf(0.0, record[6] - (snowfall - record[7])) * weight * tread
			var old := image.get_pixel(x, y)
			var old_cut := maxf(0.0, old.r - snowfall) if old.a >= first_id and old.g > now and absf(old.b - record[1]) < 0.2 else 0.0
			if cut >= old_cut:
				image.set_pixel(x, y, Color(cut + snowfall, record[8] + 900.0, record[1], float(id)))
				dirty = true


func upload() -> void:
	if dirty:
		texture.update(image)
		dirty = false


func clear_tracks() -> void:
	image.fill(Color(0, 0, -10000, 0))
	painted = 0
	dirty = true


func dispose() -> void:
	if is_instance_valid(node):
		node.queue_free()
