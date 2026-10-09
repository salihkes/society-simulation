class_name BuildSnapping
extends RefCounted

## Grid and surface snapping math for the build tools.

const AXIS_ALIGNED_TOLERANCE := 0.999


static func snap_vec3(pos: Vector3, grid: float) -> Vector3:
	if grid <= 0.0:
		return pos
	return Vector3(
		roundf(pos.x / grid) * grid,
		roundf(pos.y / grid) * grid,
		roundf(pos.z / grid) * grid
	)


static func snap_scalar(value: float, grid: float) -> float:
	if grid <= 0.0:
		return value
	return roundf(value / grid) * grid


## Index (0/1/2) of the world axis the normal lies along, or -1 when sloped.
static func dominant_axis(normal: Vector3) -> int:
	for i in 3:
		if absf(normal[i]) >= AXIS_ALIGNED_TOLERANCE:
			return i
	return -1


## Distance from an oriented box's centre to its surface along `normal`.
static func support_extent(basis: Basis, local_aabb: AABB, normal: Vector3) -> float:
	var half := local_aabb.size * 0.5
	var extent := 0.0
	for i in 3:
		var axis := Vector3.ZERO
		axis[i] = 1.0
		extent += absf((basis * axis).dot(normal)) * half[i]
	return extent


## Rests a part on hit_pos; snaps tangential coords to the grid on axis-aligned faces only.
static func place_on_face(hit_pos: Vector3, normal: Vector3, part_basis: Basis, local_aabb: AABB, grid: float) -> Transform3D:
	var n := normal.normalized()
	var extent := support_extent(part_basis, local_aabb, n)
	var center_offset := part_basis * local_aabb.get_center()
	var origin := hit_pos + n * extent - center_offset

	var axis := dominant_axis(n)
	if axis >= 0 and grid > 0.0:
		for i in 3:
			if i != axis:
				origin[i] = snap_scalar(origin[i], grid)

	return Transform3D(part_basis, origin)
