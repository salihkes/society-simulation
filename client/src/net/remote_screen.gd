class_name RemoteScreen
extends Node
## A machine-room screen shown as an ImageTexture; the first viewer to send input operates it.

signal connected
signal closed(reason: String)
signal resized(w: int, h: int)
signal frame

var texture: ImageTexture
var width := 0
var height := 0
var is_open := false

var _ws := WebSocketPeer.new()
var _img: Image
var _url := ""
var _was_open := false
var _pending: Array = []
var _last_move := Vector2i(-1, -1)

## Godot keycodes → X keysym names for keys that are not text.
const KEYSYMS := {
	KEY_ENTER: "Return", KEY_KP_ENTER: "KP_Enter", KEY_BACKSPACE: "BackSpace",
	KEY_TAB: "Tab", KEY_SPACE: "space", KEY_DELETE: "Delete", KEY_INSERT: "Insert",
	KEY_UP: "Up", KEY_DOWN: "Down", KEY_LEFT: "Left", KEY_RIGHT: "Right",
	KEY_HOME: "Home", KEY_END: "End", KEY_PAGEUP: "Page_Up", KEY_PAGEDOWN: "Page_Down",
	KEY_SHIFT: "Shift_L", KEY_CTRL: "Control_L", KEY_ALT: "Alt_L", KEY_META: "Super_L",
	KEY_CAPSLOCK: "Caps_Lock", KEY_ESCAPE: "Escape",
	KEY_F1: "F1", KEY_F2: "F2", KEY_F3: "F3", KEY_F4: "F4", KEY_F5: "F5", KEY_F6: "F6",
	KEY_F7: "F7", KEY_F8: "F8", KEY_F9: "F9", KEY_F10: "F10", KEY_F11: "F11", KEY_F12: "F12",
}


func open(url: String) -> void:
	close("reopen")
	_url = url
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 8 << 20      # a full 512x342 frame is ~0.5 MB raw
	_ws.outbound_buffer_size = 1 << 16
	_ws.max_queued_packets = 1024
	var err := _ws.connect_to_url(url)
	if err != OK:
		push_warning("RemoteScreen: cannot connect to %s (%d)" % [url, err])
		closed.emit("connect failed")
		return
	set_process(true)


## Emits closed only if it had opened.
func close(reason := "closed") -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_ws.close()
	if _was_open:
		_was_open = false
		is_open = false
		closed.emit(reason)


func _process(_delta: float) -> void:
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			is_open = true
			connected.emit()
		var got := false
		while _ws.get_available_packet_count() > 0:
			var pkt := _ws.get_packet()
			if not _ws.was_string_packet():
				got = _decode(pkt) or got
		if got:
			frame.emit()
		if not _pending.is_empty():
			_ws.send_text(JSON.stringify(_pending))
			_pending.clear()
	elif state == WebSocketPeer.STATE_CLOSED:
		if _was_open:
			_was_open = false
			is_open = false
			closed.emit("code %d %s" % [_ws.get_close_code(), _ws.get_close_reason()])
		set_process(false)


## Packet (LE): "RF" u8 kind(0 full,1 delta) u16 w h ntiles; tile: u16 x y tw th, u32 raw_len comp_len, zlib RGB8.
func _decode(pkt: PackedByteArray) -> bool:
	if pkt.size() < 9 or pkt[0] != 0x52 or pkt[1] != 0x46:
		return false
	var kind := pkt.decode_u8(2)
	var w := pkt.decode_u16(3)
	var h := pkt.decode_u16(5)
	var n := pkt.decode_u16(7)
	if _img == null or w != width or h != height:
		width = w
		height = h
		_img = Image.create_empty(w, h, false, Image.FORMAT_RGB8)
		texture = ImageTexture.create_from_image(_img)
		resized.emit(w, h)
	var off := 9
	var drawn := 0
	for _i in n:
		if off + 16 > pkt.size():
			break
		var x := pkt.decode_u16(off)
		var y := pkt.decode_u16(off + 2)
		var tw := pkt.decode_u16(off + 4)
		var th := pkt.decode_u16(off + 6)
		var raw_len := pkt.decode_u32(off + 8)
		var comp_len := pkt.decode_u32(off + 12)
		off += 16
		if off + comp_len > pkt.size():
			break
		var raw := pkt.slice(off, off + comp_len).decompress(raw_len, FileAccess.COMPRESSION_DEFLATE)
		off += comp_len
		if raw.size() != raw_len or raw_len != tw * th * 3:
			continue
		var tile := Image.create_from_data(tw, th, false, Image.FORMAT_RGB8, raw)
		_img.blit_rect(tile, Rect2i(0, 0, tw, th), Vector2i(x, y))
		drawn += 1
	if drawn > 0 or kind == 0:
		texture.update(_img)
	return drawn > 0


## Clamped to the screen.
func send_move(x: int, y: int) -> void:
	var p := Vector2i(clampi(x, 0, maxi(width - 1, 0)), clampi(y, 0, maxi(height - 1, 0)))
	if p == _last_move:
		return
	_last_move = p
	# One move per flush: the last position wins.
	for i in range(_pending.size() - 1, -1, -1):
		if _pending[i].get("k") == "move":
			_pending.remove_at(i)
	_pending.append({"k": "move", "x": p.x, "y": p.y})


func send_button(button: int, down: bool) -> void:
	_pending.append({"k": "btn", "b": button, "down": 1 if down else 0})


func send_key(keysym: String, down: bool) -> void:
	_pending.append({"k": "key", "ks": keysym, "down": 1 if down else 0})


func send_text(text: String) -> void:
	if text != "":
		_pending.append({"k": "text", "t": text})


## True when the caller should mark the event handled.
func send_key_event(ev: InputEventKey) -> bool:
	var ks: String = KEYSYMS.get(ev.keycode, "")
	if ks != "":
		if ev.echo and ks in ["Shift_L", "Control_L", "Alt_L", "Super_L", "Caps_Lock"]:
			return true
		send_key(ks, ev.pressed)
		return true
	var chord := ev.ctrl_pressed or ev.alt_pressed or ev.meta_pressed
	if chord:
		# Ctrl+C and friends: the key by name, modifiers already held.
		var name := OS.get_keycode_string(ev.keycode).to_lower()
		if name.length() == 1 and name.is_valid_identifier() or name.is_valid_int():
			send_key(name, ev.pressed)
			return true
		return false
	if ev.pressed and ev.unicode > 0:
		send_text(char(ev.unicode))
		return true
	return ev.unicode > 0
