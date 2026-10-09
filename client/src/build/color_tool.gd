extends Control
## Colour tool panel: left-click paints parts with the picked colour (alpha kept).

const PAINT_ROOTS := ["workspace", "localworkspace"]

var selection_manager: Node = null
var paint_mode: bool = false

## Palette, RGB 0-255.
var color_palette = [
	[163, 162, 165],
	[159, 161, 172],
	[202, 203, 209],
	[231, 231, 236],
	[248, 248, 248],
	[190, 104, 98],
	[91, 93, 105],
	[234, 184, 146],
	[136, 62, 62],
	[177, 229, 166],
	[199, 212, 228],
	[218, 134, 122],
	[160, 95, 53],
	[193, 190, 66],
	[245, 205, 48],
	[215, 197, 154],
	[180, 128, 255],
	[163, 75, 75],
	[193, 202, 222],
	[255, 255, 255],
	[0, 0, 0],
	[107, 50, 124],
	[75, 151, 75],
	[153, 0, 0],
	[27, 42, 53],
	[0, 32, 96],
	[0, 143, 156],
	[0, 87, 166],
	[218, 133, 65],
	[245, 205, 47],
	[164, 189, 71],
	[217, 0, 0],
	[196, 40, 28],
	[105, 64, 40],
	[13, 105, 172],
	[170, 85, 0],
	[123, 47, 123],
	[52, 142, 64],
	[218, 134, 122]
]

var current_color: Color = Color.WHITE
@onready var color_container: GridContainer = null
@onready var current_color_display: ColorRect = null

func _ready():
	create_color_grid()

	await get_tree().process_frame
	var workspace = get_tree().current_scene
	selection_manager = workspace.get_node_or_null("SelectionManager")

	paint_mode = visible
	visibility_changed.connect(_on_visibility_changed)

func _on_visibility_changed():
	paint_mode = visible
	if paint_mode:
		print("Color Paint Mode: ENABLED - Click on objects to paint them")
	else:
		print("Color Paint Mode: DISABLED")

## Consumes the click so it does not also select.
func _input(event):
	if not paint_mode:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var clicked_object = BuildTargeting.paint_target_at(self, event.position, PAINT_ROOTS)
			if clicked_object:
				apply_color_to_object(clicked_object)
				get_viewport().set_input_as_handled()

func create_color_grid():
	color_container = get_node_or_null("ColorGrid")

	if not color_container:
		color_container = GridContainer.new()
		color_container.name = "ColorGrid"
		color_container.columns = 7
		color_container.add_theme_constant_override("h_separation", 4)
		color_container.add_theme_constant_override("v_separation", 4)
		color_container.position = Vector2(8, 60)
		color_container.size = Vector2(200, 100)
		add_child(color_container)

	current_color_display = get_node_or_null("CurrentColorDisplay")
	if not current_color_display:
		current_color_display = ColorRect.new()
		current_color_display.name = "CurrentColorDisplay"
		current_color_display.custom_minimum_size = Vector2(80, 25)
		current_color_display.position = Vector2(110, 28)
		current_color_display.color = Color.WHITE
		add_child(current_color_display)

	for rgb in color_palette:
		var color = Color(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0)
		create_color_button(color)

func create_color_button(color: Color):
	var button = Button.new()
	button.custom_minimum_size = Vector2(24, 24)

	button.add_theme_stylebox_override("normal", _swatch_style(color, 1, Color(0.3, 0.3, 0.3, 1.0)))
	button.add_theme_stylebox_override("hover", _swatch_style(color.lightened(0.2), 2, Color(1, 1, 1, 1.0)))
	button.add_theme_stylebox_override("pressed", _swatch_style(color.darkened(0.1), 2, Color(1, 1, 1, 1.0)))

	button.pressed.connect(func(): _on_color_selected(color, button))

	color_container.add_child(button)

func _swatch_style(bg: Color, border: int, border_color: Color) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = bg
	style.border_width_left = border
	style.border_width_right = border
	style.border_width_top = border
	style.border_width_bottom = border
	style.border_color = border_color
	return style

func _on_color_selected(color: Color, button: Button):
	current_color = color
	if current_color_display:
		current_color_display.color = color
	button.release_focus()
	print("Paint color selected: RGB(", int(color.r * 255), ", ", int(color.g * 255), ", ", int(color.b * 255), ") - Click on objects to paint them")

func apply_color_to_object(obj: Node3D):
	if not is_instance_valid(obj):
		return

	for mesh_instance in BuildSelectable.mesh_instances(obj):
		if not mesh_instance:
			continue

		for i in range(mesh_instance.mesh.get_surface_count()):
			var material = BuildSelectable.editable_surface_material(mesh_instance, i)
			if material is BaseMaterial3D:
				var alpha = material.albedo_color.a
				material.albedo_color = Color(current_color.r, current_color.g, current_color.b, alpha)
				mesh_instance.set_surface_override_material(i, material)

	print("Painted '", obj.name, "' with color RGB(", int(current_color.r * 255), ", ", int(current_color.g * 255), ", ", int(current_color.b * 255), ")")
