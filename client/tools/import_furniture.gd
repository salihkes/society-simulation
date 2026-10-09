extends SceneTree
## Turns a dropped .glb into a placeable plot object.
##
## The plot build tools (BuildPlots / plot_object_tool.gd) place whatever
## folders live under assets/assets/Objects/, preferring mesh.tscn over a bare
## mesh.glb. A raw AI-generated .glb is not usable as-is:
##
##   * it is normalised to a 1-unit box, and plot objects are children of the
##     0.2-scaled workspace, so it would appear 20 cm across whatever it is;
##   * it carries no collider, so the build tools could not raycast it
##     (no selecting, no dragging) and "drop to floor" would fall through it.
##
## So for every assets/assets/Objects/<name>/model.glb this writes a mesh.tscn
## that instances the model, scales it to a real-world size, and wraps it in
## a StaticBody3D box collider.
##
## Size and label come from <name>/object.json:
##     {"label": "Boho Bed", "size_m": 2.1, "source": "Meshy_AI_….glb"}
## size_m is the object's LONGEST dimension in metres; edit it and re-run to
## resize. Missing file or size → DEFAULT_SIZE_M.
##
##   godot --headless --path client --script res://tools/import_furniture.gd
##   …same, then `-- --force` to rebuild scenes that already exist
##   …same, then `-- boho_bed boho_rattan_chair` to do only those

const OBJECTS_DIR := "res://assets/assets/Objects"
const DEFAULT_SIZE_M := 1.0
## Workspace units per metre: the world root is scaled 0.2 (ARCHITECTURE.md).
const UNITS_PER_M := 5.0
## Web weight is texture weight, so albedo is capped project-wide at 1024
## (ARCHITECTURE.md, "Textures"). Generators hand out 2048 maps, which would
## quadruple this pack for detail nobody sees on a chair.
const TEXTURE_LIMIT := 1024
## Furniture sits on its own collision layer, NOT the player's layer 1, so
## you walk through a sofa instead of being stopped by the box around it.
## The build tools still find it: their raycasts search every layer, so a
## piece stays clickable, draggable, and something other pieces rest on.
const FURNITURE_LAYER := 4      # layer 3


var failures := 0
var built := 0
var skipped := 0
var retextured := 0


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var force := "--force" in args
	var only: Array = []
	for a in args:
		if not a.begins_with("--"):
			only.append(a)

	var dir := DirAccess.open(OBJECTS_DIR)
	if dir == null:
		push_error("No such directory: " + OBJECTS_DIR)
		quit(1)
		return

	for name in dir.get_directories():
		if name.begins_with("."):
			continue
		if not only.is_empty() and not (name in only):
			continue
		_build(name, force)

	print("\nfurniture: %d built, %d skipped, %d failed" % [built, skipped, failures])
	if retextured > 0:
		print("%d texture(s) capped to %dpx — run the importer once more to apply:" %
			[retextured, TEXTURE_LIMIT])
		print("  godot --headless --path client --import")
	quit(1 if failures > 0 else 0)


func _build(name: String, force: bool) -> void:
	var folder := OBJECTS_DIR + "/" + name
	var glb_path := folder + "/model.glb"
	var out_path := folder + "/mesh.tscn"

	if not ResourceLoader.exists(glb_path):
		print("  %-22s no model.glb — skipped" % name)
		skipped += 1
		return
	if FileAccess.file_exists(out_path) and not force:
		print("  %-22s mesh.tscn exists — skipped (use --force)" % name)
		skipped += 1
		return

	var meta := _read_meta(folder)
	var target_m: float = maxf(0.01, float(meta.get("size_m", DEFAULT_SIZE_M)))

	var source: PackedScene = load(glb_path)
	if source == null:
		push_error("FAIL %s: could not load %s" % [name, glb_path])
		failures += 1
		return
	var model: Node3D = source.instantiate()
	if model == null:
		push_error("FAIL %s: %s is not a 3D scene" % [name, glb_path])
		failures += 1
		return

	# Measure the model as authored, before scaling.
	var root := Node3D.new()
	root.name = name
	root.add_child(model)
	model.name = "Model"
	var raw := _aabb_of(model)
	if raw.size.length() <= 0.0:
		push_error("FAIL %s: model has no visible geometry" % name)
		failures += 1
		root.free()
		return

	# Longest dimension becomes target_m metres. Plot objects hang under the
	# 0.2-scaled workspace, so a metre is UNITS_PER_M units of our own space.
	var longest: float = maxf(raw.size.x, maxf(raw.size.y, raw.size.z))
	var factor: float = (target_m * UNITS_PER_M) / longest
	model.scale = Vector3.ONE * factor

	# Box collider around the scaled bounds: what the build tools raycast to
	# select and drag, and what other pieces rest on. It deliberately does
	# NOT block anybody walking — see FURNITURE_LAYER.
	var box := AABB(raw.position * factor, raw.size * factor)
	var body := StaticBody3D.new()
	body.name = "Body"
	body.collision_layer = FURNITURE_LAYER
	body.collision_mask = 0
	root.add_child(body)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	shape.shape = box_shape
	shape.position = box.get_center()
	body.add_child(shape)

	for child in [model, body, shape]:
		child.owner = root

	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		push_error("FAIL %s: could not pack the scene" % name)
		failures += 1
		root.free()
		return
	var err := ResourceSaver.save(packed, out_path)
	if err != OK:
		push_error("FAIL %s: could not write %s (error %d)" % [name, out_path, err])
		failures += 1
		root.free()
		return

	var capped := _cap_textures(folder)

	var world := box.size / UNITS_PER_M   # what the player will see, in metres
	print("  %-22s %-22s %.2f x %.2f x %.2f m%s" %
		[name, str(meta.get("label", name)), world.x, world.y, world.z,
		"   (capped %d texture(s))" % capped if capped > 0 else ""])
	built += 1
	root.free()


## Hold this object's textures to TEXTURE_LIMIT, the cap the rest of the
## project uses. Rewrites the .import files; Godot applies it on the next
## import pass, which run() asks for when anything changed here.
func _cap_textures(folder: String) -> int:
	var dir := DirAccess.open(folder)
	if dir == null:
		return 0
	var changed := 0
	for file in dir.get_files():
		if not file.ends_with(".import"):
			continue
		var stem := file.trim_suffix(".import").to_lower()
		if not (stem.ends_with(".png") or stem.ends_with(".jpg") or stem.ends_with(".jpeg")
				or stem.ends_with(".webp")):
			continue
		var path := folder + "/" + file
		var cfg := ConfigFile.new()
		if cfg.load(path) != OK:
			continue
		if int(cfg.get_value("params", "process/size_limit", 0)) == TEXTURE_LIMIT:
			continue
		cfg.set_value("params", "process/size_limit", TEXTURE_LIMIT)
		if cfg.save(path) == OK:
			changed += 1
	retextured += changed
	return changed


func _read_meta(folder: String) -> Dictionary:
	var path := folder + "/object.json"
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## Bounds of every visual mesh in the subtree, in `node`'s own local space.
##
## Walks the local transforms rather than reading global_transform: this runs
## on a scene that was instantiated but never added to the tree, where
## global_transform is not available and silently returns the identity.
func _aabb_of(node: Node3D) -> AABB:
	var result := AABB()
	var found := false
	# Each entry is [node, transform of that node relative to `node`].
	var stack: Array = [[node, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var current: Node = entry[0]
		var xform: Transform3D = entry[1]
		if current is VisualInstance3D:
			var b: AABB = xform * (current as VisualInstance3D).get_aabb()
			result = result.merge(b) if found else b
			found = true
		for child in current.get_children():
			if child is Node3D:
				stack.push_back([child, xform * (child as Node3D).transform])
	return result if found else AABB()
