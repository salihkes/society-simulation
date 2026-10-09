extends RefCounted
class_name GrabModule
## Picks up, carries and throws grabbable objects on desktop and in VR, over the network.

var character: CharacterBody3D
var character_model: Node3D
var xr_origin: XROrigin3D
var xr_camera: XRCamera3D

var left_controller: Node3D
var right_controller: Node3D

var left_hold_point: Node3D
var right_hold_point: Node3D
var camera_hold_point: Node3D

var is_vr_active := false

var held_left: Node3D = null
var held_right: Node3D = null
var held_normal: Node3D = null

var max_camera_grab_distance := 50.0
var max_hand_grab_distance := 25.0
var desktop_hold_distance := 1.2
var desktop_rotation_offset := Basis()

var net_update_interval := 0.1

# Recent hold point positions, for the throw velocity.
var _prev_left_positions: Array = []
var _prev_right_positions: Array = []
var _prev_camera_positions: Array = []
var _max_history := 6

var _net_update_timer := 0.0
var _last_sent_xf := {}


func setup(char: CharacterBody3D, model: Node3D) -> void:
	character = char
	character_model = model
	xr_origin = character.find_child("XROrigin3D")
	xr_camera = xr_origin.find_child("XRCamera3D") if xr_origin else null

	print("DEBUG: GrabModule setup - Character: ", character, " Model: ", character_model)
	print("DEBUG: XR Origin: ", xr_origin, " XR Camera: ", xr_camera)

	_ensure_hold_points()
	_connect_vr_controllers()


func set_vr_active(active: bool) -> void:
	is_vr_active = active


func update(delta: float) -> void:
	_record_points_history()

	if not is_vr_active:
		_update_desktop_grab()
		if held_normal:
			held_normal.global_transform = _compute_desktop_hold_transform()

	_net_update_timer += delta
	if _net_update_timer >= net_update_interval:
		_net_update_timer = 0.0
		_send_inflight_updates()


## Under each controller and the camera (the XR camera, else CamOrigin, else the model).
func _ensure_hold_points() -> void:
	if xr_origin:
		left_controller = xr_origin.find_child("LeftHand")
		right_controller = xr_origin.find_child("RightHand")

		if left_controller:
			left_hold_point = left_controller.get_node_or_null("HoldPoint")
		if left_hold_point == null:
			left_hold_point = _new_hold_point(left_controller, Vector3(0, 0, -1.0))
		if right_controller:
			right_hold_point = right_controller.get_node_or_null("HoldPoint")
			if right_hold_point == null:
				right_hold_point = _new_hold_point(right_controller, Vector3(0, 0, -1.0))

	var desktop_parent: Node3D = null
	if xr_camera:
		desktop_parent = xr_camera
	else:
		var cam_origin = character.find_child("CamOrigin")
		desktop_parent = cam_origin if cam_origin else character_model

	if desktop_parent:
		camera_hold_point = desktop_parent.get_node_or_null("HoldPoint")
		if camera_hold_point == null:
			camera_hold_point = Node3D.new()
			camera_hold_point.name = "HoldPoint"
			desktop_parent.add_child(camera_hold_point)
		camera_hold_point.transform = Transform3D(Basis(), Vector3(0, 0, -1.2))


func _new_hold_point(parent: Node3D, offset: Vector3) -> Node3D:
	var point := Node3D.new()
	point.name = "HoldPoint"
	parent.add_child(point)
	point.transform = Transform3D(Basis(), offset)
	return point


func _connect_vr_controllers() -> void:
	if not xr_origin:
		print("DEBUG: No XR origin found")
		return

	left_controller = xr_origin.find_child("LeftHand")
	right_controller = xr_origin.find_child("RightHand")

	print("DEBUG: Found controllers - Left: ", left_controller, " Right: ", right_controller)

	if left_controller:
		print("DEBUG: Connecting left controller signals")
		_connect_hand(left_controller, _on_left_button_pressed, _on_left_button_released)
	if right_controller:
		print("DEBUG: Connecting right controller signals")
		_connect_hand(right_controller, _on_right_button_pressed, _on_right_button_released)


func _connect_hand(hand: Node3D, pressed: Callable, released: Callable) -> void:
	if not hand.button_pressed.is_connected(pressed):
		hand.button_pressed.connect(pressed)
	if not hand.button_released.is_connected(released):
		hand.button_released.connect(released)


## Pressing again or releasing the key drops what is held.
func _update_desktop_grab() -> void:
	var grab_pressed := false
	var grab_released := false

	if InputMap.has_action("grab"):
		grab_pressed = Input.is_action_just_pressed("grab")
		grab_released = Input.is_action_just_released("grab")
	else:
		grab_pressed = Input.is_action_just_pressed("ui_select") or Input.is_action_just_pressed("ui_accept")
		grab_released = Input.is_action_just_released("ui_select") or Input.is_action_just_released("ui_accept")

	if grab_pressed:
		if held_normal:
			_drop(held_normal, camera_hold_point, _prev_camera_positions)
			held_normal = null
		else:
			var target = _ray_pick_from_camera()
			if target:
				_grab_object(target, camera_hold_point)
				_notify_network_grab(target)
				held_normal = target
	elif grab_released and held_normal:
		_drop(held_normal, camera_hold_point, _prev_camera_positions)
		held_normal = null


func _drop(obj: Node3D, hold_point: Node3D, history: Array) -> void:
	var v = _estimate_velocity(history)
	_release_object(obj, hold_point, v)
	_notify_network_release(obj, v)


## Returns what the hand holds afterwards.
func _toggle_hand(label: String, held: Node3D, controller: Node3D, hold_point: Node3D,
		history: Array) -> Node3D:
	print("DEBUG: ", label, " grip/trigger pressed, held_", label.to_lower(), ": ", held)
	if held:
		_drop(held, hold_point, history)
		return null
	var target = _ray_pick_from_hand(controller)
	print("DEBUG: ", label, " hand ray pick result: ", target)
	if target:
		_grab_object(target, hold_point)
		_notify_network_grab(target)
		return target
	return held


func _on_left_button_pressed(name: String) -> void:
	print("DEBUG: Left button pressed: ", name)
	if name == "grip_click" or name == "trigger_click":
		held_left = _toggle_hand("Left", held_left, left_controller, left_hold_point,
				_prev_left_positions)


func _on_left_button_released(_name: String) -> void:
	pass


func _on_right_button_pressed(name: String) -> void:
	print("DEBUG: Right button pressed: ", name)
	if name == "grip_click" or name == "trigger_click":
		held_right = _toggle_hand("Right", held_right, right_controller, right_hold_point,
				_prev_right_positions)


func _on_right_button_released(_name: String) -> void:
	pass


func _ray_pick_from_camera() -> Node3D:
	var camera := character.get_viewport().get_camera_3d()
	if camera == null:
		camera = xr_camera
	if camera == null:
		return null

	var from = camera.global_transform.origin
	var to = from + (-camera.global_transform.basis.z) * max_camera_grab_distance
	return _ray_pick(from, to)


## A point and sphere query, then rays along the hand's axes, then the closest in the scene.
func _ray_pick_from_hand(hand_node: Node3D) -> Node3D:
	if hand_node == null:
		print("DEBUG: hand_node is null")
		return null

	var sphere_result = _sphere_pick_from_hand(hand_node)
	if sphere_result:
		print("DEBUG: Found object via sphere pick: ", sphere_result)
		return sphere_result

	var from = hand_node.global_transform.origin
	var b := hand_node.global_transform.basis
	var directions = [-b.z, b.z, b.x, -b.x, b.y, -b.y]

	for dir in directions:
		var to = from + dir * max_hand_grab_distance
		print("DEBUG: Ray picking from hand: ", from, " to ", to, " direction: ", dir, " distance: ", max_hand_grab_distance)
		var result = _ray_pick(from, to)
		if result:
			print("DEBUG: Found object with direction: ", dir)
			return result

	print("DEBUG: No objects found in any direction")

	return _find_closest_grabbable_by_distance(hand_node.global_transform.origin)


func _sphere_pick_from_hand(hand_node: Node3D) -> Node3D:
	if hand_node == null:
		return null

	var origin := hand_node.global_transform.origin
	var space_state = character.get_world_3d().direct_space_state
	var query = PhysicsPointQueryParameters3D.new()
	query.position = origin
	query.collision_mask = 0xFFFFFFFF
	query.exclude = [character]

	var results = space_state.intersect_point(query)
	print("DEBUG: Sphere pick results: ", results)
	var closest_obj := _closest_grabbable(results, origin, false)
	if closest_obj != null:
		return closest_obj

	var area_query = PhysicsShapeQueryParameters3D.new()
	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = max_hand_grab_distance
	area_query.shape = sphere_shape
	area_query.transform = Transform3D(Basis(), origin)
	area_query.collision_mask = 0xFFFFFFFF
	area_query.exclude = [character]

	var area_results = space_state.intersect_shape(area_query)
	print("DEBUG: Area sphere pick results: ", area_results)
	return _closest_grabbable(area_results, origin, true)


func _closest_grabbable(results: Array, origin: Vector3, in_area: bool) -> Node3D:
	var closest_obj: Node3D = null
	var closest_distance = INF
	for result in results:
		var grabbable = _resolve_grabbable(result.get("collider"))
		if not grabbable:
			continue
		var distance = origin.distance_to(grabbable.global_transform.origin)
		if in_area:
			print("DEBUG: Found grabbable object in area at distance: ", distance)
		else:
			print("DEBUG: Found grabbable object at distance: ", distance, " max: ", max_hand_grab_distance)
		if distance < closest_distance and distance <= max_hand_grab_distance:
			closest_distance = distance
			closest_obj = grabbable
	return closest_obj


## Walks the whole scene.
func _find_closest_grabbable_by_distance(hand_position: Vector3) -> Node3D:
	print("DEBUG: Using distance-based fallback to find grabbable objects")
	var closest_obj: Node3D = null
	var closest_distance = INF

	for node in _get_all_nodes(character.get_tree().root):
		if not (node is Node3D and (node.is_in_group("grabbable") or node is RigidBody3D)):
			continue
		var distance = hand_position.distance_to(node.global_transform.origin)
		print("DEBUG: Found grabbable object: ", node.name, " at distance: ", distance)
		if distance < closest_distance and distance <= max_hand_grab_distance:
			closest_distance = distance
			closest_obj = node

	if closest_obj:
		print("DEBUG: Distance fallback found: ", closest_obj.name, " at distance: ", closest_distance)
	else:
		print("DEBUG: Distance fallback found no objects within range")

	return closest_obj


func _get_all_nodes(node: Node) -> Array:
	var nodes = []
	if node is Node3D:
		nodes.append(node)
	for child in node.get_children():
		nodes.append_array(_get_all_nodes(child))
	return nodes


func _ray_pick(from: Vector3, to: Vector3) -> Node3D:
	var space_state = character.get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [character]
	var result = space_state.intersect_ray(query)
	print("DEBUG: Ray cast result: ", result)
	if result.is_empty():
		print("DEBUG: No objects hit by ray")
		return null
	var collider = result.get("collider")
	print("DEBUG: Hit collider: ", collider, " type: ", collider.get_class() if collider else "null")
	var grabbable = _resolve_grabbable(collider)
	print("DEBUG: Resolved grabbable: ", grabbable)
	return grabbable


func _resolve_grabbable(node: Object) -> Node3D:
	var cur = node as Node
	print("DEBUG: Resolving grabbable for node: ", cur, " class: ", cur.get_class() if cur else "null")
	while cur and cur is Node3D:
		print("DEBUG: Checking node: ", cur.name, " groups: ", cur.get_groups())
		if cur.is_in_group("grabbable"):
			print("DEBUG: Found grabbable group member: ", cur)
			return cur
		if cur is RigidBody3D:
			print("DEBUG: Found RigidBody3D: ", cur)
			return cur
		cur = cur.get_parent()
	print("DEBUG: No grabbable object found")
	return null


## Remembers the old physics state in metadata; reparented in VR, placed by transform on desktop.
func _grab_object(obj: Node3D, hold_point: Node3D) -> void:
	if obj == null or hold_point == null:
		return

	print("DEBUG: Grabbing object: ", obj.name, " at hold point: ", hold_point.name)
	print("DEBUG: Hold point position: ", hold_point.global_transform.origin)
	print("DEBUG: Object position before grab: ", obj.global_transform.origin)

	obj.set_meta("grab_prev_parent_path", obj.get_parent().get_path())
	obj.set_meta("grab_prev_global_transform", obj.global_transform)

	var rb := obj as RigidBody3D
	if rb:
		obj.set_meta("grab_prev_freeze", rb.freeze)
		obj.set_meta("grab_prev_collision_layer", rb.collision_layer)
		obj.set_meta("grab_prev_collision_mask", rb.collision_mask)
		rb.freeze = true
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
		rb.collision_layer = 0
		rb.collision_mask = 0

	if hold_point == camera_hold_point:
		obj.global_transform = _compute_desktop_hold_transform()
		print("DEBUG: Desktop mode - Object positioned at: ", obj.global_transform.origin)
	else:
		if obj.get_parent() != hold_point:
			obj.reparent(hold_point, false)
		obj.transform = Transform3D(Basis(), Vector3(0, 0, 0))
		print("DEBUG: VR mode - Object positioned at: ", obj.global_transform.origin)
		print("DEBUG: Hold point global position: ", hold_point.global_transform.origin)


func _compute_desktop_hold_transform() -> Transform3D:
	var vc: Camera3D = character.get_viewport().get_camera_3d()
	var basis := Basis()
	var forward := Vector3.FORWARD
	if vc:
		basis = vc.global_transform.basis
		forward = -basis.z
	else:
		basis = character.global_transform.basis
		forward = -basis.z
	var origin = character.global_transform.origin + forward.normalized() * desktop_hold_distance
	basis = basis * desktop_rotation_offset
	return Transform3D(basis, origin)


## Back under its previous parent (or the character's parent).
func _release_object(obj: Node3D, hold_point: Node3D, throw_velocity: Vector3) -> void:
	if obj == null:
		return

	var prev_parent_path = obj.get_meta("grab_prev_parent_path")
	var prev_parent = character.get_node_or_null(prev_parent_path) if prev_parent_path else null

	if prev_parent and prev_parent is Node:
		if obj.get_parent() != prev_parent:
			obj.reparent(prev_parent, true)
	else:
		var fallback_parent = character.get_parent()
		if fallback_parent and obj.get_parent() != fallback_parent:
			obj.reparent(fallback_parent, true)

	var rb := obj as RigidBody3D
	if rb:
		_restore_body(rb, throw_velocity)

	obj.set_meta("grab_prev_parent_path", null)
	obj.set_meta("grab_prev_global_transform", null)
	obj.set_meta("grab_prev_freeze", null)
	obj.set_meta("grab_prev_collision_layer", null)
	obj.set_meta("grab_prev_collision_mask", null)
	var key = obj.get_instance_id()
	if _last_sent_xf.has(key):
		_last_sent_xf.erase(key)


func _restore_body(rb: RigidBody3D, throw_velocity: Vector3) -> void:
	var was_frozen = rb.get_meta("grab_prev_freeze")
	var prev_collision_layer = rb.get_meta("grab_prev_collision_layer")
	var prev_collision_mask = rb.get_meta("grab_prev_collision_mask")
	rb.freeze = was_frozen if was_frozen != null else false
	rb.collision_layer = prev_collision_layer if prev_collision_layer != null else 1
	rb.collision_mask = prev_collision_mask if prev_collision_mask != null else 1
	if throw_velocity.length() > 0.01:
		rb.linear_velocity = throw_velocity


func _record_points_history() -> void:
	if left_hold_point:
		_push_history(_prev_left_positions, left_hold_point.global_transform.origin)
	if right_hold_point:
		_push_history(_prev_right_positions, right_hold_point.global_transform.origin)
	if not is_vr_active:
		_prev_camera_positions.append(_compute_desktop_hold_transform().origin)
	elif camera_hold_point:
		_push_history(_prev_camera_positions, camera_hold_point.global_transform.origin)


func _push_history(history: Array, point: Vector3) -> void:
	history.append(point)
	if history.size() > _max_history:
		history.pop_front()


## From the last two frames of history.
func _estimate_velocity(history: Array) -> Vector3:
	if history.size() < 2:
		return Vector3.ZERO
	var p0: Vector3 = history[max(0, history.size() - 3)]
	var p1: Vector3 = history[history.size() - 1]
	var displacement = p1 - p0
	return displacement * 30.0


func _network_controller() -> Node:
	if not character:
		return null
	var tree = character.get_tree()
	if tree == null:
		return null
	var root = tree.root
	var nc = root.find_child("network_controller", true, false)
	if not nc:
		nc = root.find_child("NetworkController", true, false)
	return nc


func _network_objects():
	var nc = _network_controller()
	return nc.get("objects") if nc else null


func _notify_network_grab(obj: Node3D) -> void:
	var objects = _network_objects()
	if objects:
		objects.notify_object_grabbed(obj)


func _notify_network_release(obj: Node3D, throw_velocity: Vector3) -> void:
	var objects = _network_objects()
	if objects:
		objects.notify_object_released_with_path(obj.get_path(), obj.global_transform, throw_velocity)


func _notify_network_update(obj: Node3D, xf: Transform3D) -> void:
	var objects = _network_objects()
	if objects:
		objects.notify_object_update_with_path(obj.get_path(), xf)


## Only when the object moved over 2 cm or turned.
func _send_inflight_updates() -> void:
	var objs := []
	if held_normal:
		objs.append(held_normal)
	if held_left:
		objs.append(held_left)
	if held_right:
		objs.append(held_right)
	for obj in objs:
		if not obj:
			continue
		var key = obj.get_instance_id()
		var xf: Transform3D = obj.global_transform
		if _last_sent_xf.has(key) and not _moved_enough(xf, _last_sent_xf[key]):
			continue
		_notify_network_update(obj, xf)
		_last_sent_xf[key] = xf


func _moved_enough(xf: Transform3D, prev: Transform3D) -> bool:
	var pos_delta = xf.origin.distance_to(prev.origin)
	var rot_changed = xf.basis.z.dot(prev.basis.z) < 0.999
	return pos_delta > 0.02 or rot_changed
