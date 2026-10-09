@tool
extends Resource
class_name VehicleDefinition

## One drivable vehicle type; "model units" are the model's own space before the fit scale.

@export var display_name := "Car"

## On the web build it may arrive later in a pack.
@export_file("*.glb", "*.gltf", "*.tscn", "*.scn") var model_path := ""
## Degrees; for models not authored -Z-forward.
@export var model_yaw_deg := 0.0
## Workspace units after fitting (a player capsule is about 5); 0 keeps the model's scale.
@export var target_length := 20.0

@export_group("Seats")
@export var driver_seat := "DriverSeat"
@export var passenger_seats: Array[String] = []
## Above a seat anchor, in model units.
@export var eye_height := 0.7

@export_group("Doors")
## {"node", "kind": "hinge"|"slide", "axis", "angle" (deg), "offset", "out" (step-out direction), "seats"}
@export var doors: Array[Dictionary] = []

@export_group("Wheels")
@export var wheels: Array[String] = []
## Model units.
@export var wheel_radius := 0.4
@export var wheel_axis := Vector3(1, 0, 0)
## Flip to +1 for a model whose wheels roll the wrong way.
@export var wheel_spin_sign := -1.0
@export var steer_pivots: Array[String] = []
@export var max_steer_deg := 28.0
## Hub at its origin. Empty leaves it still.
@export var steering_wheel := "SteeringWheel"
## The rim's normal in the steering wheel's own space.
@export var steering_wheel_axis := Vector3(0, 1, 0)
## Degrees at full lock.
@export var steering_wheel_deg := 120.0
## Model units, for the bicycle steering model.
@export var wheelbase := 3.2

@export_group("Lights")
## Each gets its own emissive material; tail lights glow brighter when braking.
@export var headlights: Array[String] = []
@export var tail_lights: Array[String] = []

@export_group("Paint")
## Gets the paint shader (mask in UV2). Empty keeps the delivered livery.
@export var paint_material := ""
## 0 for a red-dominant body, 1 for a light body with protected trim.
@export var paint_kind := 0
## A vehicle picks one from its network id.
@export var paint_colors: Array[Color] = []
## For two-tone bodies. Empty = body colour.
@export var roof_colors: Array[Color] = []

@export_group("Body lean", "lean_")
## Visual only, on a spring. Both angles 0 switches it off.
@export var lean_roll_deg := 4.0
@export var lean_pitch_deg := 2.2
## Damping below about 2*sqrt(stiffness) wobbles.
@export var lean_stiffness := 55.0
@export var lean_damping := 9.0
## Lateral acceleration, in g, that gives the full roll angle.
@export var lean_full_g := 0.45

@export_group("Driving", "drive_")
## Workspace units / second (traffic cruises at 9–16).
@export var drive_max_speed := 36.0
@export var drive_reverse_speed := 12.0
@export var drive_accel := 16.0
@export var drive_brake := 36.0
@export var drive_coast := 6.0
## Degrees / second.
@export var drive_steer_rate := 110.0
## Fraction of the steering lock left at top speed.
@export var drive_steer_at_speed := 0.35
## World m/s².
@export var drive_gravity := 30.0

@export_group("Collision")
## Model units; zero = derived from the mesh bounds.
@export var body_size := Vector3.ZERO
@export var body_offset := Vector3.ZERO

@export_group("Camera", "cam_")
## World metres at full zoom-out.
@export var cam_distance := 11.0
## Above the vehicle's ground point.
@export var cam_pivot_height := 1.0
## Radians, faded in as the camera leaves the cabin.
@export var cam_pitch := 0.18

@export_group("Sound")
@export var engine_loop := "res://assets/art/sound/city/car_engine_loop.mp3"
@export var horn_clip := "res://assets/art/sound/city/car_horn_pip.wav"
@export var engine_volume_db := -22.0


func seat_names() -> Array[String]:
	var out: Array[String] = [driver_seat]
	out.append_array(passenger_seats)
	return out


## The index in `doors`, or -1.
func door_for_seat(seat: String) -> int:
	for i in doors.size():
		var seats: Array = doors[i].get("seats", [])
		if seats.has(seat):
			return i
	return -1


## Works before the model is in a tree (the editor preview).
static func model_bounds(model: Node3D) -> AABB:
	var corners: Array[Vector3] = []
	var stack: Array = [[model, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var node: Node = item[0]
		var xf: Transform3D = item[1]
		if node is Node3D and node != model:
			xf = xf * (node as Node3D).transform
		for child in node.get_children():
			stack.append([child, xf])
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			corners.append_array(_box_corners(xf, (node as MeshInstance3D).get_aabb()))
	return _bounds_of(corners)


static func _box_corners(xf: Transform3D, box: AABB) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for c in 8:
		out.append(xf * box.get_endpoint(c))
	return out


static func _bounds_of(points: Array[Vector3]) -> AABB:
	if points.is_empty():
		return AABB()
	var merged := AABB(points[0], Vector3.ZERO)
	for i in range(1, points.size()):
		merged = merged.expand(points[i])
	return merged


## Returns {"scale": float, "extent": AABB}, the extent in the parent's space.
func fit_model(model: Node3D) -> Dictionary:
	var aabb := model_bounds(model)
	var yaw := deg_to_rad(model_yaw_deg)
	var sideways: bool = absf(fmod(absf(model_yaw_deg), 180.0) - 90.0) < 45.0
	var length: float = aabb.size.x if sideways else aabb.size.z
	var s := 1.0
	if target_length > 0.0 and length > 0.001:
		s = target_length / length
	model.rotation.y = yaw
	model.scale = Vector3.ONE * s
	var center := aabb.get_center()
	var c2 := Vector3(center.x, 0.0, center.z).rotated(Vector3.UP, yaw) * s
	model.position = Vector3(-c2.x, -aabb.position.y * s, -c2.z)
	var extent := _bounds_of(_box_corners(model.transform, aabb))
	return {"scale": s, "extent": extent}


func paintable() -> bool:
	return paint_material != "" and not paint_colors.is_empty()


## Chosen from the network id, so every peer agrees without sending a colour.
func paint_for(seed_text: String) -> Dictionary:
	return paint_at(int(hash(seed_text)), int(hash(seed_text + "roof")))


func paint_at(body_index: int, roof_index: int) -> Dictionary:
	if paint_colors.is_empty():
		return {"body": Color.WHITE, "roof": Color.WHITE}
	var body: Color = paint_colors[posmod(body_index, paint_colors.size())]
	var roof: Color = body
	if not roof_colors.is_empty():
		roof = roof_colors[posmod(roof_index, roof_colors.size())]
	return {"body": body, "roof": roof}
