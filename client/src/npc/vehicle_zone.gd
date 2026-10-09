extends Area3D
class_name VehicleZone
## Road area where an NPC drives its car, parking it in the nearest free "CarParkSlot*" sibling on leaving.

## Vertical offset (world metres) to sit cars on the road / in the slot.
@export var car_height_offset := 0.0
## Yaw offset (radians) if a car model's forward axis differs from the NPC's.
@export var car_yaw_offset := 0.0

var _slots: Array = []
var _slot_taken: Dictionary = {}   # slot (Marker3D) -> car (Node3D)


func _ready() -> void:
	var parent := get_parent()
	if parent:
		for child in parent.get_children():
			if child is Marker3D and child.name.begins_with("CarParkSlot"):
				_slots.append(child)
	add_to_group("vehicle_zone")


## Parents the car to this zone's parent so it shares the slots' scale.
func spawn_car(scene: PackedScene) -> Node3D:
	if scene == null:
		return null
	var car: Node3D = scene.instantiate()
	get_parent().add_child(car)
	return car


func update_driving_car(car: Node3D, pos: Vector3, yaw: float) -> void:
	if not is_instance_valid(car):
		return
	car.global_position = pos + Vector3.UP * car_height_offset
	car.global_rotation = Vector3(0.0, yaw + car_yaw_offset, 0.0)


func release_slot(car: Node3D) -> void:
	for slot in _slot_taken.keys():
		if _slot_taken[slot] == car:
			_slot_taken.erase(slot)
			return


func park_car(car: Node3D) -> bool:
	if not is_instance_valid(car):
		return false
	var best: Marker3D = null
	var best_d := INF
	var from := car.global_position
	for slot in _slots:
		if _slot_taken.has(slot):
			continue
		var d: float = from.distance_to(slot.global_position)
		if d < best_d:
			best_d = d
			best = slot
	if best == null:
		return false
	_slot_taken[best] = car
	car.global_position = best.global_position + Vector3.UP * car_height_offset
	car.global_rotation = best.global_rotation
	return true
