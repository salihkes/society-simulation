class_name AmbientPedestrian
extends CharacterBody3D

## Ambient pedestrian: a player avatar scene with its rig stripped; the authority walks it, other peers interpolate.

const LimbRigScript := preload("res://src/character/limb_rig.gd")
const HumanoidFaceScript := preload("res://src/character/face/humanoid_face.gd")
const JointRigAnimation := preload("res://src/character/rig/joint_rig_animation.gd")
const DialogRegistry := preload("res://src/life/dialog/dialog_registry.gd")
const CitizenWeather := preload("res://src/life/citizen_weather.gd")
var weather_reaction = CitizenWeather.new()

var ped_id := ""
var kind := 0  # index into the manager's scene pool
var manager = null
# Set before add_child and replicated.
var flag_code := ""
var flag_dir := ""
var flag_scale := 1.0  # countryball size (sizes.json)
# skin_path is a full-body diffuse atlas; accessory_paths are scenes or library names.
var skin_path := ""
var accessory_paths: Array = []
var _acc_container: Node3D = null
# "" derives the clip folder from the scene path.
var custom_character_dir := ""

@export var walk_speed := 4.0
## Not used for movement; the shared animation modules divide by it.
@export var run_speed := 8.0
@export var idle_min := 1.5
@export var idle_max := 9.0
@export var arrival_threshold := 2.0
@export var max_floor_angle_deg := 60.0

var _is_authority := true
var _gravity := 9.8

enum State { IDLE, WALKING }
var _state: State = State.IDLE
var idle_timer := 0.0
var _route: PackedVector3Array = PackedVector3Array()
var _route_idx := 0

var _stuck_timer := 0.0
var _stuck_ref := Vector3.ZERO
var _route_lifts: Dictionary = {}  # waypoint index -> "SchoolElevator/<floor>"
var _route_jumps: Dictionary = {}  # waypoint index -> true: step through a shut door to the next waypoint
var precise_route := false  # sampled indoor paths: reach corners before turning
var _interior := false
var _lift_wait := false
var _lift_route := PackedVector3Array()
var _lift_resume := 0
var _lift_retry := 0.0  # a full car: ask again in a moment
var _lift_refusals := 0
const LIFT_RETRY_S := 3.0
const LIFT_GIVE_UP := 40  # refusals (two minutes) before the last resort
const STAIR_CLIMB := 9.0  # workspace units per second the walker may rise toward a waypoint
# Catches wall-sliding, where the body moves but never gets closer to the waypoint.
var _wp_best := INF
var _wp_timer := 0.0

# A bias to the right for people ahead, so head-on meetings pass on their own right.
const AVOID_RADIUS := 7.0
const AVOID_STRENGTH := 3.0
const PASS_RIGHT_BIAS := 1.4
const VEHICLE_AVOID_RADIUS := 14.0
var _avoid := Vector3.ZERO
var _avoid_timer := 0.0
var _idle_push := Vector3.ZERO
# Anchored characters (a waiter, actors on marks) hold their ground instead of sidestepping.
var personal_space := true

# Remote bodies are drawn INTERP_DELAY_MS in the past.
var _remote_pos := Vector3.ZERO
var _remote_rot := 0.0
var _snap_a: Dictionary = {}  # {t (msec), pos, rot}
var _snap_b: Dictionary = {}
const INTERP_DELAY_MS := 130.0
var _remote_speed := 0.0
var _got_remote := false
var last_seen_msec := 0

var character_model: Node3D
var _rig := LimbRigScript.new()
var _has_limbs := false
var _base_model_y := 0.0

# Countryballs and rigged scenes use the players' modules; box humanoids swing limbs procedurally.
var _anim_module = null
var _face: Node = null  # humanoid_face.gd
var locked_emotion := ""  # replicated
# "notebook", "book" or MODEL_PROPS; replicated as "pr".
var held_prop := ""
var _prop_node: Node3D = null
# Walk straight at this point, no routes or wandering (a match). INF = off.
var steer_to := Vector3.INF
var steer_speed := 0.0
var _engage_t := 0.0
var _engaged := false
var _emotion_timer := 0.0

# A one-shot destination pushed by a system (a restaurant seat); the owner is told how it ended.
var errand_dest := Vector3.INF
var errand_owner: Object = null
var errand_tag := ""
var _errand_fails := 0

# Replicated as "st"; sit_how ("sh") is "chair", "lie", or a humanoid_poses.gd floor pose.
var sitting := false
var sit_how := "chair"
var _sit_pos := Vector3.INF
var sit_yaw := 0.0
const STAND_HEIGHT := 3.0  # body origin above the soles, standing

var _bubble: Label3D = null
var _bubble_timer := 0.0
var _voice: AudioStreamPlayer3D = null

# Driven by the manager, replicated as "pc"/"pl".
var calling := false
var call_conv := ""
var call_idx := -1

## Furniture-pack models: prop_<name>/mesh.tscn.
const MODEL_PROPS := ["pot", "bowl", "mug", "tote_bag", "broom"]
## In the right arm's space (the hand end).
const HAND_OFFSET := Vector3(0.0, -1.7, -0.35)

## "" (arms swing) or "folded".
var arms_pose := ""

static var _covers: Array = []
static var _covers_loaded := false

## "", "attention" or "at_ease"; applied on every peer.
var stance := ""
var animation := PedestrianAnimation.new(self)


func _ready():
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity") * 2.5
	floor_max_angle = deg_to_rad(max_floor_angle_deg)
	_strip_player_rig()

	character_model = get_node_or_null("CharacterModel")
	if character_model:
		_base_model_y = character_model.position.y
	_has_limbs = _rig.resolve(character_model)
	if _has_limbs:
		_rig.enable_joints()  # knees and elbows, for the floor poses
		_face = HumanoidFaceScript.attach(character_model)

	_remote_pos = position
	idle_timer = randf_range(0.0, idle_max)
	_apply_flag()
	_apply_skin()
	_apply_accessories()
	_setup_anim_module()
	weather_reaction.setup(self)


## The chat bubble SubViewport would be far too costly at crowd scale.
func _strip_player_rig():
	for child_name in ["CamOrigin", "XROrigin3D", "VR_Mode_Toggle"]:
		var child = get_node_or_null(child_name)
		if child:
			child.queue_free()
	var bubble_vp = get_node_or_null("ChatBubbleViewport")
	if bubble_vp and bubble_vp is SubViewport:
		bubble_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var bubble = get_node_or_null("CharacterModel/ChatBubble")
	if bubble:
		bubble.visible = false


func _setup_anim_module():
	if _has_limbs:
		return
	if character_model == null:
		return
	var sp = get_node_or_null("SoundPlayer")
	if scene_file_path.contains("countryball_quincyform"):
		_anim_module = CountryballQWCAnimation.new()
	elif character_model.find_child("Base", false, false) != null:
		_anim_module = CountryballAnimation.new()
	elif JointRigAnimation.find_rig(character_model) != null:
		_anim_module = JointRigAnimation.new()
	elif find_child("Skeleton3D", true, false) != null:
		_anim_module = CustomCharacterAnimation.new()
	if _anim_module:
		_anim_module.setup(self, character_model, sp)


## "" puts it away; a plain box stands in when the furniture pack is missing.
func set_prop(prop: String):
	if prop == held_prop:
		return
	held_prop = prop
	if _prop_node != null and is_instance_valid(_prop_node):
		_prop_node.queue_free()
		_prop_node = null
	if prop == "" or character_model == null:
		return
	var root := Node3D.new()
	root.name = "HeldProp"
	if prop in MODEL_PROPS:
		if not _attach_model_prop(prop, root):
			_attach_stand_in(root)
		return
	match prop:
		"notebook", "book":
			_build_book(prop, root)
			# _animate keeps the arm raised.
			if _has_limbs and _rig.right_arm != null:
				root.position = Vector3(-0.056, -1.574, -0.372)
				_rig.right_arm.add_child(root)
				_prop_node = root
				return
			root.position = Vector3(0.0, 1.2, -1.1)
			root.rotation_degrees = Vector3(-35.0, 0.0, 0.0)
		"bento":
			_add_prop_box(root, Vector3(1.3, 0.35, 0.9), Color(0.18, 0.14, 0.12), Vector3.ZERO)
			_add_prop_box(root, Vector3(1.34, 0.08, 0.94), Color(0.85, 0.2, 0.15),
				Vector3(0.0, -0.1, 0.0))
			root.position = Vector3(0.0, -0.1, -1.4)
	character_model.add_child(root)
	_prop_node = root


func _add_prop_box(parent: Node3D, size: Vector3, color: Color, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _build_book(prop: String, root: Node3D):
	_add_prop_box(root, Vector3(1.11, 0.25, 1.74), Color(0.93, 0.9, 0.82), Vector3.ZERO)
	var covers: Array = _book_cover() if prop == "book" else []
	var board := Color(0.2, 0.25, 0.45) if prop == "notebook" else Color(0.5, 0.18, 0.14)
	_add_prop_box(root, Vector3(1.15, 0.29, 1.78), board, Vector3.ZERO)
	# One plane per cover: a BoxMesh would spread the image over six faces.
	if covers.size() == 2:
		for side in [1.0, -1.0]:
			var cover := MeshInstance3D.new()
			var pm := PlaneMesh.new()
			pm.size = Vector2(1.11, 1.74)
			cover.mesh = pm
			var cmat := StandardMaterial3D.new()
			cmat.albedo_texture = covers[0] if side > 0.0 else covers[1]
			cover.material_override = cmat
			cover.position = Vector3(0.0, side * 0.147, 0.0)
			if side < 0.0:
				cover.rotation_degrees = Vector3(0.0, 0.0, 180.0)
			root.add_child(cover)
	_add_prop_box(root, Vector3(0.06, 0.3, 1.78), Color(0.15, 0.15, 0.2), Vector3(-0.585, 0.0, 0.0))


## Returns the node it was added to.
func _hold_in_hand(root: Node3D) -> Node3D:
	var holder: Node3D = _rig.right_arm if (_has_limbs and _rig.right_arm != null) else character_model
	root.position = HAND_OFFSET if holder != character_model else Vector3(0.0, 0.6, -1.1)
	holder.add_child(root)
	return holder


func _attach_stand_in(root: Node3D):
	_add_prop_box(root, Vector3(0.6, 0.6, 0.6), Color(0.75, 0.72, 0.66), Vector3.ZERO)
	_hold_in_hand(root)
	_prop_node = root


## The pack is authored in workspace units, so it is scaled by world scale over holder scale.
func _attach_model_prop(prop: String, root: Node3D) -> bool:
	var path := "res://assets/assets/Objects/prop_%s/mesh.tscn" % prop
	if not ResourceLoader.exists(path):
		return false
	var scene = load(path)
	if scene == null or not (scene is PackedScene):
		return false
	var model: Node3D = scene.instantiate()
	# The pack's collider is for the build tools, not for a thing in a hand.
	var body := model.get_node_or_null("Body")
	if body != null:
		body.queue_free()
	root.add_child(model)
	var holder := _hold_in_hand(root)
	var ws := 1.0
	if manager != null and manager.world() != null and manager.world().is_inside_tree():
		ws = manager.world().global_transform.basis.get_scale().x
	var hs: float = holder.global_transform.basis.get_scale().x if holder.is_inside_tree() else 1.0
	if hs > 0.0001:
		root.scale = Vector3.ONE * (ws / hs)
	_prop_node = root
	return true


## [front, back] chosen by ped_id, or [].
func _book_cover() -> Array:
	if not _covers_loaded:
		_covers_loaded = true
		_load_book_covers()
	if _covers.is_empty():
		return []
	return _covers[int(abs(hash(ped_id))) % _covers.size()]


## bookcovers/<title>.png|jpg, with <title>_back.<ext> as the back.
func _load_book_covers():
	var dir := DirAccess.open("res://assets/art/textures/bookcovers")
	if dir == null:
		return
	for f in dir.get_files():
		if not (f.ends_with(".png") or f.ends_with(".jpg")) or f.contains("_back."):
			continue
		var front = load("res://assets/art/textures/bookcovers/" + f)
		var back = load("res://assets/art/textures/bookcovers/" + f.get_basename()
			+ "_back." + f.get_extension())
		if front is Texture2D:
			_covers.append([front, back if back is Texture2D else front])


## Visual only; peers play it from the replicated kick counter.
func kick():
	animation.kick()


func bow():
	animation.bow()


## "" unlocks it and lets the mood drift resume.
func set_emotion(emotion: String):
	locked_emotion = emotion
	var face = _emoter()
	if emotion != "" and face:
		face.set_emotion(emotion)


func _emoter():
	if _face:
		return _face
	if _anim_module and _anim_module.has_method("set_emotion"):
		return _anim_module
	return null


func _drift_mood(delta: float):
	if locked_emotion != "":
		return
	var face = _emoter()
	if face == null:
		return
	_emotion_timer -= delta
	if _emotion_timer <= 0.0:
		_emotion_timer = randf_range(15.0, 45.0)
		var moods := ["neutral", "neutral", "neutral", "happy", "serious", "sad"]
		face.set_emotion(moods[randi() % moods.size()])


## Scales the ball to flag_scale about the ground.
func _apply_flag():
	if flag_code == "" or flag_dir == "":
		return
	var base = find_child("Base", true, false)
	if base == null or not (base is MeshInstance3D):
		return
	if character_model != null and flag_scale > 0.0 and absf(flag_scale - 1.0) > 0.001:
		var bottom := _ground_contact_y()
		character_model.scale = Vector3.ONE * flag_scale
		_base_model_y += bottom * (1.0 - flag_scale)
		character_model.position.y = _base_model_y
	var tex = _flag_texture()
	if tex == null:
		push_warning("[AmbientPed] Missing flag texture: " + flag_code)
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	var mi := base as MeshInstance3D
	if mi.mesh:
		for i in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, mat)
	set_meta("flag_code", flag_code)


## Model-space y from the first CollisionShape3D (never a mesh); -1.0 when there is none.
func _ground_contact_y() -> float:
	for c in get_children():
		if not (c is CollisionShape3D) or (c as CollisionShape3D).shape == null:
			continue
		var sh: Shape3D = (c as CollisionShape3D).shape
		var half := 0.0
		if sh is SphereShape3D:
			half = (sh as SphereShape3D).radius
		elif sh is CapsuleShape3D:
			half = (sh as CapsuleShape3D).height * 0.5
		elif sh is CylinderShape3D:
			half = (sh as CylinderShape3D).height * 0.5
		elif sh is BoxShape3D:
			half = (sh as BoxShape3D).size.y * 0.5
		return ((c as Node3D).position.y - half) - character_model.position.y
	return -1.0


## .svg, then .png, then .tga; null when none loads.
func _flag_texture():
	for ext in [".svg", ".png", ".tga"]:
		var path := flag_dir.path_join(flag_code + ext)
		if ResourceLoader.exists(path):
			var tex = load(path)
			if tex != null:
				return tex
	return null


## No-op when nothing changed.
func set_outfit(skin: String, accessories: Array):
	if skin == skin_path and accessories == accessory_paths:
		return
	skin_path = skin
	accessory_paths = accessories.duplicate()
	_apply_skin()
	_apply_accessories()


## Skips meshes marked preserve_materials.
func _apply_skin():
	if skin_path == "" or character_model == null:
		return
	var tex = load(skin_path)
	if tex == null:
		push_warning("[AmbientPed] Missing skin texture: " + skin_path)
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	var meshes: Array = []
	_collect_body_meshes(character_model, meshes)
	for m in meshes:
		var mi := m as MeshInstance3D
		if mi.mesh and not mi.get_meta("preserve_materials", false):
			for i in mi.mesh.get_surface_count():
				mi.set_surface_override_material(i, mat)


## Accessories and held props keep their own textures.
func _collect_body_meshes(node: Node, out: Array):
	if node == _acc_container or node == _prop_node or str(node.name) == "HeldProp":
		return
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_collect_body_meshes(child, out)


## Bare names resolve through the accessories library.
func _apply_accessories():
	if character_model == null:
		return
	if _acc_container != null and is_instance_valid(_acc_container):
		_acc_container.queue_free()
	_acc_container = null
	if accessory_paths.is_empty():
		return
	_acc_container = Node3D.new()
	_acc_container.name = "AmbAccessories"
	character_model.add_child(_acc_container)
	for p in accessory_paths:
		var path := str(p)
		if not path.begins_with("res://"):
			path = "res://assets/entities/character/accessories/%s/%s.tscn" % [path, path.to_lower()]
		if not ResourceLoader.exists(path):
			push_warning("[AmbientPed] Missing accessory: " + path)
			continue
		var scene = load(path)
		if not (scene is PackedScene):
			continue
		var acc = scene.instantiate()
		_acc_container.add_child(acc)
		# Countryballs are drawn with an outline; what they wear gets one too.
		if find_child("Base", true, false) != null:
			_add_outlines(acc)


## Inverted hull: the same mesh a little grown, black, unshaded, front faces culled.
func _add_outlines(node: Node):
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta("outline_of") or String(mi.name).ends_with("Outline"):
			continue
		var m: MeshInstance3D = mi
		if m.mesh == null:
			continue
		var o := MeshInstance3D.new()
		o.name = String(m.name) + "Outline"
		o.mesh = m.mesh
		o.set_meta("outline_of", m.name)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.02, 0.02, 0.03)
		mat.cull_mode = BaseMaterial3D.CULL_FRONT
		mat.grow = true
		mat.grow_amount = 0.012
		o.material_override = mat
		o.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.add_child(o)


func set_authority(is_auth: bool) -> void:
	_is_authority = is_auth
	if not is_auth:
		_remote_pos = position
		_route = PackedVector3Array()
		_state = State.IDLE


## The authority plays it when it teleports; remotes on a position jump.
func play_door_sound():
	var clip = load("res://assets/art/sound/city/door_open_close.mp3")
	if clip == null:
		return
	var snd := AudioStreamPlayer3D.new()
	snd.stream = clip
	snd.max_distance = 45.0
	snd.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	snd.volume_db = -6.0
	add_child(snd)
	snd.play()
	snd.finished.connect(snd.queue_free)


## The first state and jumps over 12 units snap.
func apply_remote_state(pos: Vector3, rot_y: float, speed: float) -> void:
	var now := float(Time.get_ticks_msec())
	if not _got_remote:
		position = pos
		_got_remote = true
		_snap_a = {"t": now - 100.0, "pos": pos, "rot": rot_y}
	elif pos.distance_to(_remote_pos) > 12.0:
		play_door_sound()
		position = pos
		_snap_a = {"t": now - 100.0, "pos": pos, "rot": rot_y}
	else:
		_snap_a = _snap_b if not _snap_b.is_empty() else {"t": now - 100.0, "pos": _remote_pos, "rot": _remote_rot}
	_snap_b = {"t": now, "pos": pos, "rot": rot_y}
	_remote_pos = pos
	_remote_rot = rot_y
	_remote_speed = speed
	last_seen_msec = Time.get_ticks_msec()


## Extrapolates at most 35% past the newest when the next state is late.
func _remote_sample() -> Dictionary:
	if _snap_b.is_empty():
		return {"pos": _remote_pos, "rot": _remote_rot}
	if _snap_a.is_empty():
		return {"pos": _snap_b.pos, "rot": _snap_b.rot}
	var rt: float = float(Time.get_ticks_msec()) - INTERP_DELAY_MS
	var ta: float = float(_snap_a.t)
	var tb: float = float(_snap_b.t)
	if tb - ta < 1.0:
		return {"pos": _snap_b.pos, "rot": _snap_b.rot}
	var u: float = clampf((rt - ta) / (tb - ta), 0.0, 1.35)
	return {"pos": Vector3(_snap_a.pos).lerp(Vector3(_snap_b.pos), u),
		"rot": lerp_angle(float(_snap_a.rot), float(_snap_b.rot), minf(u, 1.0))}


func current_speed() -> float:
	if _is_authority:
		return Vector2(velocity.x, velocity.z).length()
	return _remote_speed


func model_rot_y() -> float:
	return character_model.rotation.y if character_model else 0.0


## The authority simulates in _physics_process.
func _process(delta):
	if not _is_authority:
		var smp: Dictionary = _remote_sample()
		position = position.lerp(Vector3(smp.pos), minf(delta * 25.0, 1.0))
		if character_model:
			character_model.rotation.y = lerp_angle(character_model.rotation.y,
				float(smp.rot), minf(delta * 14.0, 1.0))
		_animate(delta)


func _physics_process(delta):
	if not _is_authority:
		return
	weather_reaction.tick(delta)

	if sitting:
		_hold_seat(delta)
		_animate(delta)
		return

	if not is_on_floor():
		velocity.y -= _gravity * delta
	_respawn_if_fallen()
	_update_engagement(delta)

	if steer_to != Vector3.INF:
		_follow_steer(delta)
		move_and_slide()
		_animate(delta)
		return

	match _state:
		State.IDLE:
			_idle_tick(delta)
		State.WALKING:
			_walk(delta)

	move_and_slide()
	_animate(delta)


func _hold_seat(delta):
	velocity = Vector3.ZERO
	if _sit_pos != Vector3.INF:
		position = position.lerp(_sit_pos, delta * 8.0)
	if character_model:
		character_model.rotation.y = lerp_angle(character_model.rotation.y, sit_yaw, delta * 6.0)


## Below y = -200 (spawned over nothing).
func _respawn_if_fallen():
	if position.y < -200.0 and manager != null and manager.nav != null and not manager.nav.is_empty():
		print("[AmbientPed %s] fell out of the world at y=%.0f — respawned" % [ped_id, position.y])
		position = manager.nav.random_point(manager.rng()) + Vector3.UP * 3.0
		velocity = Vector3.ZERO
		enter_idle()


## Every half second; not during an errand or a call.
func _update_engagement(delta):
	_engage_t -= delta
	if _engage_t > 0.0:
		return
	_engage_t = 0.5
	var eng = manager.get("engagement") if manager != null else null
	var near: Node3D = eng.engaged_player(self) if (eng != null \
		and errand_owner == null and not calling) else null
	_engaged = near != null
	if near == null or manager.world() == null:
		return
	if _state == State.WALKING:
		enter_idle()
	idle_timer = maxf(idle_timer, 2.0)
	var d: Vector3 = manager.world().to_local(near.global_position) - position
	d.y = 0.0
	if d.length_squared() > 0.01 and character_model:
		character_model.rotation.y = lerp_angle(character_model.rotation.y, atan2(d.x, d.z) + PI, 0.6)


func _follow_steer(delta):
	var to: Vector3 = steer_to - position
	to.y = 0.0
	var d: float = to.length()
	var top: float = steer_speed if steer_speed > 0.0 else walk_speed
	var want := Vector3.ZERO
	if d > 0.5:
		want = to / d * minf(top, d * 3.0)
	velocity.x = lerpf(velocity.x, want.x, minf(delta * 10.0, 1.0))
	velocity.z = lerpf(velocity.z, want.z, minf(delta * 10.0, 1.0))
	if character_model and want.length_squared() > 1.0:
		var face := atan2(want.x, want.z) + PI
		character_model.rotation.y = lerp_angle(character_model.rotation.y, face, delta * 8.0)
	_state = State.IDLE
	_route = PackedVector3Array()
	idle_timer = 999999.0


func _idle_tick(delta):
	velocity.x = lerp(velocity.x, 0.0, delta * 8.0)
	velocity.z = lerp(velocity.z, 0.0, delta * 8.0)
	_avoid_timer -= delta
	if _avoid_timer <= 0.0:
		_avoid_timer = 0.4
		_idle_push = Vector3.ZERO if _engaged else _idle_separation()
	if _idle_push != Vector3.ZERO:
		velocity.x = _idle_push.x
		velocity.z = _idle_push.z
	idle_timer -= delta
	if not (idle_timer <= 0.0 and manager):
		return
	var route: PackedVector3Array = _request_route()
	if route.size() > 0:
		_route = route
		_route_idx = 0
		_state = State.WALKING
		reset_progress()
	else:
		idle_timer = randf_range(idle_min, idle_max)


func reset_progress():
	_stuck_timer = 0.0
	_stuck_ref = position
	_wp_best = INF
	_wp_timer = 0.0


func _walk(delta):
	if _route_idx >= _route.size():
		enter_idle()
		return
	var target: Vector3 = _route[_route_idx]
	var to_target := target - position
	to_target.y = 0.0
	# Rise toward a higher waypoint as it nears, so a step riser never pins the capsule.
	if _interior and target.y > position.y + 0.3 and to_target.length() < 8.0:
		position.y = minf(position.y + STAIR_CLIMB * delta, target.y)
		velocity.y = 0.0
	if to_target.length() <= (minf(arrival_threshold, 0.25) if precise_route else arrival_threshold):
		_reach_waypoint(delta)
		return

	if to_target.length() < _wp_best - 1.5:
		_wp_best = to_target.length()
		_wp_timer = 0.0
	else:
		_wp_timer += delta
		if _wp_timer >= 4.0:
			_give_up_walk("no progress")
			return

	_steer_walk(delta, to_target)
	_check_stuck(delta)


func _give_up_walk(reason: String):
	if _interior:
		print("[Walker %s] gave up the school walk at %s, waypoint %d of %d (%s)" % [ped_id,
			str(position.snapped(Vector3(1, 1, 1))), _route_idx, _route.size(), reason])
	_on_route_abandoned()
	enter_idle()


func _reach_waypoint(delta):
	if _route_jumps.has(_route_idx) and _route_idx + 1 < _route.size():
		_step_through_door()
		return
	if _route_lifts.has(_route_idx) and manager != null and manager.has_method("request_elevator_ride"):
		_ride_lift(delta)
		return
	_route_idx += 1
	_wp_best = INF
	_wp_timer = 0.0
	if _route_idx >= _route.size():
		_on_route_arrived()
		enter_idle()


## A classroom door the collision keeps shut: teleport to the waypoint on the other side.
func _step_through_door():
	_route_jumps.erase(_route_idx)
	_route_idx += 1
	position = _route[_route_idx] + Vector3.UP * 1.0
	velocity = Vector3.ZERO
	play_door_sound()
	reset_progress()


## A full car is retried every LIFT_RETRY_S; after LIFT_GIVE_UP refusals it teleports on.
func _ride_lift(delta):
	var place := str(_route_lifts[_route_idx])
	_lift_retry -= delta
	if _lift_retry > 0.0:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	_lift_route = _route
	_lift_resume = _route_idx + 1
	if manager.request_elevator_ride(self, place, {}):
		print("[Walker %s] boards the lift for %s" % [ped_id, place])
		_route_lifts.erase(_route_idx)
		_lift_refusals = 0
		_lift_wait = true
		_route = PackedVector3Array()
		enter_idle()
		idle_timer = 999999.0
		return
	_lift_refusals += 1
	if _lift_refusals < LIFT_GIVE_UP:
		_lift_retry = LIFT_RETRY_S
		_stuck_ref = position
		_stuck_timer = 0.0
		_wp_timer = 0.0
		return
	_lift_refusals = 0
	_route_lifts.erase(_route_idx)
	print("[Walker %s] no room in the lift at %s (%s) — the last resort" % [ped_id,
		str(position.snapped(Vector3(1, 1, 1))), place])
	if _lift_resume < _lift_route.size():
		position = _lift_route[_lift_resume] + Vector3.UP * 2.0
		velocity = Vector3.ZERO
	_route_idx += 1


## Precise indoor routes skip avoidance and slow down near the waypoint.
func _steer_walk(delta, to_target: Vector3):
	var dir := to_target.normalized()
	_avoid_timer -= delta
	if _avoid_timer <= 0.0:
		_avoid_timer = 0.15
		_avoid = _crowd_avoidance(dir)

	# Avoidance redirects the walk but never slows it.
	var weather_speed: float = walk_speed * weather_reaction.speed_factor
	var steer := dir * weather_speed + _avoid
	steer.y = 0.0
	if steer.length_squared() > 0.01:
		steer = steer.normalized() * weather_speed
	else:
		steer = dir * weather_speed
	if _avoid != Vector3.ZERO and manager != null:
		var probe := position + steer * 0.35
		if not manager.nav.is_walkable(Vector2(probe.x, probe.z)):
			steer = dir * weather_speed
	if precise_route:
		steer = dir * minf(weather_speed, to_target.length() * global_basis.get_scale().x * 8.0)
	velocity.x = steer.x
	velocity.z = steer.z
	if character_model:
		var face := atan2(steer.x, steer.z) + PI
		character_model.rotation.y = lerp_angle(character_model.rotation.y, face, delta * 6.0)


## Moved less than 0.6 in the last 1.5 seconds.
func _check_stuck(delta):
	_stuck_timer += delta
	if _stuck_timer < 1.5:
		return
	if position.distance_to(_stuck_ref) < 0.6:
		_give_up_walk("stuck")
		return
	_stuck_timer = 0.0
	_stuck_ref = position


## Zero when clear, personal_space is off, or it would leave the walkable area.
func _idle_separation() -> Vector3:
	if manager == null or not personal_space:
		return Vector3.ZERO
	var out := Vector3.ZERO
	for p in manager.people_positions_local():
		var away: Vector3 = position - p
		away.y = 0.0
		var d := away.length()
		if d < 0.05 or d > 2.8:
			continue
		out += away / maxf(d, 0.2)
	for p in manager.vehicle_positions_local():
		var away: Vector3 = position - p
		away.y = 0.0
		var d := away.length()
		if d < 0.05 or d > VEHICLE_AVOID_RADIUS * 0.6:
			continue
		out += (away / maxf(d, 0.2)) * 2.0
	if out.length_squared() < 0.01:
		return Vector3.ZERO
	var push := out.normalized() * walk_speed * 0.45
	var ahead := position + push * 0.4
	if not manager.nav.is_walkable(Vector2(ahead.x, ahead.z)):
		return Vector3.ZERO
	return push


## Our own entry is skipped at distance ~0.
func _crowd_avoidance(desired: Vector3) -> Vector3:
	if manager == null:
		return Vector3.ZERO
	var out := Vector3.ZERO
	var right := desired.cross(Vector3.UP)
	for p in manager.people_positions_local():
		var away: Vector3 = position - p
		away.y = 0.0
		var d := away.length()
		if d < 0.05 or d > AVOID_RADIUS:
			continue
		var closeness := (AVOID_RADIUS - d) / AVOID_RADIUS
		out += (away / d) * closeness * AVOID_STRENGTH
		var ahead: float = (-away / d).dot(desired)
		if ahead > 0.4:
			out += right * PASS_RIGHT_BIAS * ahead * closeness
	for p in manager.vehicle_positions_local():
		var away: Vector3 = position - p
		away.y = 0.0
		var d := away.length()
		if d < 0.05 or d > VEHICLE_AVOID_RADIUS:
			continue
		var closeness := (VEHICLE_AVOID_RADIUS - d) / VEHICLE_AVOID_RADIUS
		out += (away / d) * closeness * AVOID_STRENGTH * 2.5
	return out


## The owner's errand_finished(ped, tag, ok) is called when it ends.
func assign_errand(owner: Object, dest: Vector3, tag: String):
	errand_owner = owner
	errand_dest = dest
	errand_tag = tag
	_errand_fails = 0
	enter_idle()
	idle_timer = 0.2


func _errand_notify(ok: bool):
	var owner := errand_owner
	var tag := errand_tag
	errand_owner = null
	errand_dest = Vector3.INF
	errand_tag = ""
	_errand_fails = 0
	if owner != null and is_instance_valid(owner) and owner.has_method("errand_finished"):
		owner.errand_finished(self, tag, ok)


## "chair": the marker is the seat surface; "lie": on its back; else a humanoid_poses.gd floor pose.
func sit_at(pos: Vector3, yaw: float, how := "chair"):
	sitting = true
	sit_how = how if (_has_limbs and (HumanoidPoses.has(how) or how == "lie")) else "chair"
	var raise: float = 1.0 if _has_limbs else 1.2
	if sit_how == "lie":
		raise = 0.9
	elif sit_how != "chair":
		raise = STAND_HEIGHT
	_sit_pos = pos + Vector3.UP * raise
	sit_yaw = yaw
	_route = PackedVector3Array()
	_state = State.IDLE
	idle_timer = 999999.0


func stand_up():
	sitting = false
	sit_how = "chair"
	_sit_pos = Vector3.INF
	enter_idle()


## Anonymous peds get a stable generic voice from their id hash.
func voice_id() -> String:
	return DialogRegistry.voice_for(ped_id)


## Falls back to the generic voice when this one has no clip.
func say_line(line_id: String, seconds := 5.0):
	var l: Dictionary = DialogRegistry.line(line_id)
	if l.is_empty():
		push_warning("[AmbientPed] Unknown dialog line: " + line_id)
		return
	var path := DialogRegistry.clip(voice_id(), line_id)
	if not ResourceLoader.exists(path):
		path = DialogRegistry.clip("generic", line_id)
	var stream = load(path) if ResourceLoader.exists(path) else null
	if stream is AudioStream:
		seconds = maxf(seconds, float(stream.get_length()) + 1.5)
	say(str(l.get("text", "")), seconds)
	if stream != null:
		play_voice(path)


## A change to a valid line index speaks it, so every peer plays the same scene.
func set_call(conv: String, idx: int):
	if conv == call_conv and idx == call_idx:
		return
	call_conv = conv
	call_idx = idx
	calling = conv != ""
	if conv != "" and idx >= 0:
		var entries: Array = DialogRegistry.conv(conv)
		if idx < entries.size():
			say_line(str(entries[idx].get("l", "")), 4.0)


func say(text: String, seconds := 5.0):
	if _bubble == null or not is_instance_valid(_bubble):
		_bubble = _make_bubble()
		add_child(_bubble)
	_bubble.text = text
	_bubble.visible = true
	_bubble_timer = seconds


## Uses a system CJK font because the bundled UI fonts lack the world's script.
func _make_bubble() -> Label3D:
	var b := Label3D.new()
	b.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	b.no_depth_test = true
	b.font_size = 64
	b.outline_size = 18
	b.pixel_size = 0.006
	b.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY  # CJK has no spaces
	b.width = 1100.0
	b.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.modulate = Color(1.0, 1.0, 1.0)
	b.outline_modulate = Color(0.05, 0.05, 0.08, 0.9)
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"Hiragino Sans", "Yu Gothic UI", "Meiryo",
		"Noto Sans CJK JP", "Noto Sans JP"])
	b.font = f
	b.position = Vector3(0, 4.9 * maxf(flag_scale, 1.0), 0)
	return b


func play_voice(path: String):
	if path == "":
		return
	var stream = load(path)
	if stream == null or not (stream is AudioStream):
		push_warning("[AmbientPed] Cannot load voice clip: " + path)
		return
	play_voice_stream(stream)


func play_voice_stream(stream: AudioStream):
	if stream == null:
		return
	if _voice == null or not is_instance_valid(_voice):
		_voice = AudioStreamPlayer3D.new()
		_voice.max_distance = 55.0
		_voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(_voice)
	_voice.stream = stream
	_voice.play()


func _request_route() -> PackedVector3Array:
	precise_route = false
	if errand_owner != null and errand_dest != Vector3.INF:
		return _errand_route()
	return manager.request_ped_route(self)


## Restaurant route, else walk zones, else beside it; empty (errand failed) when unreachable.
func _errand_route() -> PackedVector3Array:
	if manager.has_method("restaurant_route"):
		var dining: Dictionary = manager.restaurant_route(position, errand_dest)
		if not dining.is_empty():
			precise_route = true
			if dining.route.is_empty():
				_on_errand_unreachable()
			return dining.route
	var route: PackedVector3Array = manager.nav.find_route(position, errand_dest)
	if route.is_empty():
		route = _route_beside(errand_dest)
	if route.is_empty():
		print("[Errand %s] no route to %s from %s (walkable=%s)" % [ped_id, errand_dest, position,
			manager.nav.is_walkable(Vector2(position.x, position.z))])
		_on_errand_unreachable()
		return PackedVector3Array()
	return route


## Closest of 8 reachable points sampled within 30 units.
func _route_beside(dest: Vector3) -> PackedVector3Array:
	var route := PackedVector3Array()
	var best_d := INF
	for i in 8:
		var near: Vector3 = manager.nav.random_point_near(dest, 30.0, manager.rng())
		var d := near.distance_to(dest)
		if d >= best_d:
			continue
		var r: PackedVector3Array = manager.nav.find_route(position, near)
		if not r.is_empty():
			best_d = d
			route = r
	return route


func _on_errand_unreachable():
	_errand_notify(false)


func _strict_errand() -> bool:
	return is_instance_valid(errand_owner) and errand_owner.has_method("errand_arrival_radius") \
		and errand_owner.errand_arrival_radius(errand_tag) < 25.0


## Succeeds within the owner's arrival radius (default 25); fails after 3 misses.
func _on_route_arrived():
	if errand_owner != null and errand_dest != Vector3.INF:
		var flat := errand_dest - position
		flat.y = 0.0
		var reach := 25.0
		if is_instance_valid(errand_owner) and errand_owner.has_method("errand_arrival_radius"):
			reach = errand_owner.errand_arrival_radius(errand_tag)
		if flat.length() <= reach:
			_errand_notify(true)
			return
		_errand_fails += 1
		print("[Errand %s] arrived %.1f from %s (fail %d)" % [ped_id, flat.length(), errand_dest, _errand_fails])
		if _errand_fails >= 3:
			_errand_notify(false)
		else:
			idle_timer = 0.5


## An errand fails after 4 of these.
func _on_route_abandoned():
	if errand_owner != null and errand_dest != Vector3.INF:
		_errand_fails += 1
		print("[Errand %s] stuck at %s heading %s (fail %d)" % [ped_id, position, errand_dest, _errand_fails])
		if _errand_fails >= 4:
			_errand_notify(false)


func hold_idle(seconds: float) -> void:
	enter_idle()
	idle_timer = seconds


func walk_route(route: PackedVector3Array) -> void:
	_route = route
	_route_idx = 0
	_state = State.WALKING


func is_walking() -> bool:
	return _state == State.WALKING


func waiting_for_lift() -> bool:
	return _lift_wait


func is_authority() -> bool:
	return _is_authority


func is_engaged() -> bool:
	return _engaged


func has_limbs() -> bool:
	return _has_limbs


func limb_rig():
	return _rig


## School route state is kept while waiting for a lift.
func enter_idle():
	_state = State.IDLE
	_route = PackedVector3Array()
	idle_timer = randf_range(idle_min, idle_max)
	if not _lift_wait:
		_route_lifts = {}
		_route_jumps = {}
		_interior = false


## Abandons the school route when the ride failed.
func lift_trip_done(floor_index: int, ok: bool) -> void:
	if not _lift_wait:
		return
	_lift_wait = false
	if ok and _lift_resume < _lift_route.size():
		_route = _lift_route
		_route_idx = _lift_resume
		_state = State.WALKING
		_interior = true
		reset_progress()
		idle_timer = 999999.0
	else:
		_lift_route = PackedVector3Array()
		_route_lifts = {}
		_route_jumps = {}
		_on_route_abandoned()
		enter_idle()


## False when it has fewer than 2 points.
func follow_school_route(r: Dictionary) -> bool:
	var pts: PackedVector3Array = r.get("points", PackedVector3Array())
	if pts.size() < 2:
		return false
	_route = pts
	_route_idx = 0
	_route_lifts = r.get("lifts", {}).duplicate()
	_route_jumps = r.get("jumps", {}).duplicate()
	_interior = true
	_state = State.WALKING
	reset_progress()
	idle_timer = 999999.0
	if "_teleport_after_route" in self:
		set("_teleport_after_route", not bool(r.get("reached", false)))
	return true


func _animate(delta):
	_drift_mood(delta)
	_tick_bubble(delta)
	animation.animate(delta)
	weather_reaction.pose()


func _tick_bubble(delta):
	if _bubble != null and is_instance_valid(_bubble) and _bubble.visible:
		_bubble_timer -= delta
		if _bubble_timer <= 0.0:
			_bubble.visible = false


func base_model_y() -> float:
	return _base_model_y


## The character's own animation module (countryball, joint rig, skeleton), or null.
func anim_module():
	return _anim_module


## Worn accessories' parent, or null.
func accessory_container() -> Node3D:
	return _acc_container
