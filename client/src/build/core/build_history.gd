class_name BuildHistory
extends Node

## Undo/redo for the build tools; detached nodes are freed only when their record leaves.

signal changed

const MAX_UNDO := 100

var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []


## Call right after adding new nodes to the scene.
func record_created(nodes: Array, action := "Create") -> void:
	var entries: Array[Dictionary] = []
	for node in nodes:
		if is_instance_valid(node) and node.is_inside_tree():
			entries.append({"node": node, "parent": node.get_parent()})
	if entries.is_empty():
		return
	_push({"type": "create", "action": action, "entries": entries})


## Use instead of queue_free() for anything undoable: detaches the nodes.
func delete_nodes(nodes: Array, action := "Delete") -> void:
	var entries: Array[Dictionary] = []
	for node in nodes:
		if is_instance_valid(node) and node.is_inside_tree():
			var parent := (node as Node).get_parent()
			entries.append({"node": node, "parent": parent})
			parent.remove_child(node)
	if entries.is_empty():
		return
	_push({"type": "delete", "action": action, "entries": entries})


## Pass the returned token to commit_transform() when the edit ends.
func begin_transform(objects: Array) -> Array[Dictionary]:
	var token: Array[Dictionary] = []
	for obj in objects:
		if is_instance_valid(obj) and obj is Node3D:
			token.append({"node": obj, "before": (obj as Node3D).global_transform})
	return token


func commit_transform(token: Array[Dictionary], action := "Transform") -> void:
	var entries: Array[Dictionary] = []
	for snap in token:
		var obj = snap.node
		if not is_instance_valid(obj) or not obj.is_inside_tree():
			continue
		var after: Transform3D = obj.global_transform
		if not _transforms_equal(snap.before, after):
			entries.append({"node": obj, "before": snap.before, "after": after})
	if entries.is_empty():
		return
	_push({"type": "transform", "action": action, "entries": entries})


func record_property(object: Object, property: String, before, after, action := "Edit") -> void:
	if not is_instance_valid(object) or before == after:
		return
	_push({
		"type": "property", "action": action,
		"entries": [{"node": object, "property": property, "before": before, "after": after}],
	})


func can_undo() -> bool:
	return not _undo_stack.is_empty()


func can_redo() -> bool:
	return not _redo_stack.is_empty()


func undo() -> void:
	if _undo_stack.is_empty():
		print("Nothing to undo")
		return
	var record: Dictionary = _undo_stack.pop_back()
	_apply(record, true)
	_redo_stack.append(record)
	print("Undid: ", record.action)
	changed.emit()


func redo() -> void:
	if _redo_stack.is_empty():
		print("Nothing to redo")
		return
	var record: Dictionary = _redo_stack.pop_back()
	_apply(record, false)
	_undo_stack.append(record)
	print("Redid: ", record.action)
	changed.emit()


func _push(record: Dictionary) -> void:
	_undo_stack.append(record)
	while _undo_stack.size() > MAX_UNDO:
		_discard(_undo_stack.pop_front())
	for old in _redo_stack:
		_discard(old)
	_redo_stack.clear()
	changed.emit()


func _apply(record: Dictionary, is_undo: bool) -> void:
	match record.type:
		"create":
			if is_undo:
				_detach_entries(record.entries)
			else:
				_reattach_entries(record.entries)
		"delete":
			if is_undo:
				_reattach_entries(record.entries)
			else:
				_detach_entries(record.entries)
		"transform":
			for entry in record.entries:
				var obj = entry.node
				if is_instance_valid(obj) and obj.is_inside_tree():
					obj.global_transform = entry.before if is_undo else entry.after
		"property":
			for entry in record.entries:
				var obj = entry.node
				if is_instance_valid(obj):
					obj.set(entry.property, entry.before if is_undo else entry.after)


func _detach_entries(entries: Array) -> void:
	for entry in entries:
		var node = entry.node
		if is_instance_valid(node) and node.is_inside_tree():
			node.get_parent().remove_child(node)


func _reattach_entries(entries: Array) -> void:
	for entry in entries:
		var node = entry.node
		var parent = entry.parent
		if is_instance_valid(node) and not node.is_inside_tree() \
				and is_instance_valid(parent) and parent.is_inside_tree():
			parent.add_child(node)


## Nodes in the tree are left alone.
func _discard(record: Dictionary) -> void:
	if record.type != "create" and record.type != "delete":
		return
	for entry in record.entries:
		var node = entry.node
		if is_instance_valid(node) and not node.is_inside_tree():
			node.queue_free()


func _transforms_equal(a: Transform3D, b: Transform3D) -> bool:
	return a.is_equal_approx(b)


func _exit_tree() -> void:
	for record in _undo_stack:
		_discard(record)
	for record in _redo_stack:
		_discard(record)
	_undo_stack.clear()
	_redo_stack.clear()
