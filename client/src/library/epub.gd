class_name Epub
extends RefCounted
## An EPUB book whose XHTML chapters become BBCode on first read; also the HTML-to-BBCode converter.

var title := ""
var author := ""
## [{file, title, bbcode}]; title and bbcode are filled in by chapter().
var chapters: Array[Dictionary] = []
var path := ""

const MAX_CHAPTERS := 2000


## The book at `file_path`, or null when it is unreadable or has no chapters.
static func open(file_path: String) -> Epub:
	var zip := ZIPReader.new()
	if zip.open(file_path) != OK:
		return null
	var book := Epub.new()
	book.path = file_path
	var opf_path := book._find_opf(zip)
	if opf_path.is_empty():
		zip.close()
		return null
	var opf := zip.read_file(opf_path).get_string_from_utf8()
	var base := opf_path.get_base_dir()
	book._read_metadata(opf)
	var manifest := book._read_manifest(opf)
	for idref in book._read_spine(opf):
		if book.chapters.size() >= MAX_CHAPTERS:
			break
		var href: String = manifest.get(idref, "")
		if href.is_empty():
			continue
		var full := _join(base, href)
		if zip.file_exists(full):
			book.chapters.append({"file": full, "title": "", "bbcode": ""})
	zip.close()
	return book if not book.chapters.is_empty() else null


## Converted lazily: converting a whole book at open() stalls for seconds.
func chapter(index: int) -> Dictionary:
	if index < 0 or index >= chapters.size():
		return {"title": "", "bbcode": ""}
	var entry: Dictionary = chapters[index]
	if not String(entry.bbcode).is_empty():
		return entry
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return entry
	var html := zip.read_file(String(entry.file)).get_string_from_utf8()
	zip.close()
	entry.bbcode = html_to_bbcode(html)
	entry.title = _first_heading(html, "%d" % (index + 1))
	chapters[index] = entry
	return entry


static func _join(base: String, href: String) -> String:
	href = href.split("#")[0].uri_decode()
	if base.is_empty():
		return href
	var joined := base + "/" + href
	var parts: Array[String] = []
	for part in joined.split("/"):
		if part == "." or part.is_empty():
			continue
		if part == "..":
			if not parts.is_empty():
				parts.pop_back()
			continue
		parts.append(part)
	return "/".join(parts)


## The OPF path named by META-INF/container.xml, else any .opf in the zip.
func _find_opf(zip: ZIPReader) -> String:
	if zip.file_exists("META-INF/container.xml"):
		var container := zip.read_file("META-INF/container.xml").get_string_from_utf8()
		var m := _match(container, "full-path=\"([^\"]+)\"")
		if not m.is_empty():
			return m
	for name in zip.get_files():
		if name.to_lower().ends_with(".opf"):
			return name
	return ""


func _read_metadata(opf: String) -> void:
	title = _strip_tags(_match(opf, "<dc:title[^>]*>([\\s\\S]*?)</dc:title>"))
	author = _strip_tags(_match(opf, "<dc:creator[^>]*>([\\s\\S]*?)</dc:creator>"))
	if title.is_empty():
		title = path.get_file().get_basename()


func _read_manifest(opf: String) -> Dictionary:
	var out := {}
	for item in _re("<item\\s+[^>]*>").search_all(opf):
		var tag := item.get_string()
		var id := _match(tag, "id=\"([^\"]*)\"")
		var href := _match(tag, "href=\"([^\"]*)\"")
		if not id.is_empty() and not href.is_empty():
			out[id] = href
	return out


func _read_spine(opf: String) -> PackedStringArray:
	var out := PackedStringArray()
	var spine := _match(opf, "<spine[^>]*>([\\s\\S]*?)</spine>")
	for m in _re("idref=\"([^\"]+)\"").search_all(spine):
		out.append(m.get_string(1))
	return out


## By regex, not a strict parser, so broken markup still renders; keep_images leaves [zimimg=src] markers.
static func html_to_bbcode(html: String, keep_links := false, keep_images := false) -> String:
	var s := _match(html, "<body[^>]*>([\\s\\S]*)</body>")
	if s.is_empty():
		s = html
	s = _drop(s, "<script[\\s\\S]*?</script>")
	s = _drop(s, "<style[\\s\\S]*?</style>")
	s = _drop(s, "<head[\\s\\S]*?</head>")
	s = _drop(s, "<!--[\\s\\S]*?-->")

	if keep_images:
		s = _sub(s, "<img[^>]*src=\"([^\"]*)\"[^>]*>", "\n[zimimg=${1}]\n")
		s = _sub(s, "<img[^>]*src='([^']*)'[^>]*>", "\n[zimimg=${1}]\n")

	s = _sub(s, "<\\s*(br|BR)\\s*/?>", "\n")
	# Cells become "|"-separated text: [table] needs a fixed column count.
	s = _sub(s, "<\\s*/\\s*(td|th)\\s*>", "   |   ")
	s = _sub(s, "<\\s*/\\s*tr\\s*>", "\n")
	s = _sub(s, "<\\s*/\\s*(p|div|li)\\s*>", "\n\n")
	s = _sub(s, "<\\s*li[^>]*>", "  • ")
	s = _sub(s, "<\\s*h[1-6][^>]*>", "\n\n[b]")
	s = _sub(s, "<\\s*(b|strong)[^>]*>", "[b]")
	s = _sub(s, "<\\s*/\\s*(b|strong)\\s*>", "[/b]")
	s = _sub(s, "<\\s*(i|em)[^>]*>", "[i]")
	s = _sub(s, "<\\s*/\\s*(i|em)\\s*>", "[/i]")
	s = _sub(s, "<\\s*/\\s*h[1-6]\\s*>", "[/b]\n\n")
	if keep_links:
		# Whole elements are matched so an anchor without href leaves no [/url].
		s = _sub(s, "<a[^>]*href=\"([^\"]*)\"[^>]*>([\\s\\S]*?)</a>", "[url=${1}]${2}[/url]")
		s = _sub(s, "<a[^>]*href='([^']*)'[^>]*>([\\s\\S]*?)</a>", "[url=${1}]${2}[/url]")
	s = _drop(s, "<[^>]*>")
	s = unescape(s)
	s = _sub(s, "[ \\t]+", " ")
	# Lines left holding only spaces would read as runs of blank lines.
	s = _sub(s, " *\\n", "\n")
	s = _sub(s, "\\n{3,}", "\n\n")
	return s.strip_edges()


static func unescape(s: String) -> String:
	for pair in [["&nbsp;", " "], ["&amp;", "&"], ["&lt;", "<"], ["&gt;", ">"],
			["&quot;", "\""], ["&apos;", "'"], ["&mdash;", "—"], ["&ndash;", "–"],
			["&hellip;", "…"], ["&rsquo;", "’"], ["&lsquo;", "‘"],
			["&ldquo;", "“"], ["&rdquo;", "”"]]:
		s = s.replace(pair[0], pair[1])
	var re := _re("&#(x?)([0-9A-Fa-f]+);")
	var out := ""
	var last := 0
	for m in re.search_all(s):
		out += s.substr(last, m.get_start() - last)
		var digits := m.get_string(2)
		var code := digits.hex_to_int() if m.get_string(1) == "x" else digits.to_int()
		if code > 0:
			out += String.chr(code)
		last = m.get_end()
	return out + s.substr(last)


## The first <h1>-<h6> text, else the <title>, else `fallback`.
static func _first_heading(html: String, fallback: String) -> String:
	var h := _strip_tags(_match(html, "<h[1-6][^>]*>([\\s\\S]*?)</h[1-6]>"))
	h = unescape(h).strip_edges()
	if h.is_empty():
		h = _strip_tags(_match(html, "<title[^>]*>([\\s\\S]*?)</title>")).strip_edges()
	return h if not h.is_empty() else fallback


static func _strip_tags(s: String) -> String:
	return _drop(s, "<[^>]*>").strip_edges()


## Compiled RegEx by pattern; compiling per chapter is too slow.
static var _cache: Dictionary = {}


static func _re(pattern: String) -> RegEx:
	var re: RegEx = _cache.get(pattern)
	if re == null:
		re = RegEx.new()
		re.compile(pattern)
		_cache[pattern] = re
	return re


static func _match(text: String, pattern: String) -> String:
	var m := _re(pattern).search(text)
	return m.get_string(1) if m else ""


static func _sub(text: String, pattern: String, with: String) -> String:
	return _re(pattern).sub(text, with, true)


static func _drop(text: String, pattern: String) -> String:
	return _sub(text, pattern, "")
