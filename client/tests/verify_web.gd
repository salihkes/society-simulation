extends SceneTree
## Checks an exported web build without a browser.
##
## The web main pck holds only scripts, scenes and the local player; everything
## heavy is an InstancePlaceholder that PCKManager fills in as its pack mounts
## (see ARCHITECTURE.md, "The web build"). Nothing in the export pipeline fails
## when a folder is excluded from the main pck but declared in no pack — the
## content simply disappears, and the first sign of it is a browser that will
## not boot. This mounts every pack, loads the main scene, materializes what it
## can, and fails on anything left over or missing.
##
## Run it from an EMPTY directory, or the editor binary silently reads the
## project files instead of the pck and everything passes:
##   tools/tests/test_web.sh
##
## GAME_PCK_DIR overrides where the packs are read from.

const DEFAULT_PCK_DIR := "../../server/assets/pck/"
const WORLD := "res://assets/scenes/workspace_local.tscn"

var _missing: Array = []

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var pck_dir := OS.get_environment("GAME_PCK_DIR")
	if pck_dir == "":
		pck_dir = DEFAULT_PCK_DIR
	if not pck_dir.ends_with("/"):
		pck_dir += "/"

	var dir := DirAccess.open(pck_dir)
	if dir == null:
		print("[verify] FAIL: cannot open pack directory ", pck_dir)
		quit(1)
		return
	var mounted := 0
	var names := dir.get_files()
	names.sort()
	for f in names:
		if f.ends_with(".pck") and ProjectSettings.load_resource_pack(pck_dir + f):
			mounted += 1
	print("[verify] mounted %d pack(s) from %s" % [mounted, pck_dir])

	var packed: PackedScene = load(WORLD)
	if packed == null:
		print("[verify] FAIL: ", WORLD, " does not load from the main pck.")
		print("[verify] It is the boot scene, so every resource it names as a property")
		print("[verify] (a texture, a video, a .tres) must be IN the main pck — a property")
		print("[verify] cannot become a placeholder. Errors above name the paths.")
		quit(1)
		return

	var world: Node = packed.instantiate()
	root.add_child(world)
	for i in range(3):
		await process_frame

	var pckm: Node = root.get_node_or_null("/root/PCKManager")
	if pckm == null:
		print("[verify] FAIL: PCKManager autoload missing")
		quit(1)
		return
	var before := _count()
	var made: int = pckm.materialize_placeholders()
	for i in range(3):
		await process_frame
	var left := _collect()

	print("[verify] placeholders before=%d  materialized=%d  remaining=%d" % [before, made, left.size()])
	if left.is_empty():
		print("[verify] PASS")
		quit(0)
		return

	var seen := {}
	print("[verify] These are excluded from the main pck but in no pack — declare them")
	print("[verify] in tools/packs.json, or they are gone from the web build:")
	for ph in left:
		var p: String = ph.get_instance_path()
		if not seen.has(p):
			seen[p] = true
			print("   ", p)
	print("[verify] FAIL")
	quit(1)

func _count() -> int:
	return _collect().size()

func _collect() -> Array:
	var out: Array = []
	_walk(root, out)
	return out

func _walk(n: Node, out: Array) -> void:
	if n is InstancePlaceholder:
		out.append(n)
		return
	for c in n.get_children():
		_walk(c, out)
