@tool
extends EditorPlugin
## Planet Designer: in-viewport authoring for cube-sphere planets.
##
## Select any node of a planet scene that contains a PlanetTerrain and use
## the dock (right panel) to switch modes:
##   Select   — normal editor behaviour, brushes off
##   Sculpt   — LMB raise, Shift+LMB lower
##   Smooth   — LMB relaxes terrain toward the local mean
##   Flatten  — first click picks the height, drag spreads it
##   Roads    — LMB adds points to the active road (New Road to start one),
##              Apply Roads stamps them into the terrain
##   Place    — LMB drops the asset from the scene path field as an anchor
##   Scatter  — LMB sprinkles assets from the palette within the brush
##   Erase    — LMB removes anchors under the brush
## Brushes hit the terrain via its analytic raycast: no physics needed in
## the editor. Sculpt and placement edits are undoable (Ctrl+Z).

var _dock: Control
var _terrain: PlanetTerrain
var _mode := "select"
var _painting := false
var _stroke_undo: Array = []
var _flatten_h := 0.0
var _flatten_set := false
var _active_road: PlanetRoad
var _cursor: MeshInstance3D
var _last_hit := {}

# dock controls we need to read later
var _radius_slider: HSlider
var _strength_slider: HSlider
var _radius_val: Label
var _strength_val: Label
var _scene_edit: LineEdit
var _pad_spin: SpinBox
var _align_check: CheckBox
var _auto_pad_check: CheckBox
var _rand_yaw_check: CheckBox
var _palette_edit: TextEdit
var _density_spin: SpinBox
var _profile_option: OptionButton
var _road_label: Label
var _status: Label
var _mode_buttons := {}


func _enter_tree() -> void:
	_dock = _build_dock()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)


func _exit_tree() -> void:
	remove_control_from_docks(_dock)
	_dock.free()
	_clear_cursor()


func _handles(object: Object) -> bool:
	return object is Node and _find_terrain(object) != null


func _edit(object: Object) -> void:
	if object == null:
		return
	var t := _find_terrain(object)
	if t and t != _terrain:
		_terrain = t
		_active_road = null
		_set_status("Editing: %s" % _terrain.get_parent().name)


func _find_terrain(node: Object) -> PlanetTerrain:
	if node is PlanetTerrain:
		return node
	if not (node is Node):
		return null
	# search up to the scene root, then down
	var root := node as Node
	while root.get_parent() != null and not (root.get_parent() is Window) \
			and root.owner != null:
		root = root.get_parent()
	return _search_terrain(root)


func _search_terrain(node: Node) -> PlanetTerrain:
	if node is PlanetTerrain:
		return node
	for child in node.get_children():
		var found := _search_terrain(child)
		if found:
			return found
	return null


# ---------------------------------------------------------------- input --

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if _mode == "select" or _terrain == null or not is_instance_valid(_terrain):
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouseMotion:
		_last_hit = _pick(camera, event.position)
		_update_cursor()
		if _painting and not _last_hit.is_empty():
			_apply_at(_last_hit, event)
		return AFTER_GUI_INPUT_STOP if _painting else AFTER_GUI_INPUT_PASS
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_last_hit = _pick(camera, event.position)
			if _last_hit.is_empty():
				return AFTER_GUI_INPUT_PASS
			_painting = true
			_stroke_undo = []
			_flatten_set = false
			_apply_at(_last_hit, event)
			return AFTER_GUI_INPUT_STOP
		elif _painting:
			_painting = false
			_end_stroke()
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


func _pick(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var xf := _terrain.global_transform
	var local_origin := xf.affine_inverse() * origin
	var local_dir := (xf.basis.inverse() * dir).normalized()
	return _terrain.raycast_surface(local_origin, local_dir)


func _apply_at(hit: Dictionary, event: InputEvent) -> void:
	var radius: float = _radius_slider.value
	var strength: float = _strength_slider.value
	match _mode:
		"sculpt":
			var kind := "lower" if event.shift_pressed else "raise"
			_stroke_undo.append_array(_terrain.apply_brush(kind, hit.dir, radius, strength * 0.35))
		"smooth":
			_stroke_undo.append_array(_terrain.apply_brush("smooth", hit.dir, radius, strength))
		"flatten":
			if not _flatten_set:
				_flatten_h = hit.height
				_flatten_set = true
			_stroke_undo.append_array(_terrain.apply_brush("flatten", hit.dir, radius, strength, _flatten_h))
		"roads":
			if not _painting or event is InputEventMouseButton:
				_road_click(hit)
		"place":
			if event is InputEventMouseButton:
				_place_click(hit)
		"scatter":
			_scatter_at(hit)
		"erase":
			_erase_at(hit)


func _end_stroke() -> void:
	if _mode in ["sculpt", "smooth", "flatten"] and not _stroke_undo.is_empty():
		# dedupe pixels, capture 'after' values for redo
		var seen := {}
		var before: Array = []
		for e in _stroke_undo:
			var k: int = (e.face * 8192 + e.y) * 8192 + e.x
			if not seen.has(k):
				seen[k] = true
				before.append(e)
		var after: Array = []
		var field: PlanetHeightField = _terrain.get_base_field()
		for e in before:
			after.append({"face": e.face, "x": e.x, "y": e.y, "before": field.get_px(e.face, e.x, e.y)})
		var ur := get_undo_redo()
		ur.create_action("Sculpt planet terrain")
		ur.add_do_method(_terrain, "apply_pixel_snapshot", after)
		ur.add_undo_method(_terrain, "apply_pixel_snapshot", before)
		ur.commit_action(false)
		_terrain.rebake()
		_set_status("Sculpted %d texels — remember Save Heights" % before.size())
	_stroke_undo = []


# ---------------------------------------------------------------- roads --

func _road_click(hit: Dictionary) -> void:
	if _active_road == null or not is_instance_valid(_active_road):
		_set_status("Roads: press New Road first")
		return
	_active_road.add_point(hit.dir, hit.height + 0.3)
	_active_road.rebuild_mesh(_terrain, _terrain.get_field())
	_road_label.text = "Active: %s (%d pts)" % [_active_road.name, _active_road.point_count()]


func _new_road() -> void:
	if _terrain == null:
		return
	var network := _find_or_make_network()
	var kind: String = ["asphalt", "dirt", "skyway"][_profile_option.selected]
	_active_road = network.new_road(RoadProfile.make_default(kind))
	_road_label.text = "Active: %s (0 pts)" % _active_road.name
	_set_status("Click terrain to add road points, then Apply Roads")


func _find_or_make_network() -> PlanetRoadNetwork:
	var planet_root := _terrain.get_parent()
	for child in planet_root.get_children():
		if child is PlanetRoadNetwork:
			return child
	var network := PlanetRoadNetwork.new()
	network.name = "RoadNetwork"
	planet_root.add_child(network)
	network.owner = _terrain.owner if _terrain.owner else planet_root
	return network


func _undo_road_point() -> void:
	if _active_road and is_instance_valid(_active_road):
		_active_road.remove_last_point()
		_active_road.rebuild_mesh(_terrain, _terrain.get_field())
		_road_label.text = "Active: %s (%d pts)" % [_active_road.name, _active_road.point_count()]


# ------------------------------------------------------------ placement --

func _placements() -> PlanetPlacements:
	var planet_root := _terrain.get_parent()
	for child in planet_root.get_children():
		if child is PlanetPlacements:
			return child
	var p := PlanetPlacements.new()
	p.name = "Placements"
	planet_root.add_child(p)
	p.owner = _terrain.owner if _terrain.owner else planet_root
	return p


func _place_click(hit: Dictionary) -> void:
	var path := _scene_edit.text.strip_edges()
	var p := _placements()
	var yaw := randf() * TAU if _rand_yaw_check.button_pressed else 0.0
	# pad: explicit spin value wins; otherwise measured from the asset's
	# footprint. PROJECT RULE: an asset's origin (0,0,0) IS its ground
	# point — placement never offsets or re-seats models.
	var pad: float = _pad_spin.value
	var h_off := 0.0
	if _auto_pad_check.button_pressed and path != "" and pad <= 0.0:
		var m := _measure_scene(path)
		if not m.is_empty():
			pad = m.pad
	var anchor := {
		"scene": path, "dir": hit.dir, "yaw": yaw, "h_off": h_off,
		"align": 1 if _align_check.button_pressed else 0, "scale": 1.0,
		"pad_radius": pad, "pad_falloff": pad * 0.8,
	}
	var ur := get_undo_redo()
	ur.create_action("Place planet prop")
	ur.add_do_method(self, "_do_add_anchor", p, anchor)
	ur.add_undo_method(self, "_do_remove_last_anchor", p)
	ur.commit_action()
	if pad > 0.0:
		_terrain.rebake()
	_set_status("Placed %s (pad %.0f m)" % [path.get_file() if path != "" else "placeholder", pad])


var _measure_cache := {}
## Footprint pad radius + seating offset of a placeable scene/mesh, from its
## merged mesh AABB. Cached per path.
func _measure_scene(path: String) -> Dictionary:
	if _measure_cache.has(path):
		return _measure_cache[path]
	if not ResourceLoader.exists(path):
		return {}
	var res: Resource = load(path)
	var aabb := AABB()
	var found := false
	if res is PackedScene:
		var inst := (res as PackedScene).instantiate()
		var stack: Array = [[inst, Transform3D.IDENTITY]]
		while not stack.is_empty():
			var entry: Array = stack.pop_back()
			var node: Node = entry[0]
			var xf: Transform3D = entry[1]
			if node is MeshInstance3D and node.mesh:
				var local: AABB = xf * node.mesh.get_aabb()
				aabb = aabb.merge(local) if found else local
				found = true
			for child in node.get_children():
				stack.append([child, xf * child.transform if child is Node3D else xf])
		inst.free()
	elif res is Mesh:
		aabb = (res as Mesh).get_aabb()
		found = true
	if not found:
		return {}
	var out := {
		"pad": clampf(maxf(aabb.size.x, aabb.size.z) * 0.5 + 5.0, 3.0, 160.0),
	}
	_measure_cache[path] = out
	return out


func _do_add_anchor(p: PlanetPlacements, anchor: Dictionary) -> void:
	p.add_anchor(anchor)
	p.rebuild(_terrain)


func _do_remove_last_anchor(p: PlanetPlacements) -> void:
	if not p.anchors.is_empty():
		p.anchors.pop_back()
		p.rebuild(_terrain)


func _scatter_at(hit: Dictionary) -> void:
	var lines: Array = []
	for line in _palette_edit.text.split("\n"):
		var s: String = line.strip_edges()
		if s != "":
			lines.append(s)
	var p := _placements()
	var radius: float = _radius_slider.value
	var count := maxi(int(_density_spin.value), 1)
	var r: float = _terrain.data.radius
	var frame := CubeSphere.tangent_frame(hit.dir)
	var added := 0
	for i in count:
		var off: Vector3 = (frame[0] * randf_range(-1.0, 1.0) + frame[1] * randf_range(-1.0, 1.0)) * (radius / r)
		var d: Vector3 = (hit.dir + off).normalized()
		if CubeSphere.angle_between(d, hit.dir) > radius / r:
			continue
		var h: float = _terrain.height_at_dir(d)
		if h < 0.5:   # don't scatter into the sea
			continue
		p.add_anchor({
			"scene": lines[randi() % lines.size()] if not lines.is_empty() else "",
			"dir": d, "yaw": randf() * TAU, "h_off": 0.0, "align": 1,
			"scale": randf_range(0.8, 1.25), "pad_radius": 0.0,
		})
		added += 1
	if added > 0:
		p.rebuild(_terrain)
		_set_status("Scattered %d" % added)


func _erase_at(hit: Dictionary) -> void:
	var p := _placements()
	var removed := p.remove_anchors_within(hit.dir, _radius_slider.value, _terrain.data.radius)
	if not removed.is_empty():
		p.rebuild(_terrain)
		_set_status("Erased %d" % removed.size())


# --------------------------------------------------------------- cursor --

func _update_cursor() -> void:
	if _last_hit.is_empty() or _mode == "select" or _terrain == null:
		_clear_cursor()
		return
	if _cursor == null or not is_instance_valid(_cursor):
		_cursor = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radial_segments = 24
		sphere.rings = 12
		var m := StandardMaterial3D.new()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(0.3, 0.8, 1.0, 0.25)
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sphere.material = m
		_cursor.mesh = sphere
		_terrain.add_child(_cursor)
	var s: float = maxf(_radius_slider.value, 0.5)
	_cursor.scale = Vector3.ONE * s
	_cursor.position = _last_hit.position


func _clear_cursor() -> void:
	if _cursor and is_instance_valid(_cursor):
		_cursor.queue_free()
	_cursor = null


# ----------------------------------------------------------------- dock --

func _build_dock() -> Control:
	var root := VBoxContainer.new()
	root.name = "Planet Designer"
	var modes := GridContainer.new()
	modes.columns = 4
	root.add_child(modes)
	for m in ["select", "sculpt", "smooth", "flatten", "roads", "place", "scatter", "erase"]:
		var b := Button.new()
		b.text = m.capitalize()
		b.toggle_mode = true
		b.button_pressed = m == "select"
		b.pressed.connect(_on_mode.bind(m))
		modes.add_child(b)
		_mode_buttons[m] = b

	root.add_child(HSeparator.new())
	_radius_slider = _labeled_slider(root, "Brush radius", 2.0, 300.0, 45.0)
	_strength_slider = _labeled_slider(root, "Strength", 0.1, 10.0, 2.0)

	root.add_child(HSeparator.new())
	var road_title := Label.new()
	road_title.text = "Roads"
	root.add_child(road_title)
	_profile_option = OptionButton.new()
	for p in ["Asphalt street", "Dirt track", "Skyway"]:
		_profile_option.add_item(p)
	root.add_child(_profile_option)
	var road_row := HBoxContainer.new()
	root.add_child(road_row)
	var new_road_btn := Button.new()
	new_road_btn.text = "New Road"
	new_road_btn.pressed.connect(_new_road)
	road_row.add_child(new_road_btn)
	var undo_pt_btn := Button.new()
	undo_pt_btn.text = "Undo Pt"
	undo_pt_btn.pressed.connect(_undo_road_point)
	road_row.add_child(undo_pt_btn)
	var apply_btn := Button.new()
	apply_btn.text = "Apply Roads"
	apply_btn.pressed.connect(func() -> void:
		if _terrain:
			_terrain.rebake()
			_set_status("Roads stamped into terrain"))
	road_row.add_child(apply_btn)
	_road_label = Label.new()
	_road_label.text = "Active: none"
	root.add_child(_road_label)

	root.add_child(HSeparator.new())
	var place_title := Label.new()
	place_title.text = "Place / Scatter"
	root.add_child(place_title)
	_scene_edit = LineEdit.new()
	_scene_edit.placeholder_text = "res://... scene or mesh to place"
	root.add_child(_scene_edit)
	var opt_row := HBoxContainer.new()
	root.add_child(opt_row)
	_align_check = CheckBox.new()
	_align_check.text = "Align to slope"
	opt_row.add_child(_align_check)
	_rand_yaw_check = CheckBox.new()
	_rand_yaw_check.text = "Random yaw"
	_rand_yaw_check.button_pressed = true
	opt_row.add_child(_rand_yaw_check)
	_auto_pad_check = CheckBox.new()
	_auto_pad_check.text = "Auto pad (from asset footprint)"
	_auto_pad_check.button_pressed = true
	root.add_child(_auto_pad_check)
	var pad_row := HBoxContainer.new()
	root.add_child(pad_row)
	var pad_label := Label.new()
	pad_label.text = "Pad radius (0 = auto)"
	pad_row.add_child(pad_label)
	_pad_spin = SpinBox.new()
	_pad_spin.min_value = 0.0
	_pad_spin.max_value = 160.0
	_pad_spin.step = 0.5
	pad_row.add_child(_pad_spin)
	_palette_edit = TextEdit.new()
	_palette_edit.placeholder_text = "Scatter palette: one res:// path per line (empty = placeholders)"
	_palette_edit.custom_minimum_size = Vector2(0, 70)
	root.add_child(_palette_edit)
	var dens_row := HBoxContainer.new()
	root.add_child(dens_row)
	var dens_label := Label.new()
	dens_label.text = "Per stamp"
	dens_row.add_child(dens_label)
	_density_spin = SpinBox.new()
	_density_spin.min_value = 1
	_density_spin.max_value = 200
	_density_spin.value = 12
	dens_row.add_child(_density_spin)

	root.add_child(HSeparator.new())
	var actions := HBoxContainer.new()
	root.add_child(actions)
	var rebake_btn := Button.new()
	rebake_btn.text = "Rebake"
	rebake_btn.pressed.connect(func() -> void:
		if _terrain:
			_terrain.rebake()
			_set_status("Rebaked"))
	actions.add_child(rebake_btn)
	var save_btn := Button.new()
	save_btn.text = "Save Heights"
	save_btn.pressed.connect(func() -> void:
		if _terrain and _terrain.save_base():
			_set_status("Saved base.res"))
	actions.add_child(save_btn)
	var snap_btn := Button.new()
	snap_btn.text = "Road→Ground"
	snap_btn.pressed.connect(func() -> void:
		if _active_road and _terrain:
			_active_road.snap_to_ground(_terrain)
			_active_road.rebuild_mesh(_terrain, _terrain.get_field())
			_set_status("Road dropped to ground"))
	actions.add_child(snap_btn)

	_status = Label.new()
	_status.text = "Select a planet, pick a mode."
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status)
	return root


func _labeled_slider(parent: Control, text: String, minv: float, maxv: float, val: float) -> HSlider:
	var label := Label.new()
	label.text = text
	parent.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minv
	slider.max_value = maxv
	slider.value = val
	slider.step = 0.1
	parent.add_child(slider)
	return slider


func _on_mode(mode: String) -> void:
	_mode = mode
	for m in _mode_buttons:
		_mode_buttons[m].button_pressed = m == mode
	if mode == "select":
		_clear_cursor()
	_set_status("Mode: %s" % mode.capitalize())


func _set_status(text: String) -> void:
	if _status:
		_status.text = text
