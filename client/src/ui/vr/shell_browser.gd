class_name ShellBrowser
extends RefCounted
## The shell's media page: locations, folders, archives on the shelf, and the deep and VR searches.

const MediaCommandsScript := preload("res://src/media/media_commands.gd")
const MediaCatalogScript := preload("res://src/media/media_catalog.gd")
const MediaProjectionScript := preload("res://src/media/media_projection.gd")
const ZimScript := preload("res://src/library/zim.gd")
const ZimShelfScript := preload("res://src/library/zim_shelf.gd")
const PhotoAlbumScript := preload("res://src/library/photo_album.gd")

const ROWS_PER_PAGE := 60
# Bounds of the folder walks, so a deep drive cannot hold the frame.
const DEEP_MAX_DIRS := 4000
const DEEP_MAX_HITS := 300
const DEEP_BUDGET_MS := 400

var _shell: SpatialShell = null
# "" is the locations overview; _media_root is the location entered, where ".." stops.
var _media_cwd := ""
var _media_root := ""
## "" when browsing ordinary folders.
var _zim_path := ""
## "" = the entity list.
var _zim_entity := ""
var _zim_entity_name := ""
var _media_filter := ""
## Empty when browsing.
var _deep_hits: Array[Dictionary] = []
var _deep_query := ""
var _deep_truncated := false
## Lists every 360/180/3D video under the current location (all drives from the overview).
var _vr_filter := false
var _vr_hits: Array[Dictionary] = []
var _vr_truncated := false


func _init(shell: SpatialShell) -> void:
	_shell = shell


func _ui(unique_name: String) -> Node:
	return _shell.get_node("%" + unique_name)


func refresh() -> void:
	for child in _ui("MediaList").get_children():
		_ui("MediaList").remove_child(child)
		child.queue_free()
	if not MediaCommandsScript.has_all_files_access():
		_media_button("Grant storage access  (opens system settings)", func():
			MediaCommandsScript.open_all_files_access_settings())
	if not _zim_path.is_empty():
		_list_zim()
	elif not _deep_hits.is_empty():
		_list_deep_hits()
	elif _vr_filter:
		_list_vr_hits()
	elif _media_cwd.is_empty():
		_list_locations()
	else:
		_list_folder()
	_shell.content_changed.emit()


## The Refresh button: walks the VR videos again when that list is up.
func rescan() -> void:
	if _vr_filter:
		_scan_vr_files()
	refresh()


## Typing filters the folder shown.
func set_filter(text: String) -> void:
	_media_filter = text
	_deep_hits.clear()
	_deep_query = ""
	refresh()


func set_vr_filter(on: bool) -> void:
	_vr_filter = on
	_vr_hits.clear()
	if on:
		_deep_hits.clear()
		_deep_query = ""
		_scan_vr_files()
	refresh()


## A drive or library root, which ".." will not leave.
func enter_location(path: String) -> void:
	_media_cwd = path
	_media_root = path
	refresh()


func _list_locations() -> void:
	_ui("MediaTitle").text = "Library Media"
	var roots: Array[Dictionary] = MediaCommandsScript.media_roots(_shell)
	if roots.is_empty():
		var empty := Label.new()
		empty.text = "No media locations — plug in a library drive."
		_ui("MediaList").add_child(empty)
	for root in roots:
		var path: String = root.path
		_media_button(String(root.label) + "  /", func(): enter_location(path))


func _list_folder() -> void:
	_ui("MediaTitle").text = "Library Media — %s/" % _media_cwd.get_file()
	_media_button("..", func():
		_media_cwd = "" if _media_cwd == _media_root else _media_cwd.get_base_dir()
		refresh())
	var listing: Dictionary = MediaCatalogScript.list_dir(_media_cwd)
	var needle := _media_filter.to_lower()
	# Pictures get one row: a photo folder can hold thousands.
	var pictures: int = PhotoAlbumScript.count_in(_media_cwd)
	if pictures > 0 and needle.is_empty():
		var here := _media_cwd
		_media_button("Photos   —   %d picture%s" % [pictures,
			"" if pictures == 1 else "s"], func(): _shell.reader.open_album(here))
	for d in listing.dirs:
		if not needle.is_empty() and not String(d.name).to_lower().contains(needle):
			continue
		var path: String = d.path
		_media_button(String(d.name) + "  /", func():
			_media_cwd = path
			refresh())
	for f in listing.files:
		if needle.is_empty() or String(f.title).to_lower().contains(needle):
			_add_file_row(f)
	if listing.dirs.is_empty() and listing.files.is_empty():
		var none := Label.new()
		none.text = "(empty folder)"
		_ui("MediaList").add_child(none)
	elif not needle.is_empty() and _ui("MediaList").get_child_count() <= 1:
		var none := Label.new()
		none.text = "Nothing here matches \"%s\".  Press Enter to search the folders below it." \
				% _media_filter
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_ui("MediaList").add_child(none)


## Archives open in the shelf or browser, saved pages in the browser, documents in the reader, media in the player.
func _add_file_row(f: Dictionary) -> void:
	var source: String = f.source
	var title: String = f.title
	match String(f.kind):
		"archive":
			_add_archive_row(title, source)
		"page":
			_media_button("%s   [%s]" % [title, f.ext], func():
				_shell.show_page("Browse")
				_shell.browse_open_file.emit(source))
		"document":
			var doc := _media_button("%s   [%s]" % [title, f.ext], func():
				_shell.reader.open_document(source))
			doc.disabled = not f.playable
		_:
			var b := _media_button("%s   [%s]%s" % [title, f.kind,
					"" if f.playable else "  (not playable here)"], func():
				if _shell.chat_ui:
					MediaCommandsScript.play_path(source, title, _shell.chat_ui))
			b.disabled = not f.playable


func _add_archive_row(title: String, source: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_ui("MediaList").add_child(row)
	var open_btn := Button.new()
	open_btn.text = "%s   [archive]" % title
	open_btn.custom_minimum_size = Vector2(0, 56)
	open_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	open_btn.focus_mode = Control.FOCUS_NONE
	open_btn.pressed.connect(func():
		_zim_entity = ""
		_open_archive(source))
	row.add_child(open_btn)
	var web_btn := Button.new()
	web_btn.text = "Browse"
	web_btn.custom_minimum_size = Vector2(120, 56)
	web_btn.focus_mode = Control.FOCUS_NONE
	web_btn.pressed.connect(func():
		_shell.show_page("Browse")
		_shell.browse_open_archive.emit(source))
	row.add_child(web_btn)


## Enter in the search box: walks the folders below this one.
func deep_search(query: String) -> void:
	_deep_hits.clear()
	_deep_truncated = false
	var needle := query.strip_edges().to_lower()
	if not _zim_path.is_empty():
		refresh()      # inside an archive the box is a filter, not a walk
		return
	if needle.length() < 2 or _media_cwd.is_empty():
		refresh()
		return
	_deep_query = query.strip_edges()
	var queue: Array[String] = [_media_cwd]
	var visited := 0
	var started := Time.get_ticks_msec()
	while not queue.is_empty():
		if visited >= DEEP_MAX_DIRS or _deep_hits.size() >= DEEP_MAX_HITS \
				or Time.get_ticks_msec() - started > DEEP_BUDGET_MS:
			_deep_truncated = true
			break
		var dir: String = queue.pop_front()
		visited += 1
		var listing: Dictionary = MediaCatalogScript.list_dir(dir)
		for d in listing.dirs:
			queue.append(String(d.path))
			if String(d.name).to_lower().contains(needle):
				_deep_hits.append({"folder": true, "title": String(d.name),
					"source": String(d.path), "kind": "folder", "ext": "",
					"playable": true})
		for f in listing.files:
			if String(f.title).to_lower().contains(needle):
				var hit: Dictionary = {"folder": false}
				hit.merge(f)
				_deep_hits.append(hit)
		# list_dir leaves pictures out, so they are matched here.
		for file in DirAccess.get_files_at(dir):
			var name := String(file)
			if name.begins_with(".") or not name.to_lower().contains(needle):
				continue
			if PhotoAlbumScript.EXTS.has(name.get_extension().to_lower()):
				_deep_hits.append({"folder": false, "title": name.get_basename(),
					"source": dir.path_join(name), "kind": "photo",
					"ext": name.get_extension().to_lower(), "playable": true})
	refresh()


func _list_deep_hits() -> void:
	var suffix := "  (stopped early — narrow it down)" if _deep_truncated else ""
	_ui("MediaTitle").text = "%d matches for \"%s\" under %s/%s" % [_deep_hits.size(),
		_deep_query, _media_cwd.get_file(), suffix]
	_media_button("..  back to %s/" % _media_cwd.get_file(), func():
		_deep_hits.clear()
		_deep_query = ""
		_ui("MediaSearch").text = ""
		_media_filter = ""
		refresh())
	for hit in _deep_hits:
		var source: String = str(hit.source)
		var title: String = str(hit.title)
		var label := _hit_label(title, source, _media_cwd)
		if bool(hit.folder):
			_media_button(label + "  /", func():
				_deep_hits.clear()
				_deep_query = ""
				_media_cwd = source
				refresh())
			continue
		if str(hit.kind) == "archive":
			_media_button("%s   [archive]" % label, func():
				_deep_hits.clear()
				_zim_entity = ""
				_open_archive(source))
			continue
		if str(hit.kind) == "photo":
			_media_button("%s   [%s]" % [label, hit.ext], func():
				_deep_hits.clear()
				_shell.reader.open_album_at(source))
			continue
		if str(hit.kind) == "page":
			_media_button("%s   [%s]" % [label, hit.ext], func():
				_shell.show_page("Browse")
				_shell.browse_open_file.emit(source))
			continue
		if str(hit.kind) == "document":
			var doc := _media_button("%s   [%s]" % [label, hit.ext], func():
				_shell.reader.open_document(source))
			doc.disabled = not bool(hit.playable)
			continue
		var b := _media_button("%s   [%s]" % [label, hit.kind], func():
			if _shell.chat_ui:
				MediaCommandsScript.play_path(source, title, _shell.chat_ui))
		b.disabled = not bool(hit.playable)


## Videos whose names say 360, 180 or 3D; from the overview it walks every location.
func _scan_vr_files() -> void:
	_vr_hits.clear()
	_vr_truncated = false
	var queue: Array[String] = []
	if _media_cwd.is_empty():
		for root in MediaCommandsScript.media_roots(_shell):
			queue.append(String(root.path))
	else:
		queue.append(_media_cwd)
	var visited := 0
	var started := Time.get_ticks_msec()
	while not queue.is_empty():
		if visited >= DEEP_MAX_DIRS or _vr_hits.size() >= DEEP_MAX_HITS \
				or Time.get_ticks_msec() - started > DEEP_BUDGET_MS:
			_vr_truncated = true
			break
		var dir: String = queue.pop_front()
		visited += 1
		var listing: Dictionary = MediaCatalogScript.list_dir(dir)
		for d in listing.dirs:
			queue.append(String(d.path))
		for f in listing.files:
			if String(f.kind) != "video" and String(f.kind) != "stream":
				continue
			var det: Dictionary = MediaProjectionScript.detect(String(f.source))
			if int(det.screen) == MediaProjectionScript.Screen.FLAT \
					and int(det.layout) == MediaProjectionScript.Layout.MONO:
				continue
			var hit: Dictionary = {"vr_label": MediaProjectionScript.label(
				int(det.screen), int(det.layout))}
			hit.merge(f)
			_vr_hits.append(hit)


static func _hit_label(title: String, source: String, base: String) -> String:
	var where: String = source.get_base_dir().trim_prefix(base).trim_prefix("/")
	return title if where.is_empty() else "%s      %s" % [title, where]


func _list_vr_hits() -> void:
	var where_name := "all drives" if _media_cwd.is_empty() else _media_cwd.get_file() + "/"
	var suffix := "  (stopped early — go into a folder and press VR again)" \
			if _vr_truncated else ""
	_ui("MediaTitle").text = "%d VR video%s under %s%s" % [_vr_hits.size(),
		"" if _vr_hits.size() == 1 else "s", where_name, suffix]
	_media_button("..  back to %s" % where_name, func():
		_ui("MediaVRButton").set_pressed_no_signal(false)
		_vr_filter = false
		_vr_hits.clear()
		refresh())
	var needle := _media_filter.to_lower()
	var shown := 0
	var base := _media_cwd
	for hit in _vr_hits:
		var title: String = str(hit.title)
		if not needle.is_empty() and not title.to_lower().contains(needle):
			continue
		shown += 1
		var source: String = str(hit.source)
		var label := _hit_label(title, source, base)
		var b := _media_button("%s   [%s]" % [label, hit.vr_label], func():
			if _shell.chat_ui:
				MediaCommandsScript.play_path(source, title, _shell.chat_ui))
		b.disabled = not bool(hit.playable)
	if shown == 0:
		var none := Label.new()
		none.text = ("No 360/180/3D video found here." if needle.is_empty()
			else "No VR video here matches \"%s\"." % _media_filter)
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_ui("MediaList").add_child(none)


## A press also redraws.
func _media_button(label: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 56)
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = label
	b.pressed.connect(func():
		on_pressed.call()
		_shell.content_changed.emit())
	_ui("MediaList").add_child(b)
	return b


## Items play in place by byte range.
func _list_zim() -> void:
	var z = ZimScript.open(_zim_path)
	if z == null:
		var bad := Label.new()
		bad.text = "Could not open this archive."
		_ui("MediaList").add_child(bad)
		return
	var archive_path := _zim_path
	if _zim_entity.is_empty():
		_list_zim_entities(z, archive_path)
	else:
		_list_zim_items(z, archive_path)
	z.close()


func _list_zim_entities(z, archive_path: String) -> void:
	_ui("MediaTitle").text = _zim_path.get_file()
	_media_button("..", func():
		_zim_path = ""
		refresh())
	var people: Array[Dictionary] = ZimShelfScript.entities(z)
	if people.is_empty():
		_list_zim_items(z, archive_path)   # archive groups by nothing
		return
	_media_button("Everything   (%d items)" % ZimShelfScript.items(z).size(), func():
		_zim_entity = "*"
		_zim_entity_name = "Everything"
		refresh())
	for who in people:
		var id := str(who.id)
		var name := str(who.name)
		var b := _media_button("%s\n%s" % [name, str(who.detail)], func():
			_zim_entity = id
			_zim_entity_name = name
			refresh())
		b.icon = ZimShelfScript.texture(z, str(who.avatar))
		b.expand_icon = true
		b.custom_minimum_size = Vector2(0, 96)


func _list_zim_items(z, archive_path: String) -> void:
	var scope := "" if _zim_entity == "*" or _zim_entity.is_empty() else _zim_entity
	_ui("MediaTitle").text = "%s — %s" % [_zim_path.get_file(),
			_zim_entity_name if not _zim_entity_name.is_empty() else "all"]
	_media_button("..", func():
		_zim_entity = ""
		_zim_entity_name = ""
		refresh())
	var all: Array[Dictionary] = ZimShelfScript.items(z, scope)
	if not _media_filter.is_empty():
		var needle := _media_filter.to_lower()
		var kept: Array[Dictionary] = []
		for it in all:
			if (str(it.title) + " " + str(it.detail)).to_lower().contains(needle):
				kept.append(it)
		all = kept
	var shown: int = mini(all.size(), ROWS_PER_PAGE)
	for i in shown:
		var item: Dictionary = all[i]
		var media_path := str(item.media)
		var range_info: Dictionary = z.file_range(media_path) \
				if not media_path.is_empty() else {}
		var cues = ZimShelfScript.subtitle_cues(z, item) \
				if String(item.kind) == "video" else null
		var b := _media_button("%s\n%s" % [str(item.title), str(item.detail)], func():
			var chat: Control = _shell.chat_ui
			if chat and chat.has_method("play_zim_media"):
				chat.play_zim_media(archive_path, range_info, str(item.title), cues))
		b.icon = ZimShelfScript.texture(z, str(item.thumb))
		b.expand_icon = true
		b.custom_minimum_size = Vector2(0, 96)
		b.disabled = range_info.is_empty() or String(item.kind) != "video"
	if all.size() > shown:
		var more := Label.new()
		more.text = "showing %d of %d — search is not built yet" % [shown, all.size()]
		more.modulate = Color(1, 1, 1, 0.6)
		_ui("MediaList").add_child(more)


func _open_archive(source: String) -> void:
	var z = ZimScript.open(source)
	if z == null:
		return
	var article: bool = z.kind() == ZimScript.Kind.ARTICLE
	z.close()
	if article:
		_shell.reader.open_document(source)
	else:
		_zim_path = source
		refresh()
