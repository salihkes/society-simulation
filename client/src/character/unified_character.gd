class_name UnifiedCharacter
extends CharacterBody3D
## The player and avatar body: movement, input and animation modules, seats and vehicles.

signal vr_mode_changed(is_active: bool)

@export var walk_speed := 4.0
@export var run_speed := 8.0
@export var jump_velocity := 8.0
@export var acceleration := 10.0
@export var air_control := 0.8
@export var gravity_multiplier := 2.5

@export var arm_swing_amount := 1.2
@export var leg_swing_amount := 0.8
@export var animation_speed := 10.0
@export var remote_min_speed_for_animation := 1

## Built only for character_type "jointrig".
const JointRigAnimationScript := preload("res://src/character/rig/joint_rig_animation.gd")

var gravity_direction := Vector3.ZERO
var mesh_forward_is_backward := true
var planet := CharacterPlanet.new(self)
var ship := CharacterShip.new(self)
## Debounced so single-frame contacts do not flicker.
var animation_floor_state := false
var animation_floor_timer := 0.0
var animation_floor_delay := 0.1

# The seat owns our position until stand_from_seat().
var _seated := false
var _seat_pos := Vector3.ZERO
var _seat_yaw := 0.0

# The car owns our position until exit_vehicle().
var _in_vehicle := false
var _current_vehicle = null
var _vehicle_prev_parent: Node = null
var _vehicle_xr_transform := Transform3D.IDENTITY

var character_model: Node3D
var camera_controller: Node3D
var xr_origin: XROrigin3D

var movement_dir := Vector3.ZERO
var was_on_floor := false

## Remote players animate from these; position deltas are unreliable on web.
var anim_speed := 0.0
var anim_is_running := false

## "seiza", "agura" or "", box humanoids only; moving or jumping stands up.
var pose := ""

## While set, keys are words, not movement.
var key_holder: Node = null

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity") * gravity_multiplier

var sound_player: AudioStreamPlayer3D
var victory_sound: AudioStream

## OpenXR stays on for Android (Quest) or FORCE_OPENXR (PCVR testing).
var _openxr_allowed := OS.has_feature("android") or OS.has_environment("FORCE_OPENXR")

var current_movement: MovementBase
var keyboard_movement: KeyboardMovement
var vr_movement: VRMovement
var is_vr_mode := false

var is_remote_player := false

var current_animation: AnimationBase
var humanoid_animation: HumanoidAnimation
var countryball_animation: CountryballAnimation
var countryball_qwc_animation: CountryballQWCAnimation
var custom_animation: CustomCharacterAnimation
var joint_rig_animation: AnimationBase
## "humanoid", "custom", "jointrig" or a flavour in CountryballTypes.TYPES.
var character_type := "humanoid"

var grab_module: GrabModule

## 0.2 to 1.5; 1.0 is the scene's own size.
var character_scale := 1.0
var _base_model_scale: Vector3
var _base_collision_radius: float = 2.0
var _base_collision_height: float = 5.0

func _ready():
	character_model = $CharacterModel
	camera_controller = find_child("CamOrigin")
	xr_origin = find_child("XROrigin3D")
	_base_model_scale = character_model.scale
	var collision_shape = get_node_or_null("CollisionShape3D")
	if collision_shape and collision_shape.shape is CapsuleShape3D:
		_base_collision_radius = collision_shape.shape.radius
		_base_collision_height = collision_shape.shape.height
	$CharacterModel/ChatBubble/Sprite3D.visible = false
	sound_player = $SoundPlayer
	victory_sound = load("res://assets/art/sound/victory.wav")
	if sound_player and victory_sound:
		sound_player.stream = victory_sound
		sound_player.play()
	planet.find()
	animation_floor_state = planet.is_on_floor()
	_setup_movement_modules()
	_setup_animation_modules()
	_setup_grab_module()
	_initialize_vr_system()
	if not is_remote_player:
		var interactions := preload("res://src/character/vr_interactions.gd").new()
		interactions.name = "VRInteractions"
		add_child(interactions)

func _setup_movement_modules():
	keyboard_movement = KeyboardMovement.new()
	keyboard_movement.setup(self, character_model)
	vr_movement = VRMovement.new()
	vr_movement.setup(self, character_model)
	current_movement = keyboard_movement
	print("Movement modules initialized")

func _setup_animation_modules():
	_detect_character_type()
	humanoid_animation = HumanoidAnimation.new()
	humanoid_animation.setup(self, character_model, sound_player)
	countryball_animation = CountryballAnimation.new()
	countryball_animation.setup(self, character_model, sound_player)
	if character_type == "jointrig":
		joint_rig_animation = JointRigAnimationScript.new()
		joint_rig_animation.setup(self, character_model, sound_player)
		current_animation = joint_rig_animation
	elif character_type == "custom":
		# Built only when needed: it builds an AnimationPlayer from the FBX clips.
		custom_animation = CustomCharacterAnimation.new()
		custom_animation.setup(self, character_model, sound_player)
		current_animation = custom_animation
	elif character_type == CountryballTypes.QWC:
		# QWC balls drive their face with meshes, so they get their own module.
		countryball_qwc_animation = CountryballQWCAnimation.new()
		countryball_qwc_animation.setup(self, character_model, sound_player)
		current_animation = countryball_qwc_animation
	elif CountryballTypes.is_countryball(character_type):
		current_animation = countryball_animation
	else:
		current_animation = humanoid_animation
	print("Animation modules initialized for character type: ", character_type)

func _setup_grab_module():
	grab_module = GrabModule.new()
	grab_module.setup(self, character_model)

func _detect_character_type():
	# First: a joint rig builds a Skeleton3D too and may live in a custom_character folder.
	if JointRigAnimationScript.find_rig(character_model) != null:
		character_type = "jointrig"
		return
	# custom_character folders are per user: a blocky body there animates as a humanoid.
	if scene_file_path.contains("custom_character"):
		if character_model.find_children("*", "Skeleton3D", true, false).size() > 0:
			character_type = "custom"
			return
	# Before flag_code: QWC balls wear a flag too.
	if scene_file_path.contains("countryball_quincyform"):
		character_type = CountryballTypes.QWC
		return
	# flag_code is set by the network controller for one-sided balls.
	if has_meta("flag_code"):
		character_type = CountryballTypes.ONESIDE
		return
	if scene_file_path.contains("countryballoneside"):
		character_type = CountryballTypes.ONESIDE
		return
	if character_model.has_node("Base") and character_model.has_node("Emotions"):
		character_type = CountryballTypes.CLASSIC
		return
	character_type = "humanoid"
	# Limbs may sit inside an instanced model scene, so search recursively.
	if not (character_model.find_child("LeftArm", true, false) and character_model.find_child("RightArm", true, false)):
		print("Warning: Could not detect character type, defaulting to humanoid")

func _initialize_vr_system():
	if is_remote_player:
		return
	# Left running without a use_xr viewport OpenXR logs an error every frame.
	if not _openxr_allowed:
		var xr_off = XRServer.find_interface("OpenXR")
		if xr_off and xr_off.is_initialized():
			xr_off.uninitialize()
		print("OpenXR force-disabled in code, using keyboard mode only")
		set_vr_mode(false)
		return
	var xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface:
		print("OpenXR interface found, initializing VR system")
		call_deferred("_setup_vr")
	else:
		print("No OpenXR interface found, using keyboard mode only")
		set_vr_mode(false)

func _setup_vr():
	if is_remote_player or is_queued_for_deletion() or not is_inside_tree():
		return
	var xr_interface = XRServer.find_interface("OpenXR")
	if not (xr_interface and (xr_interface.is_initialized() or xr_interface.initialize())):
		print("Failed to initialize XR Interface, staying in keyboard mode")
		set_vr_mode(false)
		return
	print("XR Interface initialized successfully")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	if is_remote_player or is_queued_for_deletion():
		return
	set_vr_mode(true)

## The seat owner poses the limbs; movement resumes on stand_from_seat().
func sit_on_seat(seat_global_pos: Vector3, yaw: float):
	_seated = true
	_seat_pos = seat_global_pos
	_seat_yaw = yaw
	velocity = Vector3.ZERO

func stand_from_seat():
	_seated = false

## A key holder, a focused VR chat field or a focused text field.
func _typing() -> bool:
	if key_holder != null and is_instance_valid(key_holder):
		return true
	if is_vr_mode and _vr_chat_focused():
		return true
	var f := get_viewport().gui_get_focus_owner() if get_viewport() else null
	return f is LineEdit or f is TextEdit

func _vr_chat_focused() -> bool:
	for panel in get_tree().get_nodes_in_group("vr_chat_panel"):
		if not panel.panel_visible or panel.sub_viewport == null:
			continue
		var focused = panel.sub_viewport.gui_get_focus_owner()
		if focused is LineEdit or focused is TextEdit:
			return true
	return false

func _physics_process(delta):
	if _in_vehicle:
		return
	if _seated:
		_ease_onto_seat(delta)
		return
	if pose != "" and not is_remote_player and not _typing():
		if Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down") != Vector2.ZERO \
				or Input.is_action_just_pressed("jump"):
			set_pose("")
	# Aboard a ship the ship owns gravity.
	if not ship.is_aboard():
		planet.tick_scan(delta)
	if ship.is_aboard():
		ship.physics(delta)
		return
	planet.physics(delta)

func _ease_onto_seat(delta: float) -> void:
	global_position = global_position.lerp(_seat_pos, delta * 8.0)
	velocity = Vector3.ZERO
	var cm = get_node_or_null("CharacterModel")
	if cm != null:
		cm.rotation.y = lerp_angle(cm.rotation.y, _seat_yaw, delta * 6.0)

func animate_local(delta: float, speed: float) -> void:
	var is_running = current_movement and current_movement.is_running
	anim_speed = speed
	anim_is_running = is_running
	current_animation.animate(delta, speed, movement_dir, is_running, animation_floor_state)

func update_grab_and_interact(delta: float) -> void:
	if grab_module:
		grab_module.update(delta)
	if not _typing() and Input.is_action_just_pressed("interact"):
		ship.handle_interact()

func toggle_vr_mode():
	var xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		set_vr_mode(not is_vr_mode)
	else:
		print("Cannot toggle VR mode - OpenXR interface not available")

## Remote players never enter VR.
func set_vr_mode(active: bool):
	if is_remote_player:
		return
	is_vr_mode = active
	if current_movement:
		current_movement.cleanup()
	if active:
		current_movement = vr_movement
		vr_movement.set_vr_active(true)
	else:
		current_movement = keyboard_movement
		if vr_movement:
			vr_movement.set_vr_active(false)
	_show_vr_nodes(active)
	_handle_xr_viewport(active)
	_configure_vr_audio(active)
	if grab_module:
		grab_module.set_vr_active(active)
	vr_mode_changed.emit(active)
	print("VR mode " + ("enabled" if active else "disabled"))

func _show_vr_nodes(active: bool) -> void:
	if xr_origin:
		xr_origin.visible = active
		xr_origin.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	if camera_controller:
		# VR has its own camera; leaving first person gives the head and the cursor back.
		if active and camera_controller.has_method("set_first_person"):
			camera_controller.set_first_person(false)
		camera_controller.visible = not active
		camera_controller.process_mode = Node.PROCESS_MODE_INHERIT if not active else Node.PROCESS_MODE_DISABLED
	# A body with a LocalPlayer node hides its whole model in VR.
	var model = get_node_or_null("CharacterModel")
	if model and get_node_or_null("LocalPlayer"):
		model.visible = not active

func _handle_xr_viewport(enable: bool):
	if is_remote_player:
		return
	var xr_interface = XRServer.find_interface("OpenXR")
	if not xr_interface or not xr_interface.is_initialized():
		return
	var root_viewport = get_tree().root
	if root_viewport:
		root_viewport.use_xr = enable
		print("XR viewport " + ("enabled" if enable else "disabled"))

func _configure_vr_audio(vr_active: bool):
	var npc_spatial_audio = get_node_or_null("/root/workspace/NPC2/Skeleton3D/AudioStreamPlayer3D")
	var global_audio = get_node_or_null("/root/workspace/AudioStreamPlayer")
	var npc = get_node_or_null("/root/workspace/NPC2/Skeleton3D")
	if npc_spatial_audio:
		npc_spatial_audio.volume_db = -80.0 if vr_active else 0.0
	if not (npc and "use_vr_audio" in npc):
		return
	npc.use_vr_audio = vr_active
	if vr_active and "vr_audio_player" in npc:
		npc.vr_audio_player = global_audio

func play_jump_sound():
	if current_animation:
		current_animation.play_jump_sound()

func set_input_enabled(enabled: bool):
	if keyboard_movement:
		keyboard_movement.set_input_enabled(enabled)

func set_as_remote_player():
	set_input_enabled(false)
	is_remote_player = true

## Only box humanoids can; others always get "".
func set_pose(pose_name: String):
	if not HumanoidPoses.has(pose_name) or humanoid_animation == null or not humanoid_animation.can_pose():
		pose_name = ""
	pose = pose_name
	if humanoid_animation != null:
		humanoid_animation.set_pose(pose_name)

## Speeds under remote_min_speed_for_animation play idle so jitter does not twitch the legs.
func animate_remote_movement(speed, direction, on_floor: bool = true):
	if not current_animation:
		return
	var play_speed = speed
	if remote_min_speed_for_animation > 0.0 and speed < remote_min_speed_for_animation:
		play_speed = 0.0
	current_animation.animate_remote(play_speed, direction, on_floor)

func show_chat_bubble(message: String):
	var rich_text = $ChatBubbleViewport/Control/TextureRect/RichTextLabel
	rich_text.text = message
	$CharacterModel/ChatBubble/Sprite3D.visible = true
	if current_animation and current_animation.has_method("say"):
		current_animation.say(message)
	var timer = get_tree().create_timer(5.0)
	timer.timeout.connect(func(): $CharacterModel/ChatBubble/Sprite3D.visible = false)

## Leaving the floor while rising takes effect at once so jumps animate immediately.
func update_animation_floor_state(delta: float, current_floor_state: bool):
	if current_floor_state == animation_floor_state:
		animation_floor_timer = 0.0
		return
	animation_floor_timer += delta
	var required_delay = animation_floor_delay
	if not current_floor_state and planet.up_speed() > 0.5:
		required_delay = 0.02
	if animation_floor_timer >= required_delay:
		animation_floor_state = current_floor_state
		animation_floor_timer = 0.0

## The countryball module's, or a "Base" MeshInstance3D.
func get_base_mesh() -> MeshInstance3D:
	if CountryballTypes.is_countryball(character_type) and current_animation and current_animation.has_method("get_base_mesh"):
		var mesh = current_animation.get_base_mesh()
		if mesh:
			return mesh
	if character_model:
		# owned=false so a Base inside an instanced scene is found too.
		var found = character_model.find_child("Base", true, false)
		if found is MeshInstance3D:
			return found
	return null

func get_character_type() -> String:
	return character_type

## False if unsupported.
func set_emotion(emotion: String) -> bool:
	if current_animation and current_animation.has_method("set_emotion"):
		return current_animation.set_emotion(emotion)
	return false

func get_emotion() -> String:
	if current_animation and current_animation.has_method("get_emotion"):
		return current_animation.get_emotion()
	return "neutral"

## Empty for custom models.
func get_available_emotions() -> Array:
	if current_animation and current_animation.has_method("get_available_emotions"):
		return current_animation.get_available_emotions()
	return CountryballTypes.emotions_for(character_type)

## Relative to the scene's size, clamped to 0.2..1.5.
func set_character_scale(new_scale: float) -> void:
	character_scale = clampf(new_scale, 0.2, 1.5)
	var target_scale = _base_model_scale * character_scale
	character_model.scale = target_scale
	# Keeps squash and stretch relative to the new size.
	if current_animation and current_animation.has_method("update_original_scale"):
		current_animation.update_original_scale(target_scale)
	var collision_shape = get_node_or_null("CollisionShape3D")
	if collision_shape and collision_shape.shape:
		# The shape resource is shared between instances of the scene.
		collision_shape.shape = collision_shape.shape.duplicate()
		if collision_shape.shape is CapsuleShape3D:
			collision_shape.shape.radius = _base_collision_radius * character_scale
			collision_shape.shape.height = _base_collision_height * character_scale
	print("Character scale set to: ", character_scale)

## Called by DrivableVehicle.board(): model hidden, self-movement frozen.
func enter_vehicle(vehicle, seat, as_driver):
	_in_vehicle = true
	_current_vehicle = vehicle
	_vehicle_prev_parent = get_parent()
	if is_vr_mode and not is_remote_player and xr_origin:
		_vehicle_xr_transform = xr_origin.transform
	if seat and seat is Node3D:
		reparent(seat, false)
		transform = Transform3D.IDENTITY
	velocity = Vector3.ZERO
	if character_model:
		character_model.visible = false
	if is_remote_player:
		return
	if is_vr_mode and xr_origin:
		_center_vr_head_on_seat(vehicle, seat)
		return
	# The character camera consumes wheel and mouse motion, so it must stop first.
	disable_camera()
	if vehicle.has_method("activate_camera"):
		vehicle.activate_camera()

func _center_vr_head_on_seat(vehicle, seat) -> void:
	var head := xr_origin.get_node_or_null("XRCamera3D") as XRCamera3D
	if head == null:
		return
	var forward := -head.transform.basis.z
	xr_origin.rotation = Vector3(0, atan2(forward.x, -forward.z), 0)
	xr_origin.position += to_local(vehicle.vr_eye_position(seat)) - to_local(head.global_position)
	head.current = true

func exit_vehicle(exit_pos):
	var xr_heading: float = xr_origin.global_rotation.y if is_vr_mode and xr_origin else 0.0
	_in_vehicle = false
	if _vehicle_prev_parent and is_instance_valid(_vehicle_prev_parent):
		reparent(_vehicle_prev_parent, false)
	global_position = exit_pos
	velocity = Vector3.ZERO
	if character_model:
		character_model.visible = not is_vr_mode
	if not is_remote_player and is_instance_valid(_current_vehicle) \
			and _current_vehicle.has_method("deactivate_camera"):
		_current_vehicle.deactivate_camera()
	if not is_remote_player:
		if is_vr_mode and xr_origin:
			_restore_vr_view(xr_heading)
		else:
			ship.restore_character_camera()
	_current_vehicle = null

## Keeps the heading the player had in the car.
func _restore_vr_view(xr_heading: float) -> void:
	xr_origin.transform = _vehicle_xr_transform
	global_rotation = Vector3(0, xr_heading - xr_origin.rotation.y, 0)
	vr_movement.jump_just_pressed = false
	var head := xr_origin.get_node_or_null("XRCamera3D") as XRCamera3D
	if head != null:
		head.current = true

func disable_camera() -> void:
	if not camera_controller:
		return
	camera_controller.process_mode = Node.PROCESS_MODE_DISABLED
	var char_cam = camera_controller.find_child("Camera3D")
	if char_cam:
		char_cam.current = false

## In _input so weapon and build tools do not take the click first.
func _input(event):
	ship.input(event)

func _unhandled_input(event):
	ship.unhandled_input(event)

func enable_camera() -> void:
	if camera_controller:
		camera_controller.process_mode = Node.PROCESS_MODE_INHERIT
		var char_cam = camera_controller.find_child("Camera3D")
		if char_cam:
			char_cam.current = true

## Null when unsupported.
func get_outfit():
	if joint_rig_animation and joint_rig_animation.rig and joint_rig_animation.rig.has_method("get_outfit"):
		return joint_rig_animation.rig.get_outfit()
	return null

func set_outfit(ids: Array) -> bool:
	if joint_rig_animation and joint_rig_animation.rig and joint_rig_animation.rig.has_method("set_outfit"):
		return joint_rig_animation.rig.set_outfit(ids)
	return false
