extends Control
## The studio's controls built in code; layout only, studio.gd wires the controls named in `n`.

const PANEL_W := 390

var n: Dictionary = {}
var preview: TextureRect
var preview_area: Control
var _preview_size := Vector2(1024, 768)


func build(w: int, h: int, weathers: Array, emotions: Array, school_ops: Array,
		lessons: Array, weekdays: Array) -> void:
	_preview_size = Vector2(w, h)
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.10, 0.11)
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)

	_build_top_bar(column)

	var body := HBoxContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	column.add_child(body)
	var tabs := TabContainer.new()
	tabs.custom_minimum_size.x = PANEL_W
	tabs.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_child(tabs)
	n.tabs = tabs
	_build_camera(_tab(tabs, "Camera"))
	_build_scene(_tab(tabs, "Scene"), weathers)
	_build_people(_tab(tabs, "People"), emotions)
	_build_world(_tab(tabs, "World"), school_ops, lessons, weekdays)
	_build_shots(_tab(tabs, "Shots"))
	_build_log(_tab(tabs, "Log"))

	var center := VBoxContainer.new()
	center.size_flags_horizontal = SIZE_EXPAND_FILL
	center.size_flags_vertical = SIZE_EXPAND_FILL
	center.add_theme_constant_override("separation", 6)
	body.add_child(center)
	_build_preview(center)
	_build_record_bar(center)
	_build_bottom_bars(center)
	fit_preview.call_deferred()


func _build_top_bar(column: Control) -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	column.add_child(top)
	var title := _label(top, "STUDIO")
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	n.status = _label(top, "starting…")
	n.status.size_flags_horizontal = SIZE_EXPAND_FILL
	n.status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	n.rec_badge = _label(top, "")
	n.rec_badge.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	n.rec_badge.add_theme_font_size_override("font_size", 16)


func _build_preview(center: Control) -> void:
	preview_area = Control.new()
	preview_area.size_flags_horizontal = SIZE_EXPAND_FILL
	preview_area.size_flags_vertical = SIZE_EXPAND_FILL
	preview_area.mouse_filter = MOUSE_FILTER_IGNORE
	preview_area.custom_minimum_size = Vector2(512, 384)
	center.add_child(preview_area)
	n.frame = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.25, 0.25, 0.27)
	n.frame.add_theme_stylebox_override("panel", sb)
	n.frame.mouse_filter = MOUSE_FILTER_IGNORE
	preview_area.add_child(n.frame)
	n.frame_style = sb
	preview = TextureRect.new()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_SCALE
	preview.focus_mode = FOCUS_ALL
	preview.mouse_filter = MOUSE_FILTER_STOP
	preview_area.add_child(preview)
	preview_area.resized.connect(fit_preview)


func _build_record_bar(center: Control) -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	center.add_child(bar)
	n.btn_rec = _btn(bar, "● Record  (F9)")
	n.btn_rec.custom_minimum_size.x = 150
	n.rec_time = _label(bar, "00:00")
	n.rec_time.custom_minimum_size.x = 60
	_label(bar, "fps")
	n.fps = _option(bar, ["24", "25", "30", "50", "60"])
	n.fps.select(2)
	_fixed(n.fps, 70)
	n.pace = _option(bar, ["real time", "every frame"])
	_fixed(n.pace, 130)
	n.audio = _check(bar, "audio", true)
	n.btn_snap = _btn(bar, "Snapshot (F12)")
	n.preview_note = _label(bar, "")
	n.preview_note.size_flags_horizontal = SIZE_EXPAND_FILL
	n.preview_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	n.preview_note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	n.preview_note.add_theme_color_override("font_color", Color(0.6, 0.6, 0.62))


func _build_bottom_bars(center: Control) -> void:
	var bar2 := HBoxContainer.new()
	bar2.add_theme_constant_override("separation", 8)
	center.add_child(bar2)
	_label(bar2, "save to")
	n.out_dir = _line(bar2, "folder for clips and snapshots")
	n.out_dir.size_flags_horizontal = SIZE_EXPAND_FILL
	n.btn_open_dir = _btn(bar2, "Open folder")
	var bar3 := HBoxContainer.new()
	bar3.add_theme_constant_override("separation", 8)
	center.add_child(bar3)
	_label(bar3, "chat")
	n.chat_text = _line(bar3, "say something as the player, or /connect host")
	n.chat_text.size_flags_horizontal = SIZE_EXPAND_FILL
	n.btn_chat = _btn(bar3, "Send")
	n.hint = _label(center, "Click the preview to fly:  right-drag look · W A S D move · "
			+ "Q E down/up · Shift fast · Alt slow · wheel speed · middle-drag slide · "
			+ "Esc lets go of the mouse")
	n.hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.58))
	n.hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


## 1:1 pixels when there is room, else scaled down, never up; the recording keeps its own size.
func fit_preview() -> void:
	var a := preview_area.size
	if a.x <= 0.0 or a.y <= 0.0:
		return
	var k := minf(1.0, minf(a.x / _preview_size.x, a.y / _preview_size.y))
	var s := (_preview_size * k).floor()
	preview.size = s
	preview.position = ((a - s) / 2.0).floor()
	n.frame.position = preview.position - Vector2(2, 2)
	n.frame.size = s + Vector2(4, 4)
	if k < 0.999:
		n.preview_note.text = "preview scaled to %d%% — the recording stays %d×%d" % [
				int(round(k * 100.0)), int(_preview_size.x), int(_preview_size.y)]
	else:
		n.preview_note.text = "preview 1:1"


func set_preview_focused(f: bool) -> void:
	n.frame_style.border_color = Color(1, 0.75, 0.2) if f else Color(0.25, 0.25, 0.27)


func _build_camera(v: VBoxContainer) -> void:
	_section(v, "Camera")
	n.cam_mode = _option(_row(v, "mode"), ["Free flight", "Orbit", "Follow"])
	var pos := _row(v, "position")
	n.pos_x = _spin(pos, -100000, 100000, 0.01, 0)
	n.pos_y = _spin(pos, -100000, 100000, 0.01, 0)
	n.pos_z = _spin(pos, -100000, 100000, 0.01, 0)
	var ang := _row(v, "yaw pitch roll")
	n.yaw = _spin(ang, -100000, 100000, 0.1, 0)
	n.pitch = _spin(ang, -89, 89, 0.1, 0)
	n.roll = _spin(ang, -180, 180, 0.1, 0)
	var fr := _row(v, "fov")
	n.fov = _slider(fr, 10, 130, 0.5, 70)
	n.fov_label = _label(fr, "70°")
	n.fov_label.custom_minimum_size.x = 44
	n.speed = _spin(_row(v, "speed"), 0.05, 200, 0.1, 4.0)
	n.smooth = _check(_row(v, ""), "smooth look", true)
	var b := _buttons(v)
	n.btn_to_player = _btn(b, "To player")
	n.btn_to_spawn = _btn(b, "To spawn")
	n.btn_copy = _btn(b, "Copy pose")
	n.btn_paste = _btn(b, "Paste pose")
	_section(v, "Aim at a person")
	n.cam_res = _option(_row(v, "person"), [])
	b = _buttons(v)
	n.btn_res_go = _btn(b, "Go to")
	n.btn_res_orbit = _btn(b, "Orbit")
	n.btn_res_follow = _btn(b, "Follow")
	_section(v, "Aim at a place")
	n.cam_place = _option(_row(v, "place"), [])
	b = _buttons(v)
	n.btn_place_go = _btn(b, "Go to")
	n.btn_place_orbit = _btn(b, "Orbit")
	n.btn_refresh_lists = _btn(b, "Refresh lists")
	_section(v, "Orbit / follow")
	n.distance = _spin(_row(v, "distance"), 0.05, 500, 0.05, 3.0)
	n.look_height = _spin(_row(v, "look height"), -50, 50, 0.05, 0.8)
	n.spin = _spin(_row(v, "spin °/s"), -180, 180, 1, 0)
	n.chase = _check(_row(v, ""), "follow turns with the person", true)
	_section(v, "Depth of field")
	var dn := _row(v, "near")
	n.dof_near = _check(dn, "blur", false)
	n.dof_near_dist = _spin(dn, 0, 100, 0.05, 0.5)
	var df := _row(v, "far")
	n.dof_far = _check(df, "blur", false)
	n.dof_far_dist = _spin(df, 0, 5000, 0.5, 50)
	n.dof_far_trans = _spin(_row(v, "far fade"), 0, 1000, 0.5, 25)


func _build_scene(v: VBoxContainer, weathers: Array) -> void:
	_section(v, "Time of day (this window only)")
	n.scene_hint = _hint(v,
			"These change this window only; the city keeps its own clock and weather.")
	n.time_local = _check(_row(v, ""), "override the server's clock here", false)
	var tr := _row(v, "hour")
	n.time_slider = _slider(tr, 0, 24, 0.01, 12)
	n.time_label = _label(tr, "12:00")
	n.time_label.custom_minimum_size.x = 48
	var b := _buttons(v)
	n.btn_dawn = _btn(b, "Dawn")
	n.btn_noon = _btn(b, "Noon")
	n.btn_sunset = _btn(b, "Sunset")
	n.btn_night = _btn(b, "Night")
	_section(v, "Weather")
	n.weather = _option(_row(v, "look"), weathers)
	n.weather_instant = _check(_row(v, ""), "switch instantly (no front rolling in)", false)
	_hint(v, "The city follows its %s climatology; this only changes what this window shows."
			% Identity.value("climate_name"))
	_section(v, "Your body")
	n.body_mode = _option(_row(v, "body"),
			["Parked where it stands", "Follows the camera, hidden", "Drop it under the camera"])
	_hint(v, "Rooms light up and residents notice you near your body. "
			+ "'Follows' keeps that next to the lens; others online see it fly.")
	_section(v, "Speed of time (this window only)")
	var sr := _row(v, "scale")
	n.time_scale = _slider(sr, 0.05, 2.0, 0.05, 1.0)
	n.time_scale_label = _label(sr, "1.00×")
	n.time_scale_label.custom_minimum_size.x = 48
	n.btn_scale_reset = _btn(_buttons(v), "Normal speed")
	_hint(v, "Slow motion is local; people mirrored from the world step forward "
			+ "each server tick.")


func _build_people(v: VBoxContainer, emotions: Array) -> void:
	_section(v, "Person")
	n.ppl_res = _option(_row(v, "who"), [])
	var b := _buttons(v)
	n.btn_ppl_cam = _btn(b, "Camera to")
	n.btn_ppl_orbit = _btn(b, "Orbit")
	n.btn_ppl_follow = _btn(b, "Follow")
	n.btn_ppl_refresh = _btn(b, "Refresh")
	_section(v, "Say (spoken → %s bubble + voice)" % Identity.value("conlang_name"))
	n.say_text = _line(v, Labels.text("greeting", "Hello, everyone."))
	b = _buttons(v)
	n.btn_say = _btn(b, "Say")
	n.btn_say_raw = _btn(b, "Show as written, no voice")
	_section(v, "Send somewhere")
	n.ppl_place = _option(_row(v, "place"), [])
	n.ppl_then = _option(_row(v, "then"), ["wander", "stay"])
	b = _buttons(v)
	n.btn_go = _btn(b, "Go")
	n.btn_eat = _btn(b, "Eat there")
	n.btn_sit = _btn(b, "Sit there")
	_section(v, "Emotion")
	var er := _row(v, "emotion")
	n.emotion = _option(er, emotions)
	n.emotion.select(1)
	n.emote_secs = _spin(er, 1, 600, 1, 15)
	n.btn_emote = _btn(er, "Emote")
	_section(v, "Autonomy (the mind's life loop)")
	b = _buttons(v)
	n.btn_life_pause = _btn(b, "Pause this one")
	n.btn_life_resume = _btn(b, "Resume")
	n.btn_life_off = _btn(b, "All off")
	n.btn_life_on = _btn(b, "All on")
	n.btn_consolidate = _btn(_buttons(v), "Consolidate memory now")
	_section(v, "Household")
	b = _buttons(v)
	n.btn_hh_restock = _btn(b, "Restock")
	n.btn_hh_ill = _btn(b, "Fall ill")
	n.btn_hh_well = _btn(b, "Recover")


func _build_world(v: VBoxContainer, school_ops: Array, lessons: Array, weekdays: Array) -> void:
	_section(v, "Rehearsal")
	n.rehearsal = _check(_row(v, ""), "the city forgets this session", true)
	_hint(v, "On: the server snapshots the residents' memories and every world file when "
			+ "the studio connects, and puts them back when the studio leaves (or when this "
			+ "is switched off). Nothing shot here stays in anyone's memory. A city with no "
			+ "memories at all is a server start: tools/run/city.sh --clean.")
	_section(v, "Clock (server, everyone)")
	var cr := _row(v, "hour")
	n.clock_hour = _spin(cr, 0, 24, 0.25, 12)
	n.btn_clock_fixed = _btn(cr, "Pin")
	var rr := _row(v, "rate")
	n.clock_rate = _spin(rr, 1, 3600, 1, 60)
	n.btn_clock_scaled = _btn(rr, "Run from hour")
	n.btn_clock_real = _btn(rr, "Real time")
	var wr := _row(v, "weekday")
	n.weekday = _option(wr, weekdays)
	n.btn_weekday = _btn(wr, "Set")
	_section(v, "School")
	var sr := _row(v, "room")
	n.school_op = _option(sr, school_ops)
	n.school_class = _line(sr, "class (12B), blank = all")
	n.btn_school = _btn(sr, "Send")
	var lr := _row(v, "lesson")
	n.lesson_id = _option(lr, lessons)
	var lb := _buttons(v)
	n.btn_lesson_start = _btn(lb, "Start lesson")
	n.btn_lesson_stop = _btn(lb, "Stop")
	n.btn_lesson_status = _btn(lb, "Status")
	_section(v, "Event (world process)")
	var er := _row(v, "event")
	n.event_id = _line(er, "safiye")
	n.event_id.text = "safiye"
	n.btn_event_start = _btn(er, "Start")
	n.btn_event_stop = _btn(er, "Stop")
	_section(v, "Population (world process)")
	var pr := _row(v, "cars / peds")
	n.pop_cars = _spin(pr, 0, 60, 1, 12)
	n.pop_peds = _spin(pr, 0, 120, 1, 24)
	var pr2 := _row(v, "")
	n.pop_npcs = _check(pr2, "people on", true)
	n.pop_trams = _check(pr2, "trams", true)
	n.btn_populate = _btn(pr2, "Apply")
	n.world_hint = _hint(v, "The city scene ships with people and traffic off; this turns "
			+ "them on in the running world.")
	_section(v, "Diet")
	n.sitting_matter = _line(v, "the matter before the house")
	var sb := _buttons(v)
	n.btn_sitting_start = _btn(sb, "Open a sitting")
	n.btn_sitting_stop = _btn(sb, "Adjourn")
	_section(v, "")
	n.btn_status = _btn(_buttons(v), "Mind status → log")


func _build_shots(v: VBoxContainer) -> void:
	_section(v, "Saved camera shots")
	n.shots_list = ItemList.new()
	n.shots_list.custom_minimum_size.y = 220
	n.shots_list.size_flags_vertical = SIZE_EXPAND_FILL
	v.add_child(n.shots_list)
	n.shot_name = _line(v, "name for a new shot")
	var b := _buttons(v)
	n.btn_shot_add = _btn(b, "Add current")
	n.btn_shot_update = _btn(b, "Update")
	n.btn_shot_go = _btn(b, "Go")
	n.btn_shot_del = _btn(b, "Delete")
	b = _buttons(v)
	n.btn_shot_up = _btn(b, "▲")
	n.btn_shot_down = _btn(b, "▼")
	_section(v, "Fly through them in order")
	var lr := _row(v, "seconds per leg")
	n.leg_secs = _spin(lr, 0.2, 600, 0.1, 6.0)
	n.ease = _check(lr, "ease", true)
	b = _buttons(v)
	n.btn_path_play = _btn(b, "Play")
	n.btn_path_rec = _btn(b, "Play + record")
	n.btn_path_stop = _btn(b, "Stop")
	_hint(v, "Shots are kept in user://studio/shots.json. Play + record starts the clip at "
			+ "the first shot and stops it at the last.")


func _build_log(v: VBoxContainer) -> void:
	n.log = RichTextLabel.new()
	n.log.scroll_following = true
	n.log.selection_enabled = true
	n.log.size_flags_vertical = SIZE_EXPAND_FILL
	n.log.custom_minimum_size.y = 500
	n.log.add_theme_font_size_override("normal_font_size", 12)
	v.add_child(n.log)
	n.btn_log_clear = _btn(_buttons(v), "Clear")


func _tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 5)
	sc.add_child(v)
	return v


## An empty title is just the gap.
func _section(v: Control, title: String) -> void:
	if title == "":
		var sp := Control.new()
		sp.custom_minimum_size.y = 6
		v.add_child(sp)
		return
	var l := Label.new()
	l.text = title
	l.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	if v.get_child_count() > 0:
		var sp := Control.new()
		sp.custom_minimum_size.y = 6
		v.add_child(sp)
	v.add_child(l)


func _hint(v: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.62))
	v.add_child(l)
	return l


func _row(v: Control, text: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	v.add_child(h)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 84
	l.add_theme_color_override("font_color", Color(0.75, 0.75, 0.78))
	h.add_child(l)
	return h


func _buttons(v: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	v.add_child(h)
	return h


func _label(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	parent.add_child(l)
	return l


func _btn(parent: Control, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = FOCUS_NONE
	parent.add_child(b)
	return b


func _check(parent: Control, text: String, on: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.focus_mode = FOCUS_NONE
	parent.add_child(c)
	return c


func _option(parent: Control, items: Array) -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(str(it))
	o.size_flags_horizontal = SIZE_EXPAND_FILL
	o.focus_mode = FOCUS_NONE
	o.fit_to_longest_item = false
	o.clip_text = true
	parent.add_child(o)
	return o


func _fixed(o: Control, w: float) -> void:
	o.size_flags_horizontal = SIZE_SHRINK_BEGIN
	o.custom_minimum_size.x = w


func _spin(parent: Control, lo: float, hi: float, step: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.size_flags_horizontal = SIZE_EXPAND_FILL
	s.custom_minimum_size.x = 70
	parent.add_child(s)
	return s


func _slider(parent: Control, lo: float, hi: float, step: float, value: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.size_flags_horizontal = SIZE_EXPAND_FILL
	s.size_flags_vertical = SIZE_SHRINK_CENTER
	s.focus_mode = FOCUS_NONE
	parent.add_child(s)
	return s


func _line(parent: Control, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.size_flags_horizontal = SIZE_EXPAND_FILL
	parent.add_child(e)
	return e
