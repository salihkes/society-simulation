@tool
extends Node3D
## Makes imported tree materials write depth (opaque wood, alpha-scissor leaves) so they hide glass.


func _ready() -> void:
	_fix_materials(self, {})


## Overrides every surface below node; variants shares one copy per source.
func _fix_materials(node: Node, variants: Dictionary) -> void:
	if node is MeshInstance3D and node.mesh != null:
		for surface in node.mesh.get_surface_count():
			var source := node.mesh.surface_get_material(surface) as BaseMaterial3D
			if source == null:
				continue
			if not variants.has(source):
				variants[source] = _depth_writing(source)
			node.set_surface_override_material(surface, variants[source])
	for child in node.get_children():
		_fix_materials(child, variants)


func _depth_writing(source: BaseMaterial3D) -> BaseMaterial3D:
	var material := source.duplicate() as BaseMaterial3D
	if material.resource_name == "Wood1Mtl":
		material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	else:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		material.alpha_scissor_threshold = 0.5
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	return material
