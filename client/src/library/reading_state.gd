class_name ReadingState
extends RefCounted
## Reading position per document, keyed by a hash of its path and kept in user://, never on the drive.

const FILE := "user://reading.cfg"
## Least recently seen entries beyond this are dropped.
const MAX_REMEMBERED := 300

static var _config: ConfigFile = null


static func _cfg() -> ConfigFile:
	if _config == null:
		_config = ConfigFile.new()
		_config.load(FILE)
	return _config


static func _key(path: String) -> String:
	return str(hash(path))


## Stores `where` (an int chapter/page or a String entry url) for `path`.
static func remember(path: String, where) -> void:
	if path.is_empty():
		return
	var c := _cfg()
	var key := _key(path)
	c.set_value("at", key, where)
	c.set_value("seen", key, Time.get_unix_time_from_system())
	_trim(c)
	c.save(FILE)


static func recall(path: String, fallback):
	if path.is_empty():
		return fallback
	return _cfg().get_value("at", _key(path), fallback)


static func forget(path: String) -> void:
	var c := _cfg()
	var key := _key(path)
	c.erase_section_key("at", key)
	c.erase_section_key("seen", key)
	c.save(FILE)


static func _trim(c: ConfigFile) -> void:
	var keys := c.get_section_keys("at") if c.has_section("at") else PackedStringArray()
	if keys.size() <= MAX_REMEMBERED:
		return
	var ordered: Array[Array] = []
	for k in keys:
		ordered.append([float(c.get_value("seen", k, 0.0)), k])
	ordered.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for i in ordered.size() - MAX_REMEMBERED:
		c.erase_section_key("at", ordered[i][1])
		c.erase_section_key("seen", ordered[i][1])
