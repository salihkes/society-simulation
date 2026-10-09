extends Node

## Shows the build UI only while the player stands in a plot they own.

var build_ui: Control = null
var network_controller: Node = null
var local_player: Node3D = null
var owned_plot_ids: Array = []
var check_interval: float = 0.2
var check_timer: float = 0.0

## Offline play: the UI shows whenever there is a local player, without plot checks.
var offline_sandbox: bool = false

var current_plot: Dictionary = {}

var _outline: MeshInstance3D = null
var _outline_mesh: ImmediateMesh = null
var _outline_sig := ""


func _ready():
	await get_tree().process_frame
	network_controller = get_node_or_null("/root/NetworkController")
	if not network_controller:
		network_controller = get_tree().root.find_child("NetworkController", true, false)
	var workspace = get_tree().current_scene
	build_ui = workspace.get_node_or_null("UI/BuildUI")
	if build_ui:
		build_ui.visible = false
	if network_controller and network_controller.get("workspace") != null:
		owned_plot_ids = network_controller.workspace.owned_plot_ids()


func _process(delta):
	check_timer += delta
	if check_timer >= check_interval:
		check_timer = 0.0
		_update_ui_visibility()


func _update_ui_visibility():
	if not build_ui:
		return
	if not local_player or not is_instance_valid(local_player):
		local_player = _find_local_player()
	if not local_player or not is_instance_valid(local_player):
		_show(false)
		return

	if offline_sandbox:
		current_plot = {}
		_show(true)
		return

	if not network_controller:
		_show(false)
		return
	var username = network_controller.get("local_username")
	if not username or username == "" or username.begins_with("Guest"):
		_show(false)
		return
	if owned_plot_ids.is_empty():
		_show(false)
		return

	current_plot = BuildPlots.plot_at(get_tree().current_scene, local_player.global_position, owned_plot_ids)
	_show(not current_plot.is_empty())


func _show(on: bool):
	if build_ui.visible != on:
		build_ui.visible = on
	_update_outline(on and not offline_sandbox)


func _find_local_player() -> Node3D:
	var workspace = get_tree().current_scene
	if not workspace:
		return null
	if network_controller:
		var username = network_controller.get("local_username")
		if username and username != "" and not username.begins_with("Guest"):
			var player = workspace.get_node_or_null(username)
			if player and player.has_node("LocalPlayer"):
				return player
	var humanoid = workspace.find_child("humanoid", true, false)
	if humanoid and humanoid.has_node("LocalPlayer"):
		return humanoid
	var countryball = workspace.find_child("countryball", true, false)
	if countryball and countryball.has_node("LocalPlayer"):
		return countryball
	return null


func is_in_owned_plot(position: Vector3) -> bool:
	if offline_sandbox:
		return true
	return not BuildPlots.plot_at(get_tree().current_scene, position, owned_plot_ids).is_empty()


## Called by the NetworkController.
func set_offline_sandbox(enabled: bool):
	offline_sandbox = enabled
	_update_ui_visibility()


## Called by the network workspace when plots_info (or the login) arrives.
func set_owned_plots(ids: Array):
	owned_plot_ids = ids.duplicate()
	_outline_sig = ""
	_update_ui_visibility()


func _update_outline(show: bool):
	if not show:
		if _outline != null and is_instance_valid(_outline):
			_outline.visible = false
		return
	var root = get_tree().current_scene
	var layout := BuildPlots.layout_node(root)
	if layout == null:
		return
	var plots := []
	for p in BuildPlots.all_plots(root):
		if str(p.id) in owned_plot_ids:
			plots.append(p)
	var sig := str(plots.size())
	for p in plots:
		sig += "|" + str(p.id) + str(p.points) + str(p.ceiling)
	if _outline == null or not is_instance_valid(_outline):
		_create_outline(root)
	_outline.visible = true
	if sig == _outline_sig:
		return
	_outline_sig = sig
	_draw_outline(plots, layout)


func _create_outline(root: Node):
	_outline_mesh = ImmediateMesh.new()
	_outline = MeshInstance3D.new()
	_outline.name = "_PlotOutline"
	_outline.mesh = _outline_mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	_outline.material_override = mat
	root.add_child(_outline)


func _draw_outline(plots: Array, layout: Node3D):
	_outline_mesh.clear_surfaces()
	_outline_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var color := Color(1.0, 0.65, 0.2, 0.9)
	var lift := 0.05
	for p in plots:
		var pts: PackedVector3Array = p.points
		var n := pts.size()
		_outline_mesh.surface_set_color(color)
		for i in n:
			var a: Vector3 = layout.to_global(pts[i] + Vector3.UP * lift)
			var b: Vector3 = layout.to_global(pts[(i + 1) % n] + Vector3.UP * lift)
			_outline_mesh.surface_add_vertex(a)
			_outline_mesh.surface_add_vertex(b)
		_outline_mesh.surface_set_color(Color(color, 0.35))
		for i in n:
			var base: Vector3 = layout.to_global(pts[i] + Vector3.UP * lift)
			var top: Vector3 = layout.to_global(Vector3(pts[i].x, float(p.ceiling), pts[i].z))
			_outline_mesh.surface_add_vertex(base)
			_outline_mesh.surface_add_vertex(top)
	_outline_mesh.surface_end()
