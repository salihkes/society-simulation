class_name Zim
extends RefCounted
## Reader for ZIM (Kiwix) archives; nothing is loaded whole, uncompressed blobs can be streamed in place.

const MAGIC := 0x044D495A
const REDIRECT := 0xFFFF

## ARTICLE: self-contained HTML entries (mwoffliner).
## REPLAY: raw captured HTTP responses that need JavaScript to assemble (warc2zim).
## CATALOGUED: carries a catalog.json describing its items; wins when present.
enum Kind { ARTICLE, REPLAY, CATALOGUED }

var path := ""
var entry_count := 0
var cluster_count := 0
var main_page := 0
var uuid := PackedByteArray()

var _f: FileAccess
var _url_ptr := 0
var _title_ptr := 0
var _cluster_ptr := 0
var _mime_ptr := 0
var _mimes: PackedStringArray = PackedStringArray()
var _kind := -1
var _catalog: Dictionary = {}
var _catalog_read := false

const CLUSTER_CACHE := 4
var _cluster_cache_ids: Array[int] = []
var _cluster_cache_bodies: Array[PackedByteArray] = []


## The archive at `file_path` with its header read, or null if it is not a ZIM.
static func open(file_path: String) -> Zim:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return null
	if f.get_32() != MAGIC:
		return null
	var z := Zim.new()
	z._f = f
	z.path = file_path
	f.get_16()                      # major
	f.get_16()                      # minor
	z.uuid = f.get_buffer(16)
	z.entry_count = f.get_32()
	z.cluster_count = f.get_32()
	z._url_ptr = f.get_64()
	z._title_ptr = f.get_64()
	z._cluster_ptr = f.get_64()
	z._mime_ptr = f.get_64()
	z.main_page = f.get_32()
	z._read_mimes()
	return z


func close() -> void:
	if _f:
		_f.close()
		_f = null
	_cluster_cache_ids.clear()
	_cluster_cache_bodies.clear()


## At most 4097 names.
func _read_mimes() -> void:
	_f.seek(_mime_ptr)
	while true:
		var s := _read_cstring()
		if s.is_empty():
			break
		_mimes.append(s)
		if _mimes.size() > 4096:
			break


func _read_cstring() -> String:
	var bytes := PackedByteArray()
	while not _f.eof_reached():
		var b := _f.get_8()
		if b == 0:
			break
		bytes.append(b)
	return bytes.get_string_from_utf8()


func mime_name(index: int) -> String:
	return _mimes[index] if index >= 0 and index < _mimes.size() else ""


## {index, ns, mime, url, title, redirect (bool), target, cluster, blob}, or {} when out of range.
func entry(index: int) -> Dictionary:
	if index < 0 or index >= entry_count:
		return {}
	_f.seek(_url_ptr + index * 8)
	return _entry_at(_f.get_64(), index)


## An empty title becomes the url.
func _entry_at(offset: int, index: int) -> Dictionary:
	_f.seek(offset)
	var mime := _f.get_16()
	_f.get_8()                      # parameter length
	var ns := String.chr(_f.get_8())
	_f.get_32()                     # revision
	var out := {"index": index, "ns": ns, "redirect": mime == REDIRECT,
		"mime": "", "target": -1, "cluster": -1, "blob": -1}
	if mime == REDIRECT:
		out.target = _f.get_32()
	else:
		out.mime = mime_name(mime)
		out.cluster = _f.get_32()
		out.blob = _f.get_32()
	out["url"] = _read_cstring()
	out["title"] = _read_cstring()
	if String(out.title).is_empty():
		out.title = out.url
	return out


## Binary search over the url pointer list, sorted by (namespace, url); {} when missing.
func find(url: String, ns := "C") -> Dictionary:
	var lo := 0
	var hi := entry_count - 1
	while lo <= hi:
		var mid := (lo + hi) / 2
		var e := entry(mid)
		var cmp := _compare(String(e["ns"]), String(e["url"]), ns, url)
		if cmp == 0:
			return e
		if cmp < 0:
			lo = mid + 1
		else:
			hi = mid - 1
	return {}


static func _compare(ns_a: String, url_a: String, ns_b: String, url_b: String) -> int:
	if ns_a != ns_b:
		return -1 if ns_a < ns_b else 1
	if url_a == url_b:
		return 0
	return -1 if url_a < url_b else 1


## Follows at most 9 redirects.
func resolve(e: Dictionary, depth := 0) -> Dictionary:
	if e.is_empty() or not e.redirect or depth > 8:
		return e
	return resolve(entry(int(e.target)), depth + 1)


func _cluster_offset(index: int) -> int:
	_f.seek(_cluster_ptr + index * 8)
	return _f.get_64()


## Absolute {offset, size} of a blob, or {} when its cluster is compressed or out of range.
func blob_range(cluster: int, blob: int) -> Dictionary:
	if cluster < 0 or cluster >= cluster_count:
		return {}
	var base := _cluster_offset(cluster)
	_f.seek(base)
	var info := _f.get_8()
	if (info & 0x0F) > 1:
		return {}
	var wide := (info & 0x10) != 0
	var table := base + 1
	var first := _read_offset(table, 0, wide)
	var stride := 8 if wide else 4
	var count := first / stride - 1
	if blob < 0 or blob >= count:
		return {}
	var start := _read_offset(table, blob, wide)
	var end := _read_offset(table, blob + 1, wide)
	return {"offset": table + start, "size": end - start}


func _read_offset(table: int, index: int, wide: bool) -> int:
	_f.seek(table + index * (8 if wide else 4))
	return _f.get_64() if wide else _f.get_32()


## Empty on failure.
func read_blob(cluster: int, blob: int) -> PackedByteArray:
	var direct := blob_range(cluster, blob)
	if not direct.is_empty():
		_f.seek(int(direct.offset))
		return _f.get_buffer(int(direct.size))

	var body := _cluster_body(cluster)
	if body.is_empty():
		return body
	var wide := _cluster_is_wide(cluster)
	var stride := 8 if wide else 4
	var first := _offset_in(body, 0, wide)
	var count := first / stride - 1
	if blob < 0 or blob >= count:
		return PackedByteArray()
	var start := _offset_in(body, blob, wide)
	var end := _offset_in(body, blob + 1, wide)
	return body.slice(start, end)


func _cluster_is_wide(cluster: int) -> bool:
	_f.seek(_cluster_offset(cluster))
	return (_f.get_8() & 0x10) != 0


static func _offset_in(body: PackedByteArray, index: int, wide: bool) -> int:
	var at := index * (8 if wide else 4)
	return body.decode_u64(at) if wide else body.decode_u32(at)


## Without the info byte; the last CLUSTER_CACHE clusters are kept, as one page's resources share them.
func _cluster_body(cluster: int) -> PackedByteArray:
	var hit := _cluster_cache_ids.find(cluster)
	if hit >= 0:
		return _cluster_cache_bodies[hit]
	var body := _decompress_cluster(cluster)
	if not body.is_empty():
		_cluster_cache_ids.append(cluster)
		_cluster_cache_bodies.append(body)
		if _cluster_cache_ids.size() > CLUSTER_CACHE:
			_cluster_cache_ids.pop_front()
			_cluster_cache_bodies.pop_front()
	return body


func _decompress_cluster(cluster: int) -> PackedByteArray:
	var base := _cluster_offset(cluster)
	var next := _cluster_offset(cluster + 1) if cluster + 1 < cluster_count else _f.get_length()
	_f.seek(base)
	var info := _f.get_8()
	var compressed := _f.get_buffer(next - base - 1)
	match info & 0x0F:
		0, 1:
			return compressed
		5:
			return _decompress_zstd(compressed)
		_:
			# 2 zlib, 3 bzip2, 4 lzma: no decoder in Godot.
			push_warning("ZIM cluster %d uses an unsupported compression (%d)" % [cluster, info & 0x0F])
			return PackedByteArray()


## A ZIM cluster does not record its decompressed size, so growing target sizes are tried.
static func _decompress_zstd(compressed: PackedByteArray) -> PackedByteArray:
	for target in [1 << 21, 1 << 23, 1 << 25, 1 << 27]:
		var out := compressed.decompress(target, FileAccess.COMPRESSION_ZSTD)
		if not out.is_empty():
			return out
	return PackedByteArray()


## Cached: CATALOGUED if it has a catalogue, REPLAY if it carries the warc2zim wombat runtime.
func kind() -> int:
	if _kind >= 0:
		return _kind
	if not catalog().is_empty():
		_kind = Kind.CATALOGUED
		return _kind
	_kind = Kind.ARTICLE
	for marker in ["_zim_static/wombat.js", "_zim_static/wombatSetup.js", "_zim_static/__wb_module_decl.js"]:
		if not find(marker).is_empty():
			_kind = Kind.REPLAY
			break
	return _kind


## Read once; {} when there is none.
func catalog() -> Dictionary:
	if _catalog_read:
		return _catalog
	_catalog_read = true
	var e := find("catalog.json")
	if e.is_empty() or e.redirect:
		return _catalog
	var parsed = JSON.parse_string(read_text(e))
	if typeof(parsed) == TYPE_DICTIONARY:
		_catalog = parsed
	return _catalog


func read_text(e: Dictionary) -> String:
	if e.is_empty() or e.redirect:
		return ""
	return read_blob(int(e.cluster), int(e.blob)).get_string_from_utf8()


## Follows any redirect.
func lookup(url: String, ns := "C") -> Dictionary:
	return resolve(find(url, ns))


## {offset, size}, or {} if compressed or missing.
func file_range(url: String) -> Dictionary:
	var e := lookup(url)
	if e.is_empty() or e.redirect:
		return {}
	return blob_range(int(e.cluster), int(e.blob))


## Raw bytes at an absolute file offset, for range reads of uncompressed blobs.
func read_at(offset: int, size: int) -> PackedByteArray:
	if size <= 0 or _f == null:
		return PackedByteArray()
	_f.seek(offset)
	return _f.get_buffer(size)


## Url order is byte-wise and so case-sensitive, so several capitalisations of the query are tried.
func search(query: String, limit := 60, ns := "C") -> Array[Dictionary]:
	var typed := query.strip_edges()
	if typed.is_empty():
		return []
	var out: Array[Dictionary] = []
	var seen := {}
	for form in _search_forms(typed):
		_collect_prefix(form, ns, limit, out, seen)
		if out.size() >= limit:
			break
	return out


static func _search_forms(typed: String) -> Array[String]:
	var raised := typed.substr(0, 1).to_upper() + typed.substr(1)
	var forms: Array[String] = []
	for candidate in [typed, typed.capitalize(), raised, typed.replace(" ", "_"),
			typed.capitalize().replace(" ", "_"), raised.replace(" ", "_")]:
		if not forms.has(candidate):
			forms.append(candidate)
	return forms


## Stops when `out` holds `limit`; skips urls already in `seen`.
func _collect_prefix(form: String, ns: String, limit: int, out: Array[Dictionary],
		seen: Dictionary) -> void:
	var i := _lower_bound(ns, form)
	while i < entry_count and out.size() < limit:
		var e := entry(i)
		if e.is_empty() or String(e["ns"]) != ns or not String(e["url"]).begins_with(form):
			return
		i += 1
		e = resolve(e)
		if e.is_empty():
			continue
		var key := String(e["url"])
		if seen.has(key):
			continue
		seen[key] = true
		out.append(e)


## First index whose (namespace, url) is not less than the target.
func _lower_bound(ns: String, url: String) -> int:
	var lo := 0
	var hi := entry_count
	while lo < hi:
		var mid := (lo + hi) / 2
		var e := entry(mid)
		if e.is_empty() or _compare(String(e["ns"]), String(e["url"]), ns, url) < 0:
			lo = mid + 1
		else:
			hi = mid
	return lo
