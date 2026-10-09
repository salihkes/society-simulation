extends Node3D
## One stage performer: the box humanoid's model and limb rig driven by a recorded or cue score, no player or NPC logic.

const HUMAN := "res://assets/entities/character/humanoid.tscn"
const Rig := preload("res://src/character/limb_rig.gd")
const Garment := preload("res://src/theater/costumes/costume_binding.gd")

## Model-space point the upper body leans about (the hips; the torso spans y -1..1).
const HIPS := Vector3(0, -1, 0)
## The head mesh is centred on the model's vertical axis; it turns about it.
const NECK := Vector3(0, 1, 0)
## Soles sit at model y = -3; the model hangs this far above the performer's origin.
const STAND_HEIGHT := 3.0

## A recorded key is a mark: walk to it past ARRIVE, else re-face its yaw past FACE_DEADZONE (estimation noise).
const WALK_SPEED := 4.0          # stage units per second (humanoid walk_speed)
const TURN_SPEED := 8.0          # radians per second, as the ambient pedestrians turn
const CYCLE_SPEED := 10.0        # HumanoidAnimation.animation_speed
const LEG_SWING := 0.8           # HumanoidAnimation.leg_swing_amount
const ARM_SWING := 1.2           # HumanoidAnimation.arm_swing_amount
const ARRIVE := 0.6              # stage units: closer than this is "on the mark"
const FACE_DEADZONE := 0.35      # radians (~20 degrees) before re-facing

## Stride length (stage units per cycle), full-on speed and swing amplitudes (radians).
const GAITS := {
	"slide": {"stride": 0.8, "speed": 1.0, "leg": 0.21, "arm": 0.0},
	"stride": {"stride": 1.6, "speed": 3.0, "leg": LEG_SWING, "arm": ARM_SWING},
}

var rig := Rig.new()
var model: Node3D
var costume: Dictionary
var _rest := {}     # limb node -> rest Transform3D
var _walk_cycle := 0.0
var _intensity := 0.0
var _pos := Vector2.INF     # where the figure actually is (stage x/z)
var _mark := Vector2.INF    # where the score wants it
var _yaw := 0.0             # current body yaw
var _face := 0.0            # yaw the figure is turning toward

var _hand := {}             # arm node -> Node3D riding the end of the forearm
var _fan: Node3D            # fan in the right hand
var _fan_ribs: Array[Node3D] = []
var _fan_paper: MeshInstance3D
var _fan_open := -1.0
var _floor_fan: Node3D      # fan laid on the floor ahead
var _prop_anchor: Node3D    # model-space frame that leans with the torso
var _props := {}            # prop name -> Node3D
var _sticks: Array[Node3D] = []
var _drop := 0.0            # how far the model came down for a floor pose
var garments: Array[Node3D] = []   # cage-fitted clothes (costume_binding.gd), posed after the limbs

const KIT_DIR := "res://assets/art/sound/theater/hayashi/"
const MASK_DIR := "res://assets/entities/theater/masks/"
static var _streams := {}       # kit name -> AudioStream, shared by all performers
var _voices: Array[AudioStreamPlayer3D] = []
var sounds_played := 0


func build(spec: Dictionary) -> void:
	set_process(false)
	costume = spec
	var source := (load(HUMAN) as PackedScene).instantiate()
	model = source.get_node("CharacterModel")
	source.remove_child(model)
	source.free()
	var bubble := model.get_node_or_null("ChatBubble")
	if bubble:
		bubble.free()
	add_child(model)
	# The mesh looks down its -Z; a performer at yaw 0 faces +Z (the house).
	model.position.y = STAND_HEIGHT
	model.rotation.y = PI
	rig.resolve(model)
	rig.enable_joints()
	_dress()
	for limb in [rig.torso, rig.head, rig.hair, rig.accessories, rig.left_arm, rig.right_arm, rig.left_leg, rig.right_leg]:
		if limb != null:
			_rest[limb] = limb.transform
	_build_hands()
	_build_fan()
	_dress_garments()
	if rig.torso:
		_prop_anchor = Node3D.new()
		_prop_anchor.name = "Props"
		_prop_anchor.transform = _rest[rig.torso].affine_inverse()
		rig.torso.add_child(_prop_anchor)


## Directions are in CharacterModel space; a negative `delta` snaps onto the mark (seek).
func apply_pose(p: Dictionary, delta: float = -1.0) -> void:
	var target := Vector2(float(p.x), float(p.z))
	var key_yaw := float(p.yaw)
	if delta <= 0.0 or _pos == Vector2.INF:
		_pos = target
		_mark = target
		_yaw = key_yaw
		_face = key_yaw
		_intensity = 0.0
		_walk_cycle = 0.0
	else:
		_step_toward(target, key_yaw, delta)
	position.x = _pos.x
	position.z = _pos.y
	rotation.y = _yaw
	# Blended by walk intensity so a raised arm folds into the swing instead of switching.
	var lean: Basis = _swing(Vector3.UP, p.torso).slerp(Basis.IDENTITY, _intensity)
	var about_hips := Transform3D(lean, HIPS - lean * HIPS)
	var turn := Basis(Vector3.UP, float(p.head_yaw))
	var about_neck := Transform3D(turn, NECK - turn * NECK)
	_pose_upper_body(about_hips, about_neck)
	var stride := sin(_walk_cycle) * _intensity
	var swing_of := {"left_arm": -stride * ARM_SWING, "right_arm": stride * ARM_SWING,
		"left_leg": stride * LEG_SWING, "right_leg": -stride * LEG_SWING}
	for slot in ["left_arm", "right_arm", "left_leg", "right_leg"]:
		var limb: Node3D = rig.get(slot)
		var rest: Transform3D = _rest[limb]
		var swing: Basis = _swing(Vector3.DOWN, p[slot]).slerp(Basis(Vector3.RIGHT, swing_of[slot]), _intensity)
		var about_joint := Transform3D(swing, rest.origin - swing * rest.origin)
		limb.transform = (about_hips * about_joint * rest) if slot.ends_with("arm") else (about_joint * rest)
		rig.flex(limb, 0.0)
	_place_hands()
	_pose_garments()


func _step_toward(target: Vector2, key_yaw: float, delta: float) -> void:
	if target.distance_to(_mark) > ARRIVE:
		_mark = target
	var to_mark := _mark - _pos
	var dist := to_mark.length()
	var moving := dist > ARRIVE * 0.5 and (_intensity > 0.05 or dist > ARRIVE)
	if moving:
		_face = atan2(to_mark.x, to_mark.y)
		_intensity = lerpf(_intensity, 1.0, minf(delta * 5.0, 1.0))
		var step := minf(WALK_SPEED * _intensity * delta, dist)
		_pos += to_mark / dist * step
		_walk_cycle = fmod(_walk_cycle + CYCLE_SPEED * _intensity * delta, TAU)
	else:
		_intensity = lerpf(_intensity, 0.0, minf(delta * 5.0, 1.0))
		if _intensity < 0.05:
			_walk_cycle = 0.0
		if absf(angle_difference(_face, key_yaw)) > FACE_DEADZONE:
			_face = key_yaw
	_yaw = lerp_angle(_yaw, _face, minf(delta * TURN_SPEED, 1.0))


## Head, hair and accessories turn about the neck on top of the hip lean.
func _pose_upper_body(about_hips: Transform3D, about_neck: Transform3D) -> void:
	if rig.torso:
		rig.torso.transform = about_hips * _rest[rig.torso]
	for limb in [rig.head, rig.hair, rig.accessories]:
		if limb != null:
			limb.transform = about_hips * about_neck * _rest[limb]


## Shortest-arc rotation taking `from` onto `to`.
static func _swing(from: Vector3, to: Vector3) -> Basis:
	if to.length_squared() < 1e-6:
		return Basis.IDENTITY
	var f := from.normalized()
	var t := to.normalized()
	var d := clampf(f.dot(t), -1.0, 1.0)
	if d > 0.9999:
		return Basis.IDENTITY
	if d < -0.9999:
		return Basis(Vector3.RIGHT, PI)
	return Basis(f.cross(t).normalized(), acos(d))


## `p.speed` sets how far the gait is on and `p.travel` its phase, so a time always shows the same step.
func apply_channels(p: Dictionary) -> void:
	position.x = float(p.x)
	position.z = float(p.z)
	rotation.y = float(p.yaw)

	var lean := Basis(Vector3.RIGHT, -float(p.get("bow", 0.0)))
	var about_hips := Transform3D(lean, HIPS - lean * HIPS)
	var turn := Basis(Vector3.UP, float(p.get("head_yaw", 0.0))) * Basis(Vector3.RIGHT, float(p.get("head_pitch", 0.0)))
	var about_neck := Transform3D(turn, NECK - turn * NECK)
	_pose_upper_body(about_hips, about_neck)

	var gait: Dictionary = GAITS.get(String(p.get("gait", "slide")), GAITS["slide"])
	var k := clampf(float(p.get("speed", 0.0)) / float(gait.speed), 0.0, 1.0)
	var phase := float(p.get("travel", 0.0)) * TAU / float(gait.stride)
	var swing := sin(phase) * k
	var gait_pitch := {"left_arm": -swing * float(gait.arm), "right_arm": swing * float(gait.arm),
		"left_leg": swing * float(gait.leg), "right_leg": -swing * float(gait.leg)}

	var lowest := INF
	for slot in StagePose.LIMBS:
		var limb: Node3D = rig.get(slot)
		if limb == null:
			continue
		var entry: Array = p[slot]
		var pitch := float(entry[0]) + float(gait_pitch[slot])
		var flex := float(entry[2])
		var basis := StagePose.limb_basis(slot, [pitch, float(entry[1])])
		var rest: Transform3D = _rest[limb]
		var about_joint := Transform3D(basis, rest.origin - basis * rest.origin)
		limb.transform = (about_hips * about_joint * rest) if slot.ends_with("arm") else (about_joint * rest)
		rig.flex(limb, flex)
		if slot.ends_with("leg"):
			for point in HumanoidPoses.limb_points(rig, limb, {"basis": basis, "flex": flex}):
				lowest = minf(lowest, point.y)
	# Folded legs would sink below the soles' line, so the body drops (HumanoidPoses.drop).
	_drop = 0.0 if lowest == INF else maxf(0.0, (lowest - 0.5) - HumanoidPoses.FLOOR_Y)
	model.position.y = STAND_HEIGHT - _drop

	_place_hands()
	_pose_garments()
	_show_fan(String(p.get("fan", "")), float(p.get("fan_open", 0.0)))
	_show_prop(String(p.get("prop", "")))
	visible = String(p.get("presence", "")) != "off"


## Plays from the performer's seat; the oldest of a few players is retaken when all are busy.
func play_sound(name: String) -> void:
	var stream := kit_stream(name)
	if stream == null:
		return
	var voice: AudioStreamPlayer3D = null
	for v in _voices:
		if not v.playing:
			voice = v
			break
	if voice == null and _voices.size() < 3:
		voice = AudioStreamPlayer3D.new()
		voice.name = "Voice%d" % _voices.size()
		voice.unit_size = 8.0
		voice.max_distance = 60.0
		voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		voice.position = Vector3(0, 2.0, 0)
		add_child(voice)
		_voices.append(voice)
	if voice == null:
		voice = _voices[sounds_played % _voices.size()]
	voice.stream = stream
	voice.play()
	sounds_played += 1


## Imported by the editor when it has run, else read straight from disk.
static func kit_stream(name: String) -> AudioStream:
	if _streams.has(name):
		return _streams[name]
	var stream: AudioStream = null
	for ext: String in ["wav", "ogg", "mp3"]:
		var path: String = KIT_DIR + name + "." + ext
		if ResourceLoader.exists(path):
			stream = load(path) as AudioStream
		elif FileAccess.file_exists(path):
			stream = _read_audio_file(path, ext)
		if stream != null:
			break
	if stream == null:
		push_warning("Performer: no kit sound named " + name)
	_streams[name] = stream
	return stream


static func _read_audio_file(path: String, ext: String) -> AudioStream:
	match ext:
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
	return null


## Stage units.
func drop() -> float:
	return _drop


## Model space, after the pose.
func hand_position(slot: String) -> Vector3:
	var limb: Node3D = rig.get(slot)
	if limb == null or not _hand.has(limb):
		return Vector3.ZERO
	return model.to_local((_hand[limb] as Node3D).global_position)


## Hand nodes, so held things follow the elbow bend.
func _build_hands() -> void:
	for limb in [rig.left_arm, rig.right_arm]:
		if limb == null:
			continue
		var hand := Node3D.new()
		hand.name = "Hand"
		limb.add_child(hand)
		_hand[limb] = hand


func _place_hands() -> void:
	for limb in _hand:
		var bender = rig.joint_of(limb)
		var joint := Vector3(0.0, -0.5, 0.0)
		var half := 0.5
		if bender != null:
			joint = bender.joint
			half = bender.half_width
		var t := LimbBender.ring_transform(1.0, joint, half, Vector3.RIGHT, rig.flex_of(limb) * rig.flex_sign(limb))
		var hand: Node3D = _hand[limb]
		hand.transform = Transform3D(t.basis, t * (joint + Vector3.DOWN))


## Closed, the fan continues the forearm's line, like a stick held in a fist.
func _build_fan() -> void:
	if rig.right_arm == null or not _hand.has(rig.right_arm):
		return
	var fan_color := Color(String(costume.get("fan", "e9d9a8")))
	_fan = Node3D.new()
	_fan.name = "Fan"
	_fan.basis = Basis(Vector3.RIGHT, deg_to_rad(10.0))
	(_hand[rig.right_arm] as Node3D).add_child(_fan)
	for i in 9:
		var rib := _box(_fan, Vector3(0.035, 1.4, 0.02), Vector3(0, -0.7, 0), Color("6b4a2a"))
		rib.name = "Rib%d" % i
		_fan_ribs.append(rib)
	_fan_paper = MeshInstance3D.new()
	_fan_paper.name = "Paper"
	var mat := _material(fan_color)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fan_paper.material_override = mat
	_fan.add_child(_fan_paper)
	_fan.visible = false

	# The same fan laid flat on the floor a little ahead of a seated figure.
	_floor_fan = Node3D.new()
	_floor_fan.name = "FloorFan"
	_floor_fan.position = Vector3(0, 0.04, 1.0)
	_floor_fan.basis = Basis(Vector3.RIGHT, deg_to_rad(90.0)) * Basis(Vector3.UP, PI)
	add_child(_floor_fan)
	_box(_floor_fan, Vector3(0.08, 1.4, 0.05), Vector3(0, -0.7, 0), Color("6b4a2a"))
	_floor_fan.visible = false


## `state` "hand" or "floor", anything else hides it; `open` is 0..1.
func _show_fan(state: String, open: float) -> void:
	if _fan == null:
		return
	_fan.visible = state == "hand"
	_floor_fan.visible = state == "floor"
	if not _fan.visible or absf(open - _fan_open) < 0.005:
		return
	_fan_open = open
	var span := deg_to_rad(140.0) * open
	for i in _fan_ribs.size():
		var a := (float(i) / float(_fan_ribs.size() - 1) - 0.5) * span
		var rot := Basis(Vector3.BACK, a)
		_fan_ribs[i].transform = Transform3D(rot, rot * Vector3(0, -0.7, 0))
	_fan_paper.visible = open > 0.03
	if _fan_paper.visible:
		_fan_paper.mesh = _sector(0.5, 1.38, span, 12)


## Angles measured from straight down the ribs.
static func _sector(r0: float, r1: float, span: float, segments: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in segments + 1:
		var a := (float(i) / float(segments) - 0.5) * span
		var d := Vector3(sin(a), -cos(a), 0)
		verts.append(d * r0)
		verts.append(d * r1)
		normals.append(Vector3.BACK)
		normals.append(Vector3.BACK)
	for i in segments:
		var o := i * 2
		idx.append_array([o, o + 1, o + 2, o + 1, o + 3, o + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Props hang on the body; the movement poses the arms to them.
func _show_prop(prop: String) -> void:
	for name in _props:
		(_props[name] as Node3D).visible = name == prop
	for stick in _sticks:
		stick.visible = prop == "taiko"
	if prop == "" or _props.has(prop):
		return
	var node := _make_prop(prop)
	if node == null:
		return
	node.name = prop.capitalize()
	if prop == "taiko":
		# In front of the seated player, on the floor: performer space.
		node.position = Vector3(0, 0, 1.7)
		add_child(node)
	elif _prop_anchor != null:
		_prop_anchor.add_child(node)
	else:
		model.add_child(node)
	_props[prop] = node


## Null for an unknown name; the taiko also puts a stick in each hand.
func _make_prop(prop: String) -> Node3D:
	var node: Node3D = null
	match prop:
		"kotsuzumi":
			node = _hourglass(0.3, 0.12, 0.28, Color("c8923a"))
			node.position = Vector3(1.05, 1.0, -0.6)
			node.basis = Basis(Vector3.RIGHT, PI / 2.0)
		"otsuzumi":
			node = _hourglass(0.38, 0.15, 0.36, Color("b0652e"))
			node.position = Vector3(-1.0, -0.5, -0.55)
			node.basis = Basis(Vector3.BACK, PI / 2.0)
		"nohkan":
			node = _make_flute()
		"taiko":
			node = _make_taiko()
	return node


static func _make_flute() -> Node3D:
	var node := Node3D.new()
	var pipe := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.06
	cyl.bottom_radius = 0.06
	cyl.height = 1.5
	pipe.mesh = cyl
	pipe.material_override = _material(Color("2a1a10"))
	pipe.basis = Basis(Vector3.BACK, PI / 2.0)
	node.add_child(pipe)
	node.position = Vector3(0.85, 1.45, -0.8)
	return node


func _make_taiko() -> Node3D:
	var node := Node3D.new()
	var drum := MeshInstance3D.new()
	var body := CylinderMesh.new()
	body.top_radius = 0.65
	body.bottom_radius = 0.65
	body.height = 0.45
	drum.mesh = body
	drum.material_override = _material(Color("8a2b1f"))
	drum.basis = Basis(Vector3.RIGHT, PI / 2.0)
	drum.position = Vector3(0, 1.05, 0)
	node.add_child(drum)
	_box(node, Vector3(1.3, 0.5, 0.9), Vector3(0, 0.25, 0), Color("4a3320"))
	for limb in _hand:
		var stick := _box(_hand[limb], Vector3(0.05, 0.9, 0.05), Vector3(0, -0.45, 0), Color("d9c9a3"))
		stick.basis = Basis(Vector3.RIGHT, deg_to_rad(70.0))
		stick.position = stick.basis * Vector3(0, -0.45, 0)
		_sticks.append(stick)
	return node


static func _hourglass(wide: float, narrow: float, height: float, color: Color) -> Node3D:
	var node := Node3D.new()
	for sign in [1.0, -1.0]:
		var cone := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = wide if sign > 0 else narrow
		mesh.bottom_radius = narrow if sign > 0 else wide
		mesh.height = height
		cone.mesh = mesh
		cone.position = Vector3(0, sign * height * 0.5, 0)
		cone.material_override = _material(color)
		node.add_child(cone)
	return node


## `garments` lists costume folders, worn in order, innermost first.
func _dress_garments() -> void:
	for name in costume.get("garments", []):
		var garment := Garment.new()
		garment.name = String(name).capitalize().replace(" ", "")
		model.add_child(garment)
		if garment.build(rig, String(name)):
			garments.append(garment)
		else:
			garment.queue_free()


## Physics may tick several times a frame, so from a physics tick this defers to _process().
func _pose_garments() -> void:
	if Engine.is_in_physics_frame():
		set_process(true)
		return
	_update_garments()


func _process(_delta: float) -> void:
	_update_garments()
	set_process(false)


func _update_garments() -> void:
	for garment in garments:
		garment.update_pose()


func _dress() -> void:
	_paint_parts()
	# A shirt front and a bow tie on a dark suit read from the house.
	if costume.has("shirt") and rig.torso:
		var shirt := _box(rig.torso, Vector3(0.9, 1.5, 0.08), Vector3(0, 0.15, -0.54), Color(String(costume.shirt)))
		shirt.name = "Shirt"
		_box(rig.torso, Vector3(0.5, 0.18, 0.1), Vector3(0, 0.85, -0.58), Color("111111")).name = "BowTie"
	match String(costume.get("hat", "")):
		"top":
			_hat(2.0, 0.62, 0.9, Color("141414"))
		"boater":
			_hat(2.0, 0.66, 0.35, Color("e7d9a6"))
		"bowler":
			_hat(2.0, 0.6, 0.55, Color("1c1c1c"))
	if (costume.has("mask") or costume.has("mask_model")) and rig.head:
		_add_mask()


func _paint_parts() -> void:
	var parts := {
		"torso": rig.torso, "arms": [rig.left_arm, rig.right_arm], "legs": [rig.left_leg, rig.right_leg], "head": rig.head,
	}
	for key in parts:
		if not costume.has(key):
			continue
		var color := Color(String(costume[key]))
		var nodes: Array = parts[key] if parts[key] is Array else [parts[key]]
		for node in nodes:
			if node != null:
				_paint(node, color)


func _paint(node: Node3D, color: Color) -> void:
	var meshes: Array = node.find_children("*", "MeshInstance3D", true, false)
	if node is MeshInstance3D:
		meshes.append(node)
	for mesh in meshes:
		mesh.material_override = _material(color)


## `mask_model` names a carved GLB under MASK_DIR (Y up, face +Z), else `mask` colours a plain plate.
func _add_mask() -> void:
	var face_bounds: AABB = rig.head.transform * _mesh_bounds(rig.head)
	var mask := Node3D.new()
	mask.name = "Mask"
	rig.head.add_child(mask)
	mask.transform = rig.head.transform.affine_inverse()
	var carved: Node3D = null
	if costume.has("mask_model"):
		carved = _load_glb(MASK_DIR + String(costume.mask_model) + ".glb")
	if carved == null:
		_box(mask, Vector3(0.95, 1.05, 0.06), Vector3(0, 1.5, -0.64), Color(String(costume.get("mask", "f3e7d4"))))
		for x in [-0.22, 0.22]:
			_box(mask, Vector3(0.2, 0.07, 0.03), Vector3(x, 1.62, -0.68), Color("1a1410"))
		return
	carved.name = "Carved"
	mask.add_child(carved)
	var source_bounds := _mesh_bounds(carved)
	var height_scale := face_bounds.size.y * 0.98 / source_bounds.size.y
	# Width is fitted separately to the box face; depth keeps the height scale.
	carved.scale = Vector3(face_bounds.size.x * 0.96 / source_bounds.size.x,
		height_scale, height_scale)
	carved.rotation.y = PI   # the head mesh looks down -Z
	var fitted_bounds := carved.transform * source_bounds
	carved.position = face_bounds.get_center() - fitted_bounds.get_center()
	# Seat the back of the carving just outside the face plane.
	carved.position.z = face_bounds.position.z - 0.012 - fitted_bounds.end.z


## Includes imported node transforms.
static func _mesh_bounds(node: Node3D) -> AABB:
	var meshes := node.find_children("*", "MeshInstance3D", true, false)
	if node is MeshInstance3D:
		meshes.append(node)
	var bounds := AABB()
	var first := true
	for mesh in meshes:
		var local: Transform3D = node.global_transform.affine_inverse() * mesh.global_transform
		var box: AABB = local * mesh.mesh.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	return bounds


## Prefers the imported scene (exports have no raw GLB), else parses the GLB.
static func _load_glb(path: String) -> Node3D:
	if ResourceLoader.exists(path, "PackedScene"):
		var packed := load(path) as PackedScene
		return packed.instantiate() as Node3D if packed != null else null
	if not FileAccess.file_exists(path):
		push_warning("Performer: no model at " + path)
		return null
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	state.create_animations = false
	if document.append_from_file(path, state) != OK:
		push_warning("Performer: could not read " + path)
		return null
	return document.generate_scene(state) as Node3D


func _hat(y: float, radius: float, height: float, color: Color) -> void:
	if rig.head == null:
		return
	var hat := Node3D.new()
	hat.name = "Hat"
	rig.head.add_child(hat)
	# The imported head mesh carries a 90 degree bake; undo it for the hat.
	hat.transform = rig.head.transform.affine_inverse() * Transform3D(Basis.IDENTITY, Vector3(0, y, 0))
	var crown := MeshInstance3D.new()
	var crown_mesh := CylinderMesh.new()
	crown_mesh.top_radius = radius
	crown_mesh.bottom_radius = radius
	crown_mesh.height = height
	crown.mesh = crown_mesh
	crown.position.y = height * 0.5 + 0.02
	crown.material_override = _material(color)
	hat.add_child(crown)
	var brim := MeshInstance3D.new()
	var brim_mesh := CylinderMesh.new()
	brim_mesh.top_radius = radius * 1.45
	brim_mesh.bottom_radius = radius * 1.45
	brim_mesh.height = 0.05
	brim.mesh = brim_mesh
	brim.material_override = _material(color)
	hat.add_child(brim)


static func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	return mat


static func _box(parent: Node3D, size: Vector3, offset: Vector3, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	mesh.mesh = shape
	mesh.material_override = _material(color)
	# Meshes carry a 90 degree bake about X; offsets are in the unrotated frame.
	mesh.transform = parent.transform.affine_inverse() * Transform3D(Basis.IDENTITY, parent.transform.origin + offset) if parent is MeshInstance3D else Transform3D(Basis.IDENTITY, offset)
	parent.add_child(mesh)
	return mesh
