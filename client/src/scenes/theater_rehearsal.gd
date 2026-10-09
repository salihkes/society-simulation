extends Node3D
## Rehearsal room for the theater; Space, R, arrows and 1/2/3 drive it, THEATER_SHOT saves stills.

@onready var show: StagePerformance = $Performance
@onready var cam: Camera3D = $Camera3D

var _seat := 1


## THEATER_PLAY=<name> picks res://assets/entities/theater/plays/<name>.json and its soundtrack.
static func pick_play(node: StagePerformance) -> void:
	var play := OS.get_environment("THEATER_PLAY")
	if play == "":
		return
	node.score_path = "res://assets/entities/theater/plays/%s.json" % play
	node.audio_path = ""
	for ext in ["mp3", "ogg", "wav"]:
		var path := "res://assets/art/sound/theater/%s.%s" % [play, ext]
		if FileAccess.file_exists(path):
			node.audio_path = path
			break


func _enter_tree() -> void:
	pick_play($Performance)


func _ready() -> void:
	_sit(1)
	var shot := OS.get_environment("THEATER_SHOT")
	if shot == "":
		return
	await get_tree().create_timer(1.5).timeout
	show.pause()
	var seat := OS.get_environment("THEATER_SEAT")
	if seat != "":
		_sit(int(seat))
	# Several times save <shot>_<time>.png each.
	var times := OS.get_environment("THEATER_TIME").split(",", false)
	for i in times.size():
		show.seek(float(times[i]))
		await get_tree().physics_frame
		await get_tree().physics_frame
		await RenderingServer.frame_post_draw
		var path := shot if times.size() == 1 \
				else "%s_%s.png" % [shot.get_basename(), times[i].strip_edges()]
		get_viewport().get_texture().get_image().save_png(path)
		print("saved ", path)
	get_tree().quit()


## Moves the camera to seat 1 (house), 2 (stage-side) or 3 (overhead).
func _sit(seat: int) -> void:
	_seat = seat
	# The house lies along the performance's +Z.
	var center: Vector3 = show.global_position
	var toward_house: Vector3 = show.global_basis.z.normalized()
	var stage_right: Vector3 = show.global_basis.x.normalized()
	var k: float = show.global_basis.get_scale().y
	match seat:
		2:
			cam.global_position = center + stage_right * 11.0 * k \
					+ toward_house * 12.0 * k + Vector3.UP * 4.5 * k
		3:
			cam.global_position = center + toward_house * 3.0 * k + Vector3.UP * 14.0 * k
		_:
			cam.global_position = center + toward_house * 20.0 * k + Vector3.UP * 5.0 * k
	cam.look_at(center + Vector3.UP * 2.5 * k)
	cam.current = true


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	match event.keycode:
		KEY_SPACE:
			if show.playing:
				show.pause()
			else:
				show.play()
		KEY_R:
			show.seek(0.0)
			show.play()
		KEY_LEFT:
			show.seek(show.elapsed - 10.0)
		KEY_RIGHT:
			show.seek(show.elapsed + 10.0)
		KEY_1:
			_sit(1)
		KEY_2:
			_sit(2)
		KEY_3:
			_sit(3)
