extends Node
## Downloads, caches and mounts the manifest's content packs, holding play behind a loading screen until required ones mount.

## Fires once the queue drained (successfully or not) and the loading UI is gone.
signal all_packs_loaded
## Fires once per session, also when a required pack failed.
signal required_packs_ready
signal pack_downloaded(pack_name: String)
signal pack_load_failed(pack_name: String, error: String)
## percent is 0.0 to 1.0.
signal download_progress(pack_name: String, percent: float)
signal placeholders_materialized(count: int)
signal content_mounted(pack_name: String)
signal region_ready(region: String)

const WorldGeo := preload("res://src/world/region/world_geo.gd")

const LOCAL_MANIFEST_PATH = "user://pck_manifest.json"
const PCK_DIR = "user://pck_packages/"
const DEFAULT_PRIORITY := 1000
## Hides and shows the background download indicator once play is unblocked.
const TOGGLE_KEYCODE := KEY_TAB
const WEB_WINDOW := 8 * 1024 * 1024
const WEB_CHUNK := 1024 * 1024

var _local_manifest: Dictionary = {}
var _server_manifest: Dictionary = {}
var _download_queue: Array = []          # queue entries, the in-flight one first
var _is_downloading: bool = false
var _download_base_url: String = ""
var _on_demand: Dictionary = {}          # pack name -> queue entry, until request()
var _entered_regions: Dictionary = {}    # region -> true
var _region_held: Dictionary = {}        # region -> {pack name -> queue entry}
var _region_required: Dictionary = {}    # region -> {pack name -> true}
var _region_announced: Dictionary = {}   # region -> true once region_ready fired
var _current_http: HTTPRequest = null    # desktop download, polled for progress
var _current_pack_name: String = ""
var _loaded_packs: Dictionary = {}       # pack name -> true
var _pending_surface: Array = []         # pack scenes waiting for their planet
var _surface_timer: Timer = null
## {"path", "callback", "key"} parked by when_available().
var _waiting: Array = []

var _required_names: Dictionary = {}     # pack name -> true, gating this session
var _required_pending: int = 0
var _gate_active: bool = false           # tree paused behind the full-screen gate
var _released: bool = false              # play has been unblocked this session

var _total_to_download: int = 0
var _downloaded_count: int = 0

var _gate_layer: CanvasLayer = null
var _gate_label: Label = null
var _gate_bar: ProgressBar = null

var _hud_layer: CanvasLayer = null
var _hud_root: Control = null
var _hud_label: Label = null
var _hud_bar: ProgressBar = null
var _hud_visible: bool = true


func _ready():
	# Keeps downloading while the tree is paused by the gate.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_pck_directory()
	_load_local_manifest()
	print("[PCK Manager] Ready. Local manifest has ",
		  _local_manifest.get("packages", {}).size(), " cached package(s)")
	# Web streams the ground itself, so the world is held from the first frame (GAME_STARTUP_GATE=1 elsewhere).
	if OS.has_feature("web") or OS.get_environment("GAME_STARTUP_GATE") == "1":
		_activate_gate()
		if _gate_label:
			_gate_label.text = "Contacting the server…"


func _process(_delta):
	if _current_http and is_instance_valid(_current_http) and _current_pack_name != "":
		var body_size = _current_http.get_body_size()
		var downloaded_bytes = _current_http.get_downloaded_bytes()
		if body_size > 0:
			var pct = float(downloaded_bytes) / float(body_size)
			download_progress.emit(_current_pack_name, pct)
			_update_progress_ui(pct, downloaded_bytes, body_size)


func _unhandled_input(event):
	if not _released or _hud_root == null:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == TOGGLE_KEYCODE:
		_hud_visible = not _hud_visible
		_hud_root.visible = _hud_visible
		get_viewport().set_input_as_handled()


func _ensure_pck_directory():
	var dir = DirAccess.open("user://")
	if dir and not dir.dir_exists("pck_packages"):
		dir.make_dir("pck_packages")


func _load_local_manifest():
	if FileAccess.file_exists(LOCAL_MANIFEST_PATH):
		var file = FileAccess.open(LOCAL_MANIFEST_PATH, FileAccess.READ)
		if file:
			var json = JSON.new()
			if json.parse(file.get_as_text()) == OK:
				_local_manifest = json.data
			file.close()
	if not _local_manifest.has("packages"):
		_local_manifest = {"packages": {}}


func _record_local_pack(pack_name: String, server_pack: Dictionary, filename: String,
		version: String, bundled: bool):
	if not _local_manifest.has("packages"):
		_local_manifest["packages"] = {}
	var entry: Dictionary = {
		"version": version,
		"filename": filename,
		"bundled": bundled,
	}
	# Copy only declared keys: an absent scene_path must stay absent.
	for key in ["scene_path", "probe_path", "required", "priority"]:
		if server_pack.has(key):
			entry[key] = server_pack[key]
	_local_manifest["packages"][pack_name] = entry


func _save_local_manifest():
	var file = FileAccess.open(LOCAL_MANIFEST_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_local_manifest, "\t"))
		file.close()


func _pack_filename(pack: Dictionary, pack_name: String) -> String:
	return str(pack.get("filename", pack_name + ".pck"))


## Mounts what is cached, queues the rest, then gates or downloads in background.
func handle_server_manifest(data: Dictionary):
	_server_manifest = data
	_download_base_url = data.get("download_base_url", "")
	var server_packages: Dictionary = data.get("packages", {})
	var local_packages: Dictionary = _local_manifest.get("packages", {})

	_download_queue.clear()
	_on_demand.clear()
	_region_held.clear()
	_region_required.clear()
	_downloaded_count = 0
	_entered_regions[str(data.get("home_region", WorldGeo.home_id()))] = true
	_collect_required(server_packages)

	print("[PCK Manager] Server has ", server_packages.size(), " package(s), ",
		  _required_names.size(), " required")

	for pack_name in server_packages:
		_route_server_pack(pack_name, server_packages[pack_name], local_packages)
	_remove_obsolete_packs(server_packages, local_packages)

	_download_queue.sort_custom(_compare_pack)
	_recompute_required_pending()
	_total_to_download = _download_queue.size()

	if _download_queue.is_empty():
		print("[PCK Manager] All packages up to date")
		_save_local_manifest()
		_finish_all()
		return

	print("[PCK Manager] Need to download ", _total_to_download, " package(s); ",
		  _required_pending, " required still pending")
	if _required_pending > 0 and not _released:
		_activate_gate()
	else:
		_release_gate()
	_process_download_queue()


## Required packs gating this connect: those of no region or of an entered region.
func _collect_required(server_packages: Dictionary) -> void:
	_required_names.clear()
	for pack_name in server_packages:
		var region := str(server_packages[pack_name].get("region", ""))
		if not bool(server_packages[pack_name].get("required", false)):
			continue
		if region != "":
			if not _region_required.has(region):
				_region_required[region] = {}
			_region_required[region][pack_name] = true
		if region == "" or _entered_regions.has(region):
			_required_names[pack_name] = true


func _route_server_pack(pack_name: String, server_pack: Dictionary,
		local_packages: Dictionary) -> void:
	var server_version: String = str(server_pack.get("version", "0"))
	var filename := _pack_filename(server_pack, pack_name)

	if _pack_bundled_in_build(server_pack):
		print("[PCK Manager] '", pack_name, "' already present in this build — skipping download")
		_record_local_pack(pack_name, server_pack, filename, server_version, true)
		if not _loaded_packs.has(pack_name):
			_use_bundled_pack(pack_name)
		return

	var local_pack: Dictionary = local_packages.get(pack_name, {})
	var local_version: String = str(local_pack.get("version", ""))
	var pck_path: String = PCK_DIR + filename
	if not _needs_download(pack_name, local_version, server_version, pck_path):
		_record_local_pack(pack_name, server_pack, filename, server_version, false)
		if not _loaded_packs.has(pack_name):
			_load_pck(pack_name, pck_path)
		return

	var entry := _queue_entry(pack_name, server_pack, filename, server_version)
	var region := str(server_pack.get("region", ""))
	if region != "" and not _entered_regions.has(region):
		entry["roots"] = server_pack.get("roots", [])
		entry["region"] = region
		if not _region_held.has(region):
			_region_held[region] = {}
		_region_held[region][pack_name] = entry
	elif bool(server_pack.get("on_demand", false)):
		entry["roots"] = server_pack.get("roots", [])
		entry["required"] = false
		_on_demand[pack_name] = entry
	else:
		_download_queue.append(entry)


func _needs_download(pack_name: String, local_version: String, server_version: String,
		pck_path: String) -> bool:
	if local_version != server_version:
		print("[PCK Manager] Version mismatch for '", pack_name,
			  "': local=", local_version, " server=", server_version)
		return true
	if not FileAccess.file_exists(pck_path):
		print("[PCK Manager] File missing for '", pack_name, "': ", pck_path)
		return true
	return false


func _queue_entry(pack_name: String, server_pack: Dictionary, filename: String,
		version: String) -> Dictionary:
	return {
		"name": pack_name,
		"filename": filename,
		"version": version,
		"url": _download_base_url + filename,
		"required": bool(server_pack.get("required", false)),
		"priority": int(server_pack.get("priority", DEFAULT_PRIORITY)),
		"has_priority": server_pack.has("priority"),
	}


## Also frees their instanced scenes.
func _remove_obsolete_packs(server_packages: Dictionary, local_packages: Dictionary) -> void:
	var to_remove: Array = []
	for pack_name in local_packages:
		if server_packages.has(pack_name):
			continue
		to_remove.append(pack_name)
		var pck_path: String = PCK_DIR + _pack_filename(local_packages[pack_name], pack_name)
		if FileAccess.file_exists(pck_path):
			DirAccess.remove_absolute(pck_path)
			print("[PCK Manager] Removed obsolete package: ", pack_name)
		remove_pack_scene(pack_name)
	for pack_name in to_remove:
		_local_manifest["packages"].erase(pack_name)


## True while the gate is up or a required pack of an entered region is not mounted.
func required_content_pending() -> bool:
	if _gate_active or _required_pending > 0:
		return true
	for region in _entered_regions:
		if not region_required_ready(region):
			return true
	return false


## Queues its held packs, required ones right behind the current download; safe every frame and before the manifest.
func enter_region(region: String) -> void:
	if region == "" or _entered_regions.has(region):
		return
	_entered_regions[region] = true
	var held: Dictionary = _region_held.get(region, {})
	_region_held.erase(region)
	if held.is_empty():
		_check_region_ready(region)
		return
	var infos: Array = held.values()
	infos.sort_custom(_compare_pack)
	var required := 0
	var insert_at := 1 if _is_downloading else 0
	for info in infos:
		if bool(info.required):
			_download_queue.insert(insert_at, info)
			insert_at += 1
			required += 1
		else:
			_download_queue.append(info)
	_total_to_download += infos.size()
	print("[PCK Manager] entering region '%s': %d required, %d optional pack(s) to fetch" % [
		region, required, infos.size() - required])
	if not _is_downloading:
		_process_download_queue()


func has_entered_region(region: String) -> bool:
	return _entered_regions.has(region)


## True for a region without any.
func region_required_ready(region: String) -> bool:
	for pack_name in _region_required.get(region, {}):
		if not _loaded_packs.has(pack_name):
			return false
	return true


## {"required": [...], "optional": [...], "held": bool}.
func region_packs(region: String) -> Dictionary:
	var out := {"required": [], "optional": [], "held": _region_held.has(region)}
	for pack_name in _server_manifest.get("packages", {}):
		var pack: Dictionary = _server_manifest.packages[pack_name]
		if str(pack.get("region", "")) == region:
			out["required" if bool(pack.get("required", false)) else "optional"].append(pack_name)
	return out


func _check_region_ready(region: String) -> void:
	if _region_announced.has(region) or not _entered_regions.has(region):
		return
	if region_required_ready(region):
		_region_announced[region] = true
		print("[PCK Manager] region '%s' ready" % region)
		region_ready.emit(region)


## Offline entry point; safe to call twice; returns the number of packs mounted by this call.
func mount_cached_packs() -> int:
	var packages: Dictionary = _local_manifest.get("packages", {})
	if packages.is_empty():
		print("[PCK Manager] Offline: no cached packages to mount")
		_release_gate()
		return 0

	var mounted := 0
	for pack_name in packages:
		if _loaded_packs.has(pack_name):
			continue
		var pack: Dictionary = packages[pack_name]
		if _pack_bundled_in_build(pack):
			print("[PCK Manager] Offline: '", pack_name, "' is bundled in this build")
			_use_bundled_pack(pack_name)
			mounted += 1
			continue
		var pck_path: String = PCK_DIR + _pack_filename(pack, pack_name)
		if not FileAccess.file_exists(pck_path):
			print("[PCK Manager] Offline: '", pack_name, "' was never downloaded (",
				  pck_path, ") — skipping")
			continue
		_load_pck(pack_name, pck_path)
		if _loaded_packs.has(pack_name):
			mounted += 1

	print("[PCK Manager] Offline: mounted ", mounted, " cached pack(s)")
	_release_gate()
	return mounted


func has_cached_packs() -> bool:
	for pack_name in _local_manifest.get("packages", {}):
		var pack: Dictionary = _local_manifest["packages"][pack_name]
		if _pack_bundled_in_build(pack):
			return true
		if FileAccess.file_exists(PCK_DIR + _pack_filename(pack, pack_name)):
			return true
	return false


## Required, then priority-tagged (ascending), then by name.
func _compare_pack(a: Dictionary, b: Dictionary) -> bool:
	if a.required != b.required:
		return a.required
	if a.has_priority != b.has_priority:
		return a.has_priority
	if a.has_priority and b.has_priority and a.priority != b.priority:
		return a.priority < b.priority
	return str(a.name) < str(b.name)


func _recompute_required_pending():
	_required_pending = 0
	for rn in _required_names:
		if not _loaded_packs.has(rn):
			_required_pending += 1


## Puts a held-back pack in front of the queue; false when nothing by that name is held.
func request(pack_name: String) -> bool:
	if pack_name == "":
		return false
	if _loaded_packs.has(pack_name):
		return true
	for region in _region_held:
		if _region_held[region].has(pack_name):
			enter_region(region)
			return true
	if not _on_demand.has(pack_name):
		return false
	var pack_info: Dictionary = _on_demand[pack_name]
	_on_demand.erase(pack_name)
	print("[PCK Manager] '", pack_name, "' asked for; fetching it now")
	_download_queue.insert(0 if not _is_downloading else 1, pack_info)
	_total_to_download += 1
	if not _is_downloading:
		_process_download_queue()
	return true


func is_on_demand(pack_name: String) -> bool:
	return _on_demand.has(pack_name)


## "" when no held-back pack covers path.
func pack_for_path(path: String) -> String:
	for region in _region_held:
		var held := _pack_with_root(_region_held[region], path)
		if held != "":
			return held
	return _pack_with_root(_on_demand, path)


func _pack_with_root(entries: Dictionary, path: String) -> String:
	for pack_name in entries:
		for root in entries[pack_name].get("roots", []):
			if path.begins_with(str(root)):
				return pack_name
	return ""


func _process_download_queue():
	if _download_queue.is_empty():
		_save_local_manifest()
		print("[PCK Manager] All downloads complete")
		_finish_all()
		return
	if _is_downloading:
		return
	_download_pack(_download_queue[0])


func _download_pack(pack_info: Dictionary) -> void:
	var pck_path: String = PCK_DIR + pack_info.filename
	print("[PCK Manager] Downloading: ", pack_info.url)
	_is_downloading = true
	_current_pack_name = pack_info.name
	_update_progress_ui(0.0, 0, 0)
	if OS.has_feature("web"):
		_download_windowed(pack_info, pck_path)
	else:
		_download_whole(pack_info, pck_path)


func _download_whole(pack_info: Dictionary, pck_path: String) -> void:
	var http := HTTPRequest.new()
	http.download_file = pck_path
	http.download_chunk_size = 65536
	http.timeout = 300
	add_child(http)
	_current_http = http
	http.request_completed.connect(
		func(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray):
			_current_http = null
			http.queue_free()
			var ok: bool = result == HTTPRequest.RESULT_SUCCESS and response_code == 200 \
				and FileAccess.file_exists(pck_path)
			_finish_download(pack_info, pck_path, ok,
				"result=%d HTTP %d" % [result, response_code])
	)
	var error := http.request(pack_info.url)
	if error != OK:
		_current_http = null
		http.queue_free()
		_finish_download(pack_info, pck_path, false, "HTTP request error: " + str(error))


## The web HTTPRequest copies the whole body on every chunk, so bounded ranges keep it linear; a 200 is the whole file.
func _download_windowed(pack_info: Dictionary, pck_path: String) -> void:
	var file := FileAccess.open(pck_path, FileAccess.WRITE)
	if file == null:
		_finish_download(pack_info, pck_path, false, "cannot open " + pck_path)
		return
	var offset := 0
	var total := -1
	while true:
		var http := HTTPRequest.new()
		http.download_chunk_size = WEB_CHUNK
		http.timeout = 120
		add_child(http)
		var headers := PackedStringArray(["Range: bytes=%d-%d" % [offset, offset + WEB_WINDOW - 1]])
		if http.request(pack_info.url, headers) != OK:
			http.queue_free()
			file.close()
			_finish_download(pack_info, pck_path, false, "request failed at byte %d" % offset)
			return
		var res: Array = await http.request_completed
		http.queue_free()
		var result: int = res[0]
		var code: int = res[1]
		var body: PackedByteArray = res[3]
		if result != HTTPRequest.RESULT_SUCCESS or not (code == 206 or code == 200):
			file.close()
			_finish_download(pack_info, pck_path, false,
				"result=%d HTTP %d at byte %d" % [result, code, offset])
			return
		if total < 0:
			total = _range_total(res[2], code, body.size())
		file.store_buffer(body)
		offset += body.size()
		if total > 0:
			var pct := float(offset) / float(total)
			download_progress.emit(pack_info.name, pct)
			_update_progress_ui(pct, offset, total)
		# A short window means the end of the file.
		if code == 200 or body.size() < WEB_WINDOW or (total > 0 and offset >= total):
			break
	file.close()
	_finish_download(pack_info, pck_path, FileAccess.file_exists(pck_path), "")


## From a 206's "Content-Range: bytes a-b/TOTAL"; for a 200 the body size; -1 when unknown.
func _range_total(headers: PackedStringArray, code: int, body_size: int) -> int:
	if code == 200:
		return body_size
	for h in headers:
		var low := h.to_lower()
		if not low.begins_with("content-range:"):
			continue
		var slash := h.rfind("/")
		if slash >= 0:
			var tail := h.substr(slash + 1).strip_edges()
			if tail.is_valid_int():
				return tail.to_int()
	return -1


## Releases the gate when the last required pack is in, and moves the queue on.
func _finish_download(pack_info: Dictionary, pck_path: String, ok: bool, err: String) -> void:
	_current_http = null
	_current_pack_name = ""
	_is_downloading = false
	var filename: String = pack_info.filename

	if ok:
		print("[PCK Manager] Downloaded: ", filename)
		_downloaded_count += 1
		var server_pack: Dictionary = _server_manifest.get("packages", {}).get(pack_info.name, {})
		_record_local_pack(pack_info.name, server_pack, filename, pack_info.version, false)
		# Saved per pack so a reload partway through resumes instead of refetching.
		_save_local_manifest()
		_load_pck(pack_info.name, pck_path)
		pack_downloaded.emit(pack_info.name)
		_recompute_required_pending()
		if _gate_active and _required_pending == 0:
			_release_gate()
	else:
		print("[PCK Manager] Download failed (", err, ") for ", filename)
		pack_load_failed.emit(pack_info.name, "Download failed: " + err)

	if not _download_queue.is_empty():
		_download_queue.remove_at(0)
	_process_download_queue()


## Autoloads keep processing so the network stays connected.
func _activate_gate():
	if _gate_active:
		return
	_gate_active = true
	print("[PCK Manager] Blocking play until ", _required_pending, " required pack(s) ready")
	_set_autoloads_always(true)
	get_tree().paused = true
	_show_gate_ui()


func _release_gate():
	if _gate_active:
		_gate_active = false
		get_tree().paused = false
		_set_autoloads_always(false)
		_teardown_gate_ui()
		print("[PCK Manager] Required packs ready — play unblocked")

	materialize_placeholders()
	_mark_released()

	if not _download_queue.is_empty() or _is_downloading:
		_show_hud()
	else:
		_teardown_hud()


func _mark_released():
	if not _released:
		_released = true
		required_packs_ready.emit()


## Autoloads are the root's children other than the current scene and this node.
func _set_autoloads_always(always: bool) -> void:
	var scene := get_tree().current_scene
	for child in get_tree().root.get_children():
		if child == scene or child == self:
			continue
		child.process_mode = Node.PROCESS_MODE_ALWAYS if always else Node.PROCESS_MODE_INHERIT


## Releases play even if a required pack failed.
func _finish_all():
	if _gate_active:
		if _required_pending > 0:
			print("[PCK Manager] WARNING: releasing with ", _required_pending,
				  " required pack(s) unresolved (download failed?)")
		_release_gate()
	_mark_released()
	_teardown_gate_ui()
	_hide_hud_then_free()
	all_packs_loaded.emit()


## False in web builds, which exclude assets/art/models.
func _pack_bundled_in_build(server_pack: Dictionary) -> bool:
	var probe: String = str(server_pack.get("probe_path", ""))
	if probe == "":
		probe = str(server_pack.get("scene_path", ""))
	return probe != "" and ResourceLoader.exists(probe)


func _use_bundled_pack(pack_name: String) -> void:
	_loaded_packs[pack_name] = true
	_announce_content(pack_name)


func _load_pck(pack_name: String, pck_path: String):
	if _loaded_packs.has(pack_name):
		return
	if ProjectSettings.load_resource_pack(pck_path):
		_loaded_packs[pack_name] = true
		print("[PCK Manager] Loaded resource pack: ", pack_name, " from ", pck_path)
		_announce_content(pack_name)
	else:
		print("[PCK Manager] FAILED to load resource pack: ", pack_name, " from ", pck_path)
		pack_load_failed.emit(pack_name, "ProjectSettings.load_resource_pack() returned false")


func _announce_content(pack_name: String) -> void:
	var scene_path = _get_pack_scene_path(pack_name)
	if scene_path != "":
		_instantiate_pack_scene(pack_name, scene_path)
	_content_arrived(pack_name)


## {"planet": rid, "surface": {"dir" (planet-local), "yaw_deg", "h_off", "scale", "pad", "curve"}} or {}.
func _get_pack_surface(pack_name: String) -> Dictionary:
	for manifest in [_server_manifest, _local_manifest]:
		var pack = manifest.get("packages", {}).get(pack_name, {})
		var planet_rid = str(pack.get("planet", ""))
		if planet_rid == "":
			continue
		var surf = pack.get("surface", {})
		var dir_arr = surf.get("dir", [0.0, 1.0, 0.0])
		return {
			"planet": planet_rid,
			"dir": Vector3(float(dir_arr[0]), float(dir_arr[1]), float(dir_arr[2])).normalized(),
			"yaw": deg_to_rad(float(surf.get("yaw_deg", 0.0))),
			"h_off": float(surf.get("h_off", 0.0)),
			"scale": float(surf.get("scale", 1.0)),
			"pad": float(surf.get("pad", 0.0)),
			"curve": bool(surf.get("curve", false)),
		}
	return {}


func _queue_surface_attach(instance: Node, pack_name: String, surface_def: Dictionary):
	_pending_surface.append({"instance": instance, "pack": pack_name, "def": surface_def})
	if _surface_timer == null:
		_surface_timer = Timer.new()
		_surface_timer.wait_time = 0.5
		_surface_timer.timeout.connect(_poll_surface_attach)
		add_child(_surface_timer)
	_surface_timer.start()
	_poll_surface_attach()


func _poll_surface_attach():
	var still_waiting: Array = []
	for entry in _pending_surface:
		var instance: Node = entry["instance"]
		if not is_instance_valid(instance):
			continue
		var planet = _find_planet_node(str(entry["def"]["planet"]))
		if planet == null:
			still_waiting.append(entry)
			continue
		_attach_to_planet(instance, planet, entry["def"], str(entry["pack"]))
	_pending_surface = still_waiting
	if _pending_surface.is_empty() and _surface_timer:
		_surface_timer.stop()


## The home planet is the scene's untagged "Planet" node.
func _find_planet_node(rid: String) -> Node3D:
	for planet in get_tree().get_nodes_in_group("planets"):
		if planet is Node3D and str(planet.get_meta("planet_rid", "")) == rid:
			return planet
	if rid == GalaxyPlanets.HOME_RID:
		var scene_root = get_tree().current_scene
		if scene_root:
			return scene_root.get_node_or_null("Planet")
	return null


## Also gives it trimesh colliders if it has none.
func _attach_to_planet(instance: Node, planet: Node3D, def: Dictionary, pack_name: String):
	planet.add_child(instance)
	if instance is Node3D and planet.has_method("place_on_surface"):
		instance.transform = planet.place_on_surface(
			def["dir"], def["yaw"], def["h_off"], def["scale"])
		if def.get("curve", false):
			_bend_onto_planet(instance, def)
	if def["pad"] > 0.0:
		_stamp_pad(planet, def, pack_name)
	# After bending, so physics matches the bent meshes.
	if instance is Node3D and not _subtree_has_collision(instance):
		for mi in instance.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh != null:
				mi.create_trimesh_collision()
	print("[PCK Manager] Attached pack '", pack_name, "' to planet surface of ",
		  planet.name)


## The radius is in the pack's own units.
func _bend_onto_planet(instance: Node3D, def: Dictionary) -> void:
	var ground_dist: float = instance.position.length()
	var s: float = def["scale"] if def["scale"] > 0.0 else 1.0
	if ground_dist > 1.0:
		PlanetMeshBender.bend_node(instance, ground_dist / s)


func _stamp_pad(planet: Node3D, def: Dictionary, pack_name: String) -> void:
	var stamp := PlanetPadStamp.new()
	stamp.name = "pad_" + pack_name
	stamp.pad_radius = def["pad"]
	stamp.falloff = def["pad"] * 0.8
	stamp.planar = not def.get("curve", false)
	planet.add_child(stamp)
	stamp.position = def["dir"] * planet.get_surface_radius()
	for child in planet.get_children():
		if child is PlanetTerrain:
			child.rebake()
			break


func _subtree_has_collision(node: Node) -> bool:
	if node is CollisionShape3D or node is CollisionPolygon3D:
		return true
	for child in node.get_children():
		if _subtree_has_collision(child):
			return true
	return false


## Server manifest first, else the cached one.
func _get_pack_scene_path(pack_name: String) -> String:
	var pack = _server_manifest.get("packages", {}).get(pack_name, {})
	var scene_path = str(pack.get("scene_path", ""))
	if scene_path != "":
		return scene_path
	return str(_local_manifest.get("packages", {}).get(pack_name, {}).get("scene_path", ""))


func _instantiate_pack_scene(pack_name: String, scene_path: String):
	if not ResourceLoader.exists(scene_path):
		print("[PCK Manager] Scene not found in pack '", pack_name, "': ", scene_path)
		pack_load_failed.emit(pack_name, "Scene not found: " + scene_path)
		return

	var scene = load(scene_path)
	if not scene:
		print("[PCK Manager] Failed to load scene for '", pack_name, "': ", scene_path)
		pack_load_failed.emit(pack_name, "Failed to load scene: " + scene_path)
		return

	var instance = scene.instantiate()
	instance.set_meta("pck_pack_name", pack_name)
	instance.set_meta("pck_scene_path", scene_path)

	var surface_def = _get_pack_surface(pack_name)
	if not surface_def.is_empty():
		_queue_surface_attach(instance, pack_name, surface_def)
		return
	_add_to_workspace(instance, pack_name, scene_path)


## Replaces the workspace's fallback Baseplate; the current scene when there is no workspace.
func _add_to_workspace(instance: Node, pack_name: String, scene_path: String) -> void:
	var workspace = _find_workspace()
	if not workspace:
		get_tree().current_scene.add_child(instance)
		print("[PCK Manager] Instantiated scene '", scene_path, "' from pack '",
			  pack_name, "' into current scene (no workspace found)")
		return
	var baseplate = workspace.get_node_or_null("Baseplate")
	if baseplate:
		baseplate.queue_free()
		print("[PCK Manager] Removed Baseplate (replaced by pack '", pack_name, "')")
	workspace.add_child(instance)
	print("[PCK Manager] Instantiated scene '", scene_path, "' from pack '",
		  pack_name, "' into workspace")


func _content_arrived(pack_name: String) -> void:
	materialize_placeholders()
	content_mounted.emit(pack_name)
	_flush_waiting()
	for region in _entered_regions:
		_check_region_ready(region)


func _path_resolves(path: String) -> bool:
	return FileAccess.file_exists(path) or ResourceLoader.exists(path)


## Requests the held-back pack that holds path; a non-empty `key` replaces an earlier wait with that key.
func when_available(path: String, callback: Callable, key: String = "") -> void:
	if _path_resolves(path):
		callback.call()
		return
	if key != "":
		for i in range(_waiting.size() - 1, -1, -1):
			if _waiting[i]["key"] == key:
				_waiting.remove_at(i)
	var holder := pack_for_path(path)
	if holder != "":
		request(holder)
	_waiting.append({"path": path, "callback": callback, "key": key})


func _flush_waiting() -> void:
	var still: Array = []
	var ready: Array = []
	for w in _waiting:
		if _path_resolves(w["path"]):
			ready.append(w)
		else:
			still.append(w)
	_waiting = still
	for w in ready:
		var cb: Callable = w["callback"]
		if cb.is_valid():
			cb.call()


## Web exports streamed-pack scenes as InstancePlaceholders; returns the number of instances created.
func materialize_placeholders() -> int:
	var total := 0
	while true:
		var found: Array = []
		_collect_placeholders(get_tree().root, found)
		var made := 0
		for ph in found:
			if _materialize_placeholder(ph):
				made += 1
		total += made
		if made == 0:
			break
	if total > 0:
		print("[PCK Manager] Materialized ", total, " streamed scene instance(s)")
		placeholders_materialized.emit(total)
	return total


## Keeps the children placed under it.
func _materialize_placeholder(ph) -> bool:
	if not is_instance_valid(ph) or not ph.is_inside_tree():
		return false
	var scene_path: String = ph.get_instance_path()
	if not _streamed_scene_ready(scene_path, {}):
		return false
	# create_instance(true) frees the placeholder with its children.
	var kids: Array = ph.get_children()
	for k in kids:
		ph.remove_child(k)
	var inst: Node = ph.create_instance(true)
	if inst == null:
		for k in kids:
			ph.add_child(k)
		push_warning("[PCK Manager] Could not instance streamed scene: " + scene_path)
		return false
	for k in kids:
		inst.add_child(k)
	return true


func _collect_placeholders(node: Node, out: Array) -> void:
	if node is InstancePlaceholder:
		out.append(node)
		return
	for c in node.get_children():
		_collect_placeholders(c, out)


## Recursive over dependencies.
func _streamed_scene_ready(path: String, visited: Dictionary) -> bool:
	if visited.has(path):
		return true
	visited[path] = true
	if not ResourceLoader.exists(path):
		return false
	for dep in ResourceLoader.get_dependencies(path):
		var dep_path := _dependency_path(str(dep))
		if dep_path != "" and not _streamed_scene_ready(dep_path, visited):
			return false
	return true


## dep is "uid://x::res://path" or a path.
func _dependency_path(dep: String) -> String:
	var parts := dep.split("::")
	for i in range(parts.size() - 1, -1, -1):
		if parts[i].begins_with("res://"):
			return parts[i]
	if parts[0].begins_with("uid://"):
		var id := ResourceUID.text_to_id(parts[0])
		if ResourceUID.has_id(id):
			return ResourceUID.get_id_path(id)
	return ""


func _find_workspace() -> Node:
	var root = get_tree().get_root()
	var workspace = root.find_child("workspace", true, false)
	if not workspace:
		workspace = root.find_child("localworkspace", true, false)
	return workspace


func remove_pack_scene(pack_name: String):
	var workspace = _find_workspace()
	if not workspace:
		workspace = get_tree().current_scene
	if not workspace:
		return
	for child in workspace.get_children():
		if child.has_meta("pck_pack_name") and child.get_meta("pck_pack_name") == pack_name:
			print("[PCK Manager] Removing scene for pack: ", pack_name)
			child.queue_free()
			return


func _show_gate_ui():
	if _gate_layer != null:
		return

	_gate_layer = CanvasLayer.new()
	_gate_layer.layer = 100
	add_child(_gate_layer)

	var backdrop = ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.05, 0.05, 0.08, 1.0)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_gate_layer.add_child(backdrop)

	var panel = ColorRect.new()
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 202.0
	panel.offset_top = 294.0
	panel.offset_right = -202.0
	panel.offset_bottom = -294.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.color = Color(0.502, 0.502, 0.502, 0.502)
	backdrop.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16.0
	vbox.offset_top = 12.0
	vbox.offset_right = -16.0
	vbox.offset_bottom = -12.0
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	_gate_label = Label.new()
	_gate_label.text = "Preparing the world..."
	_gate_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gate_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_gate_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_gate_label.add_theme_font_size_override("font_size", 18)
	_gate_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_try_set_bold_font(_gate_label)
	vbox.add_child(_gate_label)

	_gate_bar = _make_progress_bar()
	vbox.add_child(_gate_bar)


func _teardown_gate_ui():
	if _gate_layer and is_instance_valid(_gate_layer):
		_gate_layer.queue_free()
	_gate_layer = null
	_gate_label = null
	_gate_bar = null


## Click-through, top right clear of the chat.
func _show_hud():
	if _hud_layer != null:
		if _hud_root:
			_hud_root.visible = _hud_visible
		return

	_hud_visible = true
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 99
	add_child(_hud_layer)

	_hud_root = Control.new()
	_hud_root.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(_hud_root)

	var bg = ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.55)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.position = Vector2(-332, 12)    # 320 wide, 12 px from the corner
	bg.size = Vector2(320, 58)
	_hud_root.add_child(bg)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 8.0
	vbox.offset_top = 6.0
	vbox.offset_right = -8.0
	vbox.offset_bottom = -6.0
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 4)
	bg.add_child(vbox)

	_hud_label = Label.new()
	_hud_label.text = "Downloading additional content…  (Tab to hide)"
	_hud_label.add_theme_font_size_override("font_size", 12)
	_hud_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_try_set_bold_font(_hud_label)
	vbox.add_child(_hud_label)

	_hud_bar = _make_progress_bar()
	_hud_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_hud_bar)

	_hud_root.visible = _hud_visible


func _teardown_hud():
	if _hud_layer and is_instance_valid(_hud_layer):
		_hud_layer.queue_free()
	_hud_layer = null
	_hud_root = null
	_hud_label = null
	_hud_bar = null


func _hide_hud_then_free():
	if _hud_layer == null:
		return
	if _hud_label:
		_hud_label.text = "All content downloaded."
	if _hud_bar:
		_hud_bar.value = 100.0
	var tween = create_tween()
	tween.tween_interval(0.8)
	tween.tween_callback(_teardown_hud)


func _make_progress_bar() -> ProgressBar:
	var bar = ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 14)
	bar.value = 0.0
	bar.max_value = 100.0
	bar.show_percentage = false
	bar.add_theme_stylebox_override("background", _rounded_box(Color(0.35, 0.35, 0.35, 0.6)))
	bar.add_theme_stylebox_override("fill", _rounded_box(Color(0.75, 0.75, 0.75, 0.8)))
	return bar


func _rounded_box(color: Color) -> StyleBoxFlat:
	var box = StyleBoxFlat.new()
	box.bg_color = color
	box.corner_radius_top_left = 3
	box.corner_radius_top_right = 3
	box.corner_radius_bottom_left = 3
	box.corner_radius_bottom_right = 3
	return box


func _try_set_bold_font(label: Label):
	var font_path = "res://assets/art/fonts/tahomabd.ttf"
	if ResourceLoader.exists(font_path):
		var font = load(font_path)
		if font:
			label.add_theme_font_override("font", font)


func _update_progress_ui(pct: float, downloaded_bytes: int, total_bytes: int):
	var percent_int = int(pct * 100.0)
	var required_ready = _required_names.size() - _required_pending

	if _gate_label:
		var line = "Preparing the world..."
		if _current_pack_name != "":
			line = "Downloading %s… %d%%" % [_current_pack_name, percent_int]
			if total_bytes > 0:
				line += " (%s / %s)" % [_format_bytes(downloaded_bytes), _format_bytes(total_bytes)]
		_gate_label.text = "%s\n\nRequired content: %d / %d ready" % [
			line, required_ready, _required_names.size()
		]
	if _gate_bar:
		_gate_bar.value = pct * 100.0

	if _hud_label:
		var remaining = _download_queue.size()
		if _current_pack_name != "":
			_hud_label.text = "↓ %s  %d%%   (%d pack%s left)   Tab to hide" % [
				_current_pack_name, percent_int, remaining, ("" if remaining == 1 else "s")
			]
		else:
			_hud_label.text = "Downloading additional content…   Tab to hide"
	if _hud_bar:
		_hud_bar.value = pct * 100.0


func _format_bytes(bytes: int) -> String:
	if bytes >= 1048576:
		return "%.1f MB" % (bytes / 1048576.0)
	elif bytes >= 1024:
		return "%.0f KB" % (bytes / 1024.0)
	else:
		return "%d B" % bytes


func is_pack_loaded(pack_name: String) -> bool:
	return _loaded_packs.has(pack_name)


func get_loaded_packs() -> Array:
	return _loaded_packs.keys()


func get_local_version(pack_name: String) -> String:
	var packages = _local_manifest.get("packages", {})
	var pack = packages.get(pack_name, {})
	return str(pack.get("version", ""))


func is_downloading() -> bool:
	return _is_downloading


func get_download_queue_size() -> int:
	return _download_queue.size()


## Also true when a required pack failed.
func required_packs_are_ready() -> bool:
	return _released
