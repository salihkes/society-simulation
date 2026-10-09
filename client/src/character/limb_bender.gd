extends RefCounted
class_name LimbBender
## A knee or elbow for a rigid box limb: the box is skinned at runtime and bent as a tube.

## Ring planes every RING_STEP out to RING_REACH either side; the arc radius is BEND_RADIUS half-widths.
const RING_STEP := 0.2
const RING_REACH := 0.8
const BEND_RADIUS := 0.6

static var _mesh_cache := {}  # [mesh id, child transform] -> _skinned_copy() result

var pivot: Node3D
var skeleton: Skeleton3D
var mesh_instance: MeshInstance3D
var joint := Vector3.ZERO  # joint centre, pivot space
var half_width := 0.5  # half the box cross-section
var ring_u := PackedFloat32Array()  # signed distance of each ring below the joint
var axis := Vector3.RIGHT
var angle := 0.0


## `limb_pivot`'s direct child is the box mesh; null when not shaped like that or already bendable.
static func build(limb_pivot: Node3D) -> LimbBender:
	if limb_pivot == null or limb_pivot is MeshInstance3D:
		return null
	if limb_pivot.get_node_or_null("LimbSkeleton") != null:
		return null
	var mi := _box_mesh(limb_pivot)
	if mi == null or mi.mesh.get_surface_count() == 0:
		return null

	var built := _skinned_copy(mi.mesh, mi.transform)
	if built.is_empty():
		return null

	var bender := LimbBender.new()
	bender.pivot = limb_pivot
	bender.mesh_instance = mi
	bender.joint = built.joint
	bender.half_width = built.half
	bender.ring_u = built.ring_u

	var skel := _ring_skeleton(bender.ring_u.size())
	limb_pivot.add_child(skel)
	bender.skeleton = skel

	mi.mesh = built.mesh
	mi.transform = Transform3D.IDENTITY
	mi.skeleton = mi.get_path_to(skel)
	# The bent limb sweeps outside its rest box; never let the culler lose it.
	var reach := (built.mesh as ArrayMesh).get_aabb().get_longest_axis_size() + 1.0
	mi.custom_aabb = AABB(Vector3.ONE * -reach, Vector3.ONE * 2.0 * reach)
	return bender


static func _box_mesh(limb_pivot: Node3D) -> MeshInstance3D:
	for child in limb_pivot.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh != null:
			return child
	return null


static func _ring_skeleton(count: int) -> Skeleton3D:
	var skel := Skeleton3D.new()
	skel.name = "LimbSkeleton"
	for k in count:
		skel.add_bone("ring_%d" % k)
		skel.set_bone_rest(k, Transform3D.IDENTITY)
	return skel


## The lower half turns by bend_angle about bend_axis (pivot space); 0 is the rest box.
func bend(bend_axis: Vector3, bend_angle: float) -> void:
	if skeleton == null or not is_instance_valid(skeleton):
		return
	if bend_axis.length_squared() < 1e-8:
		bend_axis = Vector3.RIGHT
	bend_axis = bend_axis.normalized()
	if is_equal_approx(bend_angle, angle) and bend_axis.is_equal_approx(axis):
		return
	axis = bend_axis
	angle = bend_angle
	for k in ring_u.size():
		var t := ring_transform(ring_u[k], joint, half_width, axis, angle)
		skeleton.set_bone_pose_position(k, t.origin)
		skeleton.set_bone_pose_rotation(k, t.basis.get_rotation_quaternion())


func straighten() -> void:
	bend(axis, 0.0)


## Rigid transform of the rest slice at `u` below the joint into the bend.
static func ring_transform(u: float, joint_pos: Vector3, half: float, bend_axis: Vector3,
		bend_angle: float) -> Transform3D:
	var rest := joint_pos + Vector3.DOWN * u
	if absf(bend_angle) < 1e-4:
		return Transform3D.IDENTITY
	var h := clampf(BEND_RADIUS * half * absf(bend_angle) * 0.5, RING_STEP * 0.5, RING_REACH)
	var d := Vector3.DOWN
	var n := bend_axis.cross(d)  # the side the limb turns toward
	if n.length_squared() < 1e-8:
		return Transform3D.IDENTITY
	n = n.normalized() * signf(bend_angle)
	var a := absf(bend_angle)
	var radius := 2.0 * h / a
	var start := joint_pos - d * h  # the arc begins above the joint
	var centre := start + n * radius
	var rot: Basis
	var pos: Vector3
	if u <= -h:
		return Transform3D.IDENTITY
	elif u < h:
		var frac := (u + h) / (2.0 * h)
		rot = Basis(bend_axis, bend_angle * frac)
		pos = centre + rot * (start - centre)
	else:
		rot = Basis(bend_axis, bend_angle)
		var arc_end := centre + rot * (start - centre)
		pos = arc_end + rot * d * (u - h)
	return Transform3D(rot, pos - rot * rest)


## {mesh, joint, half, ring_u}, or {} when the mesh is not a box hanging along Y.
static func _skinned_copy(src: Mesh, child_xf: Transform3D) -> Dictionary:
	var key := [src.get_instance_id(), child_xf]
	if _mesh_cache.has(key):
		return _mesh_cache[key]

	var out := ArrayMesh.new()
	var ring_u := PackedFloat32Array()
	var whole := _bounds(src, child_xf)
	if whole.size.y < 0.5:
		return {}
	var joint_pos := whole.get_center()
	var half := maxf(whole.size.x, whole.size.z) * 0.5
	var count := int(round(2.0 * RING_REACH / RING_STEP)) + 1
	for k in count:
		ring_u.append(-RING_REACH + k * RING_STEP)

	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		if src.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			return {}
		var soup := _MeshSoup.new(arrays, child_xf)
		var planes := []
		for k in count:
			planes.append(joint_pos.y - ring_u[k])
		soup.split_at_planes(planes)
		var skinned := soup.to_arrays(
				func(y: float) -> Array: return _weights_for(y, joint_pos.y, ring_u))
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, skinned)
		var mat := src.surface_get_material(s)
		if mat != null:
			out.surface_set_material(out.get_surface_count() - 1, mat)
	if out.get_surface_count() == 0:
		return {}

	var built := {"mesh": out, "joint": joint_pos, "half": half, "ring_u": ring_u}
	_mesh_cache[key] = built
	return built


static func _bounds(src: Mesh, child_xf: Transform3D) -> AABB:
	var whole := AABB()
	for s in src.get_surface_count():
		var verts: PackedVector3Array = src.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for i in verts.size():
			var p := child_xf * verts[i]
			whole = whole.expand(p) if i > 0 or s > 0 else AABB(p, Vector3.ZERO)
	return whole


## [bone, weight, bone, weight]: the ring at height y or a blend of the two around it.
static func _weights_for(y: float, joint_y: float, ring_u: PackedFloat32Array) -> Array:
	var u := joint_y - y
	var n := ring_u.size()
	if u <= ring_u[0] + 1e-4:
		return [0, 1.0, 0, 0.0]
	if u >= ring_u[n - 1] - 1e-4:
		return [n - 1, 1.0, 0, 0.0]
	for k in n - 1:
		if u >= ring_u[k] - 1e-4 and u <= ring_u[k + 1] + 1e-4:
			var t := clampf((u - ring_u[k]) / (ring_u[k + 1] - ring_u[k]), 0.0, 1.0)
			if t < 1e-3:
				return [k, 1.0, 0, 0.0]
			if t > 1.0 - 1e-3:
				return [k + 1, 1.0, 0, 0.0]
			return [k, 1.0 - t, k + 1, t]
	return [n - 1, 1.0, 0, 0.0]


## Triangle soup in pivot space, sliceable by horizontal planes, keeping every vertex attribute.
class _MeshSoup:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var tan := PackedFloat32Array()
	var col := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var has_nrm := false
	var has_tan := false
	var has_col := false
	var has_uv := false
	var has_uv2 := false
	var tris := PackedInt32Array()
	var _edge_cache := {}

	func _init(arrays: Array, xf: Transform3D) -> void:
		var src_pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nb := xf.basis.inverse().transposed()
		for p in src_pos:
			pos.append(xf * p)
		if arrays[Mesh.ARRAY_NORMAL] != null:
			has_nrm = true
			for n in arrays[Mesh.ARRAY_NORMAL]:
				nrm.append((nb * n).normalized())
		if arrays[Mesh.ARRAY_TANGENT] != null:
			has_tan = true
			var t: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
			for i in src_pos.size():
				var v := (xf.basis * Vector3(t[i * 4], t[i * 4 + 1], t[i * 4 + 2])).normalized()
				tan.append_array([v.x, v.y, v.z, t[i * 4 + 3]])
		if arrays[Mesh.ARRAY_COLOR] != null:
			has_col = true
			col = arrays[Mesh.ARRAY_COLOR]
		if arrays[Mesh.ARRAY_TEX_UV] != null:
			has_uv = true
			uv = arrays[Mesh.ARRAY_TEX_UV]
		if arrays[Mesh.ARRAY_TEX_UV2] != null:
			has_uv2 = true
			uv2 = arrays[Mesh.ARRAY_TEX_UV2]
		if arrays[Mesh.ARRAY_INDEX] != null:
			tris = arrays[Mesh.ARRAY_INDEX]
		else:
			for i in src_pos.size():
				tris.append(i)

	## Once per edge and t; returns the vertex index.
	func _lerp_vertex(i: int, j: int, t: float) -> int:
		var key := [mini(i, j), maxi(i, j), snappedf(t if i < j else 1.0 - t, 1e-5)]
		if _edge_cache.has(key):
			return _edge_cache[key]
		var idx := pos.size()
		pos.append(pos[i].lerp(pos[j], t))
		if has_nrm:
			nrm.append(nrm[i].lerp(nrm[j], t).normalized())
		if has_tan:
			var a := Vector3(tan[i * 4], tan[i * 4 + 1], tan[i * 4 + 2])
			var b := Vector3(tan[j * 4], tan[j * 4 + 1], tan[j * 4 + 2])
			var v := a.lerp(b, t).normalized()
			tan.append_array([v.x, v.y, v.z, tan[i * 4 + 3]])
		if has_col:
			col.append(col[i].lerp(col[j], t))
		if has_uv:
			uv.append(uv[i].lerp(uv[j], t))
		if has_uv2:
			uv2.append(uv2[i].lerp(uv2[j], t))
		_edge_cache[key] = idx
		return idx

	## Keeps winding; plane_ys may be in any order.
	func split_at_planes(plane_ys: Array) -> void:
		var planes := plane_ys.duplicate()
		planes.sort()
		planes.reverse()  # top down
		var out := PackedInt32Array()
		for t in range(0, tris.size(), 3):
			for poly in _slice([tris[t], tris[t + 1], tris[t + 2]], planes):
				for k in range(1, poly.size() - 1):
					out.append_array([poly[0], poly[k], poly[k + 1]])
		tris = out

	## Triangulating only at the end keeps the piece count low.
	func _slice(cur: Array, planes: Array) -> Array:
		var finished: Array = []
		for plane_y in planes:
			var parts := _clip(cur, plane_y)
			if parts[0].size() >= 3:
				finished.append(parts[0])
			cur = parts[1]
			if cur.size() < 3:
				break
		if cur.size() >= 3:
			finished.append(cur)
		return finished

	## Returns [above, below]; vertices on the plane belong to both.
	func _clip(poly: Array, plane_y: float) -> Array:
		const EPS := 1e-4
		var n := poly.size()
		var d := []
		var above := 0
		var below := 0
		for i in n:
			var v: float = pos[poly[i]].y - plane_y
			d.append(v)
			if v > EPS:
				above += 1
			elif v < -EPS:
				below += 1
		if below == 0:
			return [poly, []]
		if above == 0:
			return [[], poly]
		var up_poly: Array = []
		var down_poly: Array = []
		for e in n:
			var i: int = poly[e]
			var j: int = poly[(e + 1) % n]
			var di: float = d[e]
			var dj: float = d[(e + 1) % n]
			if di >= -EPS:
				up_poly.append(i)
			if di <= EPS:
				down_poly.append(i)
			if (di > EPS and dj < -EPS) or (di < -EPS and dj > EPS):
				var cut := _lerp_vertex(i, j, di / (di - dj))
				up_poly.append(cut)
				down_poly.append(cut)
		return [up_poly, down_poly]

	func to_arrays(weights_for: Callable) -> Array:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		if has_nrm:
			arrays[Mesh.ARRAY_NORMAL] = nrm
		if has_tan:
			arrays[Mesh.ARRAY_TANGENT] = tan
		if has_col:
			arrays[Mesh.ARRAY_COLOR] = col
		if has_uv:
			arrays[Mesh.ARRAY_TEX_UV] = uv
		if has_uv2:
			arrays[Mesh.ARRAY_TEX_UV2] = uv2
		arrays[Mesh.ARRAY_INDEX] = tris
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		for p in pos:
			var w: Array = weights_for.call(p.y)
			bones.append_array([w[0], w[2], 0, 0])
			weights.append_array([w[1], w[3], 0.0, 0.0])
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		return arrays
