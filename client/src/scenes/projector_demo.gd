extends Node3D
## Demo room for the FilmProjector; PROJECTOR_SHOT=/abs/prefix saves stills and quits.

@export var settle_seconds := 7.0


func _ready() -> void:
	$CamFront.look_at($FilmProjector/Lens.global_position + Vector3(0, 0.15, 0))
	$CamScreen.look_at($Screen.global_position + Vector3(0, -0.2, 0))
	$CamFront.current = true
	var shot := OS.get_environment("PROJECTOR_SHOT")
	if shot == "":
		return
	var settle_env := OS.get_environment("PROJECTOR_SETTLE")
	if settle_env != "":
		settle_seconds = float(settle_env)
	await get_tree().create_timer(settle_seconds).timeout
	# The reel viewport alone separates playback problems from projection ones.
	$FilmProjector/Film.get_texture().get_image().save_png(shot + "_reel.png")
	await _grab(shot + "_front.png")
	$CamScreen.current = true
	await get_tree().create_timer(1.0).timeout
	await _grab(shot + "_screen.png")
	get_tree().quit()


## Saves the next drawn frame to path.
func _grab(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("PROJECTOR_SHOT saved ", path)
