extends Node
## Pixel-streaming input: JSON key and mouse events over local UDP fed to Input.

var udp := PacketPeerUDP.new()
var port := 9000
var feedback := PacketPeerUDP.new()
var feedback_port := 0
var stream_session := ""
var last_mouse_mode := -1
var held_keys: Dictionary = {}
var held_buttons: Dictionary = {}


func _ready():
	var configured := OS.get_environment("GAME_STREAM_INPUT_PORT")
	if not configured.is_empty():
		port = int(configured)
	feedback_port = int(OS.get_environment("GAME_STREAM_FEEDBACK_PORT"))
	stream_session = OS.get_environment("GAME_STREAM_SESSION")
	if port < 1024 or port > 65535:
		push_error("Invalid streaming input port")
		set_process(false)
		return
	if feedback_port > 0:
		feedback.set_dest_address("127.0.0.1", feedback_port)
		Input.use_accumulated_input = false
		OS.low_processor_usage_mode = false
	var err = udp.bind(port, "127.0.0.1")
	if err != OK:
		print("Error binding to port " + str(port))
	else:
		print("Pixel Streaming Input Receiver listening on port " + str(port))
		_send_feedback({"ready": 2, "session": stream_session,
			"user_dir": OS.get_user_data_dir()})


func _send_feedback(data: Dictionary):
	if feedback_port > 0:
		feedback.put_packet(JSON.stringify(data).to_utf8_buffer())


func _process(_delta):
	if feedback_port > 0 and int(Input.mouse_mode) != last_mouse_mode:
		last_mouse_mode = int(Input.mouse_mode)
		_send_feedback({"type": "mouse_mode", "captured": Input.mouse_mode == Input.MOUSE_MODE_CAPTURED})
	# Drain the batch so mouse motion cannot delay key releases; the snapshot count bounds the loop.
	var pending := udp.get_available_packet_count()
	for _packet_index in range(pending):
		var packet = udp.get_packet()
		var packet_string = packet.get_string_from_utf8()
		if packet_string:
			_handle_input_packet(packet_string)


func _handle_input_packet(json_str):
	var json = JSON.new()
	var error = json.parse(json_str)
	if error != OK:
		print("JSON Parse Error: ", json.get_error_message())
		return

	var data = json.data
	if not data is Dictionary:
		return

	var type = data.get("type", "")

	if type == "reset":
		_release_all()
	elif type == "key":
		_on_key(data)
	elif type == "mouse_motion":
		_on_mouse_motion(data)
	elif type == "mouse_button":
		_on_mouse_button(data)
	elif type == "wheel":
		_on_wheel(data)
	elif type == "mouse_mode":
		var captured = data.get("captured", false)
		if captured:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _release_all():
	for code in held_keys:
		var release := InputEventKey.new()
		release.keycode = code
		release.physical_keycode = code
		release.pressed = false
		Input.parse_input_event(release)
	for button in held_buttons:
		var release := InputEventMouseButton.new()
		release.button_index = button
		release.pressed = false
		Input.parse_input_event(release)
	held_keys.clear()
	held_buttons.clear()


## By browser "code" when given, otherwise by raw keycodes.
func _on_key(data: Dictionary):
	var ev = InputEventKey.new()
	ev.pressed = data.get("pressed", false)

	var code_str = data.get("code", "")
	if code_str != "":
		var k = _map_js_key_to_godot(code_str)
		ev.physical_keycode = k
		ev.keycode = k
	else:
		ev.keycode = int(data.get("keycode", 0))
		ev.physical_keycode = int(data.get("physical_keycode", 0))

	ev.unicode = int(data.get("unicode", 0))
	ev.echo = data.get("echo", false)
	ev.shift_pressed = data.get("shift", false)
	ev.ctrl_pressed = data.get("ctrl", false)
	ev.alt_pressed = data.get("alt", false)
	ev.meta_pressed = data.get("meta", false)
	if ev.pressed:
		held_keys[ev.physical_keycode] = true
	else:
		held_keys.erase(ev.physical_keycode)
	Input.parse_input_event(ev)


func _on_mouse_motion(data: Dictionary):
	var ev = InputEventMouseMotion.new()
	ev.position = Vector2(data.get("x", 0), data.get("y", 0))
	ev.relative = Vector2(data.get("dx", 0), data.get("dy", 0))
	ev.screen_relative = ev.relative
	ev.button_mask = _held_button_mask()
	Input.parse_input_event(ev)


func _on_mouse_button(data: Dictionary):
	var ev = InputEventMouseButton.new()
	ev.position = Vector2(data.get("x", 0), data.get("y", 0))
	ev.button_index = int(data.get("button_index", 1))
	ev.pressed = data.get("pressed", false)
	if ev.pressed:
		held_buttons[ev.button_index] = true
	else:
		held_buttons.erase(ev.button_index)
	ev.button_mask = _held_button_mask()
	Input.parse_input_event(ev)


## A wheel step becomes a press and release of the wheel button.
func _on_wheel(data: Dictionary):
	var ev = InputEventMouseButton.new()
	ev.position = Vector2(data.get("x", 0), data.get("y", 0))
	var delta_y = data.get("delta_y", 0)
	if delta_y == 0:
		return
	if delta_y > 0:
		ev.button_index = MOUSE_BUTTON_WHEEL_DOWN
	else:
		ev.button_index = MOUSE_BUTTON_WHEEL_UP
	ev.pressed = true
	Input.parse_input_event(ev)
	ev.pressed = false
	Input.parse_input_event(ev)


func _held_button_mask() -> int:
	var mask := 0
	for button in held_buttons:
		mask |= 1 << (int(button) - 1)
	return mask


func _map_js_key_to_godot(js_code: String) -> int:
	var key_str = js_code
	if key_str.begins_with("Key"):
		key_str = key_str.substr(3)
	elif key_str.begins_with("Digit"):
		key_str = key_str.substr(5)
	
	match key_str:
		"ArrowUp": key_str = "Up"
		"ArrowDown": key_str = "Down"
		"ArrowLeft": key_str = "Left"
		"ArrowRight": key_str = "Right"
		"ControlLeft": key_str = "Ctrl"
		"ControlRight": key_str = "Ctrl"
		"ShiftLeft": key_str = "Shift"
		"ShiftRight": key_str = "Shift"
		"AltLeft": key_str = "Alt"
		"AltRight": key_str = "Alt"
		"Escape": key_str = "Escape"
		"Enter": key_str = "Enter"
		"Space": key_str = "Space"
		"Backspace": key_str = "Backspace"
		"Tab": key_str = "Tab"
		"Minus": key_str = "-"
		"Equal": key_str = "="
		"BracketLeft": key_str = "["
		"BracketRight": key_str = "]"
		"Semicolon": key_str = ";"
		"Quote": key_str = "'"
		"Comma": key_str = ","
		"Period": key_str = "."
		"Slash": key_str = "/"
		"Backquote": key_str = "`"
		
	return OS.find_keycode_from_string(key_str)
