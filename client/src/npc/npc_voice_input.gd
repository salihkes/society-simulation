extends Node
## Push-to-talk to NPCs: hold Numpad 5, release to send the clip for speech-to-text to the nearest NPC.

const RECORD_KEY = KEY_KP_5
const STT_BUS_NAME = "STT"

var _recording := false
var _capture: AudioEffectCapture = null
var _recorded_frames: PackedVector2Array = PackedVector2Array()
var _npc_manager = null
var _network_controller = null
var _mic_sender = null  # MicrophoneSender — paused while recording for STT
var _sample_rate: int = 0


func _ready():
	_npc_manager = get_parent().get_node_or_null("NpcManager")
	_network_controller = get_node_or_null("/root/NetworkController")
	_mic_sender = get_parent().get_node_or_null("MicrophoneSender")

	_setup_stt_bus()


func _setup_stt_bus():
	# Reuse the existing capture: macOS allows only one AudioStreamMicrophone.
	var record_bus_idx = AudioServer.get_bus_index("Record")
	if record_bus_idx < 0:
		print("[NpcVoice] No 'Record' bus found — voice input disabled")
		return

	for i in AudioServer.get_bus_effect_count(record_bus_idx):
		var effect = AudioServer.get_bus_effect(record_bus_idx, i)
		if effect is AudioEffectCapture:
			_capture = effect
			break

	if _capture == null:
		print("[NpcVoice] No AudioEffectCapture on Record bus — voice input disabled")
		return

	_sample_rate = AudioServer.get_mix_rate()
	print("[NpcVoice] Ready — sharing Record bus capture at %d Hz. Hold Numpad 5 to speak." % _sample_rate)

	await get_tree().create_timer(2.0).timeout
	_check_mic_health()


func _check_mic_health():
	if _capture == null:
		return
	var mic_player = get_parent().get_node_or_null("AudioStreamPlayer")
	print("[NpcVoice] ── MIC DIAGNOSTIC ──")
	print("[NpcVoice]   Mic player: ", mic_player)
	if mic_player:
		print("[NpcVoice]   Playing: ", mic_player.playing)
		print("[NpcVoice]   Bus: ", mic_player.bus)
		print("[NpcVoice]   Stream: ", mic_player.stream)
	print("[NpcVoice]   Capture buffer frames available: ", _capture.get_frames_available())
	var avail = _capture.get_frames_available()
	if avail > 0:
		var mx := _peak(_capture.get_buffer(mini(avail, 4800)))
		print("[NpcVoice]   Sample max amplitude: %.6f" % mx)
		if mx < 0.0001:
			print("[NpcVoice]   ⚠ SILENT — check macOS Privacy > Microphone > Godot permission")
		else:
			print("[NpcVoice]   ✓ Mic is live")
	else:
		print("[NpcVoice]   ⚠ No frames in capture buffer — MicrophoneSender may be draining them")
		await _probe_with_sender_paused()


## Pauses MicrophoneSender for 0.2 s and logs what the capture received.
func _probe_with_sender_paused():
	if not _mic_sender:
		return
	_mic_sender.set_process(false)
	await get_tree().create_timer(0.2).timeout
	var avail2 = _capture.get_frames_available()
	print("[NpcVoice]   After pausing sender: %d frames available" % avail2)
	if avail2 > 0:
		var mx2 := _peak(_capture.get_buffer(mini(avail2, 4800)))
		print("[NpcVoice]   Sample max amplitude: %.6f" % mx2)
	_mic_sender.set_process(true)


func _peak(frames: PackedVector2Array) -> float:
	var mx: float = 0.0
	for f in frames:
		mx = maxf(mx, maxf(absf(f.x), absf(f.y)))
	return mx


func _input(event: InputEvent):
	if _capture == null:
		return
	if not (event is InputEventKey):
		return

	var key_event: InputEventKey = event
	if key_event.physical_keycode != RECORD_KEY:
		return

	if key_event.pressed and not key_event.is_echo() and not _recording:
		_start_recording()
	elif not key_event.pressed and _recording:
		_stop_recording_and_send()


func _start_recording():
	_recording = true
	_recorded_frames = PackedVector2Array()
	if _mic_sender:
		_mic_sender.set_process(false)
	_capture.clear_buffer()
	print("[NpcVoice] Recording...")


func _process(_delta: float):
	if not _recording or _capture == null:
		return

	var available = _capture.get_frames_available()
	if available > 0:
		var buf = _capture.get_buffer(available)
		_recorded_frames.append_array(buf)


func _stop_recording_and_send():
	_recording = false

	if _mic_sender:
		_mic_sender.set_process(true)

	var remaining = _capture.get_frames_available()
	if remaining > 0:
		_recorded_frames.append_array(_capture.get_buffer(remaining))

	var duration = float(_recorded_frames.size()) / float(_sample_rate)
	print("[NpcVoice] Stopped. %.1fs, %d frames" % [duration, _recorded_frames.size()])

	var max_val := _peak(_recorded_frames)
	print("[NpcVoice] Max amplitude: %.4f" % max_val)

	if max_val < 0.001:
		print("[NpcVoice] Silent recording, ignoring")
		return

	if duration < 0.3:
		print("[NpcVoice] Too short, ignoring")
		return

	if _npc_manager == null:
		print("[NpcVoice] No NpcManager!")
		return
	var npc_id: String = _npc_manager.find_nearest_npc_to_player()
	print("[NpcVoice] Nearest NPC: '%s'" % npc_id)
	if npc_id == "":
		print("[NpcVoice] No NPC within range")
		return

	_send_recording(npc_id)


## Also stops the NPC so it listens.
func _send_recording(npc_id: String) -> void:
	var wav_bytes = _encode_wav()
	var audio_b64 = Marshalls.raw_to_base64(wav_bytes)

	if not (_network_controller and _network_controller.connected):
		return
	_network_controller.send_json({
		"type": "npc_voice_chat",
		"npc_id": npc_id,
		"audio": audio_b64
	})
	print("[NpcVoice] Sent %d bytes for '%s'" % [wav_bytes.size(), npc_id])

	var npcs = _npc_manager._npcs
	if npc_id in npcs:
		var npc = npcs[npc_id]
		if is_instance_valid(npc) and is_instance_valid(_network_controller.players.local_player):
			npc.start_chatting(_network_controller.players.local_player)


## Mono 16-bit PCM; stereo is averaged.
func _encode_wav() -> PackedByteArray:
	var num_samples = _recorded_frames.size()
	var data_size = num_samples * 2  # 16-bit mono
	var file_size = 44 + data_size

	var buf = PackedByteArray()
	buf.resize(file_size)

	# RIFF header
	buf[0] = 0x52; buf[1] = 0x49; buf[2] = 0x46; buf[3] = 0x46
	buf.encode_u32(4, file_size - 8)
	buf[8] = 0x57; buf[9] = 0x41; buf[10] = 0x56; buf[11] = 0x45

	# fmt
	buf[12] = 0x66; buf[13] = 0x6D; buf[14] = 0x74; buf[15] = 0x20
	buf.encode_u32(16, 16)
	buf.encode_u16(20, 1)          # PCM
	buf.encode_u16(22, 1)          # mono
	buf.encode_u32(24, _sample_rate)
	buf.encode_u32(28, _sample_rate * 2)  # byte rate
	buf.encode_u16(32, 2)          # block align
	buf.encode_u16(34, 16)         # bits per sample

	# data
	buf[36] = 0x64; buf[37] = 0x61; buf[38] = 0x74; buf[39] = 0x61
	buf.encode_u32(40, data_size)

	var offset = 44
	for frame in _recorded_frames:
		var mono = (frame.x + frame.y) * 0.5
		var sample = int(clampf(mono, -1.0, 1.0) * 32767.0)
		buf.encode_s16(offset, sample)
		offset += 2

	return buf
