extends SceneTree
## Only the web build streams. Every other target bundles its content and must
## never fetch a pack at runtime, so a non-web preset may not exclude anything
## that tools/packs.json declares streamed. The Quest preset once excluded
## "*assets/art/models/*" and streamed it back through PCKManager; this is the
## check that stops that returning unnoticed.
##
##   godot --headless --path client -s res://tests/test_presets.gd

const PACKS := "res://tools/packs.json"
const PRESETS := "res://export_presets.cfg"

var failures := 0
## "[preset.3]" opens a preset; "[preset.3.options]" continues it.
var _RE_PRESET := RegEx.create_from_string("^\\[preset\\.[0-9]+\\]$")


func _init() -> void:
	print("== export preset test ==")
	var roots := _pack_roots()
	if roots.is_empty():
		_fail("could not read pack roots from " + PACKS)
		quit(1)
		return
	for preset in _presets() + _presets("res://export_presets.quest.cfg"):
		var name: String = preset["name"]
		var web := str(preset["platform"]) == "Web"
		var excluded: String = preset["exclude"]
		if web:
			print("  --   %s (web: streaming is expected here)" % name)
			continue
		var offenders := []
		for glob in excluded.split(","):
			var g := glob.strip_edges()
			if g == "":
				continue
			for r in roots:
				if _glob_hits(g, r):
					offenders.append("%s → %s" % [g, r])
					break
		if offenders.is_empty():
			print("  ok   %s bundles every streamed root" % name)
		else:
			_fail("%s excludes streamed content, so it would download at runtime: %s"
				% [name, ", ".join(offenders)])
		# export_filter="exclude" means export_files is a list of files to LEAVE
		# OUT, one checkbox at a time in the editor. The Quest preset carried 143
		# of them, including workspace.gd and plot_ui.tscn, which the main scene
		# needs — the build installed fine and then died on the loading screen
		# with "Failed loading scene". A non-web build has no reason to drop
		# single files, so any entry at all is a fault.
		if str(preset["filter"]) == "exclude" and preset["files"] > 0:
			_fail("%s drops %d file(s) one by one (export_files); a non-web build ships everything"
				% [name, preset["files"]])
		else:
			print("  ok   %s drops no individual files" % name)
	print("== done, %d failure(s) ==" % failures)
	quit(1 if failures > 0 else 0)


func _fail(what: String) -> void:
	failures += 1
	print("  FAIL " + what)


## A pack root the glob would strip. Roots are plain folder prefixes, so a
## simple containment test is enough for the shapes these filters use.
func _glob_hits(glob: String, root: String) -> bool:
	var g := glob.replace("res://", "").trim_prefix("*").trim_suffix("*")
	return g != "" and root.find(g) >= 0


func _pack_roots() -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open(PACKS, FileAccess.READ)
	if f == null:
		return out
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY or not data.has("packs"):
		return out
	for name in data["packs"]:
		for r in data["packs"][name].get("roots", []):
			out.append(str(r).replace("res://", ""))
	return out


## [{name, platform, exclude}] straight out of export_presets.cfg.
func _presets(path: String = PRESETS) -> Array:
	var out := []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_fail("could not read export presets from " + path)
		return out
	var cur := {}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if _RE_PRESET.search(line) != null:
			if cur.has("name"):
				out.append(cur)
			cur = {"name": "?", "platform": "?", "exclude": "", "filter": "", "files": 0}
		elif line.begins_with("name="):
			cur["name"] = line.substr(5).strip_edges().trim_prefix('"').trim_suffix('"')
		elif line.begins_with("platform="):
			cur["platform"] = line.substr(9).strip_edges().trim_prefix('"').trim_suffix('"')
		elif line.begins_with("exclude_filter="):
			cur["exclude"] = line.substr(15).strip_edges().trim_prefix('"').trim_suffix('"')
		elif line.begins_with("export_filter="):
			cur["filter"] = line.substr(14).strip_edges().trim_prefix('"').trim_suffix('"')
		elif line.begins_with("export_files="):
			cur["files"] = line.count("res://")
	if cur.has("name") and cur["name"] != "?":
		out.append(cur)
	return out
