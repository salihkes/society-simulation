class_name CubeSphere
## Cube-sphere addressing: planet-local unit direction <-> (face, u, v) on six faces +X -X +Y -Y +Z -Z.

const FACE_COUNT := 6


## u, v in [0, 1].
static func face_uv_to_dir(face: int, u: float, v: float) -> Vector3:
	var a := u * 2.0 - 1.0
	var b := v * 2.0 - 1.0
	var p: Vector3
	match face:
		0: p = Vector3(1.0, -b, -a)   # +X
		1: p = Vector3(-1.0, -b, a)   # -X
		2: p = Vector3(a, 1.0, b)     # +Y
		3: p = Vector3(a, -1.0, -b)   # -Y
		4: p = Vector3(a, -b, 1.0)    # +Z
		_: p = Vector3(-a, -b, -1.0)  # -Z
	return p.normalized()


## Returns [face, u, v]; exact inverse of face_uv_to_dir.
static func dir_to_face_uv(dir: Vector3) -> Array:
	var ax := absf(dir.x)
	var ay := absf(dir.y)
	var az := absf(dir.z)
	var face: int
	var a: float
	var b: float
	if ax >= ay and ax >= az:
		if dir.x > 0.0:
			face = 0; a = -dir.z / ax; b = -dir.y / ax
		else:
			face = 1; a = dir.z / ax; b = -dir.y / ax
	elif ay >= ax and ay >= az:
		if dir.y > 0.0:
			face = 2; a = dir.x / ay; b = dir.z / ay
		else:
			face = 3; a = dir.x / ay; b = -dir.z / ay
	else:
		if dir.z > 0.0:
			face = 4; a = dir.x / az; b = -dir.y / az
		else:
			face = 5; a = -dir.x / az; b = -dir.y / az
	return [face, (a + 1.0) * 0.5, (b + 1.0) * 0.5]


## [u, v] unclamped (may fall outside 0..1), or [] when dir is behind the face plane.
static func dir_uv_on_face(face: int, dir: Vector3) -> Array:
	var d: float
	var a: float
	var b: float
	match face:
		0: d = dir.x;  a = -dir.z; b = -dir.y
		1: d = -dir.x; a = dir.z;  b = -dir.y
		2: d = dir.y;  a = dir.x;  b = dir.z
		3: d = -dir.y; a = dir.x;  b = -dir.z
		4: d = dir.z;  a = dir.x;  b = -dir.y
		_: d = -dir.z; a = -dir.x; b = -dir.y
	if d <= 0.0001:
		return []
	return [(a / d + 1.0) * 0.5, (b / d + 1.0) * 0.5]


## [east, north], stable at the poles.
static func tangent_frame(dir: Vector3) -> Array:
	var ref := Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT
	var east := ref.cross(dir).normalized()
	var north := dir.cross(east).normalized()
	return [east, north]


## Radians.
static func angle_between(a: Vector3, b: Vector3) -> float:
	return acos(clampf(a.dot(b), -1.0, 1.0))


## Computed in 3D and renormalised; accurate only for segments much smaller than the planet.
static func catmull_rom_dir(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	var v := 0.5 * ((2.0 * p1) + (-p0 + p2) * t \
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 \
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
	return v.normalized()


static func catmull_rom_f(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t \
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 \
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
