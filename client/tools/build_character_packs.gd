@tool
extends EditorScript
## Builds a mountable .pck for every custom (Mixamo-rigged) character folder so
## the server can deliver them at runtime instead of baking them into the game.
##
## HOW TO RUN
##   Open this file in the Godot script editor and choose  File ▸ Run
##   (Ctrl+Shift+X). Watch the Output panel for the per-pack summary.
##
## WHAT IT DOES
##   For each folder under res://assets/entities/custom_character/<name>/ it writes
##   <name>.pck straight into the server's asset dir:
##       ../server/assets/pck/<name>.pck
##   Each pack contains that folder's .tscn plus the *.import sidecars and their
##   imported artifacts (res://.godot/imported/*), which is exactly what Godot
##   needs to resolve the character at its original res:// path once the pack is
##   mounted with ProjectSettings.load_resource_pack() (done by PCKManager).
##
##   Raw source assets (.fbx / .jpg) are intentionally NOT packed — the game
##   loads the imported artifacts, so the pack stays a fraction of the source
##   size (a 47 MB Char.fbx becomes its much smaller imported mesh).
##
## AFTER RUNNING
##   The server auto-discovers new .pck files (see server/pck_server.py
##   get_pck_manifest), so there is nothing else to edit — restart the game
##   server (or just have clients reconnect) and the pack is delivered. The
##   version string is derived from the file, so re-running after a change makes
##   every client re-download only that pack.

const SRC_ROOT := "res://assets/entities/custom_character/"
# Server asset directory, relative to the Godot project root (res:// == client/).
const OUT_DIR_REL := "res://../server/assets/pck/"
const IMPORTED_PREFIX := "res://.godot/imported/"

func _run() -> void:
	var out_dir := ProjectSettings.globalize_path(OUT_DIR_REL)
	DirAccess.make_dir_recursive_absolute(out_dir)

	var names := _list_subdirs(SRC_ROOT)
	if names.is_empty():
		push_warning("[CharacterPacks] No character folders found under " + SRC_ROOT)
		return

	print("[CharacterPacks] Output dir: ", out_dir)
	for name in names:
		_build_pack(name, out_dir)
	print("[CharacterPacks] Done. Built ", names.size(), " pack(s).")

func _list_subdirs(root: String) -> Array:
	var result := []
	var dir := DirAccess.open(root)
	if dir == null:
		push_error("[CharacterPacks] Cannot open " + root)
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			result.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return result

func _build_pack(name: String, out_dir: String) -> void:
	var folder := SRC_ROOT + name + "/"
	# The scene must exist or the character is unusable.
	var entry_scene := folder + "humanoid.tscn"
	if not FileAccess.file_exists(entry_scene):
		push_warning("[CharacterPacks] Skipping '" + name + "': no humanoid.tscn")
		return

	# Collect the res:// paths this pack must carry.
	var to_pack := {}  # res_path -> true (dedup)
	for f in _list_files_recursive(folder):
		if f.ends_with(".tscn") or f.ends_with(".tres") or f.ends_with(".material"):
			to_pack[f] = true
		elif f.ends_with(".import"):
			to_pack[f] = true
			for artifact in _imported_artifacts(f):
				to_pack[artifact] = true
		# Raw source files (.fbx/.jpg/.png/.wav/...) are covered by their imported
		# artifacts, so we skip them to keep the pack small.

	var out_path := out_dir.path_join(name + ".pck")
	var packer := PCKPacker.new()
	var err := packer.pck_start(out_path)
	if err != OK:
		push_error("[CharacterPacks] pck_start failed for '" + name + "': " + str(err))
		return

	var packed := 0
	var missing := []
	for res_path in to_pack.keys():
		if not FileAccess.file_exists(res_path):
			missing.append(res_path)
			continue
		var add_err := packer.add_file(res_path, res_path)
		if add_err == OK:
			packed += 1
		else:
			push_warning("[CharacterPacks] add_file failed: " + res_path + " (" + str(add_err) + ")")

	err = packer.flush(true)
	if err != OK:
		push_error("[CharacterPacks] flush failed for '" + name + "': " + str(err))
		return

	if not missing.is_empty():
		push_warning("[CharacterPacks] '" + name + "' missing " + str(missing.size())
			+ " file(s) — did you (re)import the folder in the editor first? " + str(missing))

	print("[CharacterPacks] Built ", name, ".pck  (", packed, " files) -> ", out_path)

func _list_files_recursive(root: String) -> Array:
	var result := []
	var dir := DirAccess.open(root)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := root + entry
		if dir.current_is_dir():
			if not entry.begins_with("."):
				result.append_array(_list_files_recursive(full + "/"))
		else:
			result.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return result

# Parse a .import sidecar and return every imported-artifact res:// path it
# references (res://.godot/imported/...). Covers both texture imports
# ([remap] path=...) and multi-output imports ([deps] dest_files=[...]).
func _imported_artifacts(import_path: String) -> Array:
	var artifacts := []
	var cfg := ConfigFile.new()
	if cfg.load(import_path) != OK:
		return artifacts

	var remap_path = cfg.get_value("remap", "path", "")
	if typeof(remap_path) == TYPE_STRING and remap_path.begins_with(IMPORTED_PREFIX):
		artifacts.append(remap_path)

	var dest_files = cfg.get_value("deps", "dest_files", [])
	if typeof(dest_files) == TYPE_ARRAY:
		for d in dest_files:
			if typeof(d) == TYPE_STRING and d.begins_with(IMPORTED_PREFIX):
				artifacts.append(d)

	return artifacts
