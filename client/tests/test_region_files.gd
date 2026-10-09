extends SceneTree
## The web build's country map: tiles and road chunks fetched from the server
## as byte ranges, kept on disk, checked against the server's hashes, pruned
## when outdated; the terrain streams entirely through it.
##
## Needs the region served (tools/bake/publish_region.sh first):
##   tests/test_region_files.sh   (starts pck_server's handler on a spare
##   port and runs this with REGION_TEST_URL=http://127.0.0.1:<port>/pck/region/)
const RegionFiles = preload("res://src/world/region/region_files.gd")
const Terrain = preload("res://src/world/region/streamed_terrain.gd")
const DATA := "res://assets/world/region/data/"
const TEST_CACHE := "user://regioncache_test/"
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("REGION FILES FAIL: " + label)
	else:
		print("  ok  ", label)

func wipe(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		wipe(dir.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)

func bytes_of(path: String, offset: int, length: int) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	f.seek(offset)
	return f.get_buffer(length if length > 0 else f.get_length())

func wait_for(rf: Node, path: String, offset: int, length: int, seconds := 20.0) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		var located: Dictionary = rf.locate(path, offset, length)
		if not located.is_empty() or rf.has_failed(path, offset, length):
			return located
		await process_frame
	return {}

func run() -> void:
	var url := OS.get_environment("REGION_TEST_URL")
	if url == "":
		push_error("REGION_TEST_URL not set; run tests/test_region_files.sh")
		quit(2)
		return
	wipe(TEST_CACHE)
	var rf: Node = RegionFiles.instance(self)
	await process_frame
	rf.use_cache(TEST_CACHE)
	rf.force_remote = true
	rf.base_url = url

	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "meta.json"))
	var tile_bytes := (int(meta.quads) + 3) * (int(meta.quads) + 3) * 4
	var page := DATA + str(meta.tiles_dir) + "/0_0.bin"
	var offset := 37 * tile_bytes

	# ── One tile as a byte range ──
	check(rf.locate(page, offset, tile_bytes).is_empty(), "nothing kept yet: the tile must be fetched")
	rf.request(page, offset, tile_bytes)
	var got: Dictionary = await wait_for(rf, page, offset, tile_bytes)
	check(not got.is_empty(), "tile arrives")
	if not got.is_empty():
		check(got.path.begins_with(TEST_CACHE) and int(got.offset) == 0, "kept in the cache as its own file")
		check(bytes_of(got.path, 0, 0) == bytes_of(page, offset, tile_bytes), "kept tile is byte-identical to the page's range")
		check(FileAccess.get_file_as_bytes(got.path).size() == tile_bytes, "only the tile was stored, not the page")
	var stats: Dictionary = rf.get_stats()
	check(stats.index == "READY", "server index read")

	# ── A whole road chunk ──
	var roads: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "roads/manifest.json"))
	var chunk := DATA + "roads/" + str(roads.chunks[0].file)
	rf.request(chunk)
	got = await wait_for(rf, chunk, 0, 0)
	check(not got.is_empty() and bytes_of(got.path, 0, 0) == FileAccess.get_file_as_bytes(chunk), "road chunk arrives intact")

	# ── Kept across sessions: a fresh instance finds it without the network ──
	rf._save_local()
	var again: Node = load(RegionFiles.SCRIPT_PATH).new()
	again.use_cache(TEST_CACHE)
	again.force_remote = true
	check(not again.locate(page, offset, tile_bytes).is_empty(), "a new session uses the kept tile (no download)")
	again.free()

	# ── Versions: a changed file is fetched again; withdrawn files are deleted ──
	var key := "%s/0_0.bin@%d" % [str(meta.tiles_dir), offset]
	rf._local[key] = "0000000000000000"
	check(rf.locate(page, offset, tile_bytes).is_empty(), "a kept tile whose server hash changed is not used")
	rf._prune()
	check(not FileAccess.file_exists(TEST_CACHE + key), "the outdated copy is deleted")
	rf.request(page, offset, tile_bytes)
	got = await wait_for(rf, page, offset, tile_bytes)
	check(not got.is_empty(), "and fetched again")

	# ── Unpublished (a stale bake) fails instead of retrying forever ──
	var stale := ""
	for dir in DirAccess.get_directories_at(DATA + "roads"):
		if dir != str(roads.version):
			stale = DATA + "roads/" + dir + "/chunk_0.bin"
			break
	if stale != "":
		rf.request(stale)
		await wait_for(rf, stale, 0, 0, 5.0)
		check(rf.has_failed(stale), "a file the server does not publish fails")

	# ── The terrain streams through it end to end ──
	var before: int = rf.get_stats().fetched
	var terrain := Terrain.new()
	terrain.scale = Vector3.ONE * 0.2
	root.add_child(terrain)
	terrain.set_viewer(Vector3.ZERO)
	var deadline := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline:
		var t: Dictionary = terrain.get_streaming_stats()
		if t.tiles == t.wanted and not t.busy and t.fetching == 0:
			break
		await create_timer(0.1).timeout
	var ts: Dictionary = terrain.get_streaming_stats()
	print("  terrain: ", ts, "\n  files: ", rf.get_stats())
	check(ts.tiles == 289 and ts.failed == 0, "full terrain window built from fetched tiles")
	check(int(rf.get_stats().fetched) - before >= 280, "the tiles came over HTTP")
	check(ts.colliders == 25, "collision around the viewer")
	terrain.queue_free()
	await process_frame
	wipe(TEST_CACHE)
	print("REGION FILES: %d failures" % failures)
	quit(1 if failures else 0)
