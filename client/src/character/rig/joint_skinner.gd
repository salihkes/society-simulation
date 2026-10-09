extends RefCounted
## Builds a Skeleton3D from a Marker3D joint tree and skins an unrigged mesh to it; a segment runs to the FIRST child joint.

const SIDE_EPS := 0.03
const FALLOFF := 4.0
const MIN_RADIUS := 0.1
const MAX_INFLUENCES := 4

## [mesh id, joint layout hash, mesh transform, falloff] -> skinned ArrayMesh
static var _cache := {}


class Bone:
	var name: String
	var parent := -1
	var rest_pos := Vector3.ZERO  # rig space
	var tip := Vector3.ZERO  # rig space, end of the segment
	var radius := MIN_RADIUS
	var is_end := false  # leaf joint: no vertices


## Positions are relative to rig_root, where the Skeleton3D will sit.
static func collect_bones(joints_root: Node3D, rig_root: Node3D) -> Array:
	var bones: Array = []
	_collect(joints_root, rig_root, -1, bones)
	for bi in bones.size():
		var b: Bone = bones[bi]
		var first_child := -1
		for i in bones.size():
			if bones[i].parent == bi:
				first_child = i
				break
		if first_child < 0:
			b.is_end = true
			b.tip = b.rest_pos
		else:
			b.tip = bones[first_child].rest_pos
	return bones


static func _collect(node: Node, rig_root: Node3D, parent: int, out: Array) -> void:
	for child in node.get_children():
		if not (child is Node3D):
			continue
		var b := Bone.new()
		b.name = String(child.name)
		b.parent = parent
		b.rest_pos = _relative_to(child, rig_root).origin
		if child.has_meta("radius"):
			b.radius = float(child.get_meta("radius"))
		else:
			b.radius = -1.0  # decided once the tip is known
		out.append(b)
		_collect(child, rig_root, out.size() - 1, out)


## From node transforms alone: global transforms are not trustworthy before the first frame.
static func _relative_to(node: Node3D, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## Moves the mesh under the skeleton; null with no mesh, joint or triangle surface.
static func build(rig_root: Node3D, joints_root: Node3D, mesh_instance: MeshInstance3D) -> Skeleton3D:
	if mesh_instance == null or mesh_instance.mesh == null:
		return null
	var bones := collect_bones(joints_root, rig_root)
	if bones.is_empty():
		return null
	for b in bones:
		if b.radius < 0.0:
			b.radius = maxf(MIN_RADIUS, 0.5 * b.rest_pos.distance_to(b.tip))
	var falloff := float(joints_root.get_meta("falloff", FALLOFF))

	var mesh_xf := _relative_to(mesh_instance, rig_root)
	var key := [mesh_instance.mesh.get_instance_id(), _layout_hash(bones), mesh_xf, falloff]
	var skinned: ArrayMesh
	if _cache.has(key):
		skinned = _cache[key]
	else:
		skinned = _skin(mesh_instance.mesh, mesh_xf, bones, falloff)
		if skinned == null:
			return null
		_cache[key] = skinned

	var skel := _make_skeleton(bones)
	rig_root.add_child(skel)

	var parent := mesh_instance.get_parent()
	if parent != null:
		parent.remove_child(mesh_instance)
	skel.add_child(mesh_instance)
	mesh_instance.transform = Transform3D.IDENTITY
	mesh_instance.mesh = skinned
	mesh_instance.skin = skel.create_skin_from_rest_transforms()
	mesh_instance.skeleton = mesh_instance.get_path_to(skel)
	var reach := skinned.get_aabb().get_longest_axis_size() + 1.0
	mesh_instance.custom_aabb = AABB(Vector3.ONE * -reach, Vector3.ONE * 2 * reach)
	return skel


## Translation-only rests.
static func _make_skeleton(bones: Array) -> Skeleton3D:
	var skel := Skeleton3D.new()
	skel.name = "Skeleton"
	for i in bones.size():
		var b: Bone = bones[i]
		skel.add_bone(b.name)
		var local_pos: Vector3 = b.rest_pos
		if b.parent >= 0:
			skel.set_bone_parent(i, b.parent)
			local_pos = b.rest_pos - bones[b.parent].rest_pos
		skel.set_bone_rest(i, Transform3D(Basis.IDENTITY, local_pos))
	skel.reset_bone_poses()
	return skel


static func _layout_hash(bones: Array) -> int:
	var parts := []
	for b in bones:
		parts.append([b.name, b.parent, b.rest_pos, b.tip, b.radius])
	return hash(parts)


## Null when nothing could be skinned.
static func _skin(src: Mesh, mesh_xf: Transform3D, bones: Array, falloff: float) -> ArrayMesh:
	var seg := _segments(bones)
	var m: int = seg.active.size()
	if m == 0:
		return null
	var out := ArrayMesh.new()
	var fallback_total := 0
	var started := Time.get_ticks_msec()
	for s in src.get_surface_count():
		if src.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var result := _skin_surface(src.surface_get_arrays(s), mesh_xf, seg, falloff)
		fallback_total += result[1]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, result[0])
		var mat := src.surface_get_material(s)
		if mat != null:
			out.surface_set_material(out.get_surface_count() - 1, mat)
	print("JointSkinner: skinned %d surfaces to %d bones in %d ms (%d vertices outside every envelope)"
			% [out.get_surface_count(), m, Time.get_ticks_msec() - started, fallback_total])
	return out if out.get_surface_count() > 0 else null


## Skips end bones.
static func _segments(bones: Array) -> Dictionary:
	var seg := {
		"a": PackedVector3Array(), "dir": PackedVector3Array(), "len": PackedFloat32Array(),
		"r2": PackedFloat32Array(), "side": PackedFloat32Array(), "active": PackedInt32Array(),
	}
	for i in bones.size():
		var b: Bone = bones[i]
		if b.is_end:
			continue
		var d: Vector3 = b.tip - b.rest_pos
		var l := d.length()
		seg.active.append(i)
		seg.a.append(b.rest_pos)
		seg.dir.append(d / l if l > 1e-6 else Vector3.UP)
		seg.len.append(l)
		seg.r2.append(b.radius * b.radius)
		var mid_x := (b.rest_pos.x + b.tip.x) * 0.5
		seg.side.append(signf(mid_x) if absf(mid_x) > SIDE_EPS else 0.0)
	return seg


## Returns [skinned surface arrays, number of vertices outside every envelope].
static func _skin_surface(arrays: Array, mesh_xf: Transform3D, seg: Dictionary,
		falloff: float) -> Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var count := verts.size()
	var pos := PackedVector3Array()
	pos.resize(count)
	var bone_ids := PackedInt32Array()
	bone_ids.resize(count * 4)
	var weights := PackedFloat32Array()
	weights.resize(count * 4)
	var fallbacks := 0
	for v in count:
		var p: Vector3 = mesh_xf * verts[v]
		pos[v] = p
		if not _weigh_vertex(p, v * 4, seg, falloff, bone_ids, weights):
			fallbacks += 1
		if v % 50000 == 0 and v > 0:
			print("JointSkinner: %d / %d vertices" % [v, count])
	var skinned := []
	skinned.resize(Mesh.ARRAY_MAX)
	skinned[Mesh.ARRAY_VERTEX] = pos
	if arrays[Mesh.ARRAY_NORMAL] != null:
		var normal_xf := mesh_xf.basis.inverse().transposed()
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var out_n := PackedVector3Array()
		out_n.resize(nrm.size())
		for i in nrm.size():
			out_n[i] = (normal_xf * nrm[i]).normalized()
		skinned[Mesh.ARRAY_NORMAL] = out_n
	for slot in [Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV,
			Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_INDEX]:
		if arrays[slot] != null:
			skinned[slot] = arrays[slot]
	skinned[Mesh.ARRAY_BONES] = bone_ids
	skinned[Mesh.ARRAY_WEIGHTS] = weights
	return [skinned, fallbacks]


## False when no envelope holds the vertex and it went rigidly to the nearest bone.
static func _weigh_vertex(p: Vector3, base: int, seg: Dictionary, falloff: float,
		bone_ids: PackedInt32Array, weights: PackedFloat32Array) -> bool:
	var active: PackedInt32Array = seg.active
	var seg_a: PackedVector3Array = seg.a
	var seg_dir: PackedVector3Array = seg.dir
	var seg_len: PackedFloat32Array = seg.len
	var seg_r2: PackedFloat32Array = seg.r2
	var seg_side: PackedFloat32Array = seg.side
	var cand_i := PackedInt32Array()
	var cand_w := PackedFloat32Array()
	var nearest := -1
	var nearest_d2 := INF
	for k in active.size():
		var side := seg_side[k]
		if side != 0.0 and p.x * side < -0.005:
			continue
		var rel := p - seg_a[k]
		var t := clampf(rel.dot(seg_dir[k]), 0.0, seg_len[k])
		var d2 := (rel - seg_dir[k] * t).length_squared()
		if d2 < nearest_d2:
			nearest_d2 = d2
			nearest = k
		if d2 > seg_r2[k]:
			continue
		cand_i.append(k)
		cand_w.append(1.0 / (pow(d2, falloff * 0.5) + 1e-9))
	if cand_i.is_empty():
		bone_ids[base] = active[nearest]
		weights[base] = 1.0
		return false
	var chosen := _keep_strongest(cand_i, cand_w)
	var total := 0.0
	for c in chosen:
		total += cand_w[c]
	for c in chosen:
		bone_ids[base + c] = active[cand_i[c]]
		weights[base + c] = cand_w[c] / total
	return true


## Strongest first; returns how many were kept.
static func _keep_strongest(cand_i: PackedInt32Array, cand_w: PackedFloat32Array) -> int:
	var nc := cand_i.size()
	var chosen := 0
	while chosen < MAX_INFLUENCES and chosen < nc:
		var best := chosen
		for c in range(chosen + 1, nc):
			if cand_w[c] > cand_w[best]:
				best = c
		var ti := cand_i[chosen]
		var tw := cand_w[chosen]
		cand_i[chosen] = cand_i[best]
		cand_w[chosen] = cand_w[best]
		cand_i[best] = ti
		cand_w[best] = tw
		chosen += 1
	return chosen
