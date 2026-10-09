class_name MediaCommands
extends Node
## The /media chat command (list, play, tracks, audio, pause, resume, stop, volume); the VR panel plays.

const Catalog := preload("res://src/media/media_catalog.gd")

## On-device folders that count as a shelf even with no drive plugged in.
const DEVICE_MEDIA_DIRS: PackedStringArray = ["/sdcard/Download", "/sdcard/Movies", "/sdcard/Music"]

## Shallow: a library drive can hold hundreds of thousands of files.
const LIST_DEPTH := 2

## Headsets ship without Dolby and DTS licences, so those tracks play as silence.
const DECODABLE := ["audio/mp4a-latm", "audio/mpeg", "audio/vorbis", "audio/opus",
	"audio/flac", "audio/raw", "audio/3gpp", "audio/amr-wb"]

var _entries: Array[Dictionary] = []
var _chat: Node = null # the ChatUI that reached us; leads to the VR panel


static func handle(parts: PackedStringArray, chat: Node) -> void:
	_node_for(chat)._run(parts, func(msg: String): chat.add_message("System", msg, true))


## For UI buttons: paths may contain spaces, which the chat split would break.
static func play_path(source: String, title: String, chat: Node) -> void:
	_node_for(chat)._play(source, title, func(msg: String): chat.add_message("System", msg, true))


## The shared MediaCommands node under /root, remembering `chat`.
static func _node_for(chat: Node) -> Node:
	var root := chat.get_tree().root
	var node = root.get_node_or_null("MediaCommands")
	if node == null:
		# load() works even before the global class cache is built.
		node = (load("res://src/media/media_commands.gd") as GDScript).new()
		node.name = "MediaCommands"
		root.add_child(node)
	node._chat = chat
	return node


func _run(parts: PackedStringArray, say: Callable) -> void:
	var sub := parts[1].to_lower() if parts.size() > 1 else "help"
	match sub:
		"list":
			_cmd_list(say)
		"play":
			_cmd_play(parts, say)
		"tracks":
			_say_tracks(say)
		"audio":
			_cmd_audio(parts, say)
		"pause":
			var video = _video()
			if video:
				video.pause()
		"resume":
			var video = _video()
			if video:
				video.resume()
		"stop":
			var video = _video()
			if video:
				video.close()
				say.call("Player closed.")
		"volume":
			if parts.size() < 3 or not String(parts[2]).is_valid_int():
				say.call("Usage: /media volume <0-100>")
				return
			var video = _video()
			if video:
				video.set_volume(clampf(String(parts[2]).to_int() / 100.0, 0.0, 1.0))
		_:
			say.call("/media list | play <n or url> | tracks | audio <n> | pause | resume | stop | volume <0-100>")


func _cmd_list(say: Callable) -> void:
	_rescan()
	if _entries.is_empty():
		say.call("No media found. Plug a drive in, or pass --drive-root=<folder>.")
		return
	for i in _entries.size():
		var e := _entries[i]
		var note := "" if e.playable else " (not playable on this device)"
		say.call("%d. [%s] %s%s" % [i + 1, e.kind, e.title, note])


## Rescans the list when n is out of range.
func _cmd_play(parts: PackedStringArray, say: Callable) -> void:
	if parts.size() < 3:
		say.call("Usage: /media play <number from /media list, or a URL/path>")
		return
	# Rejoin: file paths may contain spaces.
	var arg := " ".join(parts.slice(2)).strip_edges()
	if not arg.is_valid_int():
		_play(arg, "", say)
		return
	var idx := arg.to_int() - 1
	if idx < 0 or idx >= _entries.size():
		_rescan()
	if idx < 0 or idx >= _entries.size():
		say.call("No media entry %s — run /media list first." % arg)
		return
	var e := _entries[idx]
	if not e.playable:
		say.call("Heads up: '%s' is not expected to play on this device, trying anyway..." % e.title)
	_play(String(e.source), String(e.title), say)


func _cmd_audio(parts: PackedStringArray, say: Callable) -> void:
	if parts.size() < 3 or not String(parts[2]).is_valid_int():
		say.call("Usage: /media audio <track number from /media tracks>")
		return
	var video = _video()
	if video == null:
		say.call("Nothing is playing.")
		return
	if video.select_track(String(parts[2]).to_int()):
		say.call("Switched to track %s." % parts[2])
	else:
		say.call("Could not select track %s." % parts[2])


static func scan_all(context: Node) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var drives := context.get_node_or_null("/root/Drives")
	if drives != null:
		for d in drives.drives():
			out.append_array(Catalog.scan_folder(String(d.root), OS.get_name(), LIST_DEPTH))
	if OS.has_feature("android"):
		for d in DEVICE_MEDIA_DIRS:
			out.append_array(Catalog.scan_folder(d, OS.get_name(), LIST_DEPTH))
	return out


## Mounted drives plus existing device media folders, as [{label, path}].
static func media_roots(context: Node) -> Array[Dictionary]:
	var roots: Array[Dictionary] = []
	var seen := {}
	var drives := context.get_node_or_null("/root/Drives")
	if drives != null:
		for d in drives.drives():
			_add_root(roots, seen, str(d.name), String(d.root))
	if OS.has_feature("android"):
		for d in DEVICE_MEDIA_DIRS:
			_add_root(roots, seen, "Quest — %s" % String(d).get_file(), d)
	return roots


static func _add_root(roots: Array[Dictionary], seen: Dictionary, label: String, path: String) -> void:
	if seen.has(path) or not DirAccess.dir_exists_absolute(path):
		return
	seen[path] = true
	roots.append({"label": label, "path": path})


## Android 11+ has no runtime dialog for this; adb appops or the settings screen grants it.
static func has_all_files_access() -> bool:
	if not OS.has_feature("android"):
		return true
	var environment = JavaClassWrapper.wrap("android.os.Environment")
	if environment == null:
		return true
	var ok = environment.isExternalStorageManager()
	JavaClassWrapper.get_exception() # pre-R devices lack the method
	return bool(ok)


static func open_all_files_access_settings() -> void:
	if not OS.has_feature("android"):
		return
	var runtime = Engine.get_singleton("AndroidRuntime")
	var intent_class = JavaClassWrapper.wrap("android.content.Intent")
	var uri_class = JavaClassWrapper.wrap("android.net.Uri")
	if runtime == null or intent_class == null:
		return
	var activity = runtime.getActivity()
	var intent = intent_class.Intent(
		"android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION",
		uri_class.parse("package:" + str(activity.getPackageName())))
	activity.startActivity(intent)
	if JavaClassWrapper.get_exception():
		# Some builds only ship the app-agnostic screen.
		intent = intent_class.Intent("android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION")
		activity.startActivity(intent)
		JavaClassWrapper.get_exception()


func _rescan() -> void:
	_entries = scan_all(self)


func _play(source: String, title: String, say: Callable) -> void:
	var video = _video()
	if video == null:
		say.call("The player lives on the VR panel — available in the headset.")
		return
	video.open(source, title if not title.is_empty() else source.get_file().get_basename())
	say.call("Opening %s ..." % (title if not title.is_empty() else source))


## The chat's VR panel's video_player.gd, or null.
func _video():
	if _chat == null or not is_instance_valid(_chat):
		return null
	var panel = _chat.get("vr_panel")
	if panel != null and is_instance_valid(panel):
		return panel.get("video")
	return null


## Flags audio the device cannot decode, the usual cause of a silent picture.
func _say_tracks(say: Callable) -> void:
	var video = _video()
	if video == null:
		say.call("Nothing is playing.")
		return
	var tracks: Array = video.tracks()
	if tracks.is_empty():
		say.call("No track info — the player has not prepared yet.")
		return
	for t in tracks:
		var lang := "" if String(t.language).is_empty() else "  [%s]" % t.language
		var note := ""
		if t.type == "audio":
			note = "" if _decodable(String(t.mime)) else "   <- no decoder on this device"
		say.call("%d. %s  %s%s%s" % [t.index, t.type, t.mime, lang, note])
	say.call("Switch with /media audio <number>")


static func _decodable(mime: String) -> bool:
	return DECODABLE.has(mime.to_lower())
