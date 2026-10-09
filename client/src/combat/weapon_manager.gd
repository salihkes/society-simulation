extends Node
class_name WeaponManager

## Equips one of a hand's weapons at a time; VR: B cycles, desktop: 1 blaster, 0 holster.

## Null on desktop.
var controller: XRController3D = null
var weapons: Array[Node3D] = []
## -1 when holstered.
var active_index := -1
var is_vr := false
var combat_sync: CombatSync = null

var _connected := false


func setup(ctrl, weapon_list: Array[Node3D], vr_mode: bool):
	controller = ctrl
	weapons = weapon_list
	is_vr = vr_mode

	for w in weapons:
		w.visible = false
		w.set_physics_process(false)
		w.set_process(false)
	active_index = -1

	if is_vr and controller:
		_connect_vr_signals()


func _connect_vr_signals():
	if _connected or controller == null:
		return
	if not controller.button_pressed.is_connected(_on_vr_button_pressed):
		controller.button_pressed.connect(_on_vr_button_pressed)
	_connected = true


func _unhandled_input(event: InputEvent):
	if is_vr:
		return

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_0:
				holster()
			KEY_1:
				_activate_by_type(&"blaster")
			KEY_2:
				pass

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# A piloting character's left click belongs to the ship's turrets.
		var character = get_parent()
		var ship = character.get("ship") if character else null
		if ship != null and ship.is_piloting():
			return
		_use_weapon()


func _on_vr_button_pressed(button_name: String):
	if button_name == "by_button":
		cycle_weapon()
	elif button_name == "trigger_click":
		_use_weapon()


func cycle_weapon():
	var next := active_index + 1
	if next >= weapons.size():
		next = -1

	if not is_vr and next >= 0 and weapons[next] is Lightsaber:
		next += 1
		if next >= weapons.size():
			next = -1

	_activate(next)


func holster():
	_activate(-1)


func _activate_by_type(type_name: StringName):
	for i in weapons.size():
		if type_name == &"blaster" and weapons[i] is PlayerBlaster:
			_activate(i)
			return
		elif type_name == &"lightsaber" and weapons[i] is Lightsaber:
			if is_vr:
				_activate(i)
			return


func _activate(index: int):
	if active_index >= 0 and active_index < weapons.size():
		var prev := weapons[active_index]
		if prev is Lightsaber:
			prev.play_deactivate()

	for i in weapons.size():
		var w := weapons[i]
		w.visible = false
		w.set_physics_process(false)
		w.set_process(false)

	active_index = index

	if active_index >= 0 and active_index < weapons.size():
		var active := weapons[active_index]
		active.visible = true
		active.set_physics_process(true)
		active.set_process(true)

		if active is Lightsaber:
			active.play_ignite()

		var weapon_name := "blaster" if active is PlayerBlaster else "lightsaber"
		print("Weapon: ", weapon_name)
		if combat_sync:
			combat_sync.send_weapon_switch(weapon_name)
	else:
		print("Weapon: holstered")
		if combat_sync:
			combat_sync.send_weapon_switch("none")


func _use_weapon():
	if active_index < 0 or active_index >= weapons.size():
		return
	var active := weapons[active_index]
	if active is PlayerBlaster:
		active.fire()
