@tool
class_name ProvinceMap
extends MeshInstance3D
## A province map (one unique colour per province) drawn by province_map.gdshader on a plane or sphere.

signal owners_changed()
signal data_changed()
signal province_hovered(province_id: int)

@export var province_texture: Texture2D:
	set(v):
		province_texture = v
		if Engine.is_editor_hint():
			_update_editor_preview()

## Optional JSON file to load at startup.
@export_file("*.json") var province_data_path: String = ""

@export var show_borders: bool = true:
	set(v):
		show_borders = v
		_set_shader_param("show_borders", v)

@export var border_color: Color = Color(0, 0, 0, 0.6):
	set(v):
		border_color = v
		_set_shader_param("border_color", v)

## Colour of provinces without an owner.
@export var default_province_color: Color = Color(0.76, 0.78, 0.8)

## Occupation stripe period in map pixels.
@export var stripe_width: float = 8.0:
	set(v):
		stripe_width = v
		_set_shader_param("stripe_width", v)

## Plane height in world units; the width follows the image's aspect.
@export var map_world_height: float = 10.0:
	set(v):
		map_world_height = v
		if Engine.is_editor_hint():
			_update_editor_preview()

@export var sphere_mode: bool = false

## Sphere radius in world units, in sphere mode.
@export var sphere_radius: float = 0.5

## Fraction of V at each pole drawn as ocean, in sphere mode.
@export var polar_cutoff: float = 0.12

## World size (x width, y depth), set when built.
var plane_size: Vector2 = Vector2.ZERO

var _province_image: Image
var _index_image: Image
var _index_texture: ImageTexture

## Controller colour per province: the occupier if occupied, else the owner.
var _lookup_image: Image
var _lookup_texture: ImageTexture
## Sovereign owner colour per province.
var _owner_lookup_image: Image
var _owner_lookup_texture: ImageTexture

## Packed RGB int -> province id.
var _color_to_id: Dictionary = {}
## Province id -> its map colour.
var _id_to_color: Dictionary = {}
## Province id -> custom display name.
var _id_to_name: Dictionary = {}

## owner_id -> {"name": String, "color": Color}
var _owners: Dictionary = {}

## Province id -> owner_id.
var _province_owner: Dictionary = {}
## Province id -> occupier owner_id, only while occupied.
var _province_occupier: Dictionary = {}

var _province_count: int = 0
var _hovered_id: int = -1
var _is_built: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		_update_editor_preview()
		return
	_build()


func _update_editor_preview() -> void:
	if not Engine.is_editor_hint():
		return
	if not province_texture:
		mesh = null
		material_override = null
		return

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = province_texture
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	if sphere_mode:
		if not mesh is SphereMesh:
			mesh = SphereMesh.new()
		(mesh as SphereMesh).radius = sphere_radius
		(mesh as SphereMesh).height = sphere_radius * 2.0
		(mesh as SphereMesh).radial_segments = 64
		(mesh as SphereMesh).rings = 32
	else:
		var img := province_texture.get_image()
		var aspect := float(img.get_width()) / float(img.get_height())
		plane_size = Vector2(aspect * map_world_height, map_world_height)
		if not mesh is PlaneMesh:
			mesh = PlaneMesh.new()
		(mesh as PlaneMesh).size = plane_size

	material_override = mat


## Also loads province_data_path and creates the mesh, material and ray collider.
func _build() -> void:
	if not province_texture:
		push_error("ProvinceMap: Assign a province_texture!")
		return

	var start_time := Time.get_ticks_msec()

	_province_image = province_texture.get_image()
	_province_image.decompress()
	_province_image.convert(Image.FORMAT_RGB8)

	var width := _province_image.get_width()
	var height := _province_image.get_height()
	_index_image = Image.create_from_data(width, height, false, Image.FORMAT_RGB8,
		_scan_provinces(_province_image.get_data(), width * height))
	_index_texture = ImageTexture.create_from_image(_index_image)

	# 256 x 256 lookups, one texel per province id.
	_lookup_image = Image.create(256, 256, false, Image.FORMAT_RGBA8)
	_lookup_image.fill(default_province_color)
	_lookup_texture = ImageTexture.create_from_image(_lookup_image)

	_owner_lookup_image = Image.create(256, 256, false, Image.FORMAT_RGBA8)
	_owner_lookup_image.fill(default_province_color)
	_owner_lookup_texture = ImageTexture.create_from_image(_owner_lookup_image)

	if not province_data_path.is_empty():
		_apply_file(province_data_path)

	_make_mesh(width, height)
	self.material_override = _make_material(width, height)
	_make_collider()

	_is_built = true
	var elapsed := Time.get_ticks_msec() - start_time
	if sphere_mode:
		print("ProvinceMap: %d provinces in %d ms  (%d×%d)  sphere r=%.0f" % [
			_province_count, elapsed, width, height, sphere_radius])
	else:
		print("ProvinceMap: %d provinces in %d ms  (%d×%d)  plane=%.1f×%.1f" % [
			_province_count, elapsed, width, height, plane_size.x, plane_size.y])


## Ids in scan order; returns RGB8 index data, id low byte in R, high byte in G.
func _scan_provinces(src_data: PackedByteArray, pixel_count: int) -> PackedByteArray:
	_color_to_id.clear()
	_id_to_color.clear()
	_province_count = 0

	var index_data := PackedByteArray()
	index_data.resize(pixel_count * 3)

	for i in range(pixel_count):
		var off := i * 3
		var r: int = src_data[off]
		var g: int = src_data[off + 1]
		var b: int = src_data[off + 2]
		var key: int = r | (g << 8) | (b << 16)

		var id: int
		if _color_to_id.has(key):
			id = _color_to_id[key]
		else:
			id = _province_count
			_color_to_id[key] = id
			_id_to_color[id] = Color8(r, g, b)
			_province_count += 1

		index_data[off] = id % 256
		index_data[off + 1] = (id / 256) % 256
		index_data[off + 2] = 0
	return index_data


func _make_mesh(width: int, height: int) -> void:
	if sphere_mode:
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = sphere_radius
		sphere_mesh.height = sphere_radius * 2.0
		sphere_mesh.radial_segments = 64
		sphere_mesh.rings = 32
		self.mesh = sphere_mesh
	else:
		var aspect := float(width) / float(height)
		plane_size = Vector2(aspect * map_world_height, map_world_height)
		var plane_mesh := PlaneMesh.new()
		plane_mesh.size = plane_size
		plane_mesh.subdivide_width = 0
		plane_mesh.subdivide_depth = 0
		self.mesh = plane_mesh


func _make_material(width: int, height: int) -> ShaderMaterial:
	var shader := preload("res://src/world/paintablemap/province_map.gdshader")
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("index_map", _index_texture)
	mat.set_shader_parameter("color_lookup", _lookup_texture)
	mat.set_shader_parameter("owner_lookup", _owner_lookup_texture)
	mat.set_shader_parameter("map_size", Vector2(width, height))
	mat.set_shader_parameter("show_borders", show_borders)
	mat.set_shader_parameter("border_color", border_color)
	mat.set_shader_parameter("stripe_width", stripe_width)
	mat.set_shader_parameter("hover_id", Vector2(-1, -1))
	mat.set_shader_parameter("selected_id", Vector2(-1, -1))
	mat.set_shader_parameter("sphere_mode", sphere_mode)
	mat.set_shader_parameter("polar_cutoff", polar_cutoff)
	return mat


func _make_collider() -> void:
	var body := StaticBody3D.new()
	body.name = "MapCollider"
	var col := CollisionShape3D.new()
	if sphere_mode:
		var sphere_shape := SphereShape3D.new()
		sphere_shape.radius = sphere_radius
		col.shape = sphere_shape
	else:
		var box := BoxShape3D.new()
		box.size = Vector3(plane_size.x, 0.01, plane_size.y)
		col.shape = box
	body.add_child(col)
	add_child(body)


func register_owner(owner_id: String, owner_name: String, color: Color) -> void:
	_owners[owner_id] = { "name": owner_name, "color": color }
	_flush_lookups()
	owners_changed.emit()


func get_owner_data(owner_id: String) -> Dictionary:
	return _owners.get(owner_id, {})


## Also clears any occupier.
func set_province_owner(pid: int, owner_id: String) -> void:
	if pid < 0 or pid >= _province_count:
		return
	if not _owners.has(owner_id):
		return
	_province_owner[pid] = owner_id
	_province_occupier.erase(pid)
	_refresh_province(pid)
	_flush_lookups()
	data_changed.emit()


func clear_province_owner(pid: int) -> void:
	if pid < 0 or pid >= _province_count:
		return
	_province_owner.erase(pid)
	_province_occupier.erase(pid)
	_refresh_province(pid)
	_flush_lookups()
	data_changed.emit()


## Occupying with the province's own owner clears the occupation.
func set_province_occupier(pid: int, occupier_id: String) -> void:
	if pid < 0 or pid >= _province_count:
		return
	if not _province_owner.has(pid):
		push_warning("ProvinceMap: can't occupy province %d — no owner" % pid)
		return
	if not _owners.has(occupier_id):
		return
	if occupier_id == _province_owner[pid]:
		clear_province_occupier(pid)
		return
	_province_occupier[pid] = occupier_id
	_refresh_province(pid)
	_flush_lookups()
	data_changed.emit()


func clear_province_occupier(pid: int) -> void:
	if not _province_occupier.has(pid):
		return
	_province_occupier.erase(pid)
	_refresh_province(pid)
	_flush_lookups()
	data_changed.emit()


## uv 0..1; -1 for none, and in sphere mode the poles have none.
func get_province_at_uv(uv: Vector2) -> int:
	if not _is_built:
		return -1
	if sphere_mode and (uv.y < polar_cutoff or uv.y > 1.0 - polar_cutoff):
		return -1
	var sample_uv := uv
	if sphere_mode:
		var band := 1.0 - 2.0 * polar_cutoff
		sample_uv.y = (uv.y - polar_cutoff) / band
	var px := int(sample_uv.x * _province_image.get_width())
	var py := int(sample_uv.y * _province_image.get_height())
	if px < 0 or py < 0 or px >= _province_image.get_width() or py >= _province_image.get_height():
		return -1
	var c := _index_image.get_pixel(px, py)
	return int(round(c.r * 255.0)) + int(round(c.g * 255.0)) * 256


func get_province_map_color(pid: int) -> Color:
	return _id_to_color.get(pid, Color.BLACK)


func get_province_name(pid: int) -> String:
	return _id_to_name.get(pid, "Province #%d" % pid)


func get_province_owner(pid: int) -> String:
	return _province_owner.get(pid, "")


func get_province_occupier(pid: int) -> String:
	return _province_occupier.get(pid, "")


## How many provinces have a name or an owner.
func get_modified_count() -> int:
	var s := {}
	for id in _id_to_name:
		s[id] = true
	for id in _province_owner:
		s[id] = true
	return s.size()


## Also emits province_hovered.
func set_hovered_province(pid: int) -> void:
	if pid == _hovered_id:
		return
	_hovered_id = pid
	_set_shader_param("hover_id", _id_to_shader_vec(pid))
	province_hovered.emit(pid)


## In the JSON file's format.
func serialize_state() -> Dictionary:
	var owners_arr := []
	for oid in _owners:
		var o: Dictionary = _owners[oid]
		owners_arr.append({
			"id": oid,
			"name": o["name"],
			"color": (o["color"] as Color).to_html(false),
		})

	var prov_arr := []
	var written_pids := {}
	for pid in _province_owner:
		written_pids[pid] = true
	for pid in _id_to_name:
		written_pids[pid] = true
	for pid: int in written_pids:
		var entry := {}
		entry["map_color"] = get_province_map_color(pid).to_html(false)
		if _id_to_name.has(pid):
			entry["name"] = _id_to_name[pid]
		if _province_owner.has(pid):
			entry["owner"] = _province_owner[pid]
		if _province_occupier.has(pid):
			entry["occupier"] = _province_occupier[pid]
		prov_arr.append(entry)

	return { "owners": owners_arr, "provinces": prov_arr }


## Replaces all owners and province data with a network state.
func apply_state(data: Dictionary) -> void:
	_owners.clear()
	_province_owner.clear()
	_province_occupier.clear()
	_id_to_name.clear()

	if _is_built:
		_lookup_image.fill(default_province_color)
		_owner_lookup_image.fill(default_province_color)

	_apply_data(data)

	if _is_built:
		_set_shader_param("selected_id", Vector2(-1, -1))
	owners_changed.emit()
	data_changed.emit()
	print("ProvinceMap: applied network state (%d owners)" % [_owners.size()])


func _apply_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_warning("ProvinceMap: file not found — %s" % path)
		return
	var file := FileAccess.open(path, FileAccess.READ)
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("ProvinceMap: JSON error — %s" % json.get_error_message())
		return
	_apply_data(json.data)


## Entries with missing fields, unknown map colours or unknown owners are skipped.
func _apply_data(data: Dictionary) -> void:
	if data.has("owners"):
		for entry: Dictionary in data["owners"]:
			var oid: String = entry.get("id", "")
			var oname: String = entry.get("name", "")
			var chex: String = entry.get("color", "")
			if oid.is_empty() or oname.is_empty() or chex.is_empty():
				continue
			_owners[oid] = { "name": oname, "color": Color.html(chex) }

	if data.has("provinces"):
		for entry: Dictionary in data["provinces"]:
			_apply_province(entry)

	_flush_lookups()


func _apply_province(entry: Dictionary) -> void:
	var map_hex: String = entry.get("map_color", "")
	if map_hex.is_empty():
		return
	var key: int = _color_key(Color.html(map_hex))
	if not _color_to_id.has(key):
		return
	var pid: int = _color_to_id[key]

	var pname: String = entry.get("name", "")
	if not pname.is_empty():
		_id_to_name[pid] = pname

	var owner_id: String = entry.get("owner", "")
	if not owner_id.is_empty() and _owners.has(owner_id):
		_province_owner[pid] = owner_id

	var occ_id: String = entry.get("occupier", "")
	if not occ_id.is_empty() and _owners.has(occ_id):
		_province_occupier[pid] = occ_id

	_refresh_province(pid)


func _refresh_province(pid: int) -> void:
	var owner_id: String = _province_owner.get(pid, "")
	var occ_id: String = _province_occupier.get(pid, "")

	if owner_id.is_empty() or not _owners.has(owner_id):
		_set_ctrl_pixel(pid, default_province_color)
		_set_owner_pixel(pid, default_province_color)
		return

	var owner_col: Color = _owners[owner_id]["color"]
	_set_owner_pixel(pid, owner_col)

	if not occ_id.is_empty() and _owners.has(occ_id) and occ_id != owner_id:
		_set_ctrl_pixel(pid, _owners[occ_id]["color"])
	else:
		_set_ctrl_pixel(pid, owner_col)


func _flush_lookups() -> void:
	_lookup_texture.update(_lookup_image)
	_owner_lookup_texture.update(_owner_lookup_image)


func _set_ctrl_pixel(pid: int, color: Color) -> void:
	_lookup_image.set_pixel(pid % 256, (pid / 256) % 256, color)


func _set_owner_pixel(pid: int, color: Color) -> void:
	_owner_lookup_image.set_pixel(pid % 256, (pid / 256) % 256, color)


func _color_key(c: Color) -> int:
	return int(c.r * 255.0) | (int(c.g * 255.0) << 8) | (int(c.b * 255.0) << 16)


## A province id as the shader's two-byte id, (-1, -1) for none.
func _id_to_shader_vec(id: int) -> Vector2:
	if id < 0:
		return Vector2(-1.0, -1.0)
	return Vector2(float(id % 256) / 255.0, float((id / 256) % 256) / 255.0)


func _set_shader_param(param: StringName, value: Variant) -> void:
	if material_override is ShaderMaterial:
		(material_override as ShaderMaterial).set_shader_parameter(param, value)
