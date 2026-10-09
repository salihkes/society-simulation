extends RefCounted
## Parses the .srt/WebVTT sidecar next to a video and finds the cue for a playback position.


## Array of {start: ms, end: ms, text} sorted by start, or null when there is no sidecar.
static func load_sidecar(source: String):
	if source.begins_with("http://") or source.begins_with("https://"):
		return null
	var path := source.get_basename() + ".srt"
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var cues := parse_srt(f.get_as_text())
	return cues if not cues.is_empty() else null


## Also accepts WebVTT.
static func parse_srt(text: String) -> Array:
	var cues: Array = []
	if text.begins_with("WEBVTT"):
		var first_break := text.find("\n\n")
		text = text.substr(first_break + 2) if first_break > 0 else text
	var tag_re := RegEx.new()
	tag_re.compile("<[^>]*>")
	for block in text.replace("\r\n", "\n").replace("\r", "\n").split("\n\n", false):
		var lines: PackedStringArray = block.split("\n", false)
		var time_line := -1
		for i in lines.size():
			if lines[i].contains("-->"):
				time_line = i
				break
		if time_line == -1 or time_line + 1 >= lines.size():
			continue
		var times := lines[time_line].split("-->")
		if times.size() != 2:
			continue
		# VTT allows "00:01.000 --> 00:04.000 align:start position:10%"
		times[1] = times[1].strip_edges().split(" ")[0]
		var start := _parse_time(times[0])
		var end := _parse_time(times[1])
		if start < 0 or end <= start:
			continue
		var body := "\n".join(lines.slice(time_line + 1))
		cues.append({"start": start, "end": end, "text": tag_re.sub(body, "", true).strip_edges()})
	cues.sort_custom(func(a, b): return a.start < b.start)
	return cues


## Text of the cue covering `ms`, or "". `cues` must be sorted by start.
static func cue_at(cues: Array, ms: int) -> String:
	for cue in cues:
		if ms < cue.start:
			return ""
		if ms <= cue.end:
			return cue.text
	return ""


## "00:01:23,456" (comma or dot) to milliseconds, or -1 if malformed.
static func _parse_time(t: String) -> int:
	var parts := t.strip_edges().replace(",", ".").split(":")
	if parts.size() != 3:
		return -1
	var sec_parts := parts[2].split(".")
	var ms := 0
	if sec_parts.size() > 1:
		ms = int(sec_parts[1].substr(0, 3).lpad(3, "0").rpad(3, "0"))
	if not parts[0].is_valid_int() or not parts[1].is_valid_int() or not sec_parts[0].is_valid_int():
		return -1
	return (int(parts[0]) * 3600 + int(parts[1]) * 60 + int(sec_parts[0])) * 1000 + ms
