@tool
class_name PlanetMeshBender
extends Object
## Bends a flat-authored asset onto the sphere: local X/Z become arc lengths, Y height above ground.

const _EPS := 0.0001


## Once per root (meta "planet_bent"); local_radius = world radius / node scale; record feeds unbend_node().
static func bend_node(root: Node3D, local_radius: float, record: Dictionary = {}) -> int:
	if local_radius <= 0.0 or root.has_meta("planet_bent"):
		return 0
	var count := _bend_recursive(root, Transform3D.IDENTITY, local_radius, record)
	if count > 0:
		root.set_meta("planet_bent", true)
	return count


static func unbend_node(root: Node3D, record: Dictionary) -> void:
	for node in record:
		if not is_instance_valid(node):
			continue
		if node is MeshInstance3D:
			node.mesh = record[node]
		elif node is CollisionShape3D:
			node.shape = record[node]
	if root.has_meta("planet_bent"):
		root.remove_meta("planet_bent")


static func _bend_recursive(node: Node, xf: Transform3D, r: float, record: Dictionary) -> int:
	var count := 0
	if node is MeshInstance3D and node.mesh != null:
		record[node] = node.mesh
		node.mesh = _bend_mesh(node.mesh, xf, r)
		count += 1
	elif node is CollisionShape3D and node.shape != null:
		var bent := _bend_shape(node.shape, xf, r)
		if bent != null:
			record[node] = node.shape
			node.shape = bent
			count += 1
	for child in node.get_children():
		var cxf := xf * (child as Node3D).transform if child is Node3D else xf
		count += _bend_recursive(child, cxf, r, record)
	return count


static func bend_point(v: Vector3, r: float) -> Vector3:
	var d := sqrt(v.x * v.x + v.z * v.z)
	if d < _EPS:
		return v
	var ang := d / r
	var ux := v.x / d
	var uz := v.z / d
	var rr := r + v.y
	return Vector3(ux * sin(ang) * rr, cos(ang) * rr - r, uz * sin(ang) * rr)


## Rotation by d / r about the horizontal axis across the outward direction.
static func bend_dir(n: Vector3, v: Vector3, r: float) -> Vector3:
	var d := sqrt(v.x * v.x + v.z * v.z)
	if d < _EPS:
		return n
	var ang := d / r
	var a := Vector3(v.z / d, 0.0, -v.x / d)
	return n * cos(ang) + a.cross(n) * sin(ang) + a * a.dot(n) * (1.0 - cos(ang))


## xf maps the mesh into the root's frame.
static func _bend_mesh(mesh: Mesh, xf: Transform3D, r: float) -> ArrayMesh:
	var out := ArrayMesh.new()
	var inv := xf.affine_inverse()
	for si in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] \
			if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT] \
			if arrays[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
		for i in verts.size():
			var v := xf * verts[i]
			verts[i] = inv * bend_point(v, r)
			if i < normals.size():
				var n := (xf.basis * normals[i]).normalized()
				normals[i] = (inv.basis * bend_dir(n, v, r)).normalized()
			if i * 4 + 2 < tangents.size():
				var t := (xf.basis * Vector3(
					tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2])).normalized()
				t = inv.basis * bend_dir(t, v, r)
				t = t.normalized()
				tangents[i * 4] = t.x
				tangents[i * 4 + 1] = t.y
				tangents[i * 4 + 2] = t.z
		arrays[Mesh.ARRAY_VERTEX] = verts
		if not normals.is_empty():
			arrays[Mesh.ARRAY_NORMAL] = normals
		if not tangents.is_empty():
			arrays[Mesh.ARRAY_TANGENT] = tangents
		var prim: int = mesh.surface_get_primitive_type(si) if mesh is ArrayMesh \
			else Mesh.PRIMITIVE_TRIANGLES
		out.add_surface_from_arrays(prim, arrays)
		out.surface_set_material(out.get_surface_count() - 1, mesh.surface_get_material(si))
	return out


## Null for any shape that is not concave or convex.
static func _bend_shape(shape: Shape3D, xf: Transform3D, r: float) -> Shape3D:
	var inv := xf.affine_inverse()
	if shape is ConcavePolygonShape3D:
		var faces: PackedVector3Array = (shape as ConcavePolygonShape3D).get_faces()
		for i in faces.size():
			faces[i] = inv * bend_point(xf * faces[i], r)
		var out := ConcavePolygonShape3D.new()
		out.set_faces(faces)
		return out
	if shape is ConvexPolygonShape3D:
		var pts: PackedVector3Array = (shape as ConvexPolygonShape3D).points
		for i in pts.size():
			pts[i] = inv * bend_point(xf * pts[i], r)
		var out2 := ConvexPolygonShape3D.new()
		out2.points = pts
		return out2
	# Analytic shapes (box, sphere, capsule) cannot bend and stay as they are.
	return null
