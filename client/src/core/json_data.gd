@tool
extends RefCounted
## Reads JSON content files under res://assets.


## The object in path, or {} with an error when the file is missing or not an object.
static func read(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return parsed
	push_error("JsonData: cannot read %s" % path)
	return {}
