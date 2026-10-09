extends SceneTree

class Replica extends "res://src/life/ambient_pedestrian.gd":
	var poses := 0
	var samples := 0
	func _ready():
		pass
	func _remote_sample() -> Dictionary:
		samples += 1
		return {"pos": Vector3(2, 0, 0), "rot": 0.0}
	func _animate(_delta):
		poses += 1

func _initialize():
	var body := Replica.new()
	body.set_authority(false)
	for tick in 8:
		body._physics_process(1.0 / 60.0)
	var ok := body.poses == 0 and body.samples == 0
	body._process(1.0 / 30.0)
	ok = ok and body.poses == 1 and body.samples == 1 and body.position.x > 0.0
	body.set_authority(true)
	body._process(1.0 / 30.0)
	ok = ok and body.poses == 1 and body.samples == 1
	body.free()
	print("REPLICA ANIMATION: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
