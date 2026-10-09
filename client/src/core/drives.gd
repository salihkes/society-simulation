extends Node
## Lists mounted volumes (read only) and signals when one appears or disappears.

signal drive_mounted(drive: Dictionary)
signal drive_unmounted(root: String)

const POLL_INTERVAL := 2.0

## Extra roots from `--drive-root=<folder>` on the command line.
var extra_roots: PackedStringArray = PackedStringArray()

## root -> {root: String, name: String, removable: bool}
var _mounted: Dictionary = {}
var _accum := 0.0


func _ready() -> void:
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--drive-root="):
			extra_roots.append(arg.get_slice("=", 1))
	if OS.get_name() == "Android":
		OS.request_permissions()
	scan_now()


func _process(delta: float) -> void:
	_accum += delta
	if _accum < POLL_INTERVAL:
		return
	_accum = 0.0
	scan_now()


func drives() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for root in _mounted:
		out.append(_mounted[root])
	out.sort_custom(func(a, b): return String(a.name).naturalnocasecmp_to(String(b.name)) < 0)
	return out


## Rescans now, emitting drive_mounted / drive_unmounted for the changes.
func scan_now() -> void:
	var present := {}
	for root in _candidate_roots():
		if not DirAccess.dir_exists_absolute(root):
			continue
		# A mount point we cannot list is a mount point we cannot browse.
		if DirAccess.open(root) == null:
			continue
		if present.has(root):
			continue
		if _mounted.has(root):
			present[root] = _mounted[root]
			continue
		var drive := {
			"root": root,
			"name": _display_name(root),
			"removable": not _is_system_volume(root),
		}
		present[root] = drive
		drive_mounted.emit(drive)
	for root in _mounted:
		if not present.has(root):
			drive_unmounted.emit(root)
	_mounted = present


func _candidate_roots() -> PackedStringArray:
	var roots := PackedStringArray()
	roots.append_array(extra_roots)
	match OS.get_name():
		"macOS":
			_append_subdirs(roots, "/Volumes")
		"Android":
			roots.append_array(_android_roots())
		"Windows":
			for i in DirAccess.get_drive_count():
				roots.append(DirAccess.get_drive_name(i))
		"Linux":
			var user := OS.get_environment("USER")
			_append_subdirs(roots, "/media/%s" % user)
			_append_subdirs(roots, "/run/media/%s" % user)
	return roots


func _append_subdirs(roots: PackedStringArray, base: String) -> void:
	if not DirAccess.dir_exists_absolute(base):
		return
	for sub in DirAccess.get_directories_at(base):
		roots.append(base.path_join(sub))


func _display_name(root: String) -> String:
	if root == "/sdcard" or root == "/storage/emulated/0":
		return "Headset storage"
	var name := root.get_file()
	# Android names removable volumes by filesystem UUID.
	if root.begins_with("/storage/") and _looks_like_uuid(name):
		return "USB drive (%s)" % name
	return name if not name.is_empty() else root


static func _looks_like_uuid(name: String) -> bool:
	return name.length() == 9 and name[4] == "-"


## Maps /sdcard (a symlink to /storage/emulated/0) so the volume is listed once.
static func _canonical(path: String) -> String:
	if path == "/sdcard" or path.begins_with("/sdcard/"):
		return "/storage/emulated/0" + path.substr(7)
	return path.trim_suffix("/")


func _is_system_volume(root: String) -> bool:
	var name := root.get_file()
	return name in ["Macintosh HD", "Recovery", "Preboot", "VM", "Update", "xarts"]


## /storage is not listable by apps, so roots are gathered from several Android sources.
func _android_roots() -> PackedStringArray:
	var roots := PackedStringArray()
	var seen := {}
	var add := func(path: String) -> void:
		var c := _canonical(path)
		if c.is_empty() or seen.has(c):
			return
		seen[c] = true
		roots.append(c)

	add.call("/storage/emulated/0")
	for path in _proc_mount_roots():
		add.call(path)
	var activity = _android_activity()
	if activity != null:
		for path in _storage_manager_roots(activity):
			add.call(path)
		for path in _media_dir_roots(activity):
			add.call(path)
	for sub in DirAccess.get_directories_at("/storage"):
		if sub != "emulated" and sub != "self":
			add.call("/storage".path_join(sub))
	return roots


## Field 2 of each /proc/mounts line under /storage; spaces arrive octal-escaped (\040).
func _proc_mount_roots() -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open("/proc/mounts", FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var parts := f.get_line().split(" ", false)
		if parts.size() < 2:
			continue
		var point := parts[1].replace("\\040", " ")
		if not point.begins_with("/storage/"):
			continue
		var leaf := point.trim_prefix("/storage/")
		if leaf.begins_with("self") or leaf == "emulated":
			continue
		out.append(point)
	return out


## The Godot Android activity, or null off Android.
func _android_activity():
	if not Engine.has_singleton("AndroidRuntime"):
		return null
	var runtime = Engine.get_singleton("AndroidRuntime")
	if runtime == null:
		return null
	var activity = runtime.getActivity()
	JavaClassWrapper.get_exception()
	return activity


## Volume roots from getExternalMediaDirs(); emulated storage only.
func _media_dir_roots(activity) -> PackedStringArray:
	var out := PackedStringArray()
	var dirs = activity.getExternalMediaDirs()
	if JavaClassWrapper.get_exception() or dirs == null:
		return out
	for dir in dirs:
		if dir == null:
			continue
		var path := str(dir.getAbsolutePath())
		if JavaClassWrapper.get_exception() or path.is_empty():
			continue
		var cut := path.find("/Android/")
		if cut > 0:
			out.append(path.substr(0, cut))
	return out


## The Java List is walked by index because GDScript cannot iterate it.
func _storage_manager_roots(activity) -> PackedStringArray:
	var out := PackedStringArray()
	var manager = activity.getSystemService("storage")
	if JavaClassWrapper.get_exception() or manager == null:
		return out
	var volumes = manager.getStorageVolumes()
	if JavaClassWrapper.get_exception() or volumes == null:
		return out
	var count := int(volumes.size())
	if JavaClassWrapper.get_exception():
		return out
	for i in count:
		var volume = volumes.get(i)
		if JavaClassWrapper.get_exception() or volume == null:
			continue
		var path := _volume_path(volume)
		if not path.is_empty():
			out.append(path)
	return out


## /storage/<UUID> when the app has no scoped access to it; "" when unknown.
func _volume_path(volume) -> String:
	var dir = volume.getDirectory()
	if not JavaClassWrapper.get_exception() and dir != null:
		var path := str(dir.getAbsolutePath())
		if not JavaClassWrapper.get_exception() and not path.is_empty():
			return path
	var uuid = volume.getUuid()
	if JavaClassWrapper.get_exception() or uuid == null:
		return ""
	var id := str(uuid)
	if id.is_empty():
		return ""
	return "/storage".path_join(id)


## Report for the /drives chat command.
func diagnosis() -> String:
	if OS.get_name() != "Android":
		return ""
	var lines: Array[String] = []
	var media := preload("res://src/media/media_commands.gd")
	if not media.has_all_files_access():
		lines.append("All Files Access is NOT granted — see QUEST.md.")
	if _android_activity() == null:
		lines.append("No Android activity: cannot ask the OS about volumes.")
	var mounts := _proc_mount_roots()
	lines.append("/proc/mounts under /storage: %s" % (
		", ".join(mounts) if mounts.size() > 0 else "(none)"))
	for root in _android_roots():
		var openable: bool = DirAccess.open(root) != null
		lines.append("  %s  %s" % [root, "readable" if openable else "NOT readable"])
	return "\n".join(lines)
