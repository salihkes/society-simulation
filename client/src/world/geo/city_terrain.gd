@tool
extends Node3D
## The landscape around the city: a warped grid mesh and near collider from baked height rasters.

@export_dir var data_dir := ""
## Vertices per axis of the terrain grid.
@export_range(64, 1024) var grid_n := 512
## Linear share a of the warp u -> a*u + (1-a)*u^3; smaller packs more vertices near the city.
@export_range(0.05, 1.0) var dense_fraction := 0.22
@export var material: Material
@export var build_collision := true
@export var collision_half := 2600.0
@export var collision_cell := 12.0

@export_group("Editor preview")
## Editor only, never exported.
@export var preview_in_editor := true:
	set(value):
		preview_in_editor = value
		_refresh_preview()
## Coarse so scenes that instance the terrain open quickly.
@export_range(32, 512) var preview_grid_n := 160:
	set(value):
		preview_grid_n = value
		if preview_in_editor:
			_refresh_preview()
## Rebuilds the preview after the rasters are rebaked.
@export_tool_button("Rebuild preview", "Reload") var _rebuild_preview := _refresh_preview

var meta: Dictionary = {}
## name -> {h, px, upp, x0, z0, half}
var _rasters: Dictionary = {}
var _anchor := Vector2.ZERO
var _far := 15000.0
var _mesh_instance: MeshInstance3D


func _ready() -> void:
	if Engine.is_editor_hint():
		_refresh_preview()
		return
	build()


func build(n := grid_n, with_collision := build_collision) -> void:
	if not _load():
		return
	_clear()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Mesh"
	_mesh_instance.mesh = _build_mesh(n)
	_mesh_instance.material_override = material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_mesh_instance)
	if with_collision:
		_build_collision()


func _clear() -> void:
	_mesh_instance = null
	for c in get_children():
		remove_child(c)
		c.queue_free()


func _refresh_preview() -> void:
	# Setters also run while the scene's properties are being loaded.
	if not Engine.is_editor_hint() or not is_node_ready():
		return
	if preview_in_editor:
		build(preview_grid_n, false)
	else:
		_clear()


## Reads meta.json and every raster; true when inner and outer exist.
func _load() -> bool:
	var f := FileAccess.open(data_dir.path_join("meta.json"), FileAccess.READ)
	if f == null:
		push_error("CityTerrain: no meta.json in %s (run tools/bake/cityforge/build_city_terrain.py)" % data_dir)
		return false
	meta = JSON.parse_string(f.get_as_text())
	_anchor = Vector2(meta["anchor_xz"][0], meta["anchor_xz"][1])
	_far = float(meta["far_game"])
	for name in meta["rasters"]:
		var r: Dictionary = meta["rasters"][name]
		var rf := FileAccess.open(data_dir.path_join(r["file"]), FileAccess.READ)
		if rf == null:
			push_error("CityTerrain: missing raster %s" % r["file"])
			return false
		var bytes := rf.get_buffer(rf.get_length())
		_rasters[name] = {
			"h": bytes.to_float32_array(), "px": int(r["px"]), "upp": float(r["units_per_px"]),
			"x0": float(r["x0"]), "z0": float(r["z0"]), "half": float(r["half"]),
		}
	return _rasters.has("inner") and _rasters.has("outer")


## Bilinear height from one raster, clamped to its edge.
func _sample(r: Dictionary, x: float, z: float) -> float:
	var px: int = r["px"]
	var fx: float = clampf((x - r["x0"]) / r["upp"] - 0.5, 0.0, px - 1.001)
	var fz: float = clampf((z - r["z0"]) / r["upp"] - 0.5, 0.0, px - 1.001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var h: PackedFloat32Array = r["h"]
	var i := iz * px + ix
	var a := h[i] * (1.0 - tx) + h[i + 1] * tx
	var b := h[i + px] * (1.0 - tx) + h[i + px + 1] * tx
	return a * (1.0 - tz) + b * tz


## Terrain height at a city-space xz, blending inner into outer towards its edge.
func height_at(x: float, z: float) -> float:
	var inner: Dictionary = _rasters["inner"]
	var outer: Dictionary = _rasters["outer"]
	var half: float = inner["half"]
	var d := maxf(absf(x - _anchor.x), absf(z - _anchor.y))
	if d >= half:
		return _sample(outer, x, z)
	var w := smoothstep(half * 0.8, half * 0.97, d)
	if w <= 0.0:
		return _sample(inner, x, z)
	return lerpf(_sample(inner, x, z), _sample(outer, x, z), w)


## Grid coordinate u in -1..1 to a distance from the anchor.
func _warp(u: float) -> float:
	var a := dense_fraction
	return _far * (a * u + (1.0 - a) * u * u * u)


func _build_mesh(n: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(n * n)
	uvs.resize(n * n)
	var axis := PackedFloat32Array()
	axis.resize(n)
	for i in range(n):
		axis[i] = _warp(-1.0 + 2.0 * float(i) / float(n - 1))
	for iz in range(n):
		var z := _anchor.y + axis[iz]
		for ix in range(n):
			var x := _anchor.x + axis[ix]
			var k := iz * n + ix
			verts[k] = Vector3(x, height_at(x, z), z)
			uvs[k] = Vector2(x, z) * 0.001
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = _grid_normals(verts, n)
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = _grid_indices(n)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Uses the neighbours' actual positions because the grid spacing varies.
static func _grid_normals(verts: PackedVector3Array, n: int) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(n * n)
	for iz in range(n):
		for ix in range(n):
			var k := iz * n + ix
			var px := verts[k + (1 if ix < n - 1 else 0)] - verts[k - (1 if ix > 0 else 0)]
			var pz := verts[k + (n if iz < n - 1 else 0)] - verts[k - (n if iz > 0 else 0)]
			normals[k] = pz.cross(px).normalized()
	return normals


static func _grid_indices(n: int) -> PackedInt32Array:
	var idx := PackedInt32Array()
	idx.resize((n - 1) * (n - 1) * 6)
	var q := 0
	for iz in range(n - 1):
		for ix in range(n - 1):
			var a := iz * n + ix
			var b := a + 1
			var c := a + n
			var d := c + 1
			idx[q] = a
			idx[q + 1] = b
			idx[q + 2] = c
			idx[q + 3] = b
			idx[q + 4] = d
			idx[q + 5] = c
			q += 6
	return idx


func _build_collision() -> void:
	var m := int(2.0 * collision_half / collision_cell) + 1
	var data := PackedFloat32Array()
	data.resize(m * m)
	for iz in range(m):
		var z := _anchor.y - collision_half + iz * collision_cell
		for ix in range(m):
			var x := _anchor.x - collision_half + ix * collision_cell
			data[iz * m + ix] = height_at(x, z)
	var shape := HeightMapShape3D.new()
	shape.map_width = m
	shape.map_depth = m
	shape.map_data = data
	var body := StaticBody3D.new()
	body.name = "Ground"
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = shape
	cs.position = Vector3(_anchor.x, 0.0, _anchor.y)
	cs.scale = Vector3(collision_cell, 1.0, collision_cell)
	body.add_child(cs)
	add_child(body)
