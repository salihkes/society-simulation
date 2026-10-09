extends SceneTree
## Headless check for PlanetMeshBender: bend a long flat strip and assert
## every vertex lands EXACTLY on the sphere (radius = local R + its height)
## with normals pointing radially. Run:
##   Godot --headless --path <abs client> -s res://tools/test_mesh_bender.gd

const R := 120.0   # local-units radius (== world 600 under a x5-scaled asset)
const TOL := 0.01


func _init() -> void:
	var root := Node3D.new()

	# ground strip, 400 long — on radius 120 that wraps ~190 deg of arc
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 20)
	plane.subdivide_width = 80
	plane.subdivide_depth = 4
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	root.add_child(ground)

	# elevated deck at y=2, offset through an INTERMEDIATE node with a
	# translated+rotated transform — exercises the xf accumulation
	var mid := Node3D.new()
	mid.transform = Transform3D(Basis(Vector3.UP, 0.4), Vector3(30, 0, 5))
	root.add_child(mid)
	var deck_mesh := PlaneMesh.new()
	deck_mesh.size = Vector2(100, 10)
	deck_mesh.subdivide_width = 20
	deck_mesh.center_offset = Vector3(0, 2, 0)
	var deck := MeshInstance3D.new()
	deck.mesh = deck_mesh
	mid.add_child(deck)

	# trimesh collision strip
	var col := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([
		Vector3(0, 0, 0), Vector3(180, 0, 0), Vector3(180, 0, 8)]))
	col.shape = shape
	root.add_child(col)

	var bent := PlanetMeshBender.bend_node(root, R)
	print("bent items: ", bent, " (want 3)")

	var center := Vector3(0, -R, 0)
	var fails := 0

	# ground: every vertex on radius R, normal radial
	var g := _measure(ground.mesh, Transform3D.IDENTITY, center, R)
	print("ground: max radius err %.5f  min normal.radial %.5f" % [g[0], g[1]])
	if g[0] > TOL or g[1] < 0.999:
		fails += 1

	# deck: vertices in ROOT frame must sit on radius R + 2
	var d := _measure(deck.mesh, mid.transform, center, R + 2.0)
	print("deck:   max radius err %.5f  min normal.radial %.5f" % [d[0], d[1]])
	if d[0] > TOL or d[1] < 0.995:
		fails += 1

	# collision: bent faces on radius R
	var max_col := 0.0
	for v in (col.shape as ConcavePolygonShape3D).get_faces():
		max_col = maxf(max_col, absf((v - center).length() - R))
	print("collision: max radius err %.5f" % max_col)
	if max_col > TOL:
		fails += 1

	# idempotency: second bend must be a no-op
	if PlanetMeshBender.bend_node(root, R) != 0:
		print("FAIL: bend_node ran twice")
		fails += 1

	print("RESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails > 0 else 0)


## Returns [max |dist(center)-want_r|, min normal·radial] over all verts.
func _measure(mesh: Mesh, xf: Transform3D, center: Vector3, want_r: float) -> Array:
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var max_err := 0.0
	var min_dot := 1.0
	for i in verts.size():
		var v := xf * verts[i]
		max_err = maxf(max_err, absf((v - center).length() - want_r))
		if i < normals.size():
			var n := (xf.basis * normals[i]).normalized()
			min_dot = minf(min_dot, (v - center).normalized().dot(n))
	return [max_err, min_dot]
