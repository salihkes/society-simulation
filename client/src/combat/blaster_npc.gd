extends Node3D
class_name BlasterNPC
## Lightsaber practice target that fires slow bolts at target_node.

@export var fire_interval := 2.2
@export var bolt_color := Color(1.0, 0.15, 0.1)
@export var bolt_speed := 12.0
## Height above target_node's origin to aim at.
@export var aim_height_offset := 1.0
## 0 aims at the body, 1 at saber_hand.
@export var aim_saber_bias := 0.5
@export var body_color := Color(0.6, 0.15, 0.15)

var target_node: Node3D = null
var saber_hand: Node3D = null
var _fire_timer := 0.0
var _bolt_parent: Node3D = null

var body_mesh: MeshInstance3D
var gun_mesh: MeshInstance3D
var muzzle_point: Marker3D


func _ready():
	_build_body()
	_build_gun()
	_fire_timer = 0.5


func _physics_process(delta: float):
	if target_node == null or not is_instance_valid(target_node):
		return

	var target_pos := target_node.global_position + Vector3(0, aim_height_offset, 0)
	var look_pos := Vector3(target_pos.x, global_position.y, target_pos.z)
	if look_pos.distance_to(global_position) > 0.1:
		look_at(look_pos, Vector3.UP)

	_fire_timer -= delta
	if _fire_timer <= 0.0:
		_fire_timer = fire_interval
		_fire_at_target(target_pos)


func _fire_at_target(target_pos: Vector3):
	var bolt := BlasterBolt.new()
	bolt.bolt_color = bolt_color
	bolt.speed = bolt_speed

	var parent := _bolt_parent if _bolt_parent else get_parent()
	parent.add_child(bolt)

	var muzzle_pos := muzzle_point.global_position

	# Aim partly at the saber hand so bolts come where the blade already is.
	var aim_pos := target_pos
	if saber_hand and is_instance_valid(saber_hand) and aim_saber_bias > 0.0:
		var hand_pos := saber_hand.global_position
		aim_pos = target_pos.lerp(hand_pos, aim_saber_bias)

	var direction := (aim_pos - muzzle_pos).normalized()
	bolt.fire(muzzle_pos, direction)


func _build_body():
	body_mesh = MeshInstance3D.new()
	body_mesh.name = "Body"
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.4
	mesh.height = 1.8
	body_mesh.mesh = mesh
	body_mesh.position = Vector3(0, 0.9, 0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = body_color
	mat.roughness = 0.7
	body_mesh.material_override = mat

	add_child(body_mesh)

	var head_mesh := MeshInstance3D.new()
	head_mesh.name = "Head"
	var head := SphereMesh.new()
	head.radius = 0.25
	head_mesh.mesh = head
	head_mesh.position = Vector3(0, 2.05, 0)

	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = body_color.lightened(0.2)
	head_mat.roughness = 0.6
	head_mesh.material_override = head_mat

	add_child(head_mesh)

	for i in [-1, 1]:
		var eye := MeshInstance3D.new()
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = 0.05
		eye.mesh = eye_mesh
		eye.position = Vector3(0.1 * i, 2.1, -0.2)
		var eye_mat := StandardMaterial3D.new()
		eye_mat.albedo_color = Color(1, 0.2, 0.1)
		eye_mat.emission_enabled = true
		eye_mat.emission = Color(1, 0.2, 0.1)
		eye_mat.emission_energy_multiplier = 3.0
		eye.material_override = eye_mat
		add_child(eye)


func _build_gun():
	gun_mesh = MeshInstance3D.new()
	gun_mesh.name = "Gun"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.04
	mesh.bottom_radius = 0.06
	mesh.height = 0.8
	gun_mesh.mesh = mesh
	gun_mesh.rotation.x = deg_to_rad(90)
	gun_mesh.position = Vector3(0.5, 1.2, -0.4)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.2, 0.22)
	mat.metallic = 0.9
	mat.roughness = 0.2
	gun_mesh.material_override = mat

	add_child(gun_mesh)

	muzzle_point = Marker3D.new()
	muzzle_point.name = "MuzzlePoint"
	muzzle_point.position = Vector3(0.5, 1.2, -0.8)
	add_child(muzzle_point)
