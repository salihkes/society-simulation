extends Node3D
## Kabuki stage demo: Space pauses, R restarts, arrows scrub 5 s; KABUKI_SHOT saves a frame.

@onready var show: Node3D = $Performance


func _ready() -> void:
	var center: Vector3 = $Theater/Stage.global_position
	$Camera3D.global_position = center + Vector3(-5.4, 2.0, 0)
	$Camera3D.look_at(center + Vector3(0, 0.4, 0))
	$Camera3D.current = true
	if OS.get_environment("KABUKI_SHOT") != "":
		await get_tree().create_timer(2.0).timeout
		show.pause()
		show.seek(float(OS.get_environment("KABUKI_TIME")))
		await get_tree().physics_frame
		await get_tree().physics_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(OS.get_environment("KABUKI_SHOT"))
		get_tree().quit()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	match event.keycode:
		KEY_SPACE:
			if show.playing: show.pause()
			else: show.play()
		KEY_R:
			show.seek(0)
			show.play()
		KEY_LEFT: show.seek(show.elapsed - 5)
		KEY_RIGHT: show.seek(show.elapsed + 5)
