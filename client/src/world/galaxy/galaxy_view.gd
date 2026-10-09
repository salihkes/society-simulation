class_name GalaxyView
extends CanvasLayer
## Fullscreen galaxy map overlay, toggled with M, drawn in its own SubViewport world.

const TOGGLE_KEY := KEY_M

var _container: SubViewportContainer
var _viewport: SubViewport
var _map: GalaxyMap
var _hint: Label
var _borders_button: Button
var _panel: PanelContainer
var _panel_name: Label
var _panel_info: Label
var _travel_button: Button
var _you_marker: Node3D

var _focused_rid := ""
var _prev_mouse_mode := Input.MOUSE_MODE_VISIBLE
var _player_input_was_disabled := false
var _pulse := 0.0


func _ready() -> void:
	layer = 40
	_container = SubViewportContainer.new()
	_container.stretch = true
	_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_container.add_child(_viewport)
	_build_hud()
	_container.visible = false
	_hint.visible = false
	_borders_button.visible = false


func _build_hud() -> void:
	_hint = Label.new()
	_hint.text = "Left-drag / WASD — pan · right-drag — orbit · scroll — zoom · click — planet · Esc — back · M — close"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint.offset_top = -34.0
	_hint.offset_bottom = -10.0
	_hint.add_theme_color_override("font_color", Color(0.85, 0.88, 1.0, 0.85))
	_hint.add_theme_font_size_override("font_size", 13)
	add_child(_hint)

	_borders_button = Button.new()
	_borders_button.text = "Borders: off"
	_borders_button.toggle_mode = true
	_borders_button.position = Vector2(16, 16)
	_borders_button.toggled.connect(_on_borders_toggled)
	add_child(_borders_button)
	_build_panel()


func _build_panel() -> void:
	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.12, 0.92)
	style.border_color = Color(0.35, 0.45, 0.75, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", style)
	_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -320.0
	_panel.offset_right = -16.0
	_panel.offset_top = 16.0
	_panel.visible = false
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_panel.add_child(vbox)
	_panel_name = Label.new()
	_panel_name.add_theme_font_size_override("font_size", 20)
	_panel_name.add_theme_color_override("font_color", Color(0.95, 0.96, 1.0))
	vbox.add_child(_panel_name)
	_panel_info = Label.new()
	_panel_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_info.add_theme_font_size_override("font_size", 14)
	_panel_info.add_theme_color_override("font_color", Color(0.75, 0.80, 0.95))
	vbox.add_child(_panel_info)
	_travel_button = Button.new()
	_travel_button.text = "Travel here (debug)"
	_travel_button.pressed.connect(_on_travel_pressed)
	vbox.add_child(_travel_button)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# Never steal keys from a focused control such as the chat bar.
	if get_viewport().gui_get_focus_owner() != null:
		return
	if event.keycode == TOGGLE_KEY:
		if is_open():
			close_map()
		else:
			open_map()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE and is_open():
		if _focused_rid != "":
			_map.unfocus()
		else:
			close_map()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_open() or _you_marker == null:
		return
	var giw := _find_galaxy_in_world()
	var cam := get_viewport().get_camera_3d()
	if giw and giw.map and cam:
		_you_marker.position = giw.map.to_local(cam.global_position)
	_pulse += delta * 4.0
	_you_marker.scale = Vector3.ONE * (1.0 + 0.18 * sin(_pulse))


func is_open() -> bool:
	return _container.visible


## Also frees the mouse and freezes the player's input.
func open_map() -> void:
	if _map == null:
		_map = GalaxyMap.new()
		_map.home_rid = GalaxyPlanets.HOME_RID
		_viewport.add_child(_map)
		_map.build(GalaxyPlanets.PLANETS, GalaxyPlanets.colors(), GalaxyPlanets.org_colors())
		_map.set_borders_visible(false)
		_map.planet_clicked.connect(_on_planet_clicked)
		_map.deselected.connect(_on_deselected)
		_build_you_marker()
	_container.visible = true
	_hint.visible = true
	_borders_button.visible = true
	_prev_mouse_mode = Input.get_mouse_mode()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_set_player_input_enabled(false)


func close_map() -> void:
	_container.visible = false
	_hint.visible = false
	_borders_button.visible = false
	_panel.visible = false
	_focused_rid = ""
	Input.set_mouse_mode(_prev_mouse_mode)
	_set_player_input_enabled(true)


func _build_you_marker() -> void:
	_you_marker = Node3D.new()
	var dot := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1.6, 1.6)
	dot.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.albedo_texture = _map._dot_tex
	m.albedo_color = Color(1.0, 0.85, 0.35, 0.95)
	m.no_depth_test = true
	dot.set_surface_override_material(0, m)
	_you_marker.add_child(dot)
	var label := Label3D.new()
	label.text = "You are here"
	label.position = Vector3(0, 1.2, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.no_depth_test = true
	label.pixel_size = 0.0011
	label.font_size = 18
	label.outline_size = 8
	label.modulate = Color(1.0, 0.87, 0.45)
	_you_marker.add_child(label)
	_map.add_child(_you_marker)


func _on_borders_toggled(on: bool) -> void:
	_map.set_borders_visible(on)
	_borders_button.text = "Borders: on" if on else "Borders: off"


func _on_planet_clicked(rid: String) -> void:
	_focused_rid = rid
	var def: Dictionary = GalaxyPlanets.PLANETS.get(rid, {})
	_panel_name.text = str(def.get("name", rid))
	var lines: Array[String] = []
	lines.append(GalaxyPlanets.describe(rid))
	if rid == GalaxyPlanets.HOME_RID:
		lines.append("Home.")
	elif _you_marker and _map.planets.has(rid):
		var d_gu: float = _you_marker.position.distance_to(_map.planets[rid]["pos"])
		lines.append("%s ly away" % _format_ly(d_gu * GalaxyPlanets.UNIT_LY))
	_panel_info.text = "\n".join(lines)
	_panel.visible = true


func _on_deselected() -> void:
	_focused_rid = ""
	_panel.visible = false


## Debug travel: 1000 units above the focused planet, streaming its world in first.
func _on_travel_pressed() -> void:
	if _focused_rid == "":
		return
	var giw := _find_galaxy_in_world()
	if giw == null or giw.map == null or not giw.map.planets.has(_focused_rid):
		return
	giw.ensure_streamed(_focused_rid)
	# Above any terrain and placeholder sphere, inside streaming range.
	var local := giw.planet_local_position(_focused_rid) + Vector3(0, 1000, 0)
	var target := giw.to_global(local)
	var mover := _travel_mover()
	if mover == null:
		return
	# Unbind so the old planet's leash cannot pull the mover back.
	var walker = mover.get("planet")
	if walker != null:
		walker.set_planet(null, "space")
	mover.global_position = target
	if "velocity" in mover:
		mover.velocity = Vector3.ZERO
	if walker != null:
		walker.update_nearest()
	print("GalaxyView: teleported %s to %s (debug travel)" % [mover.name, _focused_rid])
	close_map()


## The ship the local player is aboard, else the player, else the scene's "Spaceship".
func _travel_mover() -> Node3D:
	var mover: Node3D = null
	var player := _find_local_player()
	if player:
		var aboard = player.get("ship")
		var ship = aboard.boarded if aboard != null else null
		if ship is Node3D and is_instance_valid(ship):
			mover = ship
		elif player is Node3D:
			mover = player
	if mover == null:
		var scene_root := get_tree().current_scene
		if scene_root:
			mover = scene_root.find_child("Spaceship", true, false) as Node3D
	return mover


## A whole number with thousands separators.
func _format_ly(ly: float) -> String:
	var s := str(int(round(ly)))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out


func _set_player_input_enabled(enabled: bool) -> void:
	if enabled and not _player_input_was_disabled:
		return
	_player_input_was_disabled = not enabled
	var player := _find_local_player()
	if player and player.has_method("set_input_enabled"):
		player.set_input_enabled(enabled)


## The NetworkController's local player, else the scene's "humanoid".
func _find_local_player() -> Node:
	var nc := get_node_or_null("/root/NetworkController")
	if nc:
		var lp = nc.get_indexed("players:local_player")
		if lp is Node and is_instance_valid(lp):
			return lp
	var scene_root := get_tree().current_scene
	if scene_root:
		return scene_root.get_node_or_null("humanoid")
	return null


func _find_galaxy_in_world() -> GalaxyInWorld:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return null
	return scene_root.find_child("GalaxyInWorld", true, false) as GalaxyInWorld
