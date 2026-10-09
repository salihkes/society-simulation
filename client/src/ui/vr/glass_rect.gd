@tool
class_name GlassRect
extends ColorRect
## Rounded glass rectangle drawn by glass_panel.gdshader; @tool so it renders in the editor too.

@export var corner_radius := 28.0:
	set(v):
		corner_radius = v
		_apply()
@export var fill_top := Color(0.30, 0.32, 0.38, 0.72):
	set(v):
		fill_top = v
		_apply()
@export var fill_bottom := Color(0.07, 0.08, 0.11, 0.90):
	set(v):
		fill_bottom = v
		_apply()
@export var border_top := Color(1, 1, 1, 0.5):
	set(v):
		border_top = v
		_apply()
@export var border_bottom := Color(1, 1, 1, 0.07):
	set(v):
		border_bottom = v
		_apply()


func _ready() -> void:
	if not (material is ShaderMaterial):
		var mat := ShaderMaterial.new()
		mat.shader = load("res://src/ui/vr/glass_panel.gdshader")
		material = mat
	color = Color.WHITE
	if not resized.is_connected(_sync_size):
		resized.connect(_sync_size)
	_apply()
	_sync_size()


func _apply() -> void:
	var mat := material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("corner_radius", corner_radius)
	mat.set_shader_parameter("fill_top", fill_top)
	mat.set_shader_parameter("fill_bottom", fill_bottom)
	mat.set_shader_parameter("border_top", border_top)
	mat.set_shader_parameter("border_bottom", border_bottom)


func _sync_size() -> void:
	var mat := material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("rect_size", size)
