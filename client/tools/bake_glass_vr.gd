extends SceneTree
## Regenerates the smooth, untextured city glass shared by desktop and VR.
## Uses ordinary alpha blending, with no refraction, rim or depth pre-pass.
## Run: godot --headless --path client -s res://tools/bake_glass_vr.gd

const MAT_OUT := "res://assets/world/environment/glass_vr.tres"


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var mat := StandardMaterial3D.new()
	mat.resource_name = "GlassVR"
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	# The runtime override supplies each pane's authored tint and opacity.
	mat.albedo_color = Color.WHITE
	mat.roughness = 0.12
	mat.metallic = 0.0
	mat.metallic_specular = 0.55
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mat.refraction_enabled = false
	mat.rim_enabled = false
	mat.disable_receive_shadows = true
	var err := ResourceSaver.save(mat, MAT_OUT)
	print("GLASS material -> %s err=%d" % [MAT_OUT, err])
	quit(0 if err == OK else 1)
