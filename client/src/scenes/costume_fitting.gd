extends Node3D
## Fitting room for a costume on the humanoid; FIT_* env vars pick garment, pose and screenshot.

const HUMAN := "res://assets/entities/character/humanoid.tscn"
const Rig := preload("res://src/character/limb_rig.gd")
const Binding := preload("res://src/theater/costumes/costume_binding.gd")
const BASE_HEIGHT := 3.0

var model: Node3D
var rig := Rig.new()
var garment: Node3D
var camera: Camera3D
var mode := 1
var inspection := false
var orbit := 0.0
var distance := 10.0
var clock := 0.0
var paused := false
var status: Label
var cage: MeshInstance3D
var costume := "crimson_blossom"
var floor_pose := ""


func _ready() -> void:
	_environment()
	var source := (load(HUMAN) as PackedScene).instantiate()
	model = source.get_node("CharacterModel")
	source.remove_child(model)
	source.free()
	model.get_node("ChatBubble").free()
	add_child(model)
	model.position.y = BASE_HEIGHT
	rig.resolve(model)
	rig.enable_joints()
	if OS.get_environment("FIT_COSTUME") != "":
		costume = OS.get_environment("FIT_COSTUME")
	floor_pose = OS.get_environment("FIT_POSE")
	_pose()
	garment = Binding.new()
	garment.name = "FittedCostume"
	model.add_child(garment)
	if not garment.build(rig, costume):
		push_error("Unable to load fitted costume")
		return
	_make_cage()
	_ui()
	_camera()
	if OS.get_environment("FIT_SHOT") != "":
		await _capture(OS.get_environment("FIT_SHOT"))


## Saves one frame to path and quits.
func _capture(path: String) -> void:
	mode = clampi(int(OS.get_environment("FIT_MODE")), 1, 3)
	inspection = OS.get_environment("FIT_INSPECT") == "1"
	orbit = deg_to_rad(float(OS.get_environment("FIT_ORBIT")))
	clock = float(OS.get_environment("FIT_TIME"))
	paused = true
	garment.set_inspection(inspection)
	_pose()
	_camera()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var result := get_viewport().get_texture().get_image().save_png(path)
	print("FITTING SHOT: ", error_string(result))
	get_tree().quit()


func _physics_process(delta: float) -> void:
	if model == null:
		return
	if not paused:
		clock += delta
		_pose()
	_camera()


## Also updates the garment and the status line.
func _pose() -> void:
	if floor_pose != "" and HumanoidPoses.has(floor_pose):
		var d := HumanoidPoses.apply(rig, floor_pose, 1.0)
		model.position.y = BASE_HEIGHT - d
		if garment != null:
			garment.update_pose()
		return
	var lower := 0.0
	var elbow := 0.0
	if mode == 2:
		lower = deg_to_rad(25) * (sin(clock) * 0.5 + 0.5)
	if mode == 3:
		elbow = deg_to_rad(40) * (sin(clock) * 0.5 + 0.5)
	for side in [-1.0, 1.0]:
		var limb: Node3D = rig.left_arm if side < 0 else rig.right_arm
		rig.pose_basis(limb, Basis(Vector3.BACK, side * (PI / 2 - lower)))
		rig.flex(limb, elbow)
	if garment != null:
		garment.update_pose()
	if status != null:
		status.text = ["", "T-pose fitting", "Shoulder test · 0–25°", "Elbow test · 0–40°"][mode]
		status.text += "  /  " + ("see-through garment" if inspection else "textured garment")


func _environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("242c35")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("c7d4e4")
	environment.ambient_light_energy = 0.65
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)
	for p in [Vector3(-4, 7, -5), Vector3(4, 5, -3), Vector3(1, 6, 3)]:
		var light := OmniLight3D.new()
		light.position = p
		light.light_energy = 1.5
		light.omni_range = 15
		light.shadow_enabled = true
		add_child(light)
	_add_floor()
	camera = Camera3D.new()
	camera.fov = 45
	camera.near = 0.05
	add_child(camera)
	camera.current = true


func _add_floor() -> void:
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	floor_mesh.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("303941")
	material.roughness = 1.0
	floor_mesh.material_override = material
	add_child(floor_mesh)


func _camera() -> void:
	if camera == null:
		return
	var focus := Vector3(0, 2.8, 0)
	camera.position = focus + Vector3(sin(orbit) * distance, 1.3, -cos(orbit) * distance)
	camera.look_at(focus)


func _ui() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)
	var text := Label.new()
	text.position = Vector2(22, 18)
	text.text = costume.to_upper().replace("_", " ") + " / GARMENT FITTING\n" \
			+ "1: T-pose   2: shoulders   3: elbows   Space: pause\n" \
			+ "X: see through garment   G: garment on/off   C: fitting cage\n" \
			+ "Left / Right: orbit   Up / Down: zoom"
	text.add_theme_color_override("font_shadow_color", Color.BLACK)
	text.add_theme_constant_override("shadow_offset_x", 1)
	text.add_theme_constant_override("shadow_offset_y", 1)
	ui.add_child(text)
	status = Label.new()
	status.position = Vector2(22, 117)
	status.add_theme_color_override("font_color", Color("f0cf91"))
	ui.add_child(status)
	_pose()


## Hidden wireframe of the body cage, from the costume's fitted.fit.json.
func _make_cage() -> void:
	var path := "res://assets/entities/theater/costumes/%s/fitted.fit.json" % costume
	if not FileAccess.file_exists(path):
		return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var body: Dictionary = data.get("body_cage", {})
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for segment in body:
		var rings: Array = body[segment].rings
		for r in rings.size():
			_add_ring_lines(lines, rings, r)
	lines.surface_end()
	cage = MeshInstance3D.new()
	cage.mesh = lines
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color("60dce5")
	material.no_depth_test = true
	cage.material_override = material
	model.add_child(cage)
	cage.visible = false


## Line segments around ring r, plus every third vertex joined to ring r + 1.
static func _add_ring_lines(lines: ImmediateMesh, rings: Array, r: int) -> void:
	var ring: Array = rings[r]
	for k in ring.size():
		lines.surface_add_vertex(_vec(ring[k]))
		lines.surface_add_vertex(_vec(ring[(k + 1) % ring.size()]))
		if r + 1 < rings.size() and k % 3 == 0:
			lines.surface_add_vertex(_vec(ring[k]))
			lines.surface_add_vertex(_vec(rings[r + 1][k]))


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return
	match event.keycode:
		KEY_1, KEY_2, KEY_3:
			mode = event.keycode - KEY_0
			paused = false
			if cage != null:
				cage.visible = false
		KEY_SPACE:
			paused = not paused
		KEY_X:
			inspection = not inspection
			garment.set_inspection(inspection)
			_pose()
		KEY_G:
			garment.visible = not garment.visible
		KEY_C:
			mode = 1
			_pose()
			cage.visible = not cage.visible
		KEY_LEFT:
			orbit -= 0.12
		KEY_RIGHT:
			orbit += 0.12
		KEY_UP:
			distance = maxf(5.0, distance - 0.4)
		KEY_DOWN:
			distance = minf(18.0, distance + 0.4)
