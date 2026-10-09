@tool
extends RefCounted
## Japanese-style overhead expressway guide signs on gantries, in city units (3.57 per metre).

const JsonData := preload("res://src/core/json_data.gd")
const SIGNS_PATH := "res://assets/world/region/junction_signs.json"

## Texts of the reference junction: left and right panels, header, side sign.
static var REFERENCE_SIGNS: Dictionary = JsonData.read(SIGNS_PATH)
static var _font: Font
static var _steel: StandardMaterial3D
static var _green: StandardMaterial3D
static var _white: StandardMaterial3D
static var _blue: StandardMaterial3D


## Builds the shared materials and bold font once.
static func prepare() -> void:
	if _font != null:
		return
	_steel = material(Color(0.62, 0.65, 0.65), true)
	_green = material(Color(0.025, 0.31, 0.12))
	_white = material(Color(0.95, 0.96, 0.90))
	_blue = material(Color(0.015, 0.23, 0.73))
	for surface in [_green, _white, _blue]:
		surface.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		surface.cull_mode = BaseMaterial3D.CULL_DISABLED
	var face: Font = load("res://assets/art/fonts/NotoSansJP.ttf")
	var bold := FontVariation.new()
	bold.base_font = face
	# 0x77676874 is the OpenType "wght" axis tag.
	bold.variation_opentype = {0x77676874: 700.0}
	_font = bold
	# Renders common glyphs ahead of first use.
	_font.get_string_size(Labels.text("sign_expressway", "") + Labels.text("sign_direction", "") + " EXPRESSWAY The City",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 96)


static func material(color: Color, metal := false) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.metallic = 0.45 if metal else 0.0
	result.roughness = 0.48 if metal else 0.92
	return result


static func box(parent: Node3D, position: Vector3, size: Vector3, surface: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = surface
	node.position = position
	parent.add_child(node)
	return node


## Shrunk to fit max_width.
static func label(parent: Node3D, value: String, position: Vector3, height: float, font: Font = null, max_width := 100.0, color := Color(0.95, 0.96, 0.9)) -> Label3D:
	var node := Label3D.new()
	node.text = value
	node.position = position
	node.font = _font if font == null else font
	node.font_size = 96
	node.pixel_size = height / 96.0
	var measured := node.font.get_multiline_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, 96).x * node.pixel_size
	if measured > max_width:
		node.pixel_size *= max_width / measured
	node.outline_size = 0
	node.modulate = color
	node.double_sided = false
	parent.add_child(node)
	return node


## Readable face points +Z.
static func plate(parent: Node3D, at: Vector3, size: Vector2, surface: Material, radius := 0.35) -> Node3D:
	var node := Node3D.new()
	node.position = at
	parent.add_child(node)
	var points := PackedVector2Array()
	for corner in 4:
		var centre := Vector2((1 if corner < 2 else -1) * (size.x * 0.5 - radius), (1 if corner == 0 or corner == 3 else -1) * (size.y * 0.5 - radius))
		for step in 7:
			var angle := PI * 0.5 - corner * PI * 0.5 - step * PI / 12.0
			points.append(centre + Vector2(cos(angle), sin(angle)) * radius)
	polygon(node, points, surface)
	return node


## Faces +Z.
static func polygon(parent: Node3D, points: PackedVector2Array, surface: Material) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	for point in points:
		vertices.append(Vector3(point.x, point.y, 0))
		normals.append(Vector3.BACK)
	var indices := Geometry2D.triangulate_polygon(points)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = surface
	parent.add_child(node)
	return node


static func tube(parent: Node3D, points: PackedVector3Array, radius: float, surface: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in points.size() - 1:
		var axis := (points[i + 1] - points[i]).normalized()
		var u := axis.cross(Vector3.FORWARD).normalized()
		if u.length_squared() < 0.5:
			u = axis.cross(Vector3.UP).normalized()
		var v := axis.cross(u).normalized()
		for side in 12:
			var n0 := u * cos(side * TAU / 12) + v * sin(side * TAU / 12)
			var n1 := u * cos((side + 1) * TAU / 12) + v * sin((side + 1) * TAU / 12)
			for entry in [[i, n0], [i + 1, n0], [i, n1], [i, n1], [i + 1, n0], [i + 1, n1]]:
				st.set_normal(entry[1])
				st.add_vertex(points[entry[0]] + entry[1] * radius)
	var mesh := MeshInstance3D.new()
	mesh.mesh = st.commit()
	mesh.material_override = surface
	parent.add_child(mesh)


static func arrow(parent: Node3D, at: Vector3, angle: float, blue := false) -> void:
	var pivot := Node3D.new()
	pivot.position = at
	pivot.rotation.z = angle
	parent.add_child(pivot)
	var outline := PackedVector2Array([Vector2(-0.34, -2.8), Vector2(0.34, -2.8), Vector2(0.34, 0.85), Vector2(1.15, 0.85), Vector2(0, 2.8), Vector2(-1.15, 0.85), Vector2(-0.34, 0.85)])
	polygon(pivot, outline, _white)
	if blue:
		var inset := Node3D.new()
		inset.position.z = 0.015
		inset.scale = Vector3(0.78, 0.93, 1)
		pivot.add_child(inset)
		polygon(inset, outline, _blue)


static func route_card(parent: Node3D, at: Vector3, width: float, route: Dictionary) -> void:
	var card := plate(parent, at, Vector2(width, 2.8), _white, 0.05)
	var code_width := 3.7
	plate(card, Vector3(-width * 0.5 + code_width * 0.5 + 0.25, 0, 0.02), Vector2(code_width, 2.3), _green, 0.06)
	label(card, str(route.get("code", "")), Vector3(-width * 0.5 + code_width * 0.5 + 0.25, 0, 0.04), 1.85, null, code_width - 0.2)
	var x := code_width * 0.5 + 0.2
	label(card, str(route.get("jp", Labels.text("sign_expressway", ""))), Vector3(x, 0.55, 0.04), 1.55, null, width - code_width - 0.6, Color(0.02, 0.28, 0.12))
	label(card, str(route.get("en", "EXPRESSWAY")), Vector3(x, -0.8, 0.04), 0.63, null, width - code_width - 0.6, Color(0.02, 0.28, 0.12))


## The arrow is angled when data.branch.
static func direction_panel(parent: Node3D, at: Vector3, width: float, data: Dictionary) -> Node3D:
	box(parent, at - Vector3(0, 0, 0.2), Vector3(width - 0.5, 10.5, 0.3), _steel)
	var panel := plate(parent, at, Vector2(width, 11.0), _green, 0.5)
	panel.name = "DirectionPanel"
	var branch: bool = data.get("branch", false)
	var routes: Array = data.get("routes", [])
	var usable := width - 5.0
	var text_x := -1.6 if branch else 1.6
	if not routes.is_empty():
		var card_width := (usable - 0.8) / routes.size()
		for i in routes.size():
			route_card(panel, Vector3(text_x - usable * 0.5 + card_width * (i + 0.5) + 0.4, 3.3, 0.04), card_width - 0.35, routes[i])
	label(panel, str(data.get("jp", "")), Vector3(text_x, -0.5, 0.08), 2.5, null, usable - 0.6)
	label(panel, str(data.get("en", "")), Vector3(text_x, -3.3, 0.08), 1.6, null, usable - 0.6)
	arrow(panel, Vector3((width * 0.5 - 2.0) * (1 if branch else -1), -0.2, 0.1), deg_to_rad(30) if branch else 0.0, branch)
	return panel


static func gantry(parent: Node3D, width: float) -> Node3D:
	prepare()
	var result := Node3D.new()
	result.name = "DirectionGantry"
	parent.add_child(result)
	var half := width * 0.5 + 3.0
	var points := PackedVector3Array([Vector3(-half, 0, 0), Vector3(-half, 18, 0)])
	for i in range(1, 13):
		var a := PI - i * PI / 24
		points.append(Vector3(-half + 4 + cos(a) * 4, 18 + sin(a) * 4, 0))
	points.append(Vector3(half - 4, 22, 0))
	for i in range(1, 13):
		var a := PI * 0.5 - i * PI / 24
		points.append(Vector3(half - 4 + cos(a) * 4, 18 + sin(a) * 4, 0))
	points.append(Vector3(half, 0, 0))
	tube(result, points, 0.58, _steel)
	for side in [-1.0, 1.0]:
		box(result, Vector3(side * half, 0.3, 0), Vector3(2.2, 0.6, 2.2), _steel)
		for dx in [-0.75, 0.75]:
			for dz in [-0.75, 0.75]:
				box(result, Vector3(side * half + dx, 0.67, dz), Vector3(0.2, 0.15, 0.2), _steel)
	box(result, Vector3(0, 22, -1.6), Vector3(width, 0.18, 2.2), _steel)
	for h in [23.2, 24.7]:
		tube(result, PackedVector3Array([Vector3(-width * 0.5, h, -2.6), Vector3(width * 0.5, h, -2.6)]), 0.07, _steel)
	for i in range(ceili(width / 4) + 1):
		var x := lerpf(-width * 0.5, width * 0.5, float(i) / ceili(width / 4))
		tube(result, PackedVector3Array([Vector3(x, 22, -2.6), Vector3(x, 24.7, -2.6)]), 0.07, _steel)
	return result


## Route text from junction_signs.json, for the junction preview.
static func reference_junction(parent: Node3D, width := 64.0) -> Node3D:
	var result := gantry(parent, width)
	var texts := REFERENCE_SIGNS
	direction_panel(result, Vector3(-16.4, 24.8, 0.75), 31.8, texts.get("left", {}))
	direction_panel(result, Vector3(16.4, 24.8, 0.75), 31.8, texts.get("right", {}))
	var head: Dictionary = texts.get("header", {})
	var header := plate(result, Vector3(-1, 32.3, 0.8), Vector2(15.4, 3), _green, 0.12)
	plate(header, Vector3(-6, 0, 0.02), Vector2(3.4, 3), _white, 0.08)
	label(header, str(head.get("number", "")), Vector3(-6, 0, 0.04), 2.3, null, 3, Color(0.02, 0.28, 0.12))
	label(header, str(head.get("jp", "")), Vector3(1.5, 0.6, 0.04), 1.65, null, 11)
	label(header, str(head.get("en", "")), Vector3(1.5, -0.85, 0.04), 0.85, null, 11)
	var sign: Dictionary = texts.get("side", {})
	var side := plate(result, Vector3(width * 0.5 + 3, 13, 0.8), Vector2(3.7, 15.5), _green, 0.2)
	var up := Node3D.new()
	up.position = Vector3(0, 6.2, 0.04)
	up.scale = Vector3.ONE * 0.36
	side.add_child(up)
	arrow(up, Vector3.ZERO, 0)
	plate(side, Vector3(0, 4.3, 0.04), Vector2(2.9, 1.55), _white, 0.04)
	label(side, str(sign.get("code", "")), Vector3(0, 4.3, 0.06), 1.2, null, 2.7, Color(0.02, 0.28, 0.12))
	label(side, str(sign.get("jp", "")), Vector3(0, -0.6, 0.04), 1.15, null, 3.0)
	label(side, str(sign.get("place", "")), Vector3(0, -6.4, 0.04), 1.55, null, 3.0)
	return result


static func install(parent: Node3D, signs: Array) -> void:
	prepare()
	for entry: Dictionary in signs:
		var lateral: Vector3 = entry.lateral
		var tangent := Vector3(lateral.z, 0, -lateral.x)
		var width: float = entry.width
		var frame := Node3D.new()
		frame.position = entry.position
		frame.basis = Basis(lateral, Vector3.UP, -tangent)
		parent.add_child(frame)
		var structure := gantry(frame, width)
		for reverse in [false, true]:
			var board := Node3D.new()
			board.position = Vector3((1.0 if reverse else -1.0) * width * 0.25, 24.8, 0.75 if not reverse else -3.0)
			board.rotation.y = PI if reverse else 0.0
			structure.add_child(board)
			direction_panel(board, Vector3.ZERO, minf(width * 0.48, 34.0), {
				"routes": [{"code":"", "jp":Labels.text("sign_expressway", ""), "en":"EXPRESSWAY"}],
				"jp":Labels.text("sign_direction", ""), "en":Identity.value("home_display_name") if reverse else "The City"})
