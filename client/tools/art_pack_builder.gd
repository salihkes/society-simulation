extends RefCounted
## Shared implementation for the art-pack build. Used by:
##   - tools/build_art_packs.gd      (EditorScript, File > Run in the editor)
##   - tools/build_art_packs_cli.gd  (SceneTree, headless command line)
## Uses only runtime-safe classes (PCKPacker/DirAccess/FileAccess/ConfigFile),
## so it works both inside the editor and in a plain --headless run.
## See build_art_packs.gd for the full documentation of what gets packed.

const SRC_ROOT := "res://assets/art/models/"
# Server asset directory, relative to the Godot project root (res:// == client/).
const OUT_DIR_REL := "res://../server/assets/pck/"
const IMPORTED_PREFIX := "res://.godot/imported/"
# Files packed verbatim (scenes + saved resources). Everything else is either an
# .import sidecar (handled specially) or a raw source we skip.
# "lmbake" carries baked LightmapGI data; its lightmap texture (.exr) ships as
# an imported artifact via the .import sidecar, so the raw .exr is NOT listed.
const DIRECT_EXTS := ["scn", "tscn", "tres", "res", "material", "mesh", "shader", "gd", "lmbake"]


# `only` limits the build to the given pack names (empty = build everything).
# Rebuilding a pack changes its mtime-derived version and makes every client
# re-download it, so partial rebuilds matter for incremental updates.
static func build_all(only: PackedStringArray = []) -> void:
	var out_dir := ProjectSettings.globalize_path(OUT_DIR_REL)
	DirAccess.make_dir_recursive_absolute(out_dir)

	var names := _list_subdirs(SRC_ROOT)
	if names.is_empty():
		push_warning("[ArtPacks] No model folders found under " + SRC_ROOT)
		return

	print("[ArtPacks] Output dir: ", out_dir)
	if not only.is_empty():
		print("[ArtPacks] Limited to: ", ", ".join(only))
	var snippets := []
	var built := 0
	for name in names:
		# A folder containing a ".packgroup" marker file is a pack GROUP: each of
		# its subfolders becomes its own independently-streamed pack, named
		# <group>_<subfolder>.pck (used by the split city under city_compare/).
		if FileAccess.file_exists(SRC_ROOT + name + "/.packgroup"):
			for sub in _list_subdirs(SRC_ROOT + name + "/"):
				if not only.is_empty() and not only.has(name + "_" + sub):
					continue
				var group_snip := _build_pack(name + "/" + sub, name + "_" + sub, out_dir)
				built += 1
				if group_snip != "":
					snippets.append(group_snip)
			continue
		if not only.is_empty() and not only.has(name):
			continue
		var snip := _build_pack(name, name, out_dir)
		built += 1
		if snip != "":
			snippets.append(snip)
	print("[ArtPacks] Done. Built ", built, " pack(s).")

	if not snippets.is_empty():
		print("\n[ArtPacks] Suggested pck_manifest.json entries ",
			"(edit required/priority; keep only the packs that need metadata):")
		print("{\n  \"packages\": {\n" + ",\n".join(snippets) + "\n  }\n}")


static func _list_subdirs(root: String) -> Array:
	var result := []
	var dir := DirAccess.open(root)
	if dir == null:
		push_error("[ArtPacks] Cannot open " + root)
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			result.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return result


# Returns a manifest-snippet string for this pack (or "" if the pack was skipped).
# rel_folder is the path under SRC_ROOT ("city_compare/base"); pack_name is the
# output .pck name ("city_compare_base") — identical for plain top-level packs.
static func _build_pack(rel_folder: String, pack_name: String, out_dir: String) -> String:
	var folder := SRC_ROOT + rel_folder + "/"
	var name := pack_name

	# Collect the res:// paths this pack must carry.
	var to_pack := {}  # res_path -> true (dedup)
	for f in _list_files_recursive(folder):
		var ext: String = f.get_extension().to_lower()
		if DIRECT_EXTS.has(ext):
			to_pack[f] = true
		elif ext == "import":
			to_pack[f] = true
			for artifact in _imported_artifacts(f):
				to_pack[artifact] = true
		# Raw source files (.glb/.fbx/.png/.jpg/...) are covered by their imported
		# artifacts, so we skip them to keep the pack small.

	if to_pack.is_empty():
		push_warning("[ArtPacks] Skipping '" + name + "': no packable files found"
			+ " (did you import the folder in the editor first?)")
		return ""

	var out_path := out_dir.path_join(name + ".pck")
	var packer := PCKPacker.new()
	var err := packer.pck_start(out_path)
	if err != OK:
		push_error("[ArtPacks] pck_start failed for '" + name + "': " + str(err))
		return ""

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
			push_warning("[ArtPacks] add_file failed: " + res_path + " (" + str(add_err) + ")")

	err = packer.flush(true)
	if err != OK:
		push_error("[ArtPacks] flush failed for '" + name + "': " + str(err))
		return ""

	if not missing.is_empty():
		push_warning("[ArtPacks] '" + name + "' missing " + str(missing.size())
			+ " file(s) — did you (re)import the folder in the editor first? " + str(missing))

	print("[ArtPacks] Built ", name, ".pck  (", packed, " files) -> ", out_path)

	# Suggest a manifest entry, pre-filling scene_path if there's an entry scene.
	var entry_scene := _find_entry_scene(folder)
	var fields := []
	if entry_scene != "":
		fields.append("\"scene_path\": \"%s\"" % entry_scene)
	fields.append("\"required\": false")
	fields.append("\"priority\": 100")
	return "    \"%s\": { %s }" % [name, ", ".join(fields)]


static func _find_entry_scene(folder: String) -> String:
	for candidate in ["main.scn", "main.tscn"]:
		if FileAccess.file_exists(folder + candidate):
			return folder + candidate
	return ""


static func _list_files_recursive(root: String) -> Array:
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
# references (res://.godot/imported/...). Covers both single-output imports
# ([remap] path=...) and multi-output imports ([deps] dest_files=[...]).
static func _imported_artifacts(import_path: String) -> Array:
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
