@tool
class_name PlanetHeightField
extends Resource
## A planet's heights: six cube-sphere faces of float32 metres above sea level (negative is seabed).

@export var resolution := 512
## 6 faces of resolution^2 heights, CubeSphere face order, row-major (v * resolution + u).
@export var faces: Array[PackedFloat32Array] = []


func is_valid() -> bool:
	if faces.size() != CubeSphere.FACE_COUNT:
		return false
	for f in faces:
		if f.size() != resolution * resolution:
			return false
	return true


func make_blank(res: int, fill := 0.0) -> void:
	resolution = res
	faces = []
	for i in CubeSphere.FACE_COUNT:
		var arr := PackedFloat32Array()
		arr.resize(res * res)
		arr.fill(fill)
		faces.append(arr)


func duplicate_field() -> PlanetHeightField:
	var out := PlanetHeightField.new()
	out.resolution = resolution
	out.faces = []
	for f in faces:
		out.faces.append(f.duplicate())
	return out


## Clamped addressing.
func get_px(face: int, x: int, y: int) -> float:
	x = clampi(x, 0, resolution - 1)
	y = clampi(y, 0, resolution - 1)
	return faces[face][y * resolution + x]


func set_px(face: int, x: int, y: int, h: float) -> void:
	if x < 0 or y < 0 or x >= resolution or y >= resolution:
		return
	faces[face][y * resolution + x] = h


func sample_dir(dir: Vector3) -> float:
	var fuv := CubeSphere.dir_to_face_uv(dir)
	var face: int = fuv[0]
	var fx: float = clampf(fuv[1], 0.0, 1.0) * (resolution - 1)
	var fy: float = clampf(fuv[2], 0.0, 1.0) * (resolution - 1)
	var x0 := int(fx)
	var y0 := int(fy)
	var tx := fx - x0
	var ty := fy - y0
	var x1 := mini(x0 + 1, resolution - 1)
	var y1 := mini(y0 + 1, resolution - 1)
	var row := faces[face]
	var h00 := row[y0 * resolution + x0]
	var h10 := row[y0 * resolution + x1]
	var h01 := row[y1 * resolution + x0]
	var h11 := row[y1 * resolution + x1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), ty)


## Planet-local, by central differences step_m apart (about one texel).
func normal_dir(dir: Vector3, radius: float, step_m: float) -> Vector3:
	var frame := CubeSphere.tangent_frame(dir)
	var east: Vector3 = frame[0]
	var north: Vector3 = frame[1]
	var ang := step_m / radius
	var de := (dir + east * ang).normalized()
	var dw := (dir - east * ang).normalized()
	var dn := (dir + north * ang).normalized()
	var ds := (dir - north * ang).normalized()
	var pe := de * (radius + sample_dir(de))
	var pw := dw * (radius + sample_dir(dw))
	var pn := dn * (radius + sample_dir(dn))
	var ps := ds * (radius + sample_dir(ds))
	var n := (pe - pw).cross(pn - ps).normalized()
	if n.dot(dir) < 0.0:
		n = -n
	return n


## tools/bake/planetforge output: face_0..5.f32 (row-major LE float32) and meta.json {"resolution": N}; null on error.
static func load_raw_folder(dir_path: String) -> PlanetHeightField:
	var meta_path := dir_path.path_join("meta.json")
	if not FileAccess.file_exists(meta_path):
		return null
	var meta_file := FileAccess.open(meta_path, FileAccess.READ)
	var meta: Variant = JSON.parse_string(meta_file.get_as_text())
	if typeof(meta) != TYPE_DICTIONARY or not meta.has("resolution"):
		push_error("PlanetHeightField: bad meta.json in %s" % dir_path)
		return null
	var res := int(meta["resolution"])
	var out := PlanetHeightField.new()
	out.resolution = res
	out.faces = []
	for i in CubeSphere.FACE_COUNT:
		var fpath := dir_path.path_join("face_%d.f32" % i)
		var f := FileAccess.open(fpath, FileAccess.READ)
		if f == null:
			push_error("PlanetHeightField: missing %s" % fpath)
			return null
		var bytes := f.get_buffer(res * res * 4)
		if bytes.size() != res * res * 4:
			push_error("PlanetHeightField: %s wrong size (%d bytes, wanted %d)" % [fpath, bytes.size(), res * res * 4])
			return null
		out.faces.append(bytes.to_float32_array())
	return out


## Deterministic fallback terrain: mountainous land with bays and coasts, the rest sea.
func generate(res: int, seed_v: int, max_height: float, ocean_depth: float) -> void:
	make_blank(res)
	var continents := FastNoiseLite.new()
	continents.seed = seed_v
	continents.frequency = 0.9
	continents.fractal_octaves = 4
	var ridges := FastNoiseLite.new()
	ridges.seed = seed_v + 1
	ridges.frequency = 3.0
	ridges.fractal_octaves = 5
	ridges.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	var detail := FastNoiseLite.new()
	detail.seed = seed_v + 2
	detail.frequency = 9.0
	detail.fractal_octaves = 4
	for face in CubeSphere.FACE_COUNT:
		var arr := faces[face]
		for y in res:
			var v := float(y) / float(res - 1)
			for x in res:
				var d := CubeSphere.face_uv_to_dir(face, float(x) / float(res - 1), v)
				arr[y * res + x] = _generated_height(d, continents, ridges, detail,
					max_height, ocean_depth)


static func _generated_height(d: Vector3, continents: FastNoiseLite, ridges: FastNoiseLite,
		detail: FastNoiseLite, max_height: float, ocean_depth: float) -> float:
	var land := continents.get_noise_3dv(d) + 0.12
	var h: float
	if land > 0.0:
		# t is 0 at the coast.
		var t := clampf(land * 3.0, 0.0, 1.0)
		var ridge := maxf(ridges.get_noise_3dv(d), 0.0)
		h = t * t * max_height * (0.35 + 0.65 * ridge)
		h += detail.get_noise_3dv(d) * max_height * 0.03 * t
		# A gentle beach shelf just above the waterline.
		if h < max_height * 0.02:
			h *= 0.5
	else:
		var t2 := clampf(-land * 3.0, 0.0, 1.0)
		h = -t2 * absf(ocean_depth)
		h += detail.get_noise_3dv(d) * 0.5
	return h
