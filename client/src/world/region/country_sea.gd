@tool
extends "res://src/world/water/city_sea.gd"
## Country-scale sea: a bounded water plane snapped under the camera.


func _ready() -> void:
	if not Engine.is_editor_hint():
		super._ready()
	var far_mesh := get_node("Far") as MeshInstance3D
	var plane := PlaneMesh.new()
	plane.size = Vector2(24000, 24000)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	far_mesh.mesh = plane


## Near stays on the city waterfront until the camera is 1200 m away, then follows too.
func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		super._process(delta)
	var camera: Camera3D
	if Engine.is_editor_hint():
		camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	else:
		camera = get_viewport().get_camera_3d()
	if camera == null:
		return
	var p := to_local(camera.global_position)
	var offset := Vector3(snappedf(p.x, 128), 0, snappedf(p.z, 128))
	get_node("Far").position = offset + Vector3(0, -1.2, 0)
	if Vector2(p.x, p.z).length() > 1200:
		get_node("Near").position = offset
	else:
		get_node("Near").position = Vector3(-900, 0, 0)
