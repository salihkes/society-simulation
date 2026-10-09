extends Node3D
## Visual-only kabuki actor: the player's humanoid mesh and rig, costumed and posed from score keys.
const HUMAN := "res://assets/entities/character/humanoid.tscn"
const Rig := preload("res://src/character/limb_rig.gd")
var rig := Rig.new()
var model: Node3D
var fan: Node3D
var joints: Dictionary = {}


## Call once after adding the actor to the tree.
func build(color: Color, fan_color: Color) -> void:
	var source := (load(HUMAN) as PackedScene).instantiate()
	model = source.get_node("CharacterModel")
	source.remove_child(model)
	source.free()
	var bubble := model.get_node_or_null("ChatBubble")
	if bubble:
		bubble.free()
	add_child(model)
	# Humanoid mesh soles are at -3 in model space.
	model.position.y = 3.0
	# Choreography yaw 0 faces stage +Z; the humanoid mesh faces -Z.
	model.rotation.y = PI
	rig.resolve(model)
	for part in [rig.torso, rig.left_arm, rig.right_arm, rig.left_leg, rig.right_leg]:
		var meshes: Array = part.find_children("*", "MeshInstance3D", true, false)
		if part is MeshInstance3D:
			meshes.append(part)
		for mesh in meshes:
			mesh.material_override = material(color)
	box(rig.torso, Vector3(2.08, 1.06, 0.32), Vector3.ZERO, Color("d6ac58"))
	for arm in [rig.left_arm, rig.right_arm]:
		box(arm, Vector3(1.12, 0.28, 1.12), Vector3(0, -1.25, 0), Color("d6ac58"))
	# The imported head is rotated 90 degrees, so hair is built in model space.
	var hair := Node3D.new()
	hair.name = "Hair"
	model.add_child(hair)
	box(hair, Vector3(1.85, 0.35, 1.1), Vector3(0, 2.18, 0), Color("17141d"))
	box(hair, Vector3(0.65, 0.65, 0.7), Vector3(0, 2.6, 0.1), Color("17141d"))
	_build_fan(fan_color)
	rig.resolve(model)
	for limb in [rig.left_arm, rig.right_arm, rig.left_leg, rig.right_leg]:
		joints[limb] = limb.position


func _build_fan(fan_color: Color) -> void:
	fan = Node3D.new()
	fan.name = "HeldFan"
	rig.right_arm.add_child(fan)
	fan.position = Vector3(0.5, -1.5, -0.65)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(12):
		var a := deg_to_rad(-65.0 + i * 130.0 / 12.0)
		var b := deg_to_rad(-65.0 + (i + 1) * 130.0 / 12.0)
		surface.add_vertex(Vector3.ZERO)
		surface.add_vertex(Vector3(sin(a), -cos(a), 0) * 1.5)
		surface.add_vertex(Vector3(sin(b), -cos(b), 0) * 1.5)
	surface.generate_normals()
	var paper := MeshInstance3D.new()
	paper.mesh = surface.commit()
	paper.material_override = material(fan_color)
	paper.material_override.cull_mode = BaseMaterial3D.CULL_DISABLED
	fan.add_child(paper)
	for i in range(13):
		var a := deg_to_rad(-65.0 + i * 130.0 / 12.0)
		var rib := box(fan, Vector3(0.025, 1.5, 0.04), Vector3(sin(a), -cos(a), -0.02) * 0.75, Color("d6ac58"))
		rib.rotation.z = a


## Angles in degrees; limbs are [pitch, spread].
func apply_pose(pose: Dictionary) -> void:
	position = Vector3(float(pose.x), 0, float(pose.z))
	rotation.y = deg_to_rad(float(pose.yaw))
	# Combined rotations about the existing joint preserve imported rest bases.
	for slot in ["left_arm", "right_arm", "left_leg", "right_leg"]:
		var limb: Node3D = rig.get(slot)
		var angles: Array = pose[slot]
		var rotation_basis := Basis.from_euler(Vector3(-deg_to_rad(angles[0]), 0, -deg_to_rad(angles[1])))
		rig.pose_about(limb, joints[limb], rotation_basis)
	var bow := Basis(Vector3.RIGHT, -deg_to_rad(float(pose.bow)))
	for limb in [rig.torso, rig.head, rig.hair]:
		rig.pose_about(limb, Vector3(0, -1, 0), bow)
	for limb in [rig.left_arm, rig.right_arm]:
		limb.transform = Transform3D(bow, Vector3(0, -1, 0) - bow * Vector3(0, -1, 0)) * limb.transform


static func material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	return mat


static func box(parent: Node3D, size: Vector3, offset: Vector3, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	mesh.mesh = shape
	mesh.material_override = material(color)
	mesh.position = offset
	parent.add_child(mesh)
	return mesh
