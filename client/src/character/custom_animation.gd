extends AnimationBase
class_name CustomCharacterAnimation

## Skeletal animation for Mixamo-rigged characters from mesh-less FBX clips retargeted at runtime.

const BLEND_TIME := 0.18
const IDLE_SPEED_THRESHOLD := 0.6

const CLIP_FILES := {
	"idle": "Idle.fbx",
	"walk": "Walking.fbx",
	"run": "Running.fbx",
	"jump": "Jump.fbx",
	"sit": "Sitting.fbx",
	"talk": "Talking.fbx",
}

var anim_player: AnimationPlayer
var skeleton: Skeleton3D
var char_root: Node3D
var current_state := ""
var available := {}              # state name -> true when its clip loaded
var talking := false             # external flag: play the talk clip while idle
var _footstep_timer := 0.0
var _bone_lookup := {}           # normalized bone name -> actual skeleton bone name


func setup(char: CharacterBody3D, model: Node3D, audio_player: AudioStreamPlayer3D) -> void:
	super.setup(char, model, audio_player)
	_build()


func _build() -> void:
	skeleton = _find_skeleton(character_model)
	if skeleton == null:
		push_warning("CustomCharacterAnimation: no Skeleton3D found under CharacterModel")
		return
	char_root = skeleton.get_parent()
	if char_root == null:
		push_warning("CustomCharacterAnimation: skeleton has no parent")
		return

	# Normalised names let clips retarget when rig prefixes differ ("mixamorig:Hips" vs "Hips").
	for b in skeleton.get_bone_count():
		_bone_lookup[_normalize_bone(skeleton.get_bone_name(b))] = skeleton.get_bone_name(b)

	# Parented to the rigged model so bone-track paths resolve against it.
	anim_player = AnimationPlayer.new()
	anim_player.name = "CustomAnimPlayer"
	char_root.add_child(anim_player)
	anim_player.root_node = anim_player.get_path_to(char_root)
	anim_player.playback_default_blend_time = BLEND_TIME

	anim_player.add_animation_library("", _build_library(str(char_root.get_path_to(skeleton))))

	if available.has("idle"):
		_play_state("idle", 0.0)
	print("CustomCharacterAnimation ready, clips: ", available.keys())


## Jump plays once and holds with locked hips (physics owns the leap); the rest loop in place.
func _build_library(skel_name: String) -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	var dir := _character_dir()
	for state in CLIP_FILES:
		var clip := _load_clip(dir + CLIP_FILES[state], skel_name)
		if clip == null:
			continue
		clip.loop_mode = Animation.LOOP_NONE if state == "jump" else Animation.LOOP_LINEAR
		if state == "walk" or state == "run":
			_strip_root_motion(clip)
		elif state == "jump":
			_strip_root_motion(clip, true)
		lib.add_animation(state, clip)
		available[state] = true
	return lib


## `custom_character_dir` when set (NPCs), else the folder of the scene file.
func _character_dir() -> String:
	var override_dir = character.get("custom_character_dir")
	if typeof(override_dir) == TYPE_STRING and override_dir != "":
		return override_dir if override_dir.ends_with("/") else override_dir + "/"
	var p: String = character.scene_file_path
	if p == "":
		return ""
	return p.get_base_dir() + "/"


## Null if the FBX has no real clip.
func _load_clip(fbx_path: String, skel_name: String) -> Animation:
	if not ResourceLoader.exists(fbx_path):
		push_warning("CustomCharacterAnimation: missing clip " + fbx_path)
		return null
	var scene := load(fbx_path) as PackedScene
	if scene == null:
		return null
	var inst := scene.instantiate()
	var src_ap := _find_anim_player(inst)
	var result: Animation = null
	if src_ap:
		result = _first_clip(src_ap)
	inst.queue_free()
	if result:
		_retarget(result, skel_name)
	return result


## Skips the generated RESET pose.
func _first_clip(player: AnimationPlayer) -> Animation:
	for lib_name in player.get_animation_library_list():
		var src_lib := player.get_animation_library(lib_name)
		for n in src_lib.get_animation_list():
			if str(n) != "RESET":
				return src_lib.get_animation(n).duplicate(true) as Animation
	return null


## Tracks for bones the rig lacks go to a dummy path so they are silently ignored.
func _retarget(anim: Animation, skel_name: String) -> void:
	var matched := 0
	for i in anim.get_track_count():
		var t := anim.track_get_type(i)
		if t != Animation.TYPE_POSITION_3D and t != Animation.TYPE_ROTATION_3D and t != Animation.TYPE_SCALE_3D:
			continue
		var s := str(anim.track_get_path(i))
		var colon := s.find(":")
		if colon == -1:
			continue
		var clip_bone := s.substr(colon + 1)
		var bone := _resolve_bone(clip_bone)
		if bone == "":
			anim.track_set_path(i, NodePath("CustomAnimMissing:" + clip_bone))
			continue
		anim.track_set_path(i, NodePath(skel_name + ":" + bone))
		matched += 1
	if matched == 0:
		push_warning("CustomCharacterAnimation: no animation tracks matched the character skeleton")

## "" if this skeleton has no such bone.


func _resolve_bone(clip_bone: String) -> String:
	if skeleton.find_bone(clip_bone) != -1:
		return clip_bone
	var key := _normalize_bone(clip_bone)
	if _bone_lookup.has(key):
		return _bone_lookup[key]
	return ""


func _normalize_bone(name: String) -> String:
	return name.to_lower().replace("mixamorig", "").replace(":", "").replace("_", "").replace(" ", "").replace(".", "")


## X/Z only, or all three axes when `full`.
func _strip_root_motion(anim: Animation, full: bool = false) -> void:
	for i in anim.get_track_count():
		if anim.track_get_type(i) != Animation.TYPE_POSITION_3D:
			continue
		var path := str(anim.track_get_path(i))
		if not path.to_lower().contains("hips"):
			continue
		var count := anim.track_get_key_count(i)
		if count == 0:
			continue
		var base: Vector3 = anim.track_get_key_value(i, 0)
		for k in count:
			var v: Vector3 = anim.track_get_key_value(i, k)
			if full:
				anim.track_set_key_value(i, k, base)
			else:
				anim.track_set_key_value(i, k, Vector3(base.x, v.y, base.z))


func animate(delta: float, speed: float, _movement_dir: Vector3, is_running: bool, is_on_floor: bool) -> void:
	_drive(delta, speed, is_running, is_on_floor)


## Remote players update about every 0.05 s, which paces their footsteps.
func animate_remote(speed: float, _direction: Vector3, is_on_floor: bool = true) -> void:
	var walk_speed: float = character.walk_speed
	var is_running: bool = speed > walk_speed + 0.5
	_drive(0.05, speed, is_running, is_on_floor)


## Walk and run are speed-matched so the feet do not slide.
func _drive(delta: float, speed: float, is_running: bool, is_on_floor: bool) -> void:
	if anim_player == null:
		return

	var state := _pick_state(speed, is_running, is_on_floor)
	if state != current_state:
		_play_state(state, BLEND_TIME)

	if state == "walk" or state == "run":
		var reference: float = character.run_speed if state == "run" else character.walk_speed
		anim_player.speed_scale = clamp(speed / max(reference, 0.1), 0.65, 1.6)
	else:
		anim_player.speed_scale = 1.0

	if is_on_floor and (state == "walk" or state == "run"):
		_footstep_timer -= delta
		if _footstep_timer <= 0.0:
			play_footstep_sound(0.8 if state == "walk" else 1.0)
			_footstep_timer = (footstep_rate * 1.7) if state == "walk" else footstep_rate
	else:
		_footstep_timer = 0.0


## In the air without a jump clip the current clip holds; idle while `talking` plays talk.
func _pick_state(speed: float, is_running: bool, is_on_floor: bool) -> String:
	if not is_on_floor:
		if available.has("jump"):
			return "jump"
		return current_state if current_state != "" else _first_of(["idle"])
	if talking and speed < IDLE_SPEED_THRESHOLD and available.has("talk"):
		return "talk"
	if speed < IDLE_SPEED_THRESHOLD:
		return _first_of(["idle"])
	if is_running:
		return _first_of(["run", "walk"])
	return _first_of(["walk", "run"])


## Else the current state, else "idle".
func _first_of(preferred: Array) -> String:
	for s: String in preferred:
		if available.has(s):
			return s
	return current_state if current_state != "" else "idle"


func _play_state(state: String, blend: float) -> void:
	if anim_player == null or not anim_player.has_animation(state):
		return
	current_state = state
	anim_player.play(state, blend)


func play_sit() -> void:
	if available.has("sit"):
		_play_state("sit", BLEND_TIME)


func cleanup() -> void:
	if anim_player and is_instance_valid(anim_player):
		anim_player.queue_free()
	anim_player = null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found
	return null


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_anim_player(child)
		if found:
			return found
	return null
