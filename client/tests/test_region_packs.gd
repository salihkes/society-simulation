extends SceneTree
## Region packs (tools/packs.json "region"): a far city's packs are held until
## the player enters its region; then required ones go first and gate that
## region only, optional ones follow. Spawning in the region makes its
## required packs part of the connect gate. Runs a sandboxed PCKManager: no
## downloads, no gate UI, the real pack cache untouched.
##   godot --headless --path client -s tests/test_region_packs.gd
var HOME: String = Identity.value("home_region")
var failures := 0

class Sandbox extends "res://src/net/pck_manager.gd":
	var started: Array = []
	var gated := false
	func _ready(): _local_manifest = {"packages": {}}
	func _save_local_manifest(): pass
	func _activate_gate(): gated = true; _gate_active = true
	func _release_gate(): _gate_active = false; _mark_released()
	func _process_download_queue():
		for p in _download_queue:
			if not started.has(p.name): started.append(p.name)
	func materialize_placeholders() -> int: return 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("REGION PACKS FAIL: " + label)
	else:
		print("  ok  ", label)

const BUNDLED := "res://assets/world/region/regions.json"   # resolves: counts as bundled
const ABSENT := "res://nowhere/never.scn"

func manifest() -> Dictionary:
	return {"download_base_url": "http://127.0.0.1:1/pck/", "packages": {
		"core": {"version": "1", "probe_path": BUNDLED, "required": true},
		"home_city": {"version": "1", "probe_path": BUNDLED, "required": true, "region": HOME},
		"city_shell": {"version": "1", "probe_path": ABSENT, "required": true, "region": "the_city",
			"roots": ["res://assets/art/models/far_city/"], "priority": 10},
		"city_extra": {"version": "1", "probe_path": ABSENT, "region": "the_city", "priority": 50},
		"city_props": {"version": "1", "probe_path": ABSENT, "region": "the_city", "priority": 40},
	}}

func run() -> void:
	# ── Spawned in the home region; The City is far away ──
	var m := Sandbox.new()
	root.add_child(m)
	var ready_regions: Array = []
	m.region_ready.connect(func(r): ready_regions.append(r))
	m.handle_server_manifest(manifest())
	check(m.has_entered_region(HOME), "the home region is entered at connect")
	check(not m.started.has("city_shell") and not m.started.has("city_extra"), "far city packs are not downloaded at connect")
	check(not m.gated and not m.required_content_pending(), "a far city's required pack does not gate the connect")
	check(not m.region_required_ready("the_city"), "The City is not ready")
	check(m.pack_for_path("res://assets/art/models/far_city/parts/core/core.scn") == "city_shell", "its paths map to its held pack")
	var packs: Dictionary = m.region_packs("the_city")
	check(packs.required == ["city_shell"] and packs.optional.size() == 2 and packs.held, "required and optional packs of The City listed")

	# ── Coming near: required first, optional after, by priority ──
	m._is_downloading = true      # something already in flight: ours go behind it
	m._download_queue = [{"name": "in_flight", "required": false, "has_priority": false, "priority": 1000}]
	m.enter_region("the_city")
	var order: Array = m._download_queue.map(func(p): return p.name)
	check(order == ["in_flight", "city_shell", "city_props", "city_extra"], "queue: in flight, required, then optional by priority (%s)" % [order])
	check(m.required_content_pending(), "entered but not mounted: ground under the player may be pending")
	m._is_downloading = false
	m._loaded_packs["city_props"] = true
	m._content_arrived("city_props")
	check(not ready_regions.has("the_city"), "an optional pack does not make the region ready")
	m._loaded_packs["city_shell"] = true
	m._content_arrived("city_shell")
	check(ready_regions.count("the_city") == 1, "the required pack makes it ready (signal)")
	check(ready_regions.has(HOME), "the home region, its required pack bundled, reports ready too")
	check(m.region_required_ready("the_city") and not m.required_content_pending(), "nothing pending once required is in")
	m.queue_free()

	# ── Spawned in The City: its required packs gate the connect ──
	var s := Sandbox.new()
	root.add_child(s)
	s.enter_region("the_city")          # regional_city.gd, before the manifest
	s.handle_server_manifest(manifest())
	check(s._required_names.has("city_shell"), "spawning there makes its required pack part of the connect gate")
	check(s.gated, "and the gate is up until it arrives")
	check(s.started.has("city_shell") and s.started.find("city_shell") < s.started.find("city_extra"), "downloaded at connect, required first")
	s.queue_free()

	# ── A build that bundles The City never waits ──
	var b := Sandbox.new()
	root.add_child(b)
	var bundled := manifest()
	for name in ["city_shell", "city_extra", "city_props"]:
		bundled.packages[name].probe_path = BUNDLED
	b.handle_server_manifest(bundled)
	check(b.region_required_ready("the_city"), "bundled: The City is ready without entering")
	b.queue_free()

	await process_frame
	print("REGION PACKS: %d failures" % failures)
	quit(1 if failures else 0)
