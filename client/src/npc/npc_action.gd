class_name NpcAction
extends RefCounted
## Base class for NPC actions, and the registry that builds them by name.

var action_name: String = ""
var _finished: bool = false


func start(npc: CharacterBody3D) -> void:
	_finished = false


func process(npc: CharacterBody3D, delta: float) -> void:
	pass


func stop(npc: CharacterBody3D) -> void:
	pass


func is_finished() -> bool:
	return _finished


## Unknown names get an idle action that never finishes.
static func create(p_name: String, params: Dictionary = {}) -> NpcAction:
	match p_name:
		"guarding":
			return _build_guarding()
		"teaching":
			return _build_teaching(params)
		_:
			var a = NpcAction.new()
			a.action_name = p_name
			return a


## Watch, walk to the player, speak, wait, return to post; forever.
static func _build_guarding() -> NpcAction:
	var loop = preload("res://src/npc/actions/npc_loop_action.gd").new()
	loop.action_name = "guarding"

	var seq = preload("res://src/npc/actions/npc_compound_action.gd").new()

	var detect = preload("res://src/npc/actions/radius_detect_action.gd").new()
	detect.radius = 10.0

	var walk = preload("res://src/npc/actions/walk_to_player_action.gd").new()
	walk.stop_distance = 2.0

	var text = preload("res://src/npc/actions/display_text_action.gd").new()
	text.message = "Halt! Show your papers."
	text.duration = 3.0

	var audio = preload("res://src/npc/actions/play_audio_action.gd").new()
	audio.audio_path = "guard/stopshowpapers.mp3"
	audio.fallback_duration = 2.6

	var present = preload("res://src/npc/actions/npc_parallel_action.gd").new()
	present.add_step(text)
	present.add_step(audio)

	var wait = preload("res://src/npc/actions/wait_action.gd").new()
	wait.duration = 2.0

	var ret = preload("res://src/npc/actions/return_to_post_action.gd").new()

	seq.add_step(detect)
	seq.add_step(walk)
	seq.add_step(present)
	seq.add_step(wait)
	seq.add_step(ret)

	loop.inner_action = seq
	return loop


## Plays one lecture clip (params "audio", "duration").
static func _build_teaching(params: Dictionary = {}) -> NpcAction:
	var seq = preload("res://src/npc/actions/npc_compound_action.gd").new()
	seq.action_name = "teaching"

	var audio = preload("res://src/npc/actions/play_audio_action.gd").new()
	audio.audio_path = params.get("audio", "res://assets/entities/pedestrians/audio/teacher_lecture.ogg")
	audio.fallback_duration = params.get("duration", 60.0)

	seq.add_step(audio)
	return seq
