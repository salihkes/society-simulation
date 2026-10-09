extends Node
## Ctrl+E exports every visible mesh to OBJ/MTL/PNG in user://exports/.

var export_folder := "user://exports/"
var current_vertex_offset := 1
var current_normal_offset := 1
var current_uv_offset := 1

## Texture -> exported file name, so each texture is written once per export.
var exported_textures := {}

func _ready():
	var dir = DirAccess.open("user://")
	if dir:
		if not dir.dir_exists("exports"):
			dir.make_dir("exports")

func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_E and event.ctrl_pressed:
			export_scene()

func export_scene():
	print("Starting OBJ export...")

	var time = Time.get_datetime_dict_from_system()
	var timestamp = "%04d%02d%02d_%02d%02d%02d" % [time.year, time.month, time.day, time.hour, time.minute, time.second]

	var obj_filename = "workspace_" + timestamp + ".obj"
	var mtl_filename = "workspace_" + timestamp + ".mtl"
	var obj_path = export_folder + obj_filename
	var mtl_path = export_folder + mtl_filename

	current_vertex_offset = 1
	current_normal_offset = 1
	current_uv_offset = 1
	exported_textures.clear()

	var obj_file = FileAccess.open(obj_path, FileAccess.WRITE)
	var mtl_file = FileAccess.open(mtl_path, FileAccess.WRITE)

	if not obj_file or not mtl_file:
		print("ERROR: Could not create export files!")
		return

	_write_headers(obj_file, mtl_file, mtl_filename, timestamp)

	var workspace = get_tree().current_scene
	var mesh_instances = []
	_collect_mesh_instances(workspace, mesh_instances)

	print("Found %d mesh instances to export" % mesh_instances.size())

	var materials_exported = {}
	for mesh_instance in mesh_instances:
		if mesh_instance is MeshInstance3D:
			var mesh = mesh_instance.mesh
			if mesh:
				_export_mesh_instance(mesh_instance, obj_file, mtl_file, materials_exported)

	obj_file.close()
	mtl_file.close()

	var real_path = ProjectSettings.globalize_path(obj_path)
	_print_summary(real_path, ProjectSettings.globalize_path(mtl_path), mesh_instances.size(), materials_exported)
	_show_export_notification(real_path)

func _write_headers(obj_file: FileAccess, mtl_file: FileAccess, mtl_filename: String, timestamp: String):
	obj_file.store_line("# Exported from %s" % Identity.value("product_name"))
	obj_file.store_line("# " + timestamp)
	obj_file.store_line("mtllib " + mtl_filename)
	obj_file.store_line("")

	mtl_file.store_line("# Material Library")
	mtl_file.store_line("# " + timestamp)
	mtl_file.store_line("")

	mtl_file.store_line("newmtl material_default")
	mtl_file.store_line("Ka 0.8 0.8 0.8")
	mtl_file.store_line("Kd 0.8 0.8 0.8")
	mtl_file.store_line("Ks 0.5 0.5 0.5")
	mtl_file.store_line("Ns 50.0")
	mtl_file.store_line("")

func _print_summary(obj_real_path: String, mtl_real_path: String, mesh_count: int, materials_exported: Dictionary):
	print("\n========================================")
	print("EXPORT COMPLETE!")
	print("========================================")
	print("OBJ file: " + obj_real_path)
	print("MTL file: " + mtl_real_path)
	print("Total meshes exported: %d" % mesh_count)
	print("Total materials exported: %d" % materials_exported.size())
	print("Total unique textures exported: %d" % exported_textures.size())
	print("\nMaterial Summary:")
	for mat in materials_exported:
		var mat_name = materials_exported[mat]
		var color_str = "N/A"
		if mat is BaseMaterial3D:
			color_str = "RGB(%.0f, %.0f, %.0f)" % [mat.albedo_color.r * 255, mat.albedo_color.g * 255, mat.albedo_color.b * 255]
		print("  %s: %s" % [mat_name, color_str])
	print("========================================\n")

func _collect_mesh_instances(node: Node, mesh_instances: Array):
	if node is MeshInstance3D:
		if not _should_skip_node(node):
			mesh_instances.append(node)

	for child in node.get_children():
		_collect_mesh_instances(child, mesh_instances)

## Skips hidden meshes and UI, chat bubbles, cameras and XR rigs.
func _should_skip_node(node: Node) -> bool:
	var path = str(node.get_path())

	if "UI" in path or "ChatBubble" in path or "Camera" in path:
		return true
	if "XROrigin3D" in path or "XRController" in path or "LeftHand" in path or "RightHand" in path:
		return true
	if node.has_method("is_visible") and not node.is_visible():
		return true

	return false

func _export_mesh_instance(mesh_instance: MeshInstance3D, obj_file: FileAccess, mtl_file: FileAccess, materials_exported: Dictionary):
	var mesh = mesh_instance.mesh
	var global_transform = mesh_instance.global_transform

	var object_name = mesh_instance.name.replace(" ", "_")
	var node_path = str(mesh_instance.get_path())
	print("\n=== Exporting mesh: %s ===" % object_name)
	print("  Path: %s" % node_path)
	print("  Mesh type: %s" % mesh.get_class())
	print("  Has material_override: %s" % str(mesh_instance.material_override != null))

	obj_file.store_line("o " + object_name)
	obj_file.store_line("g " + object_name)

	if mesh is ArrayMesh or mesh is PrimitiveMesh:
		var surface_count = mesh.get_surface_count() if mesh is ArrayMesh else 1
		print("  Surface count: %d" % surface_count)

		for surface_idx in range(surface_count):
			var arrays
			if mesh is ArrayMesh:
				arrays = mesh.surface_get_arrays(surface_idx)
			else:
				arrays = (mesh as PrimitiveMesh).get_mesh_arrays()
			if arrays.size() == 0:
				continue
			_export_surface(mesh_instance, surface_idx, arrays, global_transform, object_name, obj_file, mtl_file, materials_exported)

	obj_file.store_line("")

func _export_surface(mesh_instance: MeshInstance3D, surface_idx: int, arrays: Array, global_transform: Transform3D, object_name: String, obj_file: FileAccess, mtl_file: FileAccess, materials_exported: Dictionary):
	var vertices = arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] else []
	var normals = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] else []
	var uvs = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] else []
	var indices = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] else []

	if vertices.size() == 0:
		return

	for vertex in vertices:
		var v = global_transform * vertex
		obj_file.store_line("v %.6f %.6f %.6f" % [v.x, v.y, v.z])

	if normals.size() > 0:
		var normal_transform = global_transform.basis
		for normal in normals:
			var n = (normal_transform * normal).normalized()
			obj_file.store_line("vn %.6f %.6f %.6f" % [n.x, n.y, n.z])

	# OBJ's V axis points the other way.
	if uvs.size() > 0:
		for uv in uvs:
			obj_file.store_line("vt %.6f %.6f" % [uv.x, 1.0 - uv.y])

	print("  Surface %d:" % surface_idx)
	var material = _surface_material(mesh_instance, surface_idx)
	var material_name = _material_name(material, materials_exported, mtl_file, object_name, surface_idx)
	obj_file.store_line("usemtl " + material_name)

	var has_uvs: bool = uvs.size() > 0
	var has_normals: bool = normals.size() > 0
	if indices.size() > 0:
		for i in range(0, indices.size(), 3):
			if i + 2 < indices.size():
				_write_face(obj_file, indices[i] + current_vertex_offset, indices[i + 1] + current_vertex_offset, indices[i + 2] + current_vertex_offset, has_uvs, has_normals)
	else:
		for i in range(0, vertices.size(), 3):
			if i + 2 < vertices.size():
				_write_face(obj_file, i + current_vertex_offset, i + 1 + current_vertex_offset, i + 2 + current_vertex_offset, has_uvs, has_normals)

	current_vertex_offset += vertices.size()
	current_normal_offset += normals.size()
	current_uv_offset += uvs.size()

func _write_face(obj_file: FileAccess, v1, v2, v3, has_uvs: bool, has_normals: bool):
	if has_uvs and has_normals:
		obj_file.store_line("f %d/%d/%d %d/%d/%d %d/%d/%d" % [
			v1, v1, v1,
			v2, v2, v2,
			v3, v3, v3
		])
	elif has_uvs:
		obj_file.store_line("f %d/%d %d/%d %d/%d" % [
			v1, v1, v2, v2, v3, v3
		])
	elif has_normals:
		obj_file.store_line("f %d//%d %d//%d %d//%d" % [
			v1, v1, v2, v2, v3, v3
		])
	else:
		obj_file.store_line("f %d %d %d" % [v1, v2, v3])

func _surface_material(mesh_instance: MeshInstance3D, surface_idx: int):
	var mesh = mesh_instance.mesh
	var material = mesh_instance.get_surface_override_material(surface_idx)
	if material:
		_print_material_found("Found surface override material", material)

	if not material and mesh_instance.material_override:
		material = mesh_instance.material_override
		_print_material_found("Found material override on mesh instance", material)

	if not material and mesh is ArrayMesh:
		material = mesh.surface_get_material(surface_idx)
		if material:
			_print_material_found("Found material on mesh surface", material)

	if not material:
		print("    ✗ No material found!")
	return material

func _print_material_found(what: String, material: Material):
	print("    ✓ " + what)
	print("      Type: %s" % material.get_class())
	if material is BaseMaterial3D:
		print("      Color: %s" % str(material.albedo_color))

func _material_name(material, materials_exported: Dictionary, mtl_file: FileAccess, object_name: String, surface_idx: int) -> String:
	if not material:
		print("Warning: No material found for %s surface %d, using default" % [object_name, surface_idx])
		return "material_default"
	if materials_exported.has(material):
		var existing: String = materials_exported[material]
		print("    → Reusing existing: %s" % existing)
		return existing
	var material_name = "material_%d" % materials_exported.size()
	materials_exported[material] = material_name
	_export_material(material, material_name, mtl_file)
	print("    → Exported as: %s" % material_name)
	return material_name

func _export_material(material: Material, material_name: String, mtl_file: FileAccess):
	mtl_file.store_line("newmtl " + material_name)

	if material is BaseMaterial3D:
		_write_base_material(material as BaseMaterial3D, material_name, mtl_file)
	elif material is ShaderMaterial:
		_write_shader_material(material as ShaderMaterial, material_name, mtl_file)
	else:
		mtl_file.store_line("Ka 0.8 0.8 0.8")
		mtl_file.store_line("Kd 0.8 0.8 0.8")
		mtl_file.store_line("Ks 0.5 0.5 0.5")
		mtl_file.store_line("Ns 50.0")

	mtl_file.store_line("")

func _write_base_material(base_mat: BaseMaterial3D, material_name: String, mtl_file: FileAccess):
	var albedo = base_mat.albedo_color
	mtl_file.store_line("Ka %.6f %.6f %.6f" % [albedo.r, albedo.g, albedo.b])
	mtl_file.store_line("Kd %.6f %.6f %.6f" % [albedo.r, albedo.g, albedo.b])

	var specular = base_mat.metallic_specular
	mtl_file.store_line("Ks %.6f %.6f %.6f" % [specular, specular, specular])

	var roughness = base_mat.roughness
	var shininess = (1.0 - roughness) * 1000.0
	mtl_file.store_line("Ns %.6f" % shininess)

	if albedo.a < 1.0:
		mtl_file.store_line("d %.6f" % albedo.a)
		mtl_file.store_line("Tr %.6f" % (1.0 - albedo.a))

	if base_mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		if albedo.a < 1.0:
			mtl_file.store_line("# Transparency enabled")

	_write_map(mtl_file, base_mat.albedo_texture, "Albedo", material_name, "map_Kd")
	_write_map(mtl_file, base_mat.normal_texture, "Normal", material_name + "_normal", "map_Bump")
	_write_map(mtl_file, base_mat.roughness_texture, "Roughness", material_name + "_roughness", "map_Ns")
	_write_map(mtl_file, base_mat.metallic_texture, "Metallic", material_name + "_metallic", "map_Pm")

func _write_map(mtl_file: FileAccess, texture: Texture2D, label: String, base_name: String, key: String):
	if not texture:
		return
	print("      %s texture:" % label)
	var texture_path = _export_texture(texture, base_name)
	if texture_path != "":
		mtl_file.store_line(key + " " + texture_path)

func _write_shader_material(shader_mat: ShaderMaterial, material_name: String, mtl_file: FileAccess):
	var albedo_color = Color.WHITE
	for param_name in ["albedo", "color", "albedo_color", "base_color", "diffuse"]:
		var param_value = shader_mat.get_shader_parameter(param_name)
		if param_value is Color:
			albedo_color = param_value
			break

	mtl_file.store_line("Ka %.6f %.6f %.6f" % [albedo_color.r, albedo_color.g, albedo_color.b])
	mtl_file.store_line("Kd %.6f %.6f %.6f" % [albedo_color.r, albedo_color.g, albedo_color.b])
	mtl_file.store_line("Ks 0.5 0.5 0.5")
	mtl_file.store_line("Ns 50.0")

	for param_name in ["texture_albedo", "albedo_texture", "texture", "diffuse_texture"]:
		var param_value = shader_mat.get_shader_parameter(param_name)
		if param_value is Texture2D:
			print("      Shader texture:")
			var texture_path = _export_texture(param_value, material_name)
			if texture_path != "":
				mtl_file.store_line("map_Kd " + texture_path)
			break

func _export_texture(texture: Texture2D, base_name: String) -> String:
	if not texture:
		return ""

	if exported_textures.has(texture):
		var cached_filename = exported_textures[texture]
		print("      ↳ Reusing existing texture: %s" % cached_filename)
		return cached_filename

	var image: Image = null

	if texture.has_method("get_image"):
		image = texture.get_image()
	elif texture is ImageTexture:
		image = texture.get_image()

	if not image:
		return ""

	var texture_filename: String

	if texture.resource_path != "" and not texture.resource_path.begins_with("local://"):
		var original_path = texture.resource_path
		var original_filename = original_path.get_file()
		original_filename = original_filename.replace(" ", "_")
		original_filename = original_filename.replace("(", "")
		original_filename = original_filename.replace(")", "")
		texture_filename = original_filename
	else:
		texture_filename = base_name + ".png"

	var texture_path = export_folder + texture_filename

	var err = image.save_png(ProjectSettings.globalize_path(texture_path))
	if err == OK:
		print("      ↳ Exported new texture: %s (from %s)" % [texture_filename, texture.resource_path if texture.resource_path != "" else "runtime"])
		exported_textures[texture] = texture_filename
		return texture_filename
	else:
		print("      ↳ Failed to export texture: %s" % texture_filename)
		return ""

func _show_export_notification(path: String):
	print("\n========================================")
	print("EXPORT COMPLETE!")
	print("File saved to: " + path)
	print("========================================\n")

	var workspace = get_tree().current_scene
	var ui = workspace.get_node_or_null("UI")
	if ui:
		var notification = Label.new()
		notification.text = "Scene exported to:\n" + path
		notification.position = Vector2(400, 300)
		notification.add_theme_color_override("font_color", Color.GREEN)
		notification.add_theme_font_size_override("font_size", 20)
		notification.add_theme_color_override("font_outline_color", Color.BLACK)
		notification.add_theme_constant_override("outline_size", 3)
		ui.add_child(notification)

		await get_tree().create_timer(5.0).timeout
		notification.queue_free()
