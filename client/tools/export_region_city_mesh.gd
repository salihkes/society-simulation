extends SceneTree
## Offline geometry interchange for regionforge/bake_city_ground.py.
## godot --headless --path client --script res://tools/export_region_city_mesh.gd -- MODEL_SCENE OUTPUT_BIN

func _initialize() -> void:
	run.call_deferred()

func vector_array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("Expected model resource path and output binary path")
		quit(1)
		return
	var packed := load(args[0]) as PackedScene
	var out := FileAccess.open(args[1], FileAccess.WRITE)
	if packed == null or out == null:
		push_error("Cannot load model or create mesh export")
		quit(1)
		return
	var city := packed.instantiate()
	root.add_child(city)
	var stack: Array[Node] = [city]
	var count := 0
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not node is MeshInstance3D or node.mesh == null:
			continue
		for surface in node.mesh.get_surface_count():
			var arrays: Array = node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var transform: Transform3D = node.global_transform
			var header := JSON.stringify({"vertices": vertices.size(), "indices": indices.size(),
				"basis": [vector_array(transform.basis.x), vector_array(transform.basis.y), vector_array(transform.basis.z)],
				"origin": vector_array(transform.origin)}).to_utf8_buffer()
			out.store_32(header.size())
			out.store_buffer(header)
			out.store_buffer(vertices.to_byte_array())
			out.store_buffer(indices.to_byte_array())
			count += 1
	out.close()
	print("CITY MESH exported surfaces: ", count)
	city.queue_free()
	await process_frame
	quit()
