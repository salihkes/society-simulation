extends Node
## Fetches and hash-checks country map files the build does not carry, cached in user://regioncache.

signal file_ready(key: String)
signal file_failed(key: String)

const SCRIPT_PATH := "res://src/world/region/region_files.gd"
const DATA_ROOT := "res://assets/world/region/data/"
const CACHE := "user://regioncache/"
const MAX_ACTIVE := 4
const RETRIES := 3

enum Index { NONE, LOADING, READY, UNAVAILABLE }

## e.g. ".../pck/region/".
var base_url := ""
var cache_dir := CACHE
## Tests: behave like the web build even where res:// carries the files.
var force_remote := false
var _index_state := Index.NONE
## rel -> {"size", "hash"} from the server's index.
var _server: Dictionary = {}
## Cache key -> the server hash it was saved under.
var _local: Dictionary = {}
var _local_dirty := false
var _save_timer := 0.0
var _queue: Array[String] = []
## key -> {"rel", "offset", "length", "tries", "priority", "asked"}
var _jobs: Dictionary = {}
## key -> HTTPRequest
var _active: Dictionary = {}
var _failed: Dictionary = {}
## key -> msec before which it is not retried.
var _retry_at: Dictionary = {}
var _fetched := 0
var _fetched_bytes := 0


## Created under the root on first use.
static func instance(tree: SceneTree) -> Node:
	var existing := tree.root.get_node_or_null("RegionFiles")
	if existing != null:
		return existing
	var node: Node = load(SCRIPT_PATH).new()
	node.name = "RegionFiles"
	tree.root.add_child.call_deferred(node)
	return node


static func _key(rel: String, offset: int, length: int) -> String:
	return rel if length <= 0 else "%s@%d" % [rel, offset]


func _init() -> void:
	use_cache(CACHE)


## Tests pass their own dir.
func use_cache(dir: String) -> void:
	cache_dir = dir.trim_suffix("/") + "/"
	DirAccess.make_dir_recursive_absolute(cache_dir)
	_local = {}
	var parsed: Variant = null
	if FileAccess.file_exists(_local_index()):
		parsed = JSON.parse_string(FileAccess.get_file_as_string(_local_index()))
	if parsed is Dictionary:
		_local = parsed


func _local_index() -> String:
	return cache_dir + "index.json"


## {"path", "offset"} to read from now, or {} when it must be fetched first; length 0 is the whole file.
func locate(res_path: String, offset := 0, length := 0) -> Dictionary:
	var path := res_path.simplify_path()
	if not path.begins_with(DATA_ROOT) or (not force_remote and FileAccess.file_exists(path)):
		return {"path": path, "offset": offset}
	var rel := path.trim_prefix(DATA_ROOT)
	var key := _key(rel, offset, length)
	if _cached(key, rel):
		return {"path": cache_dir + key, "offset": 0}
	return {}


## Lower priority goes first (the streamers pass distance); unrepeated requests age and sink.
func request(res_path: String, offset := 0, length := 0, priority := 0.0) -> void:
	var path := res_path.simplify_path()
	if not path.begins_with(DATA_ROOT):
		return
	var rel := path.trim_prefix(DATA_ROOT)
	var key := _key(rel, offset, length)
	if _jobs.has(key):
		_jobs[key].priority = priority
		_jobs[key].asked = Time.get_ticks_msec()
		return
	if _failed.has(key) or _cached(key, rel):
		return
	_jobs[key] = {"rel": rel, "offset": offset, "length": length, "tries": 0,
		"priority": priority, "asked": Time.get_ticks_msec()}
	_queue.append(key)


func has_failed(res_path: String, offset := 0, length := 0) -> bool:
	var path := res_path.simplify_path()
	return _failed.has(_key(path.trim_prefix(DATA_ROOT), offset, length))


func is_fetching() -> bool:
	return not _jobs.is_empty()


func get_stats() -> Dictionary:
	return {"queued": _queue.size(), "active": _active.size(), "failed": _failed.size(),
		"fetched": _fetched, "fetched_bytes": _fetched_bytes, "cached": _local.size(),
		"index": Index.keys()[_index_state], "base_url": base_url}


func _cached(key: String, rel: String) -> bool:
	if not _local.has(key) or not FileAccess.file_exists(cache_dir + key):
		return false
	if _index_state != Index.READY:
		# Without the index, kept files are the best available.
		return true
	return _server.has(rel) and str(_server[rel].hash) == str(_local[key])


func _process(delta: float) -> void:
	if _local_dirty:
		_save_timer -= delta
		if _save_timer <= 0.0:
			_save_local()
	if _queue.is_empty() and _active.is_empty():
		return
	if base_url == "":
		base_url = _server_base()
		if base_url == "":
			return
	if _index_state == Index.NONE:
		_fetch_index()
	if _index_state == Index.LOADING:
		return
	var now := Time.get_ticks_msec()
	while _active.size() < MAX_ACTIVE:
		var best := _best_queued(now)
		if best < 0:
			break
		var chosen: String = _queue[best]
		_queue.remove_at(best)
		_start(chosen)


## Lowest priority plus age penalty among jobs not waiting to retry, or -1.
func _best_queued(now: int) -> int:
	var best := -1
	var best_score := INF
	for i in _queue.size():
		var key: String = _queue[i]
		if _retry_at.get(key, 0) > now:
			continue
		var job: Dictionary = _jobs[key]
		var score: float = float(job.priority) + float(now - int(job.asked)) / 500.0
		if score < best_score:
			best_score = score
			best = i
	return best


func _server_base() -> String:
	var packs := get_node_or_null("/root/PCKManager")
	if packs == null:
		return ""
	var pck_url := str(packs.get("_download_base_url"))
	if pck_url == "" or pck_url == "<null>":
		return ""
	return pck_url.trim_suffix("/") + "/region/"


## Without the index, downloads still run but kept files are trusted as they are.
func _fetch_index() -> void:
	_index_state = Index.LOADING
	var http := HTTPRequest.new()
	http.timeout = 30
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray):
		http.queue_free()
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8()) \
			if result == HTTPRequest.RESULT_SUCCESS and code == 200 else null
		if parsed is Dictionary and parsed.get("files") is Dictionary:
			_server = parsed.files
			_index_state = Index.READY
			_prune()
			print("[RegionFiles] server map version %s: %d files; %d kept here" % [
				parsed.get("version", "?"), _server.size(), _local.size()])
		else:
			_index_state = Index.UNAVAILABLE
			push_warning("[RegionFiles] no region index at %sindex.json (result %d, HTTP %d)" % [base_url, result, code]))
	if http.request(base_url + "index.json") != OK:
		http.queue_free()
		_index_state = Index.UNAVAILABLE


## Deletes every kept file the server no longer publishes as it is.
func _prune() -> void:
	var removed := 0
	for key: String in _local.keys():
		var rel := key.get_slice("@", 0)
		if not _server.has(rel) or str(_server[rel].hash) != str(_local[key]):
			DirAccess.remove_absolute(cache_dir + key)
			_local.erase(key)
			removed += 1
	if removed > 0:
		print("[RegionFiles] %d kept files were outdated or withdrawn; removed" % removed)
		_save_local()


## A byte range when the job has a length.
func _start(key: String) -> void:
	var job: Dictionary = _jobs[key]
	var rel: String = job.rel
	if _index_state == Index.READY and not _server.has(rel):
		_fail(key, "not published by the server")
		return
	var http := HTTPRequest.new()
	http.timeout = 60
	add_child(http)
	_active[key] = http
	var headers := PackedStringArray()
	var length: int = job.length
	var offset: int = job.offset
	if length > 0:
		headers.append("Range: bytes=%d-%d" % [offset, offset + length - 1])
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray):
		_active.erase(key)
		http.queue_free()
		_finish(key, result, code, body))
	var parts := PackedStringArray()
	for part in rel.split("/"):
		parts.append(part.uri_encode())
	var error := http.request(base_url + "/".join(parts), headers)
	if error != OK:
		_active.erase(key)
		http.queue_free()
		_retry(key, "request error %d" % error)


## 403, 404 and 416 fail at once; other errors retry.
func _finish(key: String, result: int, code: int, body: PackedByteArray) -> void:
	var job: Dictionary = _jobs.get(key, {})
	if job.is_empty():
		return
	if result != HTTPRequest.RESULT_SUCCESS or not (code == 200 or code == 206):
		if code == 404 or code == 403 or code == 416:
			_fail(key, "HTTP %d" % code)
		else:
			_retry(key, "result %d, HTTP %d" % [result, code])
		return
	var length: int = job.length
	if length > 0 and code == 200:
		# A server that ignored the range sent the whole file.
		body = body.slice(job.offset, job.offset + length)
	var expected: int = length
	if length <= 0 and _server.has(job.rel):
		expected = int(_server[job.rel].size)
	if expected > 0 and body.size() != expected:
		_retry(key, "%d bytes, expected %d" % [body.size(), expected])
		return
	if not _store(key, body):
		return
	_local[key] = str(_server[job.rel].hash) if _server.has(job.rel) else ""
	_local_dirty = true
	_save_timer = 2.0
	_jobs.erase(key)
	_retry_at.erase(key)
	_fetched += 1
	_fetched_bytes += body.size()
	file_ready.emit(key)


## Writes through a .part file; false (and the job failed) when it cannot.
func _store(key: String, body: PackedByteArray) -> bool:
	var target := cache_dir + key
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var part := target + ".part"
	var file := FileAccess.open(part, FileAccess.WRITE)
	if file == null:
		_fail(key, "cannot write %s (%s)" % [part, error_string(FileAccess.get_open_error())])
		return false
	file.store_buffer(body)
	file.close()
	DirAccess.remove_absolute(target)
	if DirAccess.rename_absolute(part, target) != OK:
		_fail(key, "cannot keep " + target)
		return false
	return true


## Quadratic back-off; fails the job after RETRIES tries.
func _retry(key: String, why: String) -> void:
	var job: Dictionary = _jobs[key]
	job.tries = int(job.tries) + 1
	if int(job.tries) >= RETRIES:
		_fail(key, why)
		return
	_retry_at[key] = Time.get_ticks_msec() + 1000 * int(job.tries) * int(job.tries)
	_queue.append(key)


func _fail(key: String, why: String) -> void:
	_jobs.erase(key)
	_retry_at.erase(key)
	_failed[key] = true
	push_warning("[RegionFiles] %s: %s" % [key, why])
	file_failed.emit(key)


## Atomic.
func _save_local() -> void:
	_local_dirty = false
	var tmp := _local_index() + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_local))
	file.close()
	DirAccess.remove_absolute(_local_index())
	DirAccess.rename_absolute(tmp, _local_index())


func _exit_tree() -> void:
	if _local_dirty:
		_save_local()
