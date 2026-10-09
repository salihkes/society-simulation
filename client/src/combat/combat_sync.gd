extends Node
class_name CombatSync

## Network messages this module handles: type -> method (see protocol/messages.json).
const MESSAGES := {
	"combat_weapon": "handle_combat_message",
	"combat_saber_xf": "handle_combat_message",
	"combat_bolt": "handle_combat_message",
	"combat_health": "handle_combat_message",
}

## Sends and receives combat state (weapons, bolts, saber, health) via NetworkController.

signal health_changed(player_id: int, new_health: float)
signal player_died(player_id: int)

## player_id -> health
var _health: Dictionary = {}
const MAX_HEALTH := 100.0

## player_id -> {saber: Lightsaber, blaster: PlayerBlaster, active: String}
var _remote_weapons: Dictionary = {}

var _nc: Node = null
var _workspace: Node3D = null
var _local_weapon_manager: WeaponManager = null

var _saber_sync_timer := 0.0
const SABER_SYNC_INTERVAL := 0.05


func _ready():
	_nc = get_node_or_null("/root/NetworkController")
	_workspace = get_parent()

	if _nc:
		_nc.player_connected.connect(_on_player_connected)
		_nc.player_disconnected.connect(_on_player_disconnected)


func _physics_process(delta: float):
	if _nc == null or not _nc.connected:
		return

	_saber_sync_timer += delta
	if _saber_sync_timer >= SABER_SYNC_INTERVAL:
		_saber_sync_timer = 0.0
		_send_local_saber_transform()


func get_health(player_id: int) -> float:
	return _health.get(player_id, MAX_HEALTH)

func set_local_health(value: float):
	if _nc == null:
		return
	var pid: int = _nc.client_id
	var old := get_health(pid)
	_health[pid] = clampf(value, 0.0, MAX_HEALTH)
	if _health[pid] != old:
		health_changed.emit(pid, _health[pid])
		_send_health()
		if _health[pid] <= 0.0:
			player_died.emit(pid)

func take_damage(amount: float):
	set_local_health(get_health(_nc.client_id) - amount)

func heal(amount: float):
	set_local_health(get_health(_nc.client_id) + amount)

func init_local_health():
	if _nc:
		_health[_nc.client_id] = MAX_HEALTH


func send_weapon_switch(weapon_name: String):
	if _nc == null:
		return
	_nc.send_json({
		"type": "combat_weapon",
		"weapon": weapon_name
	})

func send_bolt_fired(pos: Vector3, dir: Vector3, color: Color, speed: float):
	if _nc == null:
		return
	_nc.send_json({
		"type": "combat_bolt",
		"pos": _vec3_to_dict(pos),
		"dir": _vec3_to_dict(dir),
		"color": color.to_html(),
		"speed": speed
	})

func _send_local_saber_transform():
	if _nc == null or _local_weapon_manager == null:
		return
	var weapons := _local_weapon_manager.weapons
	if weapons.is_empty():
		return
	var saber: Lightsaber = null
	for w in weapons:
		if w is Lightsaber:
			saber = w
			break
	if saber == null or not saber.visible:
		return

	var pos := saber.global_position
	var rot := saber.global_rotation
	_nc.send_json({
		"type": "combat_saber_xf",
		"pos": _vec3_to_dict(pos),
		"rot": _vec3_to_dict(rot)
	})

func _send_health():
	if _nc == null:
		return
	_nc.send_json({
		"type": "combat_health",
		"health": get_health(_nc.client_id)
	})


func handle_combat_message(data: Dictionary):
	var type: String = data.get("type", "")
	var sender_id: int = data.get("player_id", -1)

	match type:
		"combat_weapon":
			_on_remote_weapon_switch(sender_id, data.get("weapon", "lightsaber"))
		"combat_saber_xf":
			_on_remote_saber_transform(sender_id, data)
		"combat_bolt":
			_on_remote_bolt_fired(sender_id, data)
		"combat_health":
			var hp: float = data.get("health", MAX_HEALTH)
			_health[sender_id] = hp
			health_changed.emit(sender_id, hp)


func _on_remote_weapon_switch(player_id: int, weapon_name: String):
	var entry = _remote_weapons.get(player_id)
	if entry == null:
		return

	entry.active = weapon_name
	if weapon_name == "lightsaber":
		entry.saber.visible = true
		entry.saber.set_physics_process(true)
		entry.saber.play_ignite()
		entry.blaster.visible = false
		entry.blaster.set_physics_process(false)
	else:
		entry.saber.visible = false
		entry.saber.set_physics_process(false)
		entry.saber.play_deactivate()
		entry.blaster.visible = true
		entry.blaster.set_physics_process(true)


func _on_remote_saber_transform(player_id: int, data: Dictionary):
	var entry = _remote_weapons.get(player_id)
	if entry == null or entry.saber == null:
		return
	var pos := _dict_to_vec3(data.get("pos", {}))
	var rot := _dict_to_vec3(data.get("rot", {}))
	var saber: Lightsaber = entry.saber
	saber.global_position = saber.global_position.lerp(pos, 0.5)
	saber.global_rotation = saber.global_rotation.lerp(rot, 0.5)


func _on_remote_bolt_fired(_player_id: int, data: Dictionary):
	var bolt := BlasterBolt.new()
	var color_hex: String = data.get("color", "#ff2020")
	bolt.bolt_color = Color.from_string(color_hex, Color(1, 0.15, 0.1))
	bolt.speed = data.get("speed", 12.0)
	_workspace.add_child(bolt)

	var pos := _dict_to_vec3(data.get("pos", {}))
	var dir := _dict_to_vec3(data.get("dir", {}))
	bolt.fire(pos, dir)


func _on_player_connected(player_id: int, _username: String):
	_spawn_remote_weapons(player_id)
	_health[player_id] = MAX_HEALTH

func _on_player_disconnected(player_id: int):
	_cleanup_remote_weapons(player_id)
	_health.erase(player_id)

func _spawn_remote_weapons(player_id: int):
	if _remote_weapons.has(player_id):
		return

	var saber := Lightsaber.new()
	saber.blade_color = Color(1.0, 0.15, 0.1)
	_workspace.add_child(saber)

	var blaster := PlayerBlaster.new()
	blaster.bolt_color = Color(1.0, 0.15, 0.1)
	_workspace.add_child(blaster)
	blaster.visible = false
	blaster.set_physics_process(false)

	_remote_weapons[player_id] = {
		"saber": saber,
		"blaster": blaster,
		"active": "lightsaber"
	}

func _cleanup_remote_weapons(player_id: int):
	var entry = _remote_weapons.get(player_id)
	if entry == null:
		return
	if is_instance_valid(entry.saber):
		entry.saber.queue_free()
	if is_instance_valid(entry.blaster):
		entry.blaster.queue_free()
	_remote_weapons.erase(player_id)


func _vec3_to_dict(v: Vector3) -> Dictionary:
	return {"x": v.x, "y": v.y, "z": v.z}

func _dict_to_vec3(d: Dictionary) -> Vector3:
	return Vector3(d.get("x", 0.0), d.get("y", 0.0), d.get("z", 0.0))
