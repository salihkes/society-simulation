class_name Identity
extends RefCounted
## Who this build is; every personal value is read from res://data/identity.json.

const PATH := "res://data/identity.json"
const EXAMPLE_PATH := "res://data/identity.example.json"

static var _values: Dictionary
static var _path := PATH


## A value from identity.json; a missing key is an error, not a guess.
static func value(key: String) -> Variant:
	if _values.is_empty():
		_values = _load()
	if not _values.has(key):
		push_error("Identity: %s has no '%s'" % [_path, key])
		return null
	return _values[key]


static func _load() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		_path = EXAMPLE_PATH
		print("Identity: using identity.example.json; copy it to identity.json and edit")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Identity: cannot read %s" % _path)
		return {}
	return parsed
