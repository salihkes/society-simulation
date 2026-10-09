extends SceneTree
## Receiving the manifest again must not download already bundled resources.

class PackManager extends "res://src/net/pck_manager.gd":
	var adopted := 0
	func _save_local_manifest():
		pass
	func _use_bundled_pack(pack_name: String):
		_loaded_packs[pack_name] = true
		adopted += 1
	func _finish_all():
		pass
	func _release_gate():
		pass
	func _activate_gate():
		pass
	func _process_download_queue():
		pass

func _initialize():
	var manager := PackManager.new()
	manager._local_manifest = {"packages": {}}
	var manifest := {"packages": {"test_bundled": {
		"version": "1", "probe_path": "res://tests/test_bundled_reconnect.gd",
		"required": true}}}
	manager.handle_server_manifest(manifest)
	manager.handle_server_manifest(manifest)
	manifest.packages.test_bundled.version = "2"
	manager.handle_server_manifest(manifest)
	var ok: bool = manager.adopted == 1 and manager._download_queue.is_empty() \
		and manager._required_pending == 0 and manager._total_to_download == 0
	print("BUNDLED RECONNECT: ", "PASS" if ok else "FAIL")
	manager.free()
	quit(0 if ok else 1)
