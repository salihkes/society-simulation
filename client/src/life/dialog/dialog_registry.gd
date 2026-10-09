extends RefCounted

## Pre-scripted NPC dialog: lines, conversations and voice clip paths from dialogs.json.

const DIALOG_JSON := "res://assets/entities/ambient/dialog/dialogs.json"
const VOICES_DIR := "res://assets/art/sound/voices"

static var _data: Dictionary = {}
static var _loaded := false


static func _db() -> Dictionary:
	if _loaded:
		return _data
	_loaded = true
	var f := FileAccess.open(DIALOG_JSON, FileAccess.READ)
	if f == null:
		return _data
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_data = parsed
	else:
		push_warning("[DialogRegistry] Bad dialogs.json")
	return _data


static func line(id: String) -> Dictionary:
	var lines: Dictionary = _db().get("lines", {})
	return lines.get(id, {})


## Ordered entries [{s, l, gap}, ...]: slot, line id, pause.
static func conv(id: String) -> Array:
	var convs: Dictionary = _db().get("conversations", {})
	return convs.get(id, [])


## Clips live at <VOICES_DIR>/<voice>/<line>.wav.
static func clip(voice: String, line_id: String) -> String:
	return "%s/%s/%s.wav" % [VOICES_DIR, voice, line_id]


## Derived from the replicated id so every peer hears the same voice.
static func voice_for(ped_id: String) -> String:
	return "generic" if hash(ped_id) % 2 == 0 else "generic_f"
