class_name PdfDocument
extends RefCounted
## A PDF rasterised by Android's PdfRenderer; pages cached as PNGs keyed by file, page and width.

const CACHE_DIR := "user://pdf_pages"

var path := ""
var page_count := 0
var error := ""

var _bridge = null
## The page on screen; the resource cache only holds it weakly.
var _held: Texture2D


## The Java PdfBridge class, or null off Android.
static func bridge_class():
	if not OS.has_feature("android"):
		return null
	var cls = JavaClassWrapper.wrap(Identity.value("android_package") + ".PdfBridge")
	JavaClassWrapper.get_exception()
	return cls


## Always returns a document; `page_count == 0` means it did not open, `error` says why.
static func open(file_path: String) -> PdfDocument:
	var doc := PdfDocument.new()
	doc.path = file_path
	doc._bridge = bridge_class()
	if doc._bridge == null:
		doc.error = "PDF pages need the Quest build — the renderer is Android's."
		return doc
	# PdfRenderer needs a real file, so callers extract archived PDFs first.
	doc._bridge.open(ProjectSettings.globalize_path(file_path))
	if JavaClassWrapper.get_exception():
		doc.error = "PdfRenderer refused this file."
		doc._bridge = null
		return doc
	doc.page_count = int(doc._bridge.getPageCount())
	if doc.page_count <= 0:
		doc.error = str(doc._bridge.getError())
		if doc.error.is_empty():
			doc.error = "no pages in this PDF"
		return doc
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	return doc


## Loadable path of the page, or "" with `error` set.
func page_image(index: int, width := 1400) -> String:
	if _bridge == null or index < 0 or index >= page_count:
		return ""
	var out := "%s/%d_%d_%d.png" % [CACHE_DIR, hash(path), index, width]
	if FileAccess.file_exists(out):
		_held = RuntimeImage.adopt(out)
		return out if _held != null else ""
	var raw = _bridge.renderPage(index, width)
	if JavaClassWrapper.get_exception():
		error = "the call into PdfBridge threw"
		return ""
	if typeof(raw) != TYPE_PACKED_BYTE_ARRAY:
		error = "PdfBridge returned %s, not image bytes" % type_string(typeof(raw))
		return ""
	var bytes: PackedByteArray = raw
	if bytes.is_empty():
		error = str(_bridge.getError())
		if error.is_empty():
			error = "the renderer produced nothing for page %d" % (index + 1)
		return ""
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		error = "could not write %s (%d)" % [out, FileAccess.get_open_error()]
		return ""
	f.store_buffer(bytes)
	f.close()
	_held = RuntimeImage.adopt(out)
	if _held == null:
		error = "the rendered page is not a readable PNG"
		return ""
	return out


func close() -> void:
	if _bridge != null:
		_bridge.close()
		JavaClassWrapper.get_exception()
		_bridge = null
	_held = null
	page_count = 0
