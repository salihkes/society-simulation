extends Node
## Puts garment meshes on a character, skinned to its skeleton, and hides covered body regions.

signal outfit_changed(ids: Array)

var skeleton: Skeleton3D
var model: Node3D
var catalog: Dictionary = {}
var equipped: Dictionary = {}


## `definitions`: garment id -> {slot, path, covers}.
func attach(body: Node3D, body_skeleton: Skeleton3D, definitions: Dictionary) -> void:
	model = body
	skeleton = body_skeleton
	catalog = definitions.duplicate(true)


## False, keeping the current outfit, for an unknown id, a shared slot or an unbindable garment.
func set_outfit(ids: Array) -> bool:
	var unique: Variant = _validated_ids(ids)
	if unique == null:
		return false
	if unique == get_outfit():
		return true
	# Build every new garment before removing the previous outfit.
	var pending: Dictionary = {}
	for id in unique:
		if equipped.has(id):
			continue
		var holder := _build_garment(id)
		if holder == null:
			_discard(pending)
			return false
		pending[id] = holder
	for id in equipped.keys():
		if not id in unique:
			equipped[id].free()
			equipped.erase(id)
	equipped.merge(pending)
	_refresh_coverage()
	outfit_changed.emit(get_outfit())
	return true


func get_outfit() -> Array:
	var ids: Array = equipped.keys()
	ids.sort()
	return ids


## Sorted unique ids, or null when one is unknown or two share a slot.
func _validated_ids(ids: Array) -> Variant:
	var unique: Array = []
	var slots: Dictionary = {}
	for id in ids:
		if not id is String or not catalog.has(id):
			return null
		if id in unique:
			continue
		var slot: String = catalog[id].slot
		if slots.has(slot):
			return null
		slots[slot] = id
		unique.append(id)
	unique.sort()
	return unique


## Null when the garment cannot be bound to the body skeleton.
func _build_garment(id: String) -> Node3D:
	var scene := load(String(catalog[id].path)) as PackedScene
	if scene == null:
		return null
	var garment := scene.instantiate() as Node3D
	model.add_child(garment)
	var meshes := garment.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		garment.free()
		return null
	for mesh: MeshInstance3D in meshes:
		if not _rebind_skin(mesh):
			garment.free()
			return null
	var holder := Node3D.new()
	holder.name = "Equipped_" + String(id)
	model.add_child(holder)
	for mesh: MeshInstance3D in meshes:
		mesh.reparent(holder, true)
		mesh.skeleton = mesh.get_path_to(skeleton)
		mesh.set_meta("preserve_materials", true)
		mesh.custom_aabb = AABB(Vector3(-1, -0.5, -1), Vector3(2, 3, 2))
	garment.free()
	return holder


## False when a bone is missing from the body.
func _rebind_skin(mesh: MeshInstance3D) -> bool:
	if mesh.skin == null:
		return false
	var src := mesh.get_node_or_null(mesh.skeleton) as Skeleton3D
	if src == null:
		return false
	var skin := mesh.skin.duplicate() as Skin
	for i in skin.get_bind_count():
		var bone := String(skin.get_bind_name(i))
		if bone == "":
			bone = src.get_bone_name(skin.get_bind_bone(i))
		if skeleton.find_bone(bone) < 0:
			return false
		skin.set_bind_name(i, bone)
	mesh.skin = skin
	return true


func _discard(pending: Dictionary) -> void:
	for node in pending.values():
		node.free()


func _refresh_coverage() -> void:
	var covered: Array = []
	for id in equipped:
		for region in catalog[id].get("covers", []):
			if not region in covered:
				covered.append(region)
	for mesh in model.find_children("Body*", "MeshInstance3D", true, false):
		var fallback := String(mesh.name).trim_prefix("Body")
		var region := String(mesh.get_meta("body_region", fallback))
		mesh.visible = not region in covered
