extends SceneTree
## Headless check for the editor curve preview: bend swaps meshes, the
## PRE_SAVE notification restores the EXACT original resources, POST_SAVE
## re-bends, and un-flagging a child restores it. Run:
##   Godot --headless --path <abs client> -s res://tools/test_bend_editor_preview.gd


func _init() -> void:
	var fails := 0
	var placements: Node3D = load("res://src/world/planet/placement/planet_placements.gd").new()
	var child := Node3D.new()
	child.position = Vector3(0, 120, 0)
	child.set_meta("curve", true)
	var mi := MeshInstance3D.new()
	var flat := PlaneMesh.new()
	flat.size = Vector2(200, 10)
	flat.subdivide_width = 20
	mi.mesh = flat
	child.add_child(mi)
	placements.add_child(child)

	placements._bend_child_editor(child)
	if mi.mesh == flat or not (mi.mesh is ArrayMesh):
		print("FAIL: bend did not swap the mesh")
		fails += 1

	# PRE_SAVE must restore the identical flat resource (what gets saved)
	placements.notification(Node.NOTIFICATION_EDITOR_PRE_SAVE)
	if mi.mesh != flat:
		print("FAIL: PRE_SAVE did not restore the flat original")
		fails += 1

	# POST_SAVE must re-bend
	placements.notification(Node.NOTIFICATION_EDITOR_POST_SAVE)
	if mi.mesh == flat:
		print("FAIL: POST_SAVE did not re-bend")
		fails += 1

	# un-flagging + re-settle path must restore and stay flat
	child.set_meta("curve", false)
	placements._bend_child_editor(child)
	if mi.mesh != flat:
		print("FAIL: unflagging curve did not restore the flat mesh")
		fails += 1
	if child.has_meta("planet_bent"):
		print("FAIL: planet_bent meta left behind")
		fails += 1

	print("RESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	placements.free()
	quit(fails)
