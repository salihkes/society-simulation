class_name MediaCatalog
extends RefCounted
## Lists the subfolders and media files of any folder, with what plays on the given platform.

const STREAMS_NAME := "streams.json"
const MAX_DEPTH := 4

## Containers Android's MediaPlayer feeds to the device decoders.
const VIDEO_EXTS: PackedStringArray = ["mp4", "m4v", "mov", "mkv", "webm", "3gp", "ts", "ogv"]
const AUDIO_EXTS: PackedStringArray = ["mp3", "ogg", "oga", "wav", "flac", "m4a", "m4b", "aac", "opus"]
## Shown on the shelf though nothing we ship decodes them.
const SHELVED_EXTS: PackedStringArray = ["avi", "wmv", "flv", "mpg", "mpeg", "divx"]
const DOC_EXTS: PackedStringArray = ["txt", "epub", "md", "pdf", "cbz", "log", "srt", "vtt"]
## Saved pages, handed to the browser rather than read as text.
const WEB_EXTS: PackedStringArray = ["html", "htm", "xhtml", "mhtml"]
## Not listed per file (photo folders get huge); see photo_album.gd.
const IMAGE_EXTS: PackedStringArray = PhotoAlbumScript.EXTS
const PhotoAlbumScript := preload("res://src/library/photo_album.gd")


## Returns {dirs: [{name, path}], files: [{title, source, kind, ext, playable}]}; not recursive.
static func list_dir(abs_dir: String, platform: String = OS.get_name()) -> Dictionary:
	var dirs: Array[Dictionary] = []
	var files: Array[Dictionary] = []
	if DirAccess.dir_exists_absolute(abs_dir):
		for sub in DirAccess.get_directories_at(abs_dir):
			if not _skip_dir(sub):
				dirs.append({"name": sub, "path": abs_dir.path_join(sub)})
		_append_files(abs_dir, platform, files)
		_read_streams(abs_dir.path_join(STREAMS_NAME), platform, files)
	dirs.sort_custom(func(a, b): return String(a.name).naturalnocasecmp_to(String(b.name)) < 0)
	files.sort_custom(func(a, b): return String(a.title).naturalnocasecmp_to(String(b.title)) < 0)
	return {"dirs": dirs, "files": files}


## Recursive, sorted by title.
static func scan_folder(abs_dir: String, platform: String = OS.get_name(), max_depth := MAX_DEPTH) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if DirAccess.dir_exists_absolute(abs_dir):
		_scan_dir(abs_dir, MAX_DEPTH - max_depth, platform, entries)
	entries.sort_custom(func(a, b): return String(a.title).naturalnocasecmp_to(String(b.title)) < 0)
	return entries


static func _scan_dir(dir_path: String, depth: int, platform: String, entries: Array[Dictionary]) -> void:
	if depth > MAX_DEPTH:
		return
	_append_files(dir_path, platform, entries)
	_read_streams(dir_path.path_join(STREAMS_NAME), platform, entries)
	for sub in DirAccess.get_directories_at(dir_path):
		if not _skip_dir(sub):
			_scan_dir(dir_path.path_join(sub), depth + 1, platform, entries)


## Hidden folders and Windows system folders.
static func _skip_dir(sub: String) -> bool:
	return sub.begins_with(".") or sub in ["$RECYCLE.BIN", "System Volume Information"]


static func _append_files(dir_path: String, platform: String, entries: Array[Dictionary]) -> void:
	for file in DirAccess.get_files_at(dir_path):
		# Also skips the "._foo.mp4" files macOS leaves on exFAT drives.
		if file.begins_with("."):
			continue
		var ext := file.get_extension().to_lower()
		var kind := _kind_for_ext(ext)
		if kind.is_empty():
			continue
		entries.append({
			"title": file.get_basename(),
			"source": dir_path.path_join(file),
			"kind": kind,
			"ext": ext,
			"playable": _is_playable(kind, ext, platform),
		})


## Format: { "streams": [ { "name": "Some TV", "url": "https://.../index.m3u8" } ] }
static func _read_streams(path: String, platform: String, entries: Array[Dictionary]) -> void:
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("media streams list unreadable: %s" % path)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed.get("streams") is Array):
		push_warning("media streams list is not {\"streams\": [...]}: %s" % path)
		return
	for item in parsed.streams:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var url := str(item.get("url", ""))
		var stream_name := str(item.get("name", ""))
		if stream_name.is_empty() or not (url.begins_with("http://") or url.begins_with("https://")):
			push_warning("media stream entry needs name + http(s) url, skipped: %s" % str(item))
			continue
		entries.append({
			"title": stream_name,
			"source": url,
			"kind": "stream",
			"ext": "",
			"playable": _is_playable("stream", "", platform),
		})


## Entry kind for an extension, or "" for files that are not listed.
static func _kind_for_ext(ext: String) -> String:
	if ext == "zim":
		return "archive"     # browsable, not playable — see ZimShelf
	if DOC_EXTS.has(ext):
		return "document"
	if WEB_EXTS.has(ext):
		return "page"
	if VIDEO_EXTS.has(ext):
		return "video"
	if AUDIO_EXTS.has(ext):
		return "audio"
	if SHELVED_EXTS.has(ext):
		return "shelved"
	return ""


static func _is_playable(kind: String, ext: String, platform: String) -> bool:
	match kind:
		"video":
			# ogv is the one format Godot decodes itself; the rest need Android's decoders.
			return platform == "Android" or ext == "ogv"
		"audio":
			# Godot has runtime loaders for these three on every platform.
			return platform == "Android" or ext in ["mp3", "ogg", "wav"]
		"stream":
			return platform == "Android"
		"archive":
			return true      # opening one is browsing, which works anywhere
		"page":
			return true      # the browser reports itself where it is missing
		"document":
			# Only pdf needs Android's PdfRenderer; the rest open anywhere.
			return ext != "pdf" or platform == "Android"
	return false


## Null for formats that need Android.
static func load_desktop_audio_stream(path: String) -> AudioStream:
	match path.get_extension().to_lower():
		"mp3":
			return AudioStreamMP3.load_from_file(path)
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"wav":
			return AudioStreamWAV.load_from_file(path)
	return null
