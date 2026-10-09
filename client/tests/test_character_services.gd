extends SceneTree
## Shared avatar scenes must not create one local voice/XR session per NPC.

const Voice := preload("res://src/character/microphone_audio_player.gd")
const Character := preload("res://src/character/unified_character.gd")

class PlayerStub extends Node3D:
	var is_remote_player := false
	func set_as_remote_player() -> void:
		is_remote_player = true

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for i in 20:
		await _check_receiver(Node3D.new(), false, "NPC %d" % i)
	var remote := PlayerStub.new()
	remote.set_as_remote_player()
	await _check_receiver(remote, false, "remote player")
	await _check_receiver(PlayerStub.new(), true, "local player")

	# Remote startup must return before touching local camera/movement modules
	# or the global XR viewport, even if called explicitly or deferred.
	var character := Character.new()
	character.is_remote_player = true
	character._initialize_vr_system()
	character._setup_vr()
	character.set_vr_mode(true)
	_check(not character.is_vr_mode, "remote character cannot enter local VR")
	character.free()
	print("Character service ownership: %d failures" % failures)
	quit(1 if failures else 0)


func _check_receiver(body: Node3D, active: bool, label: String) -> void:
	var voice := Voice.new()
	voice.auto_connect = false
	body.add_child(voice)
	root.add_child(body)
	_check((voice._audio_player_3d != null) == active, label + " audio ownership")
	_check(voice.is_processing() == active, label + " process ownership")
	if not active:
		voice.connect_to_voice_server()
		_check(voice._client.get_ready_state() == WebSocketPeer.STATE_CLOSED,
			label + " cannot open a voice socket")
	body.queue_free()
	await process_frame


func _check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error(label)
