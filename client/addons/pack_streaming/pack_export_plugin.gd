@tool
extends EditorExportPlugin
## Web exports only. The web main pck excludes every pack root listed in
## tools/packs.json (the export preset's exclude filter mirrors that list), yet
## scenes such as workspace_local.tscn instance the city, theater, school and
## props from those folders directly. Exported as-is, those instances would be
## missing dependencies. So for each exported .tscn this plugin rewrites
##     [node name="theater" parent="." instance=ExtResource("36_uo53f")]
## into
##     [node name="theater" parent="." instance_placeholder="res://assets/art/models/theater/theater.tscn"]
## and drops the now-unused ext_resource line. Godot loads an InstancePlaceholder
## without touching the target scene; PCKManager.materialize_placeholders()
## turns it into the real instance (same name, transform, editor-placed
## children) once the owning pack is mounted. Desktop, Quest and editor runs
## are untouched: they bundle the content and keep the plain instances.

const PackBuilder := preload("res://tools/pack_builder.gd")

var _active := false
var _roots := PackedStringArray()
# Scenes outside the roots that keep a streamed resource as a plain property
# (a texture on a material, say): they cannot load without the pack, so their
# own instances become placeholders too and wait for the pack.
var _tainted := {}
var _ext_re := RegEx.create_from_string(
	"(?m)^\\[ext_resource type=\"([^\"]+)\"(?: uid=\"[^\"]*\")? path=\"([^\"]+)\" id=\"([^\"]+)\"\\][ \\t]*\\r?\\n?")


func _get_name() -> String:
	return "PackStreaming"


func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_active = features.has("web")
	_roots = PackBuilder.all_roots() if _active else PackedStringArray()
	_tainted = {}
	if not _active:
		return
	for scene in _list_scenes("res://"):
		if _in_streamed_root(scene):
			continue
		if _streamed_property_refs(FileAccess.get_file_as_string(scene)).size() > 0:
			_tainted[scene] = true
	print("[PackStreaming] Web export: ", _roots.size(), " streamed root(s), ",
		_tainted.size(), " scene(s) bound to them by property; instances of either become placeholders")


func _export_end() -> void:
	_active = false


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if not _active or not path.ends_with(".tscn") or _in_streamed_root(path):
		return
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return
	var out := _placeholderize(text, path)
	if out == text:
		return
	add_file(path, out.to_utf8_buffer(), false)
	skip()


func _in_streamed_root(path: String) -> bool:
	for r in _roots:
		if path.begins_with(r):
			return true
	return false


func _is_streamed(path: String) -> bool:
	return _in_streamed_root(path) or _tainted.has(path)


## ext_resource ids of streamed resources that the text uses other than as a
## node's instance= (those cannot become placeholders).
func _streamed_property_refs(text: String) -> Array:
	var refs := []
	for m in _ext_re.search_all(text):
		if not _in_streamed_root(m.get_string(2)):
			continue
		var ref := "ExtResource(\"%s\")" % m.get_string(3)
		if text.count(ref) > text.count("instance=" + ref):
			refs.append(m.get_string(2))
	return refs


func _list_scenes(root: String) -> Array:
	var result := []
	var dir := DirAccess.open(root)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := root + entry
		if dir.current_is_dir():
			if not entry.begins_with(".") and entry != "android" and entry != "addons":
				result.append_array(_list_scenes(full + "/"))
		elif entry.ends_with(".tscn"):
			result.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return result


func _placeholderize(text: String, scene_path: String) -> String:
	var streamed := {}  # ext id -> {path, type}
	for m in _ext_re.search_all(text):
		if _is_streamed(m.get_string(2)):
			streamed[m.get_string(3)] = {"path": m.get_string(2), "type": m.get_string(1), "line": m.get_string()}
	if streamed.is_empty():
		return text
	var swapped := 0
	for id in streamed:
		var info: Dictionary = streamed[id]
		var ref := "ExtResource(\"%s\")" % id
		if info["type"] == "PackedScene":
			var before := text.count("instance=" + ref)
			text = text.replace("instance=" + ref, "instance_placeholder=\"%s\"" % info["path"])
			swapped += before
		if text.count(ref) == 0:
			text = text.replace(info["line"], "")
		elif _tainted.has(scene_path):
			pass  # expected: this scene is itself streamed-by-property and only ever loads once its pack is mounted
		else:
			push_warning("[PackStreaming] %s still references streamed %s '%s' as a property; it cannot be a placeholder and will be missing until its pack mounts"
				% [scene_path, info["type"], info["path"]])
	if swapped > 0:
		print("[PackStreaming] ", scene_path, ": ", swapped, " instance(s) exported as placeholders")
	return text
