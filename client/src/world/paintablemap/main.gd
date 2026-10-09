extends Node3D
## Province map gameplay: hover, claim, occupy and defend provinces, and treaty popups.

@onready var province_map: ProvinceMap = $ProvinceMap

# Found in the hosting scene; a host without them gets detached stand-ins, so use them unguarded.
@onready var info_label: Label = _ui("InfoLabel", Label.new()) as Label
@onready var modified_label: Label = _ui("ModifiedLabel", Label.new()) as Label
@onready var treaty_popup: PanelContainer = _ui("TreatyPopup", PanelContainer.new()) as PanelContainer
@onready var treaty_info: Label = _ui("TreatyInfo", Label.new()) as Label
@onready var treaty_countdown: Label = _ui("TreatyCountdown", Label.new()) as Label
@onready var accept_button: Button = _ui("AcceptButton", Button.new()) as Button
@onready var reject_button: Button = _ui("RejectButton", Button.new()) as Button

var _ui_standins: Array[Node] = []
var _my_owner_id: String = ""
var _my_color: String = ""

var _incoming_treaty_id: String = ""
var _incoming_treaty_proposer: String = ""
## Unix time when the incoming treaty expires.
var _incoming_treaty_expires: float = 0.0

# When required, offline players' land cannot be occupied.
var _online_owner_ids: Array = []
var _require_online_to_occupy: bool = true


func _ui(control_name: String, standin: Node) -> Node:
	var scene := get_tree().current_scene
	var found := scene.find_child(control_name, true, false) if scene else null
	if found != null:
		standin.free()
		return found
	_ui_standins.append(standin)
	return standin


func _exit_tree() -> void:
	for n in _ui_standins:
		if is_instance_valid(n):
			n.free()
	_ui_standins.clear()


func _ready() -> void:
	province_map.province_hovered.connect(_on_hovered)
	province_map.owners_changed.connect(_on_owners_changed)
	province_map.data_changed.connect(_refresh_counts)

	accept_button.pressed.connect(_on_treaty_accept)
	reject_button.pressed.connect(_on_treaty_reject)

	treaty_popup.visible = false
	_refresh_counts()


func _process(delta: float) -> void:
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		return
	var pid := _raycast_province()
	province_map.set_hovered_province(pid)

	if treaty_popup.visible and _incoming_treaty_expires > 0.0:
		var remaining := _incoming_treaty_expires - Time.get_unix_time_from_system()
		if remaining <= 0.0:
			_close_treaty_popup()
		else:
			treaty_countdown.text = "Expires in %ds" % ceili(remaining)


## Left click acts on the province under the mouse; with Shift, proposes peace.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var pid := _raycast_province()
	if pid < 0:
		return
	if mb.shift_pressed:
		_on_shift_clicked(pid)
	else:
		_on_clicked(pid)


## The province under the mouse, ignoring the local player, or -1.
func _raycast_province() -> int:
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return -1
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := cam.project_ray_origin(mouse_pos)
	var ray_dir := cam.project_ray_normal(mouse_pos)

	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin,
		ray_origin + ray_dir * 5000.0
	)
	var local_player := _find_local_player()
	if local_player:
		query.exclude = [local_player.get_rid()]
	var result := space.intersect_ray(query)
	if result.is_empty():
		return -1

	var hit_point: Vector3 = result["position"]
	var uv: Vector2
	if province_map.sphere_mode:
		uv = _hit_to_uv_sphere(hit_point)
	else:
		uv = _hit_to_uv_plane(hit_point)
	return province_map.get_province_at_uv(uv)


func _find_local_player() -> Node3D:
	var workspace := get_tree().get_root().find_child("workspace", true, false)
	if not workspace:
		return null
	for child in workspace.get_children():
		if child is CharacterBody3D and child.get_node_or_null("LocalPlayer"):
			return child
	return null


func _hit_to_uv_plane(hit_point: Vector3) -> Vector2:
	var local := province_map.to_local(hit_point)
	return Vector2(
		local.x / province_map.plane_size.x + 0.5,
		local.z / province_map.plane_size.y + 0.5,
	)


## Inverts the SphereMesh layout: x = sin(u*TAU)*sin(v*PI), z = cos(u*TAU)*sin(v*PI).
func _hit_to_uv_sphere(hit_point: Vector3) -> Vector2:
	var local := province_map.to_local(hit_point).normalized()
	var u := fposmod(atan2(local.x, local.z), TAU) / TAU
	var v := acos(clampf(local.y, -1.0, 1.0)) / PI
	return Vector2(u, v)


func _on_hovered(pid: int) -> void:
	if pid < 0:
		info_label.text = ""
		return
	var parts: Array[String] = [province_map.get_province_name(pid)]
	var oid := province_map.get_province_owner(pid)
	if not oid.is_empty():
		var o := province_map.get_owner_data(oid)
		parts.append("(%s)" % o.get("name", oid))
	var occ := province_map.get_province_occupier(pid)
	if not occ.is_empty():
		var oc := province_map.get_owner_data(occ)
		parts.append("[OCC: %s]" % oc.get("name", occ))
	if not _my_owner_id.is_empty():
		var hint := _click_hint(oid, occ)
		if not hint.is_empty():
			parts.append(hint)
	info_label.text = "  ".join(parts)


func _click_hint(oid: String, occ: String) -> String:
	if oid == _my_owner_id and not occ.is_empty():
		return "  | Click: defend  |  Shift+Click: propose peace"
	elif occ == _my_owner_id:
		return "  | Shift+Click: propose peace"
	elif oid == _my_owner_id and occ.is_empty():
		return "  | Click: unclaim"
	elif oid.is_empty():
		return "  | Click: claim"
	elif oid != _my_owner_id:
		if _require_online_to_occupy and oid not in _online_owner_ids:
			return "  | OFFLINE — protected"
		return "  | Click: occupy"
	return ""


## Offline owners' land cannot be occupied while they are protected.
func _on_clicked(pid: int) -> void:
	if _my_owner_id.is_empty():
		info_label.text = "Not logged in — waiting for server to assign your identity."
		return

	var current_owner := province_map.get_province_owner(pid)
	var current_occ := province_map.get_province_occupier(pid)

	if current_owner.is_empty():
		province_map.set_province_owner(pid, _my_owner_id)
		info_label.text = "Claimed province %d" % pid

	elif current_owner == _my_owner_id:
		if not current_occ.is_empty():
			province_map.clear_province_occupier(pid)
			var oc := province_map.get_owner_data(current_occ)
			info_label.text = "Defended! Removed %s from your province %d" % [oc.get("name", current_occ), pid]
		else:
			province_map.clear_province_owner(pid)
			info_label.text = "Unclaimed province %d" % pid

	elif current_occ == _my_owner_id:
		var o := province_map.get_owner_data(current_owner)
		info_label.text = "Already occupying %s's province. Right-click to propose peace." % o.get("name", current_owner)

	else:
		if _require_online_to_occupy and current_owner not in _online_owner_ids:
			var o := province_map.get_owner_data(current_owner)
			info_label.text = "%s is offline — cannot occupy their land." % o.get("name", current_owner)
		else:
			province_map.set_province_occupier(pid, _my_owner_id)
			var o := province_map.get_owner_data(current_owner)
			info_label.text = "Occupying %s's province %d" % [o.get("name", current_owner), pid]

	_refresh_counts()


## Targets the occupier if the province is yours, else its owner.
func _on_shift_clicked(pid: int) -> void:
	if _my_owner_id.is_empty():
		return

	var current_owner := province_map.get_province_owner(pid)
	var current_occ := province_map.get_province_occupier(pid)
	var other_owner_id: String = ""

	if current_owner == _my_owner_id and not current_occ.is_empty():
		other_owner_id = current_occ
	elif current_occ == _my_owner_id and not current_owner.is_empty():
		other_owner_id = current_owner
	elif not current_owner.is_empty() and current_owner != _my_owner_id:
		other_owner_id = current_owner

	if other_owner_id.is_empty():
		info_label.text = "No one to propose peace with here."
		return

	# Owner ids are "owner_<username>".
	var target_username := other_owner_id
	if target_username.begins_with("owner_"):
		target_username = target_username.substr(6)

	propose_peace(target_username)


func _on_owners_changed() -> void:
	_refresh_counts()


func set_player_owner(owner_id: String, color: String) -> void:
	_my_owner_id = owner_id
	_my_color = color
	info_label.text = "You are %s  (colour #%s)" % [owner_id, color]
	print("[Map] My owner_id = %s, color = #%s" % [owner_id, color])


func set_online_owners(online_ids: Array, require_online: bool) -> void:
	_online_owner_ids = online_ids
	_require_online_to_occupy = require_online


func show_treaty_incoming(treaty_id: String, proposer: String, expires_in: float) -> void:
	_incoming_treaty_id = treaty_id
	_incoming_treaty_proposer = proposer
	_incoming_treaty_expires = Time.get_unix_time_from_system() + expires_in
	treaty_info.text = "%s proposes a peace treaty." % proposer
	treaty_countdown.text = "Expires in %ds" % int(expires_in)
	treaty_popup.visible = true


func show_treaty_resolved(accepted: bool, proposer: String, target: String) -> void:
	_close_treaty_popup()
	if accepted:
		info_label.text = "Peace treaty ACCEPTED between %s and %s" % [proposer, target]
	else:
		info_label.text = "Peace treaty REJECTED between %s and %s" % [proposer, target]


func _on_treaty_accept() -> void:
	if _incoming_treaty_id.is_empty():
		return
	var mnc := _find_map_network_controller()
	if mnc:
		mnc.send_treaty_respond(_incoming_treaty_id, true)
	_close_treaty_popup()


func _on_treaty_reject() -> void:
	if _incoming_treaty_id.is_empty():
		return
	var mnc := _find_map_network_controller()
	if mnc:
		mnc.send_treaty_respond(_incoming_treaty_id, false)
	_close_treaty_popup()


func _close_treaty_popup() -> void:
	treaty_popup.visible = false
	_incoming_treaty_id = ""
	_incoming_treaty_proposer = ""
	_incoming_treaty_expires = 0.0


func _find_map_network_controller() -> Node:
	return get_node_or_null("MapNetworkController")


func propose_peace(target_username: String) -> void:
	var mnc := _find_map_network_controller()
	if mnc:
		mnc.send_treaty_propose(target_username)
		info_label.text = "Peace proposal sent to %s …" % target_username


func _refresh_counts() -> void:
	var nm := province_map.get_modified_count()
	modified_label.text = "%d modified" % nm if nm > 0 else ""
