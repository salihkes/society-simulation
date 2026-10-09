class_name PhotoAlbum
extends RefCounted
## The pictures in one folder, as cached thumbnails and capped full views (ImageBridge on Android).

const EXTS: PackedStringArray = [
	"jpg", "jpeg", "png", "webp", "bmp", "svg", "heic", "heif", "gif"]
const THUMB_DIR := "user://photo_thumbs"
const THUMB_SIZE := 320
const FULL_MAX := 2048

var dir := ""
var files: PackedStringArray = PackedStringArray()
var error := ""


## The Java ImageBridge class, or null off Android.
static func bridge_class():
	if not OS.has_feature("android"):
		return null
	var cls = JavaClassWrapper.wrap(Identity.value("android_package") + ".ImageBridge")
	JavaClassWrapper.get_exception()
	return cls


static func count_in(dir_path: String) -> int:
	return _image_names(dir_path).size()


static func _image_names(dir_path: String) -> Array[String]:
	var names: Array[String] = []
	for file in DirAccess.get_files_at(dir_path):
		var name := String(file)
		if name.begins_with("."):
			continue
		if EXTS.has(name.get_extension().to_lower()):
			names.append(name)
	return names


## The album for `dir_path`, files in natural order; `error` set when empty.
static func open(dir_path: String) -> PhotoAlbum:
	var album := PhotoAlbum.new()
	album.dir = dir_path
	var names := _image_names(dir_path)
	names.sort_custom(func(a: String, b: String) -> bool:
		return a.naturalnocasecmp_to(b) < 0)
	album.files = PackedStringArray(names)
	if album.files.is_empty():
		album.error = "No pictures in this folder."
	DirAccess.make_dir_recursive_absolute(THUMB_DIR)
	return album


func count() -> int:
	return files.size()


func name_at(index: int) -> String:
	return files[index] if index >= 0 and index < files.size() else ""


func path_at(index: int) -> String:
	var name := name_at(index)
	return dir.path_join(name) if not name.is_empty() else ""


## Returns an Image, not a texture, because callers run it on a worker thread.
func thumbnail_image(index: int) -> Image:
	var path := path_at(index)
	if path.is_empty():
		return null
	var cached := "%s/%d.png" % [THUMB_DIR, hash(path)]
	var image := Image.new()
	if FileAccess.file_exists(cached) and image.load(cached) == OK:
		return image
	image = _decode(path, THUMB_SIZE)
	if image == null:
		return null
	image.save_png(cached)
	return image


## Never cached to disk.
func full(index: int, longest_edge := FULL_MAX) -> Texture2D:
	var image := full_image(index, longest_edge)
	return ImageTexture.create_from_image(image) if image != null else null


## Sets `error` when decoding fails.
func full_image(index: int, longest_edge := FULL_MAX) -> Image:
	var path := path_at(index)
	if path.is_empty():
		return null
	var image := _decode(path, longest_edge)
	if image == null:
		error = "This picture could not be decoded."
	return image


## Does nothing; the album keeps no in-memory cache.
func forget_cache() -> void:
	pass


## ImageBridge first on Android, then Godot's loader, which cannot read HEIC; 0 = no limit.
static func _decode(path: String, longest_edge: int) -> Image:
	var bridge = bridge_class()
	if bridge != null:
		var raw = bridge.decode(path, longest_edge)
		if not JavaClassWrapper.get_exception() and typeof(raw) == TYPE_PACKED_BYTE_ARRAY:
			var bytes: PackedByteArray = raw
			var decoded := Image.new()
			if not bytes.is_empty() and decoded.load_png_from_buffer(bytes) == OK:
				return decoded
	var image := Image.new()
	if image.load(path) != OK:
		return null
	if longest_edge > 0:
		var longest: int = maxi(image.get_width(), image.get_height())
		if longest > longest_edge:
			var scale := float(longest_edge) / float(longest)
			image.resize(maxi(1, int(image.get_width() * scale)),
				maxi(1, int(image.get_height() * scale)), Image.INTERPOLATE_BILINEAR)
	return image
