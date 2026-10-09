class_name ZimServer
extends RefCounted
## Read-only HTTP server on 127.0.0.1 serving a ZIM archive to the WebView, one request at a time on a thread.

const ZimScript := preload("res://src/library/zim.gd")

## Longest single response; larger blobs are served as ranges.
const MAX_SLICE := 4 << 20

var port := 0
var archive_path := ""

var _server: TCPServer
var _thread: Thread
var _zim = null
var _running := false
var _main_url := ""


func start(path: String) -> bool:
	stop()
	_zim = ZimScript.open(path)
	if _zim == null:
		return false
	archive_path = path
	var main: Dictionary = _zim.resolve(_zim.entry(_zim.main_page))
	_main_url = str(main.get("url", "")) if not main.is_empty() else ""
	_server = TCPServer.new()
	if _server.listen(0, "127.0.0.1") != OK:
		_zim.close()
		_zim = null
		return false
	port = _server.get_local_port()
	_running = true
	_thread = Thread.new()
	_thread.start(_loop)
	return true


func stop() -> void:
	_running = false
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	if _server != null:
		_server.stop()
		_server = null
	if _zim != null:
		_zim.close()
		_zim = null
	port = 0
	archive_path = ""


func base_url() -> String:
	return "http://127.0.0.1:%d/" % port


## Where a fresh window should land.
func start_url() -> String:
	return base_url() + _encode_path(_main_url)


## Per segment, keeping slashes so relative links resolve.
static func _encode_path(url: String) -> String:
	var out: Array[String] = []
	for part in url.split("/"):
		out.append(String(part).uri_encode())
	return "/".join(out)


func _loop() -> void:
	while _running:
		if not _server.is_connection_available():
			OS.delay_msec(3)
			continue
		var peer := _server.take_connection()
		if peer == null:
			continue
		_serve(peer)
		peer.disconnect_from_host()


func _serve(peer: StreamPeerTCP) -> void:
	var head := _read_head(peer)
	if head.is_empty():
		return
	var lines := head.split("\r\n")
	var request := lines[0].split(" ")
	if request.size() < 2:
		return
	var method := request[0].to_upper()
	if method != "GET" and method != "HEAD":
		_send(peer, 405, "text/plain", "only GET".to_utf8_buffer(), {})
		return
	var target := request[1].split("?")[0].split("#")[0]

	# Redirect "/" to the main page's real path so its relative links resolve.
	if target == "/" or target.is_empty():
		if _main_url.is_empty():
			_send(peer, 404, "text/plain", "this archive has no main page".to_utf8_buffer(), {})
		else:
			_send(peer, 302, "text/plain", PackedByteArray(),
				{"Location": "/" + _encode_path(_main_url)})
		return

	var headers := _parse_headers(lines)

	var e := _find(target)
	if e.is_empty():
		_send(peer, 404, "text/plain",
			("no entry for %s" % target).to_utf8_buffer(), {})
		return

	var mime := str(e.get("mime", "application/octet-stream"))
	var range_header := str(headers.get("range", ""))
	if not range_header.is_empty():
		_send_range(peer, e, mime, range_header, method == "HEAD")
		return

	var direct: Dictionary = _zim.blob_range(int(e.cluster), int(e.blob))
	if not direct.is_empty() and int(direct.size) > MAX_SLICE:
		# Big uncompressed media: answer as a range so the player can seek.
		_send_range(peer, e, mime, "bytes=0-", method == "HEAD")
		return

	var body: PackedByteArray = PackedByteArray() if method == "HEAD" \
		else _zim.read_blob(int(e.cluster), int(e.blob))
	var extra := {"Accept-Ranges": "bytes"}
	if method == "HEAD" and not direct.is_empty():
		extra["Content-Length"] = str(int(direct.size))
	_send(peer, 200, mime, body, extra)


## Lower-cased header names to values.
static func _parse_headers(lines: PackedStringArray) -> Dictionary:
	var headers := {}
	for i in range(1, lines.size()):
		var line := String(lines[i])
		var colon := line.find(":")
		if colon > 0:
			headers[line.substr(0, colon).strip_edges().to_lower()] = \
				line.substr(colon + 1).strip_edges()
	return headers


## At most MAX_SLICE long.
func _send_range(peer: StreamPeerTCP, e: Dictionary, mime: String,
		range_header: String, head_only: bool) -> void:
	var direct: Dictionary = _zim.blob_range(int(e.cluster), int(e.blob))
	var total := 0
	var bytes := PackedByteArray()
	if direct.is_empty():
		# Compressed: the whole blob has to come out anyway.
		bytes = _zim.read_blob(int(e.cluster), int(e.blob))
		total = bytes.size()
	else:
		total = int(direct.size)
	if total <= 0:
		_send(peer, 404, "text/plain", PackedByteArray(), {})
		return

	var span := _parse_range(range_header, total)
	var from: int = span[0]
	var to: int = span[1]

	var slice := PackedByteArray()
	if not head_only:
		if direct.is_empty():
			slice = bytes.slice(from, to + 1)
		else:
			slice = _zim.read_at(int(direct.offset) + from, to - from + 1)
	_send(peer, 206, mime, slice, {
		"Accept-Ranges": "bytes",
		"Content-Range": "bytes %d-%d/%d" % [from, to, total],
		"Content-Length": str(to - from + 1),
	})


## [first, last] of "bytes=a-b", clamped to the blob and to MAX_SLICE.
static func _parse_range(range_header: String, total: int) -> Array[int]:
	var spec := range_header.replace("bytes=", "").split(",")[0]
	var halves := spec.split("-")
	var from := int(halves[0]) if halves[0] != "" else 0
	var to := total - 1
	if halves.size() > 1 and halves[1] != "":
		to = mini(int(halves[1]), total - 1)
	from = clampi(from, 0, maxi(total - 1, 0))
	to = clampi(to, from, total - 1)
	to = mini(to, from + MAX_SLICE - 1)
	return [from, to]


## Tries the path as written, without a namespace letter, then by last component: archives use all three.
func _find(target: String) -> Dictionary:
	var path := target.trim_prefix("/").uri_decode()
	if path.is_empty():
		return {}
	var e: Dictionary = _zim.lookup(path)
	if not e.is_empty():
		return e
	var parts := path.split("/")
	if parts.size() > 1:
		e = _zim.lookup("/".join(Array(parts).slice(1)))
		if not e.is_empty():
			return e
		e = _zim.lookup(parts[parts.size() - 1])
		if not e.is_empty():
			return e
	# Some archives keep assets in the old single-letter namespaces.
	for ns in ["A", "I", "-", "M", "J"]:
		e = _zim.lookup(path, ns)
		if not e.is_empty():
			return e
	return {}


## Up to the blank line, within about 2 s, or "".
func _read_head(peer: StreamPeerTCP) -> String:
	var buf := PackedByteArray()
	var waited := 0
	while waited < 2000:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return ""
		var available := peer.get_available_bytes()
		if available > 0:
			var got: Array = peer.get_data(available)
			if got[0] == OK:
				buf.append_array(got[1])
			var text := buf.get_string_from_utf8()
			var end := text.find("\r\n\r\n")
			if end >= 0:
				return text.substr(0, end)
			if buf.size() > 16384:
				return ""      # nothing legitimate sends a header this long
			continue
		OS.delay_msec(2)
		waited += 2
	return ""


func _send(peer: StreamPeerTCP, status: int, mime: String, body: PackedByteArray,
		extra: Dictionary) -> void:
	var reason: String = {200: "OK", 206: "Partial Content", 302: "Found",
		404: "Not Found", 405: "Method Not Allowed"}.get(status, "OK")
	var head := "HTTP/1.1 %d %s\r\n" % [status, reason]
	head += "Content-Type: %s\r\n" % mime
	if not extra.has("Content-Length"):
		head += "Content-Length: %d\r\n" % body.size()
	for k in extra:
		head += "%s: %s\r\n" % [k, extra[k]]
	head += "Connection: close\r\n\r\n"
	peer.put_data(head.to_utf8_buffer())
	if not body.is_empty():
		peer.put_data(body)
