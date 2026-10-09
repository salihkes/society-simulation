extends RefCounted
## Builds the server-streamed .pck packs declared in res://tools/packs.json.
## Runtime-safe (PCKPacker/DirAccess/FileAccess only), so it runs headless:
##   godot --headless --path . --script res://tools/build_packs_cli.gd [-- name ... --mobile]
##
## For every pack it gathers the files under the pack's roots — scenes, scripts,
## resources, data files, and for imported assets the .import sidecar plus its
## artifacts under res://.godot/imported/ (raw .glb/.png/.wav sources are NOT
## packed; the imported artifacts are what the game loads). It then:
##   * computes a content hash of everything it would pack and writes it next to
##     the pack as <name>.pck.version. pck_server.py serves that string as the
##     pack's version, so clients re-download a pack only when its content
##     really changed — and an unchanged pack is not even rewritten here, which
##     keeps its mtime stable too;
##   * writes the pack's metadata (required, priority, on_demand, probe_path) into
##     server/assets/pck_manifest.json, where the server merges it with
##     on-disk discovery. probe_path is a res:// path inside the pack; builds that
##     bundle the content (desktop, editor) resolve it and skip the download.
## Packs carry no scene_path: placement is owned by the scenes that instance
## them (as InstancePlaceholders in the web build — see addons/pack_streaming).

const PACKS_JSON := "res://tools/packs.json"
# Server asset directory, relative to the Godot project root (res:// == client/).
const OUT_DIR_REL := "res://../server/assets/pck/"
const MANIFEST_REL := "res://../server/assets/pck_manifest.json"
const IMPORTED_PREFIX := "res://.godot/imported/"
const MANIFEST_COMMENT := "Streamed packs. Entries are written by client/tools/pack_builder.gd from tools/packs.json (required/priority/on_demand/probe_path); version comes from <name>.pck.version next to each pack, or size+mtime when that file is absent. Any other *.pck dropped into assets/pck/ is auto-served too. Packs carry no scene_path on purpose: the scenes that use them (workspace_local.tscn and friends) place them, so the headless world process never instantiates anything extra."


## No packs.json means no streamed packs; build_all() says how to declare some.
static func load_packs() -> Dictionary:
	if not FileAccess.file_exists(PACKS_JSON):
		return {}
	var f := FileAccess.open(PACKS_JSON, FileAccess.READ)
	if f == null:
		push_error("[Packs] Cannot read " + PACKS_JSON)
		return {}
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY or not data.has("packs"):
		push_error("[Packs] " + PACKS_JSON + " has no \"packs\" object")
		return {}
	return data["packs"]


## Every root folder of every pack (used by the export plugin to exclude them).
static func all_roots() -> PackedStringArray:
	var roots := PackedStringArray()
	var packs := load_packs()
	for name in packs:
		for r in packs[name].get("roots", []):
			roots.append(_norm_root(str(r)))
	return roots


# `args` are the user command-line args: pack names limit the build to those
# packs (none = build everything); "--mobile" also packs the etc2/astc texture
# variants Android clients need (desktop and web use s3tc only).
static func build_all(args: PackedStringArray = []) -> void:
	if not FileAccess.file_exists(PACKS_JSON):
		push_error("[Packs] No %s: copy tools/packs.example.json to tools/packs.json and list your packs" % PACKS_JSON)
		return
	var packs := load_packs()
	if packs.is_empty():
		return
	var mobile := args.has("--mobile")
	var only := PackedStringArray()
	for a in args:
		if not a.begins_with("--"):
			only.append(a)
	var out_dir := ProjectSettings.globalize_path(OUT_DIR_REL)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var manifest := _load_manifest()
	var built := 0
	var unchanged := 0
	print("[Packs] Output dir: ", out_dir)
	for name in packs:
		if not only.is_empty() and not only.has(name):
			continue
		var def: Dictionary = packs[name]
		var result := _build_pack(name, def, out_dir, mobile)
		if result.is_empty():
			continue
		if result["rebuilt"]:
			built += 1
		else:
			unchanged += 1
		var entry := {
			"filename": name + ".pck",
			"probe_path": result["probe_path"],
			"priority": int(def.get("priority", 1000)),
		}
		if bool(def.get("required", false)):
			entry["required"] = true
		# A pack nobody should be made to download: a player's own character.
		# It is fetched when someone who uses it actually turns up.
		if bool(def.get("on_demand", false)):
			entry["on_demand"] = true
		# One place's content: held until the player enters that region.
		if str(def.get("region", "")) != "":
			entry["region"] = str(def.region)
		if bool(def.get("on_demand", false)) or str(def.get("region", "")) != "":
			# Only a held-back pack needs to say what it covers: it is the one
			# case where a path has to find its pack before the pack is here.
			entry["roots"] = def.get("roots", [])
		manifest["packages"][name] = entry
	_save_manifest(manifest)
	print("[Packs] Done. ", built, " rebuilt, ", unchanged, " unchanged; manifest -> ",
		ProjectSettings.globalize_path(MANIFEST_REL))


static func _build_pack(name: String, def: Dictionary, out_dir: String, mobile: bool) -> Dictionary:
	var files := {}  # res_path -> true
	var roots: Array = []
	for root in def.get("roots", []):
		var r := _norm_root(str(root))
		if not DirAccess.dir_exists_absolute(r):
			push_warning("[Packs] '" + name + "': root does not exist: " + r)
			continue
		roots.append(r)
	var entries: Array = def.get("entries", [])
	if entries.is_empty():
		# Whole folders: everything under the roots ships.
		for r in roots:
			for f in _list_files_recursive(r):
				_add_file(f, files, mobile)
	else:
		# Only what the entry files pull in (transitively), kept within the
		# roots — anything they reference outside lives in the main build or
		# another pack. Stale leftovers next to the entries stay out.
		var visited := {}
		for e in entries:
			_add_closure(str(e), roots, files, visited, mobile)
	if files.is_empty():
		push_warning("[Packs] Skipping '" + name + "': nothing to pack (imported in the editor?)")
		return {}

	var paths: Array = files.keys()
	paths.sort()
	var missing := []
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for p in paths:
		if not FileAccess.file_exists(p):
			missing.append(p)
			continue
		ctx.update((p + ":" + FileAccess.get_sha256(p) + "\n").to_utf8_buffer())
	var version := ctx.finish().hex_encode().substr(0, 16)
	if not missing.is_empty():
		push_warning("[Packs] '" + name + "' is missing " + str(missing.size())
			+ " file(s) — reimport the folder in the editor: " + str(missing))

	var probe := _probe_path(paths)
	var out_path := out_dir.path_join(name + ".pck")
	var ver_path := out_path + ".version"
	if FileAccess.file_exists(out_path) and FileAccess.file_exists(ver_path) \
			and FileAccess.get_file_as_string(ver_path).strip_edges() == version:
		print("[Packs] ", name, ".pck unchanged (", version, ")")
		return {"probe_path": probe, "rebuilt": false}

	var packer := PCKPacker.new()
	var err := packer.pck_start(out_path)
	if err != OK:
		push_error("[Packs] pck_start failed for '" + name + "': " + str(err))
		return {}
	var packed := 0
	for p in paths:
		if not FileAccess.file_exists(p):
			continue
		if packer.add_file(p, p) == OK:
			packed += 1
		else:
			push_warning("[Packs] add_file failed: " + p)
	err = packer.flush(true)
	if err != OK:
		push_error("[Packs] flush failed for '" + name + "': " + str(err))
		return {}
	var vf := FileAccess.open(ver_path, FileAccess.WRITE)
	if vf:
		vf.store_string(version + "\n")
		vf.close()
	var size_mb := float(FileAccess.open(out_path, FileAccess.READ).get_length()) / 1048576.0
	print("[Packs] Built ", name, ".pck  (", packed, " files, %.1f MB, version " % size_mb, version, ")")
	return {"probe_path": probe, "rebuilt": true}


## Add a source file to the pack set: imported assets contribute their .import
## sidecar plus imported artifacts (never the raw .glb/.png/.wav); anything
## else ships as-is.
static func _add_file(f: String, files: Dictionary, mobile: bool) -> void:
	if f.ends_with(".import"):
		files[f] = true
		for artifact in _imported_artifacts(f):
			if _wanted_artifact(artifact, mobile):
				files[artifact] = true
	elif FileAccess.file_exists(f + ".import"):
		_add_file(f + ".import", files, mobile)
	else:
		files[f] = true


## Textures import once per GPU family. Web and desktop load the s3tc variant;
## the etc2/astc one is only for Android (Quest), so it ships only with --mobile.
static func _wanted_artifact(artifact: String, mobile: bool) -> bool:
	if artifact.contains(".etc2.") or artifact.contains(".astc."):
		return mobile
	return true


static func _add_closure(path: String, roots: Array, files: Dictionary, visited: Dictionary, mobile: bool) -> void:
	if visited.has(path):
		return
	visited[path] = true
	var in_scope := false
	for r in roots:
		if path.begins_with(r):
			in_scope = true
			break
	if not in_scope:
		return
	if not FileAccess.file_exists(path):
		push_warning("[Packs] entry/dependency not found: " + path)
		return
	_add_file(path, files, mobile)
	if path.get_extension() in ["gd", "gdshader", "json", "txt", "md", "import"]:
		return
	for dep in ResourceLoader.get_dependencies(path):
		var dep_path := _dependency_path(str(dep))
		if dep_path != "":
			_add_closure(dep_path, roots, files, visited, mobile)


static func _dependency_path(dep: String) -> String:
	# get_dependencies() entries look like "uid://x::res://path" or "res://path".
	var parts := dep.split("::")
	for i in range(parts.size() - 1, -1, -1):
		if parts[i].begins_with("res://"):
			return parts[i]
	if parts[0].begins_with("uid://"):
		var id := ResourceUID.text_to_id(parts[0])
		if ResourceUID.has_id(id):
			return ResourceUID.get_id_path(id)
	return ""


## A res:// path that resolves once the pack is mounted (or bundled): a scene if
## the pack has one, else the source path of an imported asset, else any file.
static func _probe_path(paths: Array) -> String:
	for p in paths:
		if (p.ends_with(".tscn") or p.ends_with(".scn")) and not p.begins_with(IMPORTED_PREFIX):
			return p
	for p in paths:
		if p.ends_with(".import"):
			return p.trim_suffix(".import")
	for p in paths:
		if not p.begins_with(IMPORTED_PREFIX):
			return p
	return ""


static func _norm_root(r: String) -> String:
	return r if r.ends_with("/") else r + "/"


static func _load_manifest() -> Dictionary:
	var manifest := {"packages": {}}
	var path := ProjectSettings.globalize_path(MANIFEST_REL)
	if FileAccess.file_exists(path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(data) == TYPE_DICTIONARY:
			manifest = data
	if typeof(manifest.get("packages")) != TYPE_DICTIONARY:
		manifest["packages"] = {}
	manifest["_comment"] = MANIFEST_COMMENT
	return manifest


static func _save_manifest(manifest: Dictionary) -> void:
	var path := ProjectSettings.globalize_path(MANIFEST_REL)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[Packs] Cannot write manifest " + path)
		return
	f.store_string(JSON.stringify(manifest, "\t") + "\n")
	f.close()


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
# references (single-output [remap] path=... and multi-output [deps] dest_files).
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
