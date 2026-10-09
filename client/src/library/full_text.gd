class_name FullText
extends RefCounted
## Full-text ZIM search via Android SearchBridge; works only on an uncompressed Xapian index read in place.

## Where the index lives inside a ZIM; both spellings exist.
const INDEX_PATHS := ["fulltext/xapian", "Z//fulltext/xapian"]

var archive_path := ""
var document_count := 0
var language := ""
var error := ""

var _bridge = null
var _handle := 0


## The Java SearchBridge class, or null off Android.
static func bridge_class():
	if not OS.has_feature("android"):
		return null
	var cls = JavaClassWrapper.wrap(Identity.value("android_package") + ".SearchBridge")
	JavaClassWrapper.get_exception()
	return cls


## `zim` only locates the index and is not kept; null without a readable uncompressed index.
static func open(zim, path: String) -> FullText:
	var cls = bridge_class()
	if cls == null or not bool(cls.isAvailable()):
		return null
	var entry: Dictionary = {}
	for candidate in INDEX_PATHS:
		entry = zim.lookup(candidate, "X")
		if entry.is_empty():
			entry = zim.lookup(candidate)
		if not entry.is_empty():
			break
	if entry.is_empty() or entry.redirect:
		return null
	# A compressed index has no byte range to hand Xapian, so it is skipped.
	var where: Dictionary = zim.blob_range(int(entry.cluster), int(entry.blob))
	if where.is_empty():
		return null
	var index := FullText.new()
	index.archive_path = path
	index._bridge = cls
	index._handle = int(cls.open(path, int(where.offset)))
	if JavaClassWrapper.get_exception() or index._handle == 0:
		index.error = str(cls.getLoadError())
		return null
	index.document_count = int(cls.documentCount(index._handle))
	index.language = str(cls.language(index._handle))
	return index


## [{path, title, score}], best first, with any "X/" namespace prefix stripped from `path`.
func search(query: String, limit := 40) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _handle == 0 or query.strip_edges().is_empty():
		return out
	var raw := str(_bridge.search(_handle, query, limit))
	if JavaClassWrapper.get_exception():
		error = "the search call threw"
		return out
	var parsed = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		error = "the bridge returned something unreadable"
		return out
	if parsed.has("error"):
		error = str(parsed["error"])
		return out
	error = ""
	for hit in parsed.get("hits", []):
		var path := str(hit.get("path", ""))
		if path.length() > 2 and path[1] == "/":
			path = path.substr(2)
		out.append({
			"path": path,
			"title": str(hit.get("title", "")),
			"score": int(hit.get("score", 0)),
		})
	return out


func close() -> void:
	if _handle != 0 and _bridge != null:
		_bridge.close(_handle)
		JavaClassWrapper.get_exception()
	_handle = 0
	_bridge = null
