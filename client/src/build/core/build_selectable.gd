class_name BuildSelectable
extends RefCounted

## Which objects the build tools may select; a part inside a "Group*" selects the group.

const EXCLUDED_ROOT_CHILDREN := [
	"humanoid", "Lightning", "InteractiveObjects",
	"SelectionMarkers", "FreeCamera", "CameraToggleUI",
]


static func is_local_workspace(scene_root: Node) -> bool:
	return scene_root != null and scene_root.name == "localworkspace"


## The object's `locked`, or its parent's when the object has none.
static func is_locked(obj: Node3D) -> bool:
	var locked_value = obj.get("locked")
	if locked_value == null and obj.get_parent():
		locked_value = obj.get_parent().get("locked")
	return locked_value == true


## Returns null if the hit belongs to nothing selectable.
static func find_selectable_parent(node: Node, scene_root: Node) -> Node3D:
	if node == null or scene_root == null:
		return null

	var local_mode := is_local_workspace(scene_root)
	var current: Node = node

	while current:
		if current is Node3D:
			if _is_never_selectable(current, scene_root):
				return null
			var parent := current.get_parent()
			if parent and _is_top_container(parent, scene_root):
				if not local_mode and not current.has_meta("is_plot_object"):
					return null
				if is_locked(current):
					return null
				return current
			if parent and parent is Node3D and parent.name.begins_with("Group"):
				var grandparent := parent.get_parent()
				if grandparent and _is_top_container(grandparent, scene_root):
					return null if is_locked(parent) else parent
		current = current.get_parent()

	return null


static func _is_never_selectable(node: Node, scene_root: Node) -> bool:
	if node.name == "SelectionMarkers" or has_ancestor_named(node, "SelectionMarkers"):
		return true
	if node.name == "humanoid" or has_ancestor_named(node, "humanoid"):
		return true
	if node == scene_root:
		return true
	return node.name.contains("Lightning") or node.name.contains("Camera")


static func _is_top_container(node: Node, scene_root: Node) -> bool:
	return node == scene_root or node.name == "InteractiveObjects"


static func all_selectable(scene_root: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if scene_root == null:
		return result

	var local_mode := is_local_workspace(scene_root)
	var containers: Array[Node] = [scene_root]
	if scene_root.has_node("InteractiveObjects"):
		containers.append(scene_root.get_node("InteractiveObjects"))

	for container in containers:
		for child in container.get_children():
			if not (child is Node3D):
				continue
			if container == scene_root and child.name in EXCLUDED_ROOT_CHILDREN:
				continue
			if not local_mode and not child.has_meta("is_plot_object"):
				continue
			if is_locked(child):
				continue
			result.append(child)

	return result


static func get_aabb(obj: Node3D) -> AABB:
	var inv := obj.global_transform.affine_inverse()
	var result := AABB()
	var found := false
	var stack: Array = [obj]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is VisualInstance3D:
			var box: AABB = (inv * node.global_transform) * node.get_aabb()
			result = result.merge(box) if found else box
			found = true
		for child in node.get_children():
			if child is Node3D:
				stack.push_back(child)
	if not found:
		return AABB(Vector3.ZERO, Vector3.ONE)
	return result


static func has_ancestor_named(node: Node, ancestor_name: String) -> bool:
	var current := node.get_parent()
	while current:
		if current.name == ancestor_name:
			return true
		current = current.get_parent()
	return false


## A single part of a "Group*" under `roots` is its own paint target; null for locked.
static func paint_target(node: Node, roots: Array) -> Node3D:
	var current = node
	var found_part: Node3D = null

	while current:
		if current is Node3D:
			if current.name == "SelectionMarkers" or has_ancestor_named(current, "SelectionMarkers"):
				return null
			if current.name == "humanoid" or has_ancestor_named(current, "humanoid"):
				return null
			if String(current.name) in roots:
				return null
			if current.name.contains("Lightning") or current.name.contains("Camera"):
				return null

			var parent = current.get_parent()
			if parent and (String(parent.name) in roots or parent.name == "InteractiveObjects"):
				found_part = current
				break
			elif parent and parent is Node3D and parent.name.begins_with("Group"):
				var grandparent = parent.get_parent()
				if grandparent and String(grandparent.name) in roots:
					found_part = current
					break
		current = current.get_parent()

	if found_part and is_locked(found_part):
		return null
	return found_part


static func mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []

	if node is MeshInstance3D:
		meshes.append(node)
		return meshes

	for child in node.get_children():
		if child is MeshInstance3D:
			meshes.append(child)
		else:
			meshes.append_array(mesh_instances(child))

	return meshes


## A fresh copy to edit: the override, else the mesh's own, else a new material.
static func editable_surface_material(mesh_instance: MeshInstance3D, surface: int) -> Material:
	var material = mesh_instance.get_surface_override_material(surface)
	if not material:
		material = mesh_instance.mesh.surface_get_material(surface)
		if material:
			material = material.duplicate()
		else:
			material = StandardMaterial3D.new()
	else:
		material = material.duplicate()
	return material
