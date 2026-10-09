extends Node3D
## Plays a stage score (recorded or cues) on box humanoids at a theater's Stage marker, slaved to its soundtrack.
class_name StagePerformance

const Performer := preload("res://src/theater/performer.gd")

@export_file("*.json") var score_path := "res://assets/entities/theater/plays/birikim.json"
@export_file("*.ogg", "*.wav", "*.mp3") var audio_path := ""   # a cue score names its own; recorded scores set this
@export var stage_path: NodePath
@export var stage_offset := Vector3.ZERO
## The theater's house lies along the stage's -X; -90 turns choreography +Z onto it.
@export var facing_degrees := -90.0
@export var autoplay := true
@export var loop := true
@export var volume_db := -4.0
@export var supertitles := true
@export var stage_lights := true

var score: Dictionary
var performers: Array[Node3D] = []
var audio: AudioStreamPlayer3D
var caption: Label3D
var stage: Node3D
var elapsed := 0.0
var playing := false
var duration := 0.0
var _cursor: PackedInt32Array   # last key index per track, for monotonic playback
var channels := false           # true for a compiled cue score
var _spots: Array[SpotLight3D] = []
var _set_pieces: Array[Dictionary] = []   # {node, from, until}


static func is_cue_score(data: Dictionary) -> bool:
	return String(data.get("format", "")) == "cues"


func _ready() -> void:
	if not FileAccess.file_exists(score_path):
		# On the web the score arrives in a pack; set up once it lands.
		var pm = get_node_or_null("/root/PCKManager")
		if pm != null and pm.has_method("when_available"):
			pm.when_available(score_path, _ready, "stage_score:" + str(get_path()))
			return
		push_error("StagePerformance: score not found: " + score_path)
		return
	score = JSON.parse_string(FileAccess.get_file_as_string(score_path))
	if is_cue_score(score):
		score = StageScore.compile(score)
		channels = true
		if score.has("audio"):
			var named := String(score.audio)
			audio_path = "" if named == "" else (named if named.begins_with("res://") else "res://assets/art/sound/theater/" + named)
	duration = float(score.get("duration", 0.0))
	stage = get_node_or_null(stage_path) as Node3D
	if stage == null:
		push_error("StagePerformance: stage_path must point at the theater's Stage marker.")
		return
	global_transform = stage.global_transform
	translate_object_local(stage_offset)
	rotate_object_local(Vector3.UP, deg_to_rad(facing_degrees))

	_spawn_performers()
	if supertitles:
		_add_caption()
	_add_audio()
	if stage_lights:
		_add_stage_lights()
	_build_set()

	seek(0.0)
	if autoplay:
		play()


func _spawn_performers() -> void:
	var cast: Array = score.get("cast", [])
	var tracks: Array = score.get("tracks", [])
	_cursor.resize(tracks.size())
	for i in tracks.size():
		var spec: Dictionary = cast[i] if i < cast.size() else {}
		var performer := Performer.new()
		performer.name = String(spec.get("name", "Performer%d" % (i + 1)))
		add_child(performer)
		performer.build(spec)
		performers.append(performer)


func _add_caption() -> void:
	caption = Label3D.new()
	caption.name = "Supertitles"
	caption.position = Vector3(0, 7.0, 0)
	caption.font_size = 40
	caption.pixel_size = 0.022
	caption.outline_size = 8
	caption.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.width = 1100.0
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(caption)


func _add_audio() -> void:
	audio = AudioStreamPlayer3D.new()
	audio.name = "Soundtrack"
	audio.stream = _load_audio(audio_path)
	audio.unit_size = 8.0
	audio.max_distance = 60.0
	audio.volume_db = volume_db
	audio.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(audio)


## Shadowed so a raised arm or a bent knee reads against the floor.
func _add_stage_lights() -> void:
	for x in [-6.0, 6.0]:
		var light := SpotLight3D.new()
		light.position = Vector3(x, 9, 6)
		light.light_color = Color("ffe2b0")
		light.light_energy = 2.2
		light.spot_range = 24.0
		light.spot_angle = 50.0
		light.spot_angle_attenuation = 0.6
		light.shadow_enabled = true
		add_child(light)
		light.look_at(to_global(Vector3(0, 1.5, 0)))
		_spots.append(light)


## Reads the file directly when the editor has not imported it yet.
static func _load_audio(path: String) -> AudioStream:
	if path == "":
		return null
	if ResourceLoader.exists(path):
		var imported := load(path) as AudioStream
		if imported != null:
			return imported
	if not FileAccess.file_exists(path):
		push_warning("StagePerformance: soundtrack missing: " + path)
		return null
	match path.get_extension().to_lower():
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
	return null


func play() -> void:
	playing = true
	if audio and audio.stream:
		audio.play(elapsed)


func pause() -> void:
	playing = false
	if audio:
		audio.stop()


func seek(seconds: float) -> void:
	elapsed = clampf(seconds, 0.0, duration)
	_cursor.fill(0)
	_apply_time()
	if playing and audio and audio.stream:
		audio.play(elapsed)


## The clock follows the audio position while it plays.
func _physics_process(delta: float) -> void:
	if not playing:
		_ground_performers()
		return
	if audio and audio.playing:
		elapsed = maxf(0.0, audio.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency())
	else:
		elapsed += delta
	if elapsed >= duration:
		if loop:
			seek(0.0)
			if audio and audio.stream:
				audio.play(0.0)
		else:
			elapsed = duration
			pause()
	_apply_time(delta)
	_ground_performers()


## `delta` < 0 snaps (seek); otherwise performers walk and turn at game rates.
func _apply_time(delta: float = -1.0) -> void:
	var tracks: Array = score.get("tracks", [])
	for i in performers.size():
		var keys: Array = tracks[i]
		if keys.is_empty():
			continue
		if channels:
			_apply_channels(i, keys, delta)
		else:
			performers[i].apply_pose(_sample(keys, i), delta)
	if caption:
		var line := ""
		for cue in score.get("captions", []):
			if elapsed >= float(cue.start) and elapsed < float(cue.end):
				line = String(cue.text)
		caption.text = line
	_apply_lights()
	for piece in _set_pieces:
		(piece.node as Node3D).visible = elapsed >= float(piece.from) and elapsed < float(piece.until)


## Plays key sounds only when playing forward, at most 8 keys a frame.
func _apply_channels(i: int, keys: Array, delta: float) -> void:
	var before := _cursor[i]
	var pose := StageScore.sample(keys, elapsed, _cursor[i])
	var after := int(pose._cursor)
	_cursor[i] = after
	performers[i].apply_channels(pose)
	if not (delta > 0.0 and after > before and after - before <= 8):
		return
	for k in range(before + 1, after + 1):
		if keys[k].has("sound"):
			performers[i].play_sound(String(keys[k].sound))


## `lights`: [{t, energy, color}], linear between keys; two keys at one time make a snap.
func _apply_lights() -> void:
	var keys: Array = score.get("lights", [])
	if keys.is_empty() or _spots.is_empty():
		return
	var a: Dictionary = keys[0]
	var b: Dictionary = keys[0]
	for key in keys:
		if float(key.t) <= elapsed:
			a = key
			b = key
		else:
			b = key
			break
	var span := float(b.t) - float(a.t)
	var w := 0.0 if span <= 0.0 else clampf((elapsed - float(a.t)) / span, 0.0, 1.0)
	var energy := lerpf(float(a.get("energy", 2.2)), float(b.get("energy", 2.2)), w)
	var color := Color(String(a.get("color", "ffe2b0"))).lerp(Color(String(b.get("color", "ffe2b0"))), w)
	for spot in _spots:
		spot.light_energy = energy
		spot.light_color = color


## `set`: [{kind: desk|box, at: [x, z], yaw, size, color, from, until}], in performer units (a figure is six tall).
func _build_set() -> void:
	for spec in score.get("set", []):
		var node := Node3D.new()
		node.name = String(spec.get("name", spec.get("kind", "Piece"))).capitalize()
		var at: Array = spec.get("at", [0, 0])
		node.position = Vector3(float(at[0]), 0.0, float(at[1]))
		node.rotation.y = deg_to_rad(float(spec.get("yaw", 0.0)))
		var color := Color(String(spec.get("color", "5a4632")))
		match String(spec.get("kind", "box")):
			"desk":
				_set_box(node, Vector3(3.2, 0.16, 1.5), Vector3(0, 2.4, 0), color)
				for x in [-1.5, 1.5]:
					_set_box(node, Vector3(0.14, 2.4, 1.4), Vector3(x, 1.2, 0), color.darkened(0.15))
				_set_box(node, Vector3(3.0, 1.0, 0.12), Vector3(0, 1.6, -0.62), color.darkened(0.25))
			_:
				var size: Array = spec.get("size", [1, 1, 1])
				var dims := Vector3(float(size[0]), float(size[1]), float(size[2]))
				_set_box(node, dims, Vector3(0, dims.y * 0.5, 0), color)
		add_child(node)
		_set_pieces.append({"node": node, "from": float(spec.get("from", 0.0)), "until": float(spec.get("until", INF))})


static func _set_box(parent: Node3D, size: Vector3, offset: Vector3, color: Color) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = offset
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	mesh.material_override = material
	parent.add_child(mesh)


## Keys are sorted by `t`.
func _sample(keys: Array, track: int) -> Dictionary:
	var i := _cursor[track]
	if i >= keys.size() or float(keys[i].t) > elapsed:
		i = 0
	while i + 1 < keys.size() and float(keys[i + 1].t) <= elapsed:
		i += 1
	_cursor[track] = i
	var a: Dictionary = keys[i]
	var b: Dictionary = keys[mini(i + 1, keys.size() - 1)]
	var span := float(b.t) - float(a.t)
	var w := 0.0 if span <= 0.0 else clampf((elapsed - float(a.t)) / span, 0.0, 1.0)
	return {
		"x": lerpf(float(a.x), float(b.x), w),
		"z": lerpf(float(a.z), float(b.z), w),
		"yaw": lerp_angle(float(a.yaw), float(b.yaw), w),
		"head_yaw": lerp_angle(float(a.head_yaw), float(b.head_yaw), w),
		"torso": _lerp_dir(a.torso, b.torso, w),
		"left_arm": _lerp_dir(a.left_arm, b.left_arm, w),
		"right_arm": _lerp_dir(a.right_arm, b.right_arm, w),
		"left_leg": _lerp_dir(a.left_leg, b.left_leg, w),
		"right_leg": _lerp_dir(a.right_leg, b.right_leg, w),
	}


static func _lerp_dir(a: Array, b: Array, w: float) -> Vector3:
	var va := Vector3(float(a[0]), float(a[1]), float(a[2]))
	var vb := Vector3(float(b[0]), float(b[1]), float(b[2]))
	var v := va.lerp(vb, w)
	return v.normalized() if v.length_squared() > 1e-6 else va


func _ground_performers() -> void:
	if stage == null or not is_inside_tree():
		return
	var space := get_world_3d().direct_space_state
	for performer in performers:
		_ground(space, performer, 0.02)
	for piece in _set_pieces:
		_ground(space, piece.node, 0.0)


func _ground(space: PhysicsDirectSpaceState3D, node: Node3D, lift: float) -> void:
	var start := to_global(Vector3(node.position.x, 1.0, node.position.z))
	var query := PhysicsRayQueryParameters3D.create(start, start - global_basis.y * 20.0)
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		node.position.y = to_local(hit.position).y + lift
