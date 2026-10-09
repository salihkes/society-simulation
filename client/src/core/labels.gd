class_name Labels
extends RefCounted
## Short on-screen words the world may rename, from res://assets/ui/labels.json.

const PATH := "res://assets/ui/labels.json"

static var _values: Dictionary
static var _loaded := false


## The world's word for key, or fallback when the world has none.
static func text(key: String, fallback: String) -> String:
	if not _loaded:
		_loaded = true
		if FileAccess.file_exists(PATH):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
			if parsed is Dictionary:
				_values = parsed
	return str(_values.get(key, fallback))
