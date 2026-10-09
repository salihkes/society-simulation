class_name ZimShelf
extends RefCounted
## Browsing model for catalogued ZIM archives: entities (channels, accounts) owning items (videos, posts).


## [{id, name, detail, avatar, count}], sorted by name.
static func entities(z) -> Array[Dictionary]:
	var c: Dictionary = z.catalog()
	var out: Array[Dictionary] = []
	for ch in c.get("channels", []):
		out.append(_channel_entity(ch))
	for a in c.get("accounts", []):
		out.append(_account_entity(a))
	out.sort_custom(func(x, y): return String(x.name).naturalnocasecmp_to(String(y.name)) < 0)
	return out


static func _channel_entity(ch) -> Dictionary:
	return {
		"id": str(ch.get("id", "")),
		"name": _text(ch.get("name", "")),
		"detail": "%s   %s subscribers   %d videos" % [_text(ch.get("handle", "")),
			_compact(ch.get("subscribers", 0)), int(_num(ch.get("videos", 0)))],
		"avatar": "a-%s.jpg" % str(ch.get("id", "")),
		"count": int(_num(ch.get("videos", 0))),
	}


static func _account_entity(a) -> Dictionary:
	var counts: Dictionary = a.get("counts", {})
	var bits: Array[String] = []
	for key in ["posts", "reels", "stories", "highlights"]:
		var n := int(_num(counts.get(key, 0)))
		if n > 0:
			bits.append("%d %s" % [n, key])
	var username := _text(a.get("username", ""))
	var name := _text(a.get("full_name", ""))
	if name.is_empty():
		name = username
	return {
		"id": username,
		"name": "%s%s" % [name, "  ✓" if bool(a.get("verified", false)) else ""],
		"detail": "@%s   %s" % [username, "  ".join(bits)],
		"avatar": _text(a.get("avatar", "")),
		"count": int(_num(counts.get("posts", 0))) + int(_num(counts.get("reels", 0))),
	}


## [{id, title, detail, media, thumb, kind, subtitles, sort}], newest first; whole archive when entity_id is empty.
static func items(z, entity_id := "", limit := 4000) -> Array[Dictionary]:
	var c: Dictionary = z.catalog()
	var out: Array[Dictionary] = []
	for v in c.get("videos", []):
		if out.size() >= limit:
			break
		if not entity_id.is_empty() and str(v.get("channel_id", "")) != entity_id:
			continue
		out.append(_video_item(v))
	for item in c.get("items", []):
		if out.size() >= limit:
			break
		if not entity_id.is_empty() and _text(item.get("user", "")) != entity_id:
			continue
		out.append(_post_item(item))
	out.sort_custom(func(x, y): return String(x.sort) > String(y.sort))
	return out


static func _video_item(v) -> Dictionary:
	var id := str(v.get("id", ""))
	return {
		"id": id,
		"title": _text(v.get("title", "untitled")),
		"detail": "%s   %s   %s views%s" % [_text(v.get("channel", "")),
			_clock(v.get("duration", 0.0)), _compact(v.get("view_count", 0)),
			"   short" if bool(v.get("is_short", false)) else ""],
		"media": str(v.get("media", "")),
		"thumb": "t-%s.jpg" % id,
		"kind": "video",
		"subtitles": v.get("subtitles", []),
		"sort": _text(v.get("upload_date", "")),
	}


static func _post_item(item) -> Dictionary:
	var first := _first_media(item.get("media", []))
	var user := _text(item.get("user", ""))
	var caption := _text(item.get("caption", "")).strip_edges().replace("\n", " ")
	if caption.is_empty():
		caption = "%s — %s" % [user, _text(item.get("kind", "post"))]
	var bits: Array[String] = [user, _text(item.get("date", "")).substr(0, 10)]
	var location := _text(item.get("location", ""))
	if not location.is_empty():
		bits.append("· " + location)
	var audio := _text(item.get("audio", ""))
	if not audio.is_empty():
		bits.append("♪ " + audio)
	return {
		"id": _text(item.get("id", "")),
		"title": caption.substr(0, 110),
		"detail": "   ".join(bits),
		"media": first.path,
		"thumb": _text(item.get("thumb", "")),
		"kind": "video" if first.video else "image",
		"subtitles": [],
		"sort": _text(item.get("date", "")),
	}


## {path, video} of the first dictionary in a post's media list.
static func _first_media(media_list) -> Dictionary:
	if media_list is Array:
		for m in media_list:
			if m is Dictionary:
				return {"path": _text(m.get("path", "")), "video": bool(m.get("video", false))}
	return {"path": "", "video": false}


## Null when the entry is missing or not a decodable picture.
static func texture(z, path: String) -> Texture2D:
	if path.is_empty():
		return null
	var e: Dictionary = z.lookup(path)
	if e.is_empty() or e.redirect:
		return null
	var bytes: PackedByteArray = z.read_blob(int(e.cluster), int(e.blob))
	if bytes.is_empty():
		return null
	var img := Image.new()
	# Format comes from the bytes: files named .jpg are often WebP.
	var err := ERR_FILE_UNRECOGNIZED
	match _picture_format(bytes):
		"jpg": err = img.load_jpg_from_buffer(bytes)
		"png": err = img.load_png_from_buffer(bytes)
		"webp": err = img.load_webp_from_buffer(bytes)
		_: return null
	if err != OK:
		return null
	return ImageTexture.create_from_image(img)


## "jpg", "png" or "webp" from the magic bytes, or "".
static func _picture_format(b: PackedByteArray) -> String:
	if b.size() < 12:
		return ""
	if b[0] == 0xFF and b[1] == 0xD8 and b[2] == 0xFF:
		return "jpg"
	if b[0] == 0x89 and b[1] == 0x50 and b[2] == 0x4E and b[3] == 0x47:
		return "png"
	if b.slice(0, 4).get_string_from_ascii() == "RIFF" and b.slice(8, 12).get_string_from_ascii() == "WEBP":
		return "webp"
	return ""


## Takes the first track not ending in "-orig", else the first; null when none.
static func subtitle_cues(z, item: Dictionary):
	var tracks = item.get("subtitles", [])
	if not (tracks is Array) or tracks.is_empty():
		return null
	var chosen := ""
	for t in tracks:
		var name := str(t)
		if not name.ends_with("-orig"):
			chosen = name
			break
	if chosen.is_empty():
		chosen = str(tracks[0])
	var e: Dictionary = z.lookup("s-%s-%s.vtt" % [_text(item.get("id", "")), chosen])
	if e.is_empty():
		return null
	var Subs := load("res://src/media/subtitles.gd")
	var cues: Array = Subs.parse_srt(z.read_text(e))
	return cues if not cues.is_empty() else null


## Seconds as "m:ss" or "h:mm:ss"; "" for zero or less.
static func _clock(seconds) -> String:
	var s := int(_num(seconds))
	if s <= 0:
		return ""
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]


## Catalogue text with null as "" (str(null) would be "<null>").
static func _text(v) -> String:
	return "" if v == null else str(v)


## A catalogue number as float, with null or other junk as 0.
static func _num(v) -> float:
	match typeof(v):
		TYPE_FLOAT, TYPE_INT: return float(v)
		TYPE_STRING: return String(v).to_float()
		_: return 0.0


static func _compact(n) -> String:
	var v := _num(n)
	if v >= 1000000.0:
		return "%.1fM" % (v / 1000000.0)
	if v >= 1000.0:
		return "%.0fK" % (v / 1000.0)
	return "%d" % int(v)
