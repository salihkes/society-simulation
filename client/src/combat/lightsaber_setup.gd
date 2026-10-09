extends Node
## Gives the local player a lightsaber (VR) and blaster once their character exists.

@export var player_blade_color := Color(0.2, 0.55, 1.0)
@export var player_bolt_color := Color(0.1, 0.8, 0.3)
@export var test_blade_color := Color(1.0, 0.15, 0.1)
@export var spawn_test_saber := true
@export var spawn_blaster_npc := true
@export var test_saber_offset := Vector3(1.5, 0, -1.0)
@export var npc_offset := Vector3(0, 0, -8)

var right_saber: Lightsaber = null
var player_blaster: PlayerBlaster = null
var weapon_mgr: WeaponManager = null
var test_saber: Lightsaber = null
var blaster_npc: BlasterNPC = null

var _setup_done := false
var _retry_timer := 0.0


func _ready():
	await get_tree().process_frame
	_try_setup()


func _physics_process(delta: float):
	if _setup_done:
		return
	_retry_timer += delta
	if _retry_timer > 0.5:
		_retry_timer = 0.0
		_try_setup()


func _try_setup():
	var humanoid := _find_local_humanoid()
	if humanoid == null:
		return

	var xr_origin: XROrigin3D = humanoid.find_child("XROrigin3D")
	if xr_origin == null:
		return

	var right_hand: XRController3D = xr_origin.find_child("RightHand")

	var is_vr := false
	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		is_vr = true

	if _setup_done:
		return

	var weapon_list: Array[Node3D] = []
	if is_vr and right_hand:
		_create_right_saber(right_hand)
		weapon_list.append(right_saber)
	_create_player_blaster(humanoid, right_hand, is_vr)
	weapon_list.append(player_blaster)

	weapon_mgr = WeaponManager.new()
	weapon_mgr.name = "WeaponManager"
	add_child(weapon_mgr)
	weapon_mgr.setup(right_hand if is_vr else null, weapon_list, is_vr)
	_connect_combat_sync()

	if is_vr:
		print("Combat: VR mode — Lightsaber + Blaster. B to switch. No weapon by default.")
	else:
		print("Combat: Desktop mode — Blaster only. Press 1 to equip, click to fire, 0 to holster.")

	if spawn_test_saber and test_saber == null and is_vr:
		_spawn_test_saber(humanoid)

	if spawn_blaster_npc and blaster_npc == null:
		_spawn_blaster_npc(humanoid)

	_setup_done = true
	set_physics_process(false)
	print("Combat: Setup complete")


func _create_right_saber(right_hand: XRController3D):
	right_saber = _create_saber(player_blade_color)
	get_parent().add_child(right_saber)
	right_saber.target_node = right_hand
	right_saber._set_global_xf(right_hand.global_transform * right_saber.grip_offset)


func _create_player_blaster(humanoid: Node3D, right_hand: XRController3D, is_vr: bool):
	player_blaster = PlayerBlaster.new()
	player_blaster.bolt_color = player_bolt_color
	player_blaster._bolt_parent = get_parent()
	player_blaster.is_vr = is_vr
	if is_vr and right_hand:
		player_blaster.target_node = right_hand
	else:
		player_blaster._character = humanoid as CharacterBody3D
	get_parent().add_child(player_blaster)


func _connect_combat_sync():
	var csync := get_parent().get_node_or_null("CombatSync") as CombatSync
	if csync:
		weapon_mgr.combat_sync = csync
		player_blaster.combat_sync = csync
		csync._local_weapon_manager = weapon_mgr
		csync.init_local_health()


func _spawn_test_saber(humanoid: Node3D):
	test_saber = _create_saber(test_blade_color)
	get_parent().add_child(test_saber)

	var spawn_pos := humanoid.global_position + humanoid.global_transform.basis * test_saber_offset
	test_saber.global_position = spawn_pos
	test_saber.rotation = Vector3(deg_to_rad(-15), deg_to_rad(30), 0)
	print("Combat: Test saber spawned")


func _spawn_blaster_npc(humanoid: Node3D):
	blaster_npc = BlasterNPC.new()
	blaster_npc.target_node = humanoid
	blaster_npc._bolt_parent = get_parent()
	var xr_origin: XROrigin3D = humanoid.find_child("XROrigin3D")
	if xr_origin:
		blaster_npc.saber_hand = xr_origin.find_child("RightHand")
	get_parent().add_child(blaster_npc)

	var spawn_pos := humanoid.global_position + humanoid.global_transform.basis * npc_offset
	blaster_npc.global_position = spawn_pos
	print("Combat: Blaster NPC spawned")


func _create_saber(color: Color) -> Lightsaber:
	var saber := Lightsaber.new()
	saber.blade_color = color
	return saber


func _find_local_humanoid() -> Node3D:
	var workspace := get_parent()
	var humanoid = workspace.get_node_or_null("humanoid")
	if humanoid:
		return humanoid

	for child in workspace.get_children():
		if child is CharacterBody3D:
			if child.find_child("XROrigin3D"):
				return child
	return null
