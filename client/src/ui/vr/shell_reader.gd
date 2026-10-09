class_name ShellReader
extends RefCounted
## The shell's readers: text, EPUB chapters, comic and PDF pages, ZIM articles, and photo albums.

const ZimScript := preload("res://src/library/zim.gd")
const EpubScript := preload("res://src/library/epub.gd")
const PdfScript := preload("res://src/library/pdf.gd")
const ComicScript := preload("res://src/library/comic.gd")
const ReadingStateScript := preload("res://src/library/reading_state.gd")
const FullTextScript := preload("res://src/library/full_text.gd")
const PhotoAlbumScript := preload("res://src/library/photo_album.gd")

const IMAGE_CACHE := "user://zim_images"
const MAX_ARTICLE_IMAGES := 12
const PHOTOS_PER_PAGE := 40
const THUMB_BOX := Vector2(180, 180)
const THUMB_WORKERS := 2

var _shell: SpatialShell = null
var _doc_kind := ""        ## "" | "txt" | "epub" | "pdf" | "cbz" | "zim"
var _doc_path := ""
var _epub = null
var _read_zim = null
## Null unless the archive has a Xapian index this build can read.
var _full_text = null
var _doc_index := 0
var _zim_trail: Array[String] = []   ## visited entry urls, for Back
var _read_size := 26
var _pdf = null
var _comic = null
## Shell pixels.
var _page_zoom := 900
## The resource cache holds the article's pictures only weakly.
var _image_refs: Array[Texture2D] = []

var _album = null
var _photo_index := 0
var _photo_page := 0
var _photo_zoom := 900
var _photo_full := false
## Thumbnails decode on worker threads; the main thread only makes textures of them.
var _photo_slots: Dictionary = {}
var _thumb_threads: Array[Thread] = []
var _thumb_lock := Mutex.new()
var _thumb_wanted: Array[int] = []      ## guarded by _thumb_lock
var _thumb_ready: Array = []            ## guarded by _thumb_lock
var _thumb_running := false


func _init(shell: SpatialShell) -> void:
	_shell = shell


func _ui(unique_name: String) -> Node:
	return _shell.get_node("%" + unique_name)


## At the remembered place.
func open_document(path: String) -> void:
	_close_document()
	_doc_path = path
	match path.get_extension().to_lower():
		"epub":
			_open_epub(path)
		"cbz":
			_open_comic(path)
		"pdf":
			_open_pdf(path)
		"zim":
			_open_zim_document(path)
		_:
			_open_text(path)


func _open_epub(path: String) -> void:
	_epub = EpubScript.open(path)
	if _epub == null:
		_show_read(path.get_file(), "This EPUB could not be opened.")
		return
	_doc_kind = "epub"
	_doc_index = clampi(int(ReadingStateScript.recall(path, 0)), 0,
		maxi(_epub.chapters.size() - 1, 0))
	_show_chapter()


func _open_comic(path: String) -> void:
	_comic = ComicScript.open(path)
	if _comic.page_count() <= 0:
		_show_read(path.get_file(), str(_comic.error))
		_comic = null
		return
	_doc_kind = "cbz"
	_doc_index = clampi(int(ReadingStateScript.recall(path, 0)), 0,
		_comic.page_count() - 1)
	_show_comic_page()


func _open_pdf(path: String) -> void:
	_pdf = PdfScript.open(path)
	if _pdf.page_count <= 0:
		_show_read(path.get_file(), str(_pdf.error))
		_pdf = null
		return
	_doc_kind = "pdf"
	_doc_index = clampi(int(ReadingStateScript.recall(path, 0)), 0,
		_pdf.page_count - 1)
	_show_pdf_page()


func _open_zim_document(path: String) -> void:
	_read_zim = ZimScript.open(path)
	if _read_zim == null:
		_show_read(path.get_file(), "This archive could not be opened.")
		return
	_doc_kind = "zim"
	_full_text = FullTextScript.open(_read_zim, path)
	var chat: Control = _shell.chat_ui
	if chat and chat.has_method("add_message"):
		chat.add_message("System", ("Full text: %s indexed documents." %
			_full_text.document_count) if _full_text != null
			else "This archive has no full-text index — search finds names only.", true)
	_zim_trail.clear()
	var start: Dictionary = {}
	var last := str(ReadingStateScript.recall(path, ""))
	if not last.is_empty():
		start = _read_zim.lookup(last)
	if start.is_empty():
		start = _read_zim.resolve(_read_zim.entry(_read_zim.main_page))
	if start.is_empty():
		start = _read_zim.lookup("index")
	if start.is_empty():
		_show_read(path.get_file(), "This archive has no main page.")
		return
	_open_zim_entry(start)


func _open_text(path: String) -> void:
	_doc_kind = "txt"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_show_read(path.get_file(), "Could not read this file.")
		return
	var body := f.get_as_text()
	f.close()
	# Escaped, so a stray [b] in plain text is not markup.
	_show_read(path.get_file(), body.replace("[", "[lb]"))


func _show_chapter() -> void:
	ReadingStateScript.remember(_doc_path, _doc_index)
	var c: Dictionary = _epub.chapter(_doc_index)
	var name := str(_epub.title)
	if not str(c.title).is_empty():
		name += "  —  " + str(c.title)
	_show_read("%s   (%d/%d)" % [name, _doc_index + 1, _epub.chapters.size()], str(c.bbcode))


## A PDF entry opens as a PDF.
func _open_zim_entry(e: Dictionary) -> void:
	if e.is_empty():
		return
	if str(e.get("mime", "")).begins_with("application/pdf"):
		_open_zim_pdf(e)
		return
	var html: String = _read_zim.read_text(e)
	if html.is_empty():
		_show_read(str(e.get("title", "")), "(this entry has no readable text)")
		return
	_zim_trail.append(str(e.get("url", "")))
	ReadingStateScript.remember(_doc_path, str(e.get("url", "")))
	var body := EpubScript.html_to_bbcode(html, true, true)
	_show_read("%s  —  %s" % [_doc_path.get_file(), str(e.get("title", ""))],
		_resolve_images(body, str(e.get("url", ""))))


func follow_link(meta) -> void:
	if _doc_kind != "zim" or _read_zim == null:
		return
	var href := str(meta).split("#")[0]
	if href.is_empty() or href.begins_with("http"):
		return
	var parts := _flatten_path(href.uri_decode())
	if parts.is_empty():
		return
	# Hrefs may still carry a namespace prefix; try the whole path, then the tail.
	var whole := "/".join(parts)
	var target: Dictionary = _read_zim.lookup(whole)
	if target.is_empty():
		target = _read_zim.lookup(parts[parts.size() - 1])
	if target.is_empty():
		_ui("ReadTitle").text = "no entry for %s" % whole
		return
	_open_zim_entry(target)


static func _flatten_path(path: String) -> Array[String]:
	var parts: Array[String] = []
	for part in path.split("/"):
		if part == "." or part.is_empty():
			continue
		if part == "..":
			if not parts.is_empty():
				parts.pop_back()
			continue
		parts.append(part)
	return parts


func read_back() -> void:
	if _doc_kind == "zim" and _zim_trail.size() > 1:
		_zim_trail.pop_back()                         # current
		var previous: String = _zim_trail.pop_back()  # re-appended on open
		var e: Dictionary = _read_zim.lookup(previous)
		if not e.is_empty():
			_open_zim_entry(e)
			return
	_close_document()
	_shell.show_page("Media")


func step_document(delta: int) -> void:
	if _doc_kind == "cbz" and _comic != null:
		_doc_index = clampi(_doc_index + delta, 0, _comic.page_count() - 1)
		_show_comic_page()
		return
	if _doc_kind == "pdf" and _pdf != null:
		_doc_index = clampi(_doc_index + delta, 0, _pdf.page_count - 1)
		_show_pdf_page()
		return
	if _doc_kind != "epub" or _epub == null:
		return
	_doc_index = clampi(_doc_index + delta, 0, _epub.chapters.size() - 1)
	_show_chapter()


func _show_comic_page() -> void:
	ReadingStateScript.remember(_doc_path, _doc_index)
	var title := "%s   (%d/%d)   %s" % [_doc_path.get_file(), _doc_index + 1,
		_comic.page_count(), _comic.page_name(_doc_index)]
	var image: String = _comic.page_image(_doc_index)
	if image.is_empty():
		_show_read(title, str(_comic.error))
		return
	_show_read(title, "[img=%d]%s[/img]" % [_page_zoom, image])


func _show_pdf_page() -> void:
	ReadingStateScript.remember(_doc_path, _doc_index)
	var title := "%s   (%d/%d)" % [_doc_path.get_file(), _doc_index + 1, _pdf.page_count]
	# Rendered wider than shown, so it stays sharp through the lens.
	var rendered := clampi(int(_page_zoom * 1.6), 480, 2400)
	var image: String = _pdf.page_image(_doc_index, rendered)
	if image.is_empty():
		_show_read(title, "This page could not be rendered.\n%s" % _pdf.error)
		return
	_show_read(title, "[img=%d]%s[/img]" % [_page_zoom, image])


## The Smaller/Bigger buttons: font size for text, a fixed zoom step for page images.
func resize_text(step: int) -> void:
	var size := _read_size + step
	if _doc_kind == "cbz" and _comic != null:
		_page_zoom = clampi(_page_zoom + (40 if size > _read_size else -40), 420, 2000)
		_show_comic_page()
		return
	if _doc_kind == "pdf" and _pdf != null:
		_page_zoom = clampi(_page_zoom + (40 if size > _read_size else -40), 420, 2000)
		_show_pdf_page()
		return
	_read_size = clampi(size, 16, 56)
	_ui("ReadText").add_theme_font_size_override("normal_font_size", _read_size)
	_shell.content_changed.emit()


func _show_read(title: String, bbcode: String) -> void:
	_ui("ReadTitle").text = title
	_ui("ReadText").text = bbcode
	_ui("ReadText").add_theme_font_size_override("normal_font_size", _read_size)
	var paged: bool = _doc_kind in ["epub", "pdf", "cbz"]
	_ui("ReadPrevButton").visible = paged
	_ui("ReadNextButton").visible = paged
	_ui("ReadSearch").visible = _doc_kind == "zim"
	_ui("ReadBrowseButton").visible = _doc_kind == "zim"
	_shell.show_page("Read")
	await _shell.get_tree().process_frame
	_ui("ReadScroll").scroll_vertical = 0
	_shell.content_changed.emit()


func _close_document() -> void:
	if _full_text != null:
		_full_text.close()
		_full_text = null
	if _read_zim != null:
		_read_zim.close()
		_read_zim = null
	if _pdf != null:
		_pdf.close()
		_pdf = null
	if _comic != null:
		_comic.close()
		_comic = null
	_epub = null
	_doc_kind = ""
	_zim_trail.clear()


## Full text when this build can read the index, else (or on no hit) by entry name.
func search_archive(query: String) -> void:
	if _doc_kind != "zim" or _read_zim == null:
		_ui("ReadTitle").text = "open an archive first"
		return
	if query.strip_edges().is_empty():
		return
	var started := Time.get_ticks_msec()
	if _full_text != null:
		if _show_full_text_results(query, started):
			return
		if not str(_full_text.error).is_empty():
			push_warning("full-text search: %s" % _full_text.error)

	var hits: Array[Dictionary] = _read_zim.search(query, 80)
	if hits.is_empty():
		_show_read("%s  —  no match for \"%s\"" % [_doc_path.get_file(), query], "")
		return
	var by_name: Array[String] = [("[b]%d results for \"%s\"[/b]   "
			+ "[color=#8fb7d8]by name · %d ms[/color]\n")
			% [hits.size(), query, Time.get_ticks_msec() - started]]
	for e in hits:
		by_name.append("[url=%s]%s[/url]" % [str(e["url"]), str(e["title"])])
	_show_read("%s  —  search" % _doc_path.get_file(), "\n".join(by_name))


## False when there are none.
func _show_full_text_results(query: String, started: int) -> bool:
	var found: Array[Dictionary] = _full_text.search(query, 80)
	if found.is_empty():
		return false
	var lines: Array[String] = [("[b]%d results for \"%s\"[/b]   "
			+ "[color=#8fb7d8]full text · %d ms[/color]\n")
			% [found.size(), query, Time.get_ticks_msec() - started]]
	for hit in found:
		var name: String = str(hit["title"])
		if name.is_empty():
			name = str(hit["path"]).replace("_", " ")
		lines.append("[url=%s]%s[/url]   [color=#6a7a8a]%d%%[/color]"
			% [str(hit["path"]), name, int(hit["score"])])
	_show_read("%s  —  search" % _doc_path.get_file(), "\n".join(lines))
	return true


## RichTextLabel's [img] needs a file path; at most MAX_ARTICLE_IMAGES.
func _resolve_images(bbcode: String, article_url: String) -> String:
	if _read_zim == null or not bbcode.contains("[zimimg="):
		return bbcode
	DirAccess.make_dir_recursive_absolute(IMAGE_CACHE)
	_image_refs.clear()
	var base := article_url.get_base_dir()
	var re := RegEx.new()
	re.compile("\\[zimimg=([^\\]]+)\\]")
	var out := ""
	var last := 0
	var count := 0
	for m in re.search_all(bbcode):
		out += bbcode.substr(last, m.get_start() - last)
		last = m.get_end()
		if count >= MAX_ARTICLE_IMAGES:
			continue
		var src := m.get_string(1)
		var cached := _cache_image(src, base)
		if not cached.is_empty():
			count += 1
			out += "[img=560]%s[/img]" % cached
	return out + bbcode.substr(last)


## "" when missing or not jpg, png or webp.
func _cache_image(src: String, base: String) -> String:
	var parts := _flatten_path(src.split("#")[0].uri_decode())
	if parts.is_empty():
		return ""
	var inside := "/".join(parts)
	var e: Dictionary = _read_zim.lookup(inside)
	if e.is_empty():
		# hrefs are written relative to the article.
		e = _read_zim.lookup(base + "/" + inside if not base.is_empty() else inside)
	if e.is_empty() or e.redirect:
		return ""
	var bytes: PackedByteArray = _read_zim.read_blob(int(e.cluster), int(e.blob))
	if bytes.is_empty():
		return ""
	var ext := str(e.mime).get_slice("/", 1).get_slice(";", 0)
	if ext == "jpeg":
		ext = "jpg"
	if not ext in ["jpg", "png", "webp"]:
		return ""
	var out_path := "%s/%d.%s" % [IMAGE_CACHE, hash(inside), ext]
	if not FileAccess.file_exists(out_path):
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f == null:
			return ""
		f.store_buffer(bytes)
		f.close()
	# ResourceLoader does not read user://, so the texture is made here.
	var texture := RuntimeImage.adopt(out_path)
	if texture == null:
		return ""
	_image_refs.append(texture)
	return out_path


## The renderer needs a file; the archive stays the document path.
func _open_zim_pdf(e: Dictionary) -> void:
	var bytes: PackedByteArray = _read_zim.read_blob(int(e.cluster), int(e.blob))
	if bytes.is_empty():
		_show_read(str(e.get("title", "")), "That PDF is empty.")
		return
	DirAccess.make_dir_recursive_absolute(PdfScript.CACHE_DIR)
	var out := "%s/%d.pdf" % [PdfScript.CACHE_DIR, hash(str(e.get("url", "")))]
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		_show_read(str(e.get("title", "")), "Could not unpack that PDF.")
		return
	f.store_buffer(bytes)
	f.close()
	var archive := _doc_path
	open_document(out)
	_doc_path = archive if _doc_path == out else _doc_path


## The open archive in the web browser.
func browse_current() -> void:
	if _doc_kind != "zim" or _doc_path.is_empty():
		return
	_shell.show_page("Browse")
	_shell.browse_open_archive.emit(_doc_path)


func open_album(dir_path: String) -> void:
	_close_album()
	_shell.set_process(true)
	_album = PhotoAlbumScript.open(dir_path)
	if _album.count() == 0:
		_ui("PhotoTitle").text = str(_album.error)
		_album = null
		_shell.show_page("Photos")
		return
	_photo_page = 0
	_photo_index = 0
	show_photo_grid()


func open_album_at(file_path: String) -> void:
	open_album(file_path.get_base_dir())
	if _album == null:
		return
	var wanted := file_path.get_file()
	for index in _album.count():
		if _album.name_at(index) == wanted:
			_show_photo(index)
			return


## From a photo back to the grid; from the grid back to the media page.
func photo_back() -> void:
	if _photo_full:
		show_photo_grid()
	else:
		_close_album()
		_shell.show_page("Media")


func _close_album() -> void:
	stop_thumbs()
	_photo_slots.clear()
	if _album != null:
		_album.forget_cache()
		_album = null


## Workers decode the thumbnails.
func show_photo_grid() -> void:
	if _album == null:
		return
	_photo_full = false
	_ui("PhotoView").visible = false
	_ui("PhotoGrid").visible = true
	_ui("PhotoGridButton").visible = false
	_ui("PhotoSmallerButton").visible = false
	_ui("PhotoBiggerButton").visible = false
	for child in _ui("PhotoGrid").get_children():
		_ui("PhotoGrid").remove_child(child)
		child.queue_free()
	stop_thumbs()
	_photo_slots.clear()

	var pages: int = maxi(1, ceili(float(_album.count()) / PHOTOS_PER_PAGE))
	_photo_page = clampi(_photo_page, 0, pages - 1)
	var first: int = _photo_page * PHOTOS_PER_PAGE
	var last: int = mini(first + PHOTOS_PER_PAGE, _album.count())
	_ui("PhotoTitle").text = "%s — %d pictures   (%d–%d of %d)" % [
		_album.dir.get_file(), _album.count(), first + 1, last, _album.count()]
	_ui("PhotoPrevButton").visible = pages > 1
	_ui("PhotoNextButton").visible = pages > 1

	for index in range(first, last):
		var slot := TextureButton.new()
		slot.custom_minimum_size = THUMB_BOX
		slot.ignore_texture_size = true
		slot.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		slot.focus_mode = Control.FOCUS_NONE
		slot.tooltip_text = _album.name_at(index)
		var at := index
		slot.pressed.connect(func(): _show_photo(at))
		_ui("PhotoGrid").add_child(slot)
		_photo_slots[index] = slot

	var queue: Array[int] = []
	for index in range(first, last):
		queue.append(index)
	_thumb_lock.lock()
	_thumb_wanted = queue
	_thumb_lock.unlock()
	_start_thumbs()

	_shell.show_page("Photos")
	_shell.content_changed.emit()


## Each frame: hands finished thumbnails to their slots.
func take_thumbs() -> void:
	if not _thumb_running:
		return
	var finished: Array = []
	_thumb_lock.lock()
	if not _thumb_ready.is_empty():
		finished = _thumb_ready
		_thumb_ready = []
	_thumb_lock.unlock()
	if finished.is_empty():
		return
	for done in finished:
		var slot = _photo_slots.get(int(done["index"]), null)
		if slot != null and is_instance_valid(slot) and done["image"] != null:
			slot.texture_normal = ImageTexture.create_from_image(done["image"])
	_shell.content_changed.emit()


## Worker thread.
func _thumb_worker() -> void:
	while true:
		var index := -1
		_thumb_lock.lock()
		if not _thumb_running:
			_thumb_lock.unlock()
			return
		if not _thumb_wanted.is_empty():
			index = _thumb_wanted.pop_front()
		_thumb_lock.unlock()
		if index < 0:
			OS.delay_msec(8)
			continue
		var album = _album
		if album == null:
			continue
		var image: Image = album.thumbnail_image(index)
		_thumb_lock.lock()
		_thumb_ready.append({"index": index, "image": image})
		_thumb_lock.unlock()


func _start_thumbs() -> void:
	if _thumb_running:
		return
	_thumb_running = true
	for _i in THUMB_WORKERS:
		var worker := Thread.new()
		worker.start(_thumb_worker)
		_thumb_threads.append(worker)


## Must finish before _album changes.
func stop_thumbs() -> void:
	if not _thumb_running:
		return
	_thumb_lock.lock()
	_thumb_running = false
	_thumb_wanted.clear()
	_thumb_lock.unlock()
	for worker in _thumb_threads:
		worker.wait_to_finish()
	_thumb_threads.clear()
	_thumb_ready.clear()


func _show_photo(index: int) -> void:
	if _album == null:
		return
	_photo_index = clampi(index, 0, _album.count() - 1)
	_photo_full = true
	stop_thumbs()
	_ui("PhotoGrid").visible = false
	_ui("PhotoView").visible = true
	_ui("PhotoGridButton").visible = true
	_ui("PhotoSmallerButton").visible = true
	_ui("PhotoBiggerButton").visible = true
	_ui("PhotoPrevButton").visible = true
	_ui("PhotoNextButton").visible = true
	var texture: Texture2D = _album.full(_photo_index)
	if texture == null:
		_ui("PhotoTitle").text = "%s — %s" % [_album.name_at(_photo_index), str(_album.error)]
		_ui("PhotoView").texture = null
		_shell.content_changed.emit()
		return
	_ui("PhotoView").texture = texture
	_apply_photo_zoom(texture)
	_ui("PhotoTitle").text = "%s   (%d/%d)   %d×%d" % [_album.name_at(_photo_index),
		_photo_index + 1, _album.count(),
		texture.get_width(), texture.get_height()]
	_shell.show_page("Photos")
	await _shell.get_tree().process_frame
	_ui("PhotoScroll").scroll_vertical = 0
	_shell.content_changed.emit()


func _apply_photo_zoom(texture: Texture2D) -> void:
	if texture == null or texture.get_width() <= 0:
		return
	var aspect: float = float(texture.get_height()) / float(texture.get_width())
	_ui("PhotoView").custom_minimum_size = Vector2(_photo_zoom, _photo_zoom * aspect)


func zoom_photo(delta: int) -> void:
	_photo_zoom = clampi(_photo_zoom + delta, 420, 3200)
	_apply_photo_zoom(_ui("PhotoView").texture)
	_shell.content_changed.emit()


func step_photo(delta: int) -> void:
	if _album == null:
		return
	if _photo_full:
		_show_photo(_photo_index + delta)
		return
	var pages: int = maxi(1, ceili(float(_album.count()) / PHOTOS_PER_PAGE))
	_photo_page = clampi(_photo_page + delta, 0, pages - 1)
	show_photo_grid()
