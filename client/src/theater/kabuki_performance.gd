extends Node3D
## A short kabuki-style scene played from a JSON score: posed actors, supertitles and soundtrack.
const Actor := preload("res://src/theater/stage_actor.gd")
const SCORE_PATH := "res://assets/entities/theater/maple_lantern.json"
const AUDIO_PATH := "res://assets/art/sound/theater/maple_lantern.wav"
@export var stage_path: NodePath
@export var stage_offset := Vector3.ZERO
@export var facing_degrees := -90.0
@export var autoplay := true
@export var loop := true
var actors: Array[Node3D] = []
var score: Dictionary
var audio: AudioStreamPlayer3D
var caption: Label3D
var stage: Node3D
var elapsed := 0.0
var playing := false


func _ready() -> void:
	score = JSON.parse_string(FileAccess.get_file_as_string(SCORE_PATH))
	stage = get_node_or_null(stage_path) as Node3D
	if stage == null:
		push_error("Kabuki performance needs a Stage marker; no actors spawned.")
		return
	# Take the marker's full transform, including the workspace scale.
	global_transform = stage.global_transform
	translate_object_local(stage_offset)
	rotate_object_local(Vector3.UP, deg_to_rad(facing_degrees))
	_spawn_cast()
	_add_caption()
	_add_audio()
	_add_lights()
	seek(0)
	if autoplay:
		play()


func _spawn_cast() -> void:
	for cast in score.cast:
		var actor := Actor.new()
		actor.name = cast.name
		add_child(actor)
		actor.build(Color(cast.color), Color(cast.fan_color))
		actors.append(actor)


func _add_caption() -> void:
	caption = Label3D.new()
	caption.name = "Supertitles"
	caption.position = Vector3(0, 6.5, 0)
	caption.font_size = 42
	caption.pixel_size = 0.022
	caption.outline_size = 8
	caption.no_depth_test = false
	caption.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(caption)


func _add_audio() -> void:
	audio = AudioStreamPlayer3D.new()
	audio.name = "StageMusic"
	# Before the editor has imported the WAV, read the source file directly.
	if FileAccess.file_exists(AUDIO_PATH) and not FileAccess.file_exists(AUDIO_PATH + ".import"):
		audio.stream = AudioStreamWAV.load_from_file(AUDIO_PATH)
	else:
		audio.stream = load(AUDIO_PATH) as AudioStream
	audio.unit_size = 7.0
	audio.max_distance = 35.0
	audio.volume_db = -8.0
	add_child(audio)


func _add_lights() -> void:
	for x in [-7.0, 7.0]:
		var light := OmniLight3D.new()
		light.position = Vector3(x, 8, 3)
		light.light_color = Color("ffe0ad")
		light.light_energy = 1.8
		light.omni_range = 18.0
		add_child(light)


func play() -> void:
	if audio == null:
		return
	playing = true
	audio.play(elapsed)


func pause() -> void:
	playing = false
	if audio:
		audio.stop()


func seek(seconds: float) -> void:
	elapsed = clampf(seconds, 0.0, float(score.duration))
	_apply_time()
	if playing:
		audio.play(elapsed)


func _physics_process(delta: float) -> void:
	if not playing:
		_ground_actors()
		return
	elapsed += delta
	# Follow the soundtrack so frame time and audio do not drift apart.
	if audio.playing:
		elapsed = maxf(0.0, audio.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency())
	if elapsed >= float(score.duration):
		if loop:
			seek(0.0)
		else:
			elapsed = float(score.duration)
			pause()
	_apply_time()
	_ground_actors()


## The stage marker sits above a sloped, raised floor.
func _ground_actors() -> void:
	if stage == null:
		return
	for actor in actors:
		var start := to_global(Vector3(actor.position.x, 1, actor.position.z))
		var query := PhysicsRayQueryParameters3D.create(start, start - global_basis.y * 20.0)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			actor.position.y = to_local(hit.position).y + 0.02


func _apply_time() -> void:
	for i in actors.size():
		actors[i].apply_pose(sample(score.tracks[i], elapsed))
	var line := ""
	for cue in score.captions:
		if elapsed >= float(cue.start) and elapsed < float(cue.end):
			line = cue.text
	caption.text = line


## Smoothstep-eased pose at `seconds`; `keys` must be sorted by time.
static func sample(keys: Array, seconds: float) -> Dictionary:
	var a: Dictionary = keys[0]
	var b: Dictionary = keys[-1]
	for key in keys:
		if float(key.time) <= seconds:
			a = key
		if float(key.time) > seconds:
			b = key
			break
	var weight := 0.0
	if float(b.time) > float(a.time):
		weight = clampf((seconds - float(a.time)) / (float(b.time) - float(a.time)), 0, 1)
	weight = smoothstep(0, 1, weight)
	var pose := {}
	for field in ["x", "z", "bow"]:
		pose[field] = lerpf(float(a[field]), float(b[field]), weight)
	pose.yaw = rad_to_deg(lerp_angle(deg_to_rad(a.yaw), deg_to_rad(b.yaw), weight))
	for field in ["left_arm", "right_arm", "left_leg", "right_leg"]:
		pose[field] = [lerpf(a[field][0], b[field][0], weight), lerpf(a[field][1], b[field][1], weight)]
	return pose
