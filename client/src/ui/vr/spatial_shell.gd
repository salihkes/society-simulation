class_name SpatialShell
extends Control
## Behaviour of spatial_shell.tscn, the 2D face of the VR panel: pages, media browser, reader, photos, player and browser chrome.

const FLAGS := ["TUR", "GRC", "ITA", "DEU", "FRA", "GBR", "USA", "RUS"]
const GalaxyPlanetsScript := preload("res://src/world/galaxy/galaxy_planets.gd")

signal content_changed               # any visual change -> host re-renders
signal keyboard_focus(active: bool)  # a text field gained/lost focus

# The video is a composition layer over the player page; the PlaybackPill replaces the command pill.
signal player_closed
signal player_toggle
signal player_seek(ms: int)
signal player_volume_changed(linear: float)
signal player_cc_toggled(on: bool)
signal player_aspect_changed(fill: bool)
signal panel_pin_toggled(on: bool)

# vr_panel.gd owns the windows.
signal window_new
signal window_close
signal snap_toggled(on: bool)
signal player_track_menu           # the Tracks button was pressed
signal player_menu_visible(open: bool)   # the video steps aside meanwhile
signal player_track_chosen(kind: String, index: int)
signal player_screen_menu          # the Screen button (flat/180/360, 2D/3D)
signal player_screen_chosen(screen: int, layout: int)  # MediaProjection enums

# The shell owns the browser chrome; the host owns the WebView and its composition layer.
signal browse_navigate(url: String)
signal browse_open_file(path: String)      # a page saved on a drive
signal browse_open_archive(path: String)   # host starts the server for it
signal browse_back
signal browse_forward
signal browse_reload
signal browse_close
signal browse_touch(action: int, uv: Vector2)
signal browse_scroll(lines: int)
signal browse_type(text: String)
signal browse_key(code: int)
signal browse_zoom(delta: int)

var _player_open := false
var _seek_dragging := false
var _panel_rest := {}              # at-rest offsets of MainPanel and MainBox
var _track_menu: PopupMenu = null
var _screen_menu: PopupMenu = null
var _screen_sel := 0               # MediaProjection.Screen of the open video
var _layout_sel := 0               # MediaProjection.Layout of the open video
var _cursor_overlay: Control = null
var _laser_cursor := Vector2(-1000, -1000)   # off-screen = hidden

var chat_ui: Control = null
var _pages := {}          # "Chat" -> PageChat node, ...
var _rail_buttons := {}   # "Chat" -> rail Button
var browser := ShellBrowser.new(self)
var reader := ShellReader.new(self)

var _browse_window := Rect2()


func _ready() -> void:
	for page in %Pages.get_children():
		_pages[String(page.name).trim_prefix("Page")] = page

	# The scene's layout is the at-rest state the player page returns to.
	for p in ["MainPanel", "MainPanel/MainBox"]:
		var n: Control = get_node(p)
		_panel_rest[p] = [n.offset_left, n.offset_top, n.offset_right, n.offset_bottom]

	for code in FLAGS:
		var b := Button.new()
		b.text = code
		b.custom_minimum_size = Vector2(120, 52)
		b.focus_mode = Control.FOCUS_NONE
		b.set_meta("flag", code)
		%FlagGrid.add_child(b)

	_wire_meta_buttons()
	_wire_account_and_reader()
	_wire_browser()
	_wire_photos_and_media()
	_wire_playback()
	_build_planet_grid()

	%CommandInput.text_submitted.connect(func(_t): _submit_pill())
	%SendButton.pressed.connect(_submit_pill)

	_wire_text_fields()
	_build_cursor_overlay()
	show_page("Chat")


## Wires every button by its metadata key ("page", "emotion", "dest", "transform", "flag").
func _wire_meta_buttons() -> void:
	for b in find_children("*", "Button", true, false):
		var btn := b as Button
		if btn.has_meta("page"):
			_rail_buttons[btn.get_meta("page")] = btn
			btn.pressed.connect(show_page.bind(String(btn.get_meta("page"))))
		elif btn.has_meta("emotion"):
			btn.pressed.connect(func(): _submit("/" + String(btn.get_meta("emotion"))))
		elif btn.has_meta("dest"):
			btn.pressed.connect(func(): _submit("/teleport " + String(btn.get_meta("dest"))))
		elif btn.has_meta("transform"):
			btn.pressed.connect(
					func(): _submit("/transform " + String(btn.get_meta("transform"))))
		elif btn.has_meta("flag"):
			btn.pressed.connect(func(): _submit("/countryball " + String(btn.get_meta("flag"))))
		btn.pressed.connect(func(): content_changed.emit())


func _wire_account_and_reader() -> void:
	%LoginButton.pressed.connect(func():
		if %UsernameField.text != "" and %PasswordField.text != "":
			_submit("/login %s %s" % [%UsernameField.text, %PasswordField.text]))
	%RegisterButton.pressed.connect(func():
		if %UsernameField.text != "" and %PasswordField.text != "":
			_submit("/register %s %s" % [%UsernameField.text, %PasswordField.text]))
	%LogoutButton.pressed.connect(func(): _submit("/logout"))
	%ApplyFlagButton.pressed.connect(func():
		if %FlagField.text != "":
			_submit("/countryball " + %FlagField.text))
	%MediaRefreshButton.pressed.connect(browser.rescan)
	%ReadBackButton.pressed.connect(reader.read_back)
	%ReadPrevButton.pressed.connect(func(): reader.step_document(-1))
	%ReadNextButton.pressed.connect(func(): reader.step_document(1))
	%ReadSmallerButton.pressed.connect(func(): reader.resize_text(-3))
	%ReadBiggerButton.pressed.connect(func(): reader.resize_text(3))
	%ReadText.meta_clicked.connect(reader.follow_link)
	%ReadSearch.text_submitted.connect(reader.search_archive)
	%ReadBrowseButton.pressed.connect(reader.browse_current)


## The chrome only forwards intent; the host shows the page.
func _wire_browser() -> void:
	%BrowseBackButton.pressed.connect(func(): browse_back.emit())
	%BrowseForwardButton.pressed.connect(func(): browse_forward.emit())
	# Reads "Stop" while loading; the host decides which the press means.
	%BrowseReloadButton.pressed.connect(func(): browse_reload.emit())
	%BrowseCloseButton.pressed.connect(func():
		browse_close.emit()
		show_page("Media"))
	%BrowseAddress.text_submitted.connect(func(t: String): browse_navigate.emit(t))
	%BrowseZoomOutButton.pressed.connect(func(): browse_zoom.emit(-20))
	%BrowseZoomInButton.pressed.connect(func(): browse_zoom.emit(20))
	# The type field takes the address field's place: another row would reflow the page and resize the picture.
	%BrowseKeysButton.toggled.connect(func(on: bool):
		%BrowseAddress.visible = not on
		for n in [%BrowseInput, %BrowseBackspaceButton, %BrowseEnterButton]:
			n.visible = on
		if on:
			%BrowseInput.grab_focus()
		content_changed.emit())
	%BrowseInput.text_submitted.connect(func(t: String):
		browse_type.emit(t)
		browse_key.emit(66)          # KEYCODE_ENTER
		%BrowseInput.text = "")
	%BrowseBackspaceButton.pressed.connect(func(): browse_key.emit(67))
	%BrowseEnterButton.pressed.connect(func(): browse_key.emit(66))
	%BrowseView.gui_input.connect(_on_browse_input)


func _wire_photos_and_media() -> void:
	%PhotoBackButton.pressed.connect(reader.photo_back)
	%PhotoGridButton.pressed.connect(reader.show_photo_grid)
	%PhotoPrevButton.pressed.connect(func(): reader.step_photo(-1))
	%PhotoNextButton.pressed.connect(func(): reader.step_photo(1))
	%PhotoSmallerButton.pressed.connect(func(): reader.zoom_photo(-160))
	%PhotoBiggerButton.pressed.connect(func(): reader.zoom_photo(160))
	%MediaSearch.text_changed.connect(browser.set_filter)
	%MediaSearch.text_submitted.connect(browser.deep_search)
	%MediaVRButton.toggled.connect(browser.set_vr_filter)
	%MediaPauseButton.pressed.connect(func(): _submit("/media pause"))
	%MediaResumeButton.pressed.connect(func(): _submit("/media resume"))
	%MediaStopButton.pressed.connect(func(): _submit("/media stop"))


func _wire_playback() -> void:
	%PlaybackBackButton.pressed.connect(close_player_page)
	%PlayPauseButton.pressed.connect(func(): player_toggle.emit())
	%CCButton.toggled.connect(func(on): player_cc_toggled.emit(on))
	%PinButton.toggled.connect(_set_pin)
	%PinPillButton.toggled.connect(_set_pin)
	%NewWindowButton.pressed.connect(func(): window_new.emit())
	%CloseWindowButton.pressed.connect(func(): window_close.emit())
	%SnapButton.toggled.connect(func(on: bool): snap_toggled.emit(on))
	%AudioButton.pressed.connect(func(): player_track_menu.emit())
	%ScreenButton.pressed.connect(func(): player_screen_menu.emit())
	%AspectButton.pressed.connect(func():
		var fill: bool = %AspectButton.text == "Fit"
		%AspectButton.text = "Fill" if fill else "Fit"
		player_aspect_changed.emit(fill))
	%VolumeSlider.value_changed.connect(func(v): player_volume_changed.emit(v / 100.0))
	%SeekSlider.drag_started.connect(func(): _seek_dragging = true)
	%SeekSlider.drag_ended.connect(func(changed):
		_seek_dragging = false
		if changed:
			player_seek.emit(int(%SeekSlider.value)))


func _build_planet_grid() -> void:
	for rid in GalaxyPlanetsScript.PLANETS:
		var b := Button.new()
		b.text = str(GalaxyPlanetsScript.PLANETS[rid].get("name", rid))
		b.custom_minimum_size = Vector2(200, 56)
		b.focus_mode = Control.FOCUS_NONE
		var planet_rid := String(rid)
		b.pressed.connect(func(): _submit("/travel " + planet_rid))
		%PlanetGrid.add_child(b)


## Every LineEdit opens the OS keyboard and reports its focus to the host.
func _wire_text_fields() -> void:
	for le in find_children("*", "LineEdit", true, false):
		var field := le as LineEdit
		field.focus_entered.connect(func():
			keyboard_focus.emit(true)
			DisplayServer.virtual_keyboard_show(field.text)
			content_changed.emit())
		field.focus_exited.connect(func():
			keyboard_focus.emit(false)
			DisplayServer.virtual_keyboard_hide()
			content_changed.emit())
		field.text_changed.connect(func(_t): content_changed.emit())


## For when immersive video covers the laser.
func _build_cursor_overlay() -> void:
	_cursor_overlay = Control.new()
	_cursor_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cursor_overlay.draw.connect(func():
		if _laser_cursor.x > -100.0:
			_cursor_overlay.draw_circle(_laser_cursor, 10.0, Color(0, 0, 0, 0.55))
			_cursor_overlay.draw_circle(_laser_cursor, 6.5, Color(1, 1, 1, 0.95)))
	add_child(_cursor_overlay)


## Its own input row is hidden in favour of the command pill.
func dock_chat_ui(ui: Control, ui_scale: float) -> void:
	chat_ui = ui
	var input_row := ui.get_node_or_null("VBoxContainer/InputContainer")
	if input_row:
		input_row.visible = false
	%ChatDock.add_child(ui)
	var fit := func():
		ui.position = Vector2.ZERO
		ui.size = %ChatDock.size / ui_scale
		ui.scale = Vector2(ui_scale, ui_scale)
	%ChatDock.resized.connect(fit)
	fit.call()
	_refresh_status()


## Keeps both Pin buttons in step and tells the host.
func _set_pin(on: bool) -> void:
	%PinButton.set_pressed_no_signal(on)
	%PinPillButton.set_pressed_no_signal(on)
	panel_pin_toggled.emit(on)
	content_changed.emit()


## Does not re-emit the command.
func set_snap(on: bool) -> void:
	%SnapButton.set_pressed_no_signal(on)
	content_changed.emit()


func _submit_pill() -> void:
	var text: String = %CommandInput.text.strip_edges()
	if text == "":
		return
	%CommandInput.text = ""
	_submit(text)


func _submit(cmd: String) -> void:
	if chat_ui and chat_ui.has_method("submit_text"):
		chat_ui.submit_text(cmd)
	_refresh_status()
	content_changed.emit()


## Leaving the player stops playback.
func show_page(page_name: String) -> void:
	for n in _pages:
		_pages[n].visible = (n == page_name)
	for n in _rail_buttons:
		_rail_buttons[n].button_pressed = (n == page_name)
	var was_player := _player_open
	_player_open = (page_name == "Player")
	if was_player and not _player_open:
		player_closed.emit()
	_set_cinema_layout(_player_open)
	if page_name == "Media":
		browser.refresh()
	_refresh_status()
	content_changed.emit()


## On the player page the page reaches the panel's edges; off it the at-rest layout returns.
func _set_cinema_layout(on: bool) -> void:
	for path in ["MainPanel/MainBox/Header", "MainPanel/MainBox/HSep", "CommandPill"]:
		var node := get_node_or_null(path)
		if node:
			node.visible = not on
	var play_pill := get_node_or_null("PlaybackPill")
	if play_pill:
		play_pill.visible = on
	if on:
		var main_box: Control = get_node("MainPanel/MainBox")
		main_box.offset_left = 0.0
		main_box.offset_top = 0.0
		main_box.offset_right = 0.0
		main_box.offset_bottom = 0.0
		return
	for p in _panel_rest:
		var n: Control = get_node(p)
		var o: Array = _panel_rest[p]
		n.offset_left = o[0]
		n.offset_top = o[1]
		n.offset_right = o[2]
		n.offset_bottom = o[3]


## Dark until the video arrives.
func show_player(title: String) -> void:
	%PlayerHint.text = title
	%PlayerSubtitle.text = ""
	%TimeLabel.text = "0:00 / 0:00"
	%SeekSlider.set_value_no_signal(0.0)
	%PlayPauseButton.text = "Pause"
	var page: Control = _pages.get("Player")
	if page:
		page.hole_rect = Rect2()
	show_page("Player")


func close_player_page() -> void:
	show_page("Media")


func is_player_open() -> bool:
	return _player_open


func set_player_hint(text: String) -> void:
	%PlayerHint.text = text
	content_changed.emit()


func player_volume() -> float:
	return %VolumeSlider.value / 100.0

## Height-limited, width from the aspect, shrunk to fit; reserve_bottom adds a strip below the picture.
func set_player_aspect(aspect: float, reserve_bottom: float) -> void:
	if not _player_open or aspect <= 0.0:
		return
	var panel: Control = get_node("MainPanel")
	var base: Array = _panel_rest["MainPanel"]
	var avail_pos := Vector2(base[0], base[1])
	var avail_size := Vector2(size.x + base[2], size.y + base[3]) - avail_pos
	var h: float = minf(avail_size.y - reserve_bottom, avail_size.x / aspect)
	var w: float = h * aspect
	var c := avail_pos + avail_size * 0.5
	var pos := Vector2(c.x - w * 0.5, c.y - (h + reserve_bottom) * 0.5)
	if Rect2(pos, Vector2(w, h + reserve_bottom)).is_equal_approx(
			Rect2(panel.position, panel.size)):
		return
	panel.offset_left = pos.x
	panel.offset_top = pos.y
	panel.offset_right = pos.x + w - size.x
	panel.offset_bottom = pos.y + h + reserve_bottom - size.y
	content_changed.emit()

## Shell pixels; the host fits the video into it.
func video_area_rect() -> Rect2:
	var page: Control = _pages.get("Player")
	return page.get_global_rect() if page else Rect2()


## Shell pixels; the page darkens the rest.
func set_video_hole(shell_rect: Rect2) -> void:
	var page: Control = _pages.get("Player")
	if page:
		page.hole_rect = Rect2(shell_rect.position - page.get_global_rect().position,
				shell_rect.size)
		%PlayerHint.text = ""
	content_changed.emit()


func set_player_cc_available(available: bool) -> void:
	%CCButton.visible = available

## An empty label hides it.
func set_player_audio_label(label: String) -> void:
	%AudioButton.visible = not label.is_empty()
	%AudioButton.text = label
	content_changed.emit()


const TEXT_ID_BASE := 1000
const TEXT_OFF_ID := 999

## The SubViewport embeds subwindows, so the laser can click the PopupMenu.
func show_track_menu(audio: Array, texts: Array, audio_selected: int,
		text_selected: int) -> void:
	if _track_menu == null:
		_track_menu = _new_player_menu(_on_track_menu_id)
	_track_menu.clear()
	if not audio.is_empty():
		_track_menu.add_separator("Audio")
		for t in audio:
			_add_radio(_track_menu, _track_label(t), int(t.index), int(t.index) == audio_selected)
	if not texts.is_empty():
		_track_menu.add_separator("Subtitles")
		_add_radio(_track_menu, "Off", TEXT_OFF_ID, text_selected < 0)
		for t in texts:
			_add_radio(_track_menu, _track_label(t), TEXT_ID_BASE + int(t.index),
					int(t.index) == text_selected)
	if _track_menu.get_item_count() == 0:
		_track_menu.add_item("No selectable tracks", -1)
		_track_menu.set_item_disabled(_track_menu.get_item_count() - 1, true)
	_popup_below(_track_menu, %AudioButton)


## The video composites over the panel, so the host hides it while the menu is open.
func _new_player_menu(on_id: Callable) -> PopupMenu:
	var menu := PopupMenu.new()
	menu.theme = theme
	menu.id_pressed.connect(on_id)
	menu.visibility_changed.connect(func():
		player_menu_visible.emit(menu.visible)
		content_changed.emit())
	add_child(menu)
	return menu


func _add_radio(menu: PopupMenu, label: String, id: int, checked: bool) -> void:
	menu.add_radio_check_item(label, id)
	menu.set_item_checked(menu.get_item_count() - 1, checked)


## Moved up only as far as it must to stay on the panel.
func _popup_below(menu: PopupMenu, anchor: Control) -> void:
	var button_rect: Rect2 = anchor.get_global_rect()
	menu.reset_size()
	var menu_size: Vector2 = menu.size
	var pos := Vector2(button_rect.position.x, button_rect.end.y + 6.0)
	pos.y = minf(pos.y, size.y - menu_size.y - 12.0)
	pos.x = clampf(pos.x, 12.0, maxf(size.x - menu_size.x - 12.0, 12.0))
	menu.popup(Rect2i(Vector2i(pos), Vector2i(menu_size)))
	content_changed.emit()


func _track_label(t: Dictionary) -> String:
	var bits: Array[String] = []
	var lang := str(t.get("language", ""))
	if not lang.is_empty():
		bits.append(lang)
	var mime := str(t.get("mime", ""))
	if not mime.is_empty():
		bits.append(mime.trim_prefix("audio/").trim_prefix("application/x-").trim_prefix("text/"))
	if bits.is_empty():
		bits.append("track %d" % int(t.get("index", 0)))
	return "  ".join(bits)


## "Off" is index -1.
func _on_track_menu_id(id: int) -> void:
	if id == TEXT_OFF_ID:
		player_track_chosen.emit("text", -1)
	elif id >= TEXT_ID_BASE:
		player_track_chosen.emit("text", id - TEXT_ID_BASE)
	elif id >= 0:
		player_track_chosen.emit("audio", id)
	content_changed.emit()


const SCREEN_ID_BASE := 2000
const LAYOUT_ID_BASE := 2100
const MediaProjectionScript := preload("res://src/media/media_projection.gd")

func set_player_screen_label(text: String) -> void:
	%ScreenButton.text = text
	content_changed.emit()


## Overrides what was detected for this video.
func show_screen_menu(screen: int, layout: int) -> void:
	if _screen_menu == null:
		_screen_menu = _new_player_menu(_on_screen_menu_id)
	_screen_sel = screen
	_layout_sel = layout
	_screen_menu.clear()
	_screen_menu.add_separator("Screen")
	for entry in [[MediaProjectionScript.Screen.FLAT, "Flat"],
			[MediaProjectionScript.Screen.DOME180, "180° dome"],
			[MediaProjectionScript.Screen.SPHERE360, "360° sphere"]]:
		_add_radio(_screen_menu, entry[1], SCREEN_ID_BASE + int(entry[0]), int(entry[0]) == screen)
	_screen_menu.add_separator("3D")
	for entry in [[MediaProjectionScript.Layout.MONO, "2D"],
			[MediaProjectionScript.Layout.SBS, "3D side-by-side"],
			[MediaProjectionScript.Layout.TB, "3D top-bottom"]]:
		_add_radio(_screen_menu, entry[1], LAYOUT_ID_BASE + int(entry[0]), int(entry[0]) == layout)
	_popup_below(_screen_menu, %ScreenButton)


## A separator does nothing.
func _on_screen_menu_id(id: int) -> void:
	if id >= LAYOUT_ID_BASE:
		_layout_sel = id - LAYOUT_ID_BASE
	elif id >= SCREEN_ID_BASE:
		_screen_sel = id - SCREEN_ID_BASE
	else:
		return
	player_screen_chosen.emit(_screen_sel, _layout_sel)
	content_changed.emit()

## Off-screen hides it; an unchanged position does not redraw.
func set_laser_cursor(pos: Vector2) -> void:
	if _cursor_overlay == null or pos.is_equal_approx(_laser_cursor):
		return
	_laser_cursor = pos
	_cursor_overlay.queue_redraw()
	content_changed.emit()


func set_subtitle(text: String) -> void:
	if %PlayerSubtitle.text != text:
		%PlayerSubtitle.text = text
		content_changed.emit()


## Not while the seek bar is being dragged.
func update_player_time(pos_ms: int, dur_ms: int, playing: bool) -> void:
	if not _seek_dragging:
		%SeekSlider.max_value = maxf(float(dur_ms), 1.0)
		%SeekSlider.set_value_no_signal(float(pos_ms))
	%TimeLabel.text = "%s / %s" % [_fmt_time(pos_ms), _fmt_time(dur_ms)]
	%PlayPauseButton.text = "Pause" if playing else "Play"
	content_changed.emit()


func _fmt_time(ms: int) -> String:
	var s := int(ms / 1000.0)
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, (s % 3600) / 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]


func _refresh_status() -> void:
	var auth = get_node_or_null("/root/AuthManager")
	if auth == null:
		return
	var logged := false
	if auth.has_method("is_logged_in"):
		logged = auth.is_logged_in()
	var uname = auth.get("current_username")
	%Status.text = ("%s" % uname) if (logged and uname) else "not logged in"


## Shell-viewport pixels.
func browse_area_rect() -> Rect2:
	var view: Control = get_node_or_null("MainPanel/MainBox/Pages/PageBrowse/BrowseView")
	return view.get_global_rect() if view else Rect2()


func is_browse_open() -> bool:
	var page = _pages.get("Browse", null)
	return page != null and page.visible


## So taps map onto the page.
func set_browse_window(shell_rect: Rect2) -> void:
	_browse_window = shell_rect
	%BrowseHint.visible = shell_rect.size.x < 2.0


## Shows the url, and the page title and progress in the header.
func set_browse_status(page_title: String, url: String, loading: bool, progress: int) -> void:
	if not %BrowseAddress.has_focus():
		%BrowseAddress.text = url
	var label := page_title if not page_title.is_empty() else "Browser"
	if loading:
		label = "%s   %d%%" % [label, progress]
	%Status.text = label
	%BrowseReloadButton.text = "Stop" if loading else "Reload"
	content_changed.emit()


## The Type field follows, unless an address is being typed.
func set_browse_typing(on: bool) -> void:
	if %BrowseAddress.has_focus() or %BrowseKeysButton.button_pressed == on:
		return
	%BrowseKeysButton.button_pressed = on      # its handler does the swap


func show_browser(url := "") -> void:
	show_page("Browse")
	if not url.is_empty():
		%BrowseAddress.text = url
		browse_navigate.emit(url)


## Mouse events on the picture become touches and scrolls on the page.
func _on_browse_input(event: InputEvent) -> void:
	if _browse_window.size.x < 2.0:
		return
	var origin: Vector2 = %BrowseView.get_global_rect().position
	if event is InputEventMouseButton:
		_on_browse_button(event, origin)
	elif event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			browse_touch.emit(2, _browse_uv(origin + event.position))


## Touch actions: 0 down, 1 up, 2 move.
func _on_browse_button(event: InputEventMouseButton, origin: Vector2) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				browse_scroll.emit(-1)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				browse_scroll.emit(1)
		MOUSE_BUTTON_LEFT:
			browse_touch.emit(0 if event.pressed else 1,
				_browse_uv(origin + event.position))


func _browse_uv(global_pos: Vector2) -> Vector2:
	var local := global_pos - _browse_window.position
	return Vector2(
		clampf(local.x / _browse_window.size.x, 0.0, 1.0),
		clampf(local.y / _browse_window.size.y, 0.0, 1.0))


func _process(_delta: float) -> void:
	reader.take_thumbs()


func _exit_tree() -> void:
	reader.stop_thumbs()
