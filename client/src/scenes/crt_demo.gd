extends Node3D
## Demo room for CRTTV; env vars CRT_REEL, CRT_TEST, CRT_SHOT and CRT_SETTLE drive it.

@export var settle_seconds := 4.0


func _ready() -> void:
	var tv: Node3D = $Telefunken
	var pvm: Node3D = $PVM
	_aim_cameras(tv.screen_centre(), pvm.screen_centre())
	var reel_path := OS.get_environment("CRT_REEL")
	if reel_path != "":
		for set in [tv, pvm]:
			set.reel = null
			set.reel_path = reel_path
			set._apply_source()
	if OS.get_environment("CRT_TEST") != "":
		var card: Texture2D = tv.test_pattern()
		tv.set_source_texture(card)
		pvm.set_source_texture(card)
	var shot := OS.get_environment("CRT_SHOT")
	if shot == "":
		return
	var settle_env := OS.get_environment("CRT_SETTLE")
	if settle_env != "":
		settle_seconds = float(settle_env)
	await get_tree().create_timer(settle_seconds).timeout
	await _shoot(shot, tv)
	get_tree().quit()


func _aim_cameras(tv_centre: Vector3, pvm_centre: Vector3) -> void:
	$CamRoom.look_at((tv_centre + pvm_centre) * 0.5 + Vector3(0, -0.15, 0))
	$CamTelefunken.global_position = tv_centre + Vector3(0.1, 0.02, -1.7)
	$CamTelefunken.look_at(tv_centre)
	$CamPVM.global_position = pvm_centre + Vector3(0.06, 0.06, -0.42)
	$CamPVM.look_at(pvm_centre)
	$CamMacro.global_position = tv_centre + Vector3(0.1, -0.05, -0.26)
	$CamMacro.look_at(tv_centre + Vector3(0.0, 0.03, 0.0))
	$CamRoom.current = true


func _shoot(shot: String, tv: Node3D) -> void:
	$Telefunken/Signal.get_texture().get_image().save_png(shot + "_signal.png")
	await _grab(shot + "_room.png")
	$CamTelefunken.current = true
	await get_tree().create_timer(0.5).timeout
	await _grab(shot + "_telefunken.png")
	$CamPVM.current = true
	await get_tree().create_timer(0.5).timeout
	await _grab(shot + "_pvm.png")
	$CamMacro.current = true
	await get_tree().create_timer(0.5).timeout
	await _grab(shot + "_macro.png")
	$CamTelefunken.current = true
	tv.power_off()
	await get_tree().create_timer(1.6).timeout
	await _grab(shot + "_off.png")
	tv.power_on()
	await get_tree().create_timer(tv.preset.warmup + 0.7).timeout
	await _grab(shot + "_warm1.png")
	await get_tree().create_timer(2.5).timeout
	await _grab(shot + "_warm2.png")


## Saves the next drawn frame to path.
func _grab(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("CRT_SHOT saved ", path)
