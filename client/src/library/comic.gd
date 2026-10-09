class_name ComicBook
extends RefCounted
## A CBZ comic: page images read in natural order and copied into a page cache Godot loads from.

const CACHE_DIR := "user://comic_pages"
const PAGE_EXTS: PackedStringArray = ["jpg", "jpeg", "png", "webp", "bmp"]

var path := ""
var pages: PackedStringArray = PackedStringArray()
var error := ""

var _zip: ZIPReader
## The page on screen; the resource cache only holds it weakly.
var _held: Texture2D


## Always returns a book; `error` is set when it cannot be read.
static func open(file_path: String) -> ComicBook:
	var book := ComicBook.new()
	book.path = file_path
	var zip := ZIPReader.new()
	if zip.open(file_path) != OK:
		book.error = "This file is not a readable zip archive."
		return book
	var names: Array[String] = []
	for entry in zip.get_files():
		var name := String(entry)
		if name.ends_with("/"):
			continue
		var leaf := name.get_file()
		# Skip macOS resource forks, which share the real pages' names.
		if leaf.begins_with(".") or name.begins_with("__MACOSX/"):
			continue
		if PAGE_EXTS.has(leaf.get_extension().to_lower()):
			names.append(name)
	if names.is_empty():
		book.error = "No page images inside this archive."
		zip.close()
		return book
	# "page2.jpg" belongs before "page10.jpg"; a plain sort disagrees.
	names.sort_custom(func(a: String, b: String) -> bool:
		return a.naturalnocasecmp_to(b) < 0)
	book.pages = PackedStringArray(names)
	book._zip = zip
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	return book


func page_count() -> int:
	return pages.size()


## Loadable path of the page, or "" with `error` set.
func page_image(index: int) -> String:
	if _zip == null or index < 0 or index >= pages.size():
		return ""
	var inside := pages[index]
	var ext := inside.get_extension().to_lower()
	if ext == "jpeg":
		ext = "jpg"
	var out := "%s/%d_%d.%s" % [CACHE_DIR, hash(path), index, ext]
	if not FileAccess.file_exists(out):
		var bytes := _zip.read_file(inside)
		if bytes.is_empty():
			error = "Page %d could not be read out of the archive." % (index + 1)
			return ""
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f == null:
			error = "Could not write the page cache."
			return ""
		f.store_buffer(bytes)
		f.close()
	_held = RuntimeImage.adopt(out)
	if _held == null:
		error = "Page %d is not an image Godot can read." % (index + 1)
		return ""
	return out


func page_name(index: int) -> String:
	if index < 0 or index >= pages.size():
		return ""
	return pages[index].get_file()


func close() -> void:
	if _zip != null:
		_zip.close()
		_zip = null
	_held = null
	pages = PackedStringArray()
