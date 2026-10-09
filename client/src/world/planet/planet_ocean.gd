@tool
class_name PlanetOcean
extends MeshInstance3D
## Planet sea-level shell: a cube-sphere mesh at data.radius with the ocean shader.

@export var data: PlanetData:
	set(v):
		data = v
		if is_inside_tree():
			_rebuild()
## Quads per cube-face edge.
@export var face_resolution := 48:
	set(v):
		face_resolution = maxi(v, 4)
		if is_inside_tree():
			_rebuild()
@export var ocean_material: Material


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	if data == null:
		return
	var r := data.radius
	var res := face_resolution
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var side := res + 1
	for face in CubeSphere.FACE_COUNT:
		var base := verts.size()
		for j in side:
			for i in side:
				var d := CubeSphere.face_uv_to_dir(face, float(i) / res, float(j) / res)
				verts.append(d * r)
				normals.append(d)
		for j in res:
			for i in res:
				var a := base + j * side + i
				var b := a + 1
				var c := a + side
				var dd := c + 1
				# Clockwise winding is the front face in Godot.
				indices.append_array(PackedInt32Array([a, b, dd, a, dd, c]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am
	if ocean_material == null:
		var shader: Shader = load("res://src/world/planet/shaders/planet_ocean.gdshader")
		if shader:
			var m := ShaderMaterial.new()
			m.shader = shader
			ocean_material = m
	if ocean_material:
		material_override = ocean_material
