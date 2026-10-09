extends Node
## Autoload: studio mode (--studio) renders, records and drives the city from its own camera and panel.

const W := 1024
const H := 768
const RigScript := preload("res://src/studio/studio_camera.gd")
const RecorderScript := preload("res://src/studio/studio_recorder.gd")
const UIScript := preload("res://src/studio/studio_ui.gd")
const SETTINGS_PATH := "user://studio/settings.cfg"
const SHOTS_PATH := "user://studio/shots.json"
## Item 0 follows the server's schedule; the rest are weather names.
var WEATHERS: Array = ["as scheduled (%s)" % Identity.value("climate_name"), "clear", "partly",
	"overcast", "fog", "drizzle", "rain", "storm", "windy", "snow"]
const EMOTIONS := ["neutral", "happy", "sad", "serious", "angry", "afraid", "scarystare",
	"shocked"]
const SCHOOL_OPS := ["status", "bell", "class", "break", "lunch", "free", "gather",
	"assembly_am", "assemble", "closed", "open"]
const LESSONS := ["kimya-11-tepkime-hizi", "biyoloji-10-ekoloji", "edebiyat-9-tiyatro",
	"felsefe-10-ahlak", "fizik-10-su-dalgalari", "matematik-11-denklem", "sosyoloji-11-kultur"]
const LESSON_TEACHER := "r_teacher_chem"
## The camera stands this far above and behind the spawn point.
const SPAWN_VIEW_OFFSET := Vector3(0, 1.6, 3.5)
## The body is kept this far below the camera when it follows it.
const BODY_BELOW_CAMERA := Vector3.DOWN * 0.9
const WEEKDAYS := ["auto", "mon", "tue", "wed", "thu", "fri", "sat", "sun"]

var active := false
var ui: Control
var rig: Node3D
var rec: Node
var sub: SubViewport
var nc: Node
var ws: Node3D
var amb: Node
var env: Node
var weather: Node
var chat_ui: Node
var game_ui: CanvasLayer

var as_world := false
var player: Node3D = null
var player_cam: Camera3D = null
var player_rig: Node = null
var _body_mode := 0
var _residents: Array = []          # ids without the r_ prefix
var _places: Array = []             # {id, kind, gpos}
var _shots: Array = []              # {name, pose}
var _looking := false
var _panning := false
var _press_pos := Vector2.ZERO
var _syncing := false
var _status_t := 0.0
var _player_t := 0.0
var _lists_t := 0.0
var _save_t := 0.0
var _path_tween: Tween = null
var _path_recording := false
var _selftest := false
var _weather_transition := 20.0
var _was_connected := false
var _rehearsal_on := false          # as the server last reported


func _ready() -> void:
	if not OS.get_cmdline_user_args().has("--studio"):
		set_process(false)
		set_process_input(false)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	_selftest = OS.get_environment("STUDIO_SELFTEST") == "1"
	set_process(false)
	_boot.call_deferred()


func _boot() -> void:
	while get_tree().current_scene == null:
		await get_tree().process_frame
	await get_tree().process_frame
	ws = get_tree().current_scene
	nc = get_node_or_null("/root/NetworkController")
	as_world = nc != null and nc.has_method("is_world_mode") and nc.is_world_mode()
	amb = ws.find_child("AmbientManager", true, false)
	env = ws.find_child("EnvironmentController", true, false)
	weather = ws.find_child("WeatherController", true, false)
	chat_ui = ws.find_child("ChatUI", true, false)
	game_ui = ws.get_node_or_null("UI")
	if weather != null:
		_weather_transition = float(weather.get("transition_seconds"))
	_build_viewport()
	_build_ui()
	_setup_window()
	_wire()
	_load_settings()
	_load_shots()
	if nc != null and nc.has_signal("studio_message"):
		nc.studio_message.connect(_on_mind_reply)
	rec.log_line.connect(_log)
	rec.started.connect(func(_p): _update_rec_ui())
	rec.finished.connect(func(_p, _ok, _m): _update_rec_ui())
	if as_world:
		ui.n.body_mode.disabled = true
		ui.n.scene_hint.text = "This window IS the world: the hour and the weather set here " \
				+ "are the city's, for everyone."
		ui.n.world_hint.text = "This window is the world: these act here directly."
	active = true
	set_process(true)
	_log("studio ready — clips go to " + rec.out_dir
			+ ("; this window is the world" if as_world else ""))
	print("[Studio] ready; recording %dx%d; server %s" % [
			W, H, str(nc.get("server_url")) if nc else "none"])
	if _selftest:
		_run_selftest()


func _build_viewport() -> void:
	sub = SubViewport.new()
	sub.name = "StudioViewport"
	sub.size = Vector2i(W, H)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.audio_listener_enable_3d = true
	sub.handle_input_locally = false
	var root := get_viewport()
	sub.msaa_3d = root.msaa_3d
	sub.screen_space_aa = root.screen_space_aa
	sub.use_taa = root.use_taa
	sub.use_debanding = root.use_debanding
	sub.scaling_3d_mode = root.scaling_3d_mode
	sub.scaling_3d_scale = root.scaling_3d_scale
	sub.fsr_sharpness = root.fsr_sharpness
	sub.positional_shadow_atlas_size = root.positional_shadow_atlas_size
	sub.mesh_lod_threshold = root.mesh_lod_threshold
	sub.use_occlusion_culling = root.use_occlusion_culling
	add_child(sub)
	rig = RigScript.new()
	rig.name = "StudioCamera"
	sub.add_child(rig)
	var we = ws.find_child("WorldEnvironment", true, false)
	var attrs: CameraAttributesPractical = null
	if we != null and we.camera_attributes is CameraAttributesPractical:
		attrs = we.camera_attributes.duplicate()
	if attrs == null:
		attrs = CameraAttributesPractical.new()
	rig.camera.attributes = attrs
	rec = RecorderScript.new()
	rec.name = "StudioRecorder"
	rec.viewport = sub
	add_child(rec)
	_look_at_spawn()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "StudioUI"
	layer.layer = 100
	add_child(layer)
	ui = UIScript.new()
	ui.name = "Panel"
	layer.add_child(ui)
	ui.build(W, H, WEATHERS, EMOTIONS, SCHOOL_OPS, LESSONS, WEEKDAYS)
	get_viewport().size_changed.connect(_fit_ui)
	_fit_ui.call_deferred()
	ui.preview.texture = sub.get_texture()
	var a: CameraAttributesPractical = rig.camera.attributes
	ui.n.dof_near.set_pressed_no_signal(a.dof_blur_near_enabled)
	ui.n.dof_near_dist.set_value_no_signal(a.dof_blur_near_distance)
	ui.n.dof_far.set_pressed_no_signal(a.dof_blur_far_enabled)
	ui.n.dof_far_dist.set_value_no_signal(a.dof_blur_far_distance)
	ui.n.dof_far_trans.set_value_no_signal(a.dof_blur_far_transition)
	ui.n.fov.set_value_no_signal(rig.camera.fov)
	ui.n.fov_label.text = "%d°" % int(rig.camera.fov)
	ui.n.speed.set_value_no_signal(rig.speed)
	ui.n.distance.set_value_no_signal(rig.distance)
	ui.n.look_height.set_value_no_signal(rig.look_height)


func _fit_ui() -> void:
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.size = get_viewport().get_visible_rect().size
	ui.fit_preview.call_deferred()


## Also turns off the window's own 3D and hides the game UI.
func _setup_window() -> void:
	var win := get_window()
	win.title = Identity.value("studio_title")
	win.min_size = Vector2i(1180, 860)
	if win.size.x < 1480 or win.size.y < 920:
		win.size = Vector2i(1480, 920)
		win.move_to_center()
	_fit_ui.call_deferred()
	get_viewport().disable_3d = true
	get_viewport().audio_listener_enable_3d = false
	if game_ui != null:
		game_ui.visible = false
	if chat_ui != null:
		# Its T shortcut would steal the keyboard from the panel's fields.
		chat_ui.set_process_input(false)
		chat_ui.set_process_unhandled_input(false)


func _wire() -> void:
	var n: Dictionary = ui.n
	ui.preview.gui_input.connect(_on_preview_input)
	ui.preview.focus_entered.connect(func(): ui.set_preview_focused(true))
	ui.preview.focus_exited.connect(func(): ui.set_preview_focused(false))
	_wire_camera(n)
	_wire_scene(n)
	_wire_people(n)
	_wire_world(n)
	_wire_shots(n)
	_wire_record_bar(n)


func _wire_camera(n: Dictionary) -> void:
	n.cam_mode.item_selected.connect(func(i): rig.set_mode(i))
	for k in ["pos_x", "pos_y", "pos_z", "yaw", "pitch", "roll"]:
		n[k].value_changed.connect(_on_pose_field)
	n.fov.value_changed.connect(func(v): rig.camera.fov = v; n.fov_label.text = "%d°" % int(v))
	n.speed.value_changed.connect(func(v): rig.speed = v)
	n.smooth.toggled.connect(func(on): rig.smooth = on)
	n.btn_to_player.pressed.connect(_cam_to_player)
	n.btn_to_spawn.pressed.connect(_cam_to_spawn)
	n.btn_copy.pressed.connect(func():
		DisplayServer.clipboard_set(JSON.stringify(rig.get_pose()))
		_log("pose copied"))
	n.btn_paste.pressed.connect(_paste_pose)
	n.btn_res_go.pressed.connect(func(): _cam_to_resident(_picked(n.cam_res), 0))
	n.btn_res_orbit.pressed.connect(func(): _cam_to_resident(_picked(n.cam_res), 1))
	n.btn_res_follow.pressed.connect(func(): _cam_to_resident(_picked(n.cam_res), 2))
	n.btn_place_go.pressed.connect(func(): _cam_to_place(n.cam_place.selected, false))
	n.btn_place_orbit.pressed.connect(func(): _cam_to_place(n.cam_place.selected, true))
	n.btn_refresh_lists.pressed.connect(_fill_lists)
	n.distance.value_changed.connect(func(v): rig.distance = v)
	n.look_height.value_changed.connect(func(v): rig.look_height = v)
	n.spin.value_changed.connect(func(v): rig.spin_deg = v)
	n.chase.toggled.connect(func(on): rig.chase = on)
	n.dof_near.toggled.connect(func(on): rig.camera.attributes.dof_blur_near_enabled = on)
	n.dof_near_dist.value_changed.connect(
			func(v): rig.camera.attributes.dof_blur_near_distance = v)
	n.dof_far.toggled.connect(func(on): rig.camera.attributes.dof_blur_far_enabled = on)
	n.dof_far_dist.value_changed.connect(
			func(v): rig.camera.attributes.dof_blur_far_distance = v)
	n.dof_far_trans.value_changed.connect(
			func(v): rig.camera.attributes.dof_blur_far_transition = v)


func _wire_scene(n: Dictionary) -> void:
	n.time_local.toggled.connect(_on_time_local)
	n.time_slider.value_changed.connect(func(v):
		n.time_label.text = _hhmm(v)
		if not n.time_local.button_pressed:
			n.time_local.button_pressed = true)
	n.btn_dawn.pressed.connect(func(): _set_local_hour(6.0))
	n.btn_noon.pressed.connect(func(): _set_local_hour(12.5))
	n.btn_sunset.pressed.connect(func(): _set_local_hour(18.2))
	n.btn_night.pressed.connect(func(): _set_local_hour(22.5))
	n.weather.item_selected.connect(_on_weather)
	n.weather_instant.toggled.connect(func(on):
		if weather:
			weather.transition_seconds = 0.3 if on else _weather_transition)
	n.body_mode.item_selected.connect(_on_body_mode)
	n.time_scale.value_changed.connect(func(v):
		Engine.time_scale = v
		n.time_scale_label.text = "%.2f×" % v)
	n.btn_scale_reset.pressed.connect(func(): n.time_scale.value = 1.0)


func _wire_people(n: Dictionary) -> void:
	n.btn_ppl_cam.pressed.connect(func(): _cam_to_resident(_picked(n.ppl_res), 0))
	n.btn_ppl_orbit.pressed.connect(func(): _cam_to_resident(_picked(n.ppl_res), 1))
	n.btn_ppl_follow.pressed.connect(func(): _cam_to_resident(_picked(n.ppl_res), 2))
	n.btn_ppl_refresh.pressed.connect(_fill_lists)
	n.btn_say.pressed.connect(func(): _say(true))
	n.btn_say_raw.pressed.connect(func(): _say(false))
	n.say_text.text_submitted.connect(func(_t): _say(true))
	n.btn_go.pressed.connect(func(): _plan([{"do": "go", "place": _picked_place(n.ppl_place),
			"then": n.ppl_then.get_item_text(n.ppl_then.selected)}]))
	n.btn_eat.pressed.connect(func(): _plan([{"do": "eat", "place": _picked_place(n.ppl_place),
			"then": n.ppl_then.get_item_text(n.ppl_then.selected)}]))
	n.btn_sit.pressed.connect(func(): _plan([{"do": "sit", "place": _picked_place(n.ppl_place)}]))
	n.btn_emote.pressed.connect(func(): _plan([{"do": "emote",
			"emotion": EMOTIONS[n.emotion.selected], "for": n.emote_secs.value}]))
	n.btn_life_pause.pressed.connect(
			func(): _mind({"cmd": "life", "op": "pause", "id": _picked(n.ppl_res)}))
	n.btn_life_resume.pressed.connect(
			func(): _mind({"cmd": "life", "op": "resume", "id": _picked(n.ppl_res)}))
	n.btn_life_off.pressed.connect(
			func(): _mind({"cmd": "life", "op": "enabled", "enabled": false}))
	n.btn_life_on.pressed.connect(
			func(): _mind({"cmd": "life", "op": "enabled", "enabled": true}))
	n.btn_consolidate.pressed.connect(
			func(): _mind({"cmd": "consolidate", "id": _picked(n.ppl_res)}))
	for pair in [[n.btn_hh_restock, "restock"], [n.btn_hh_ill, "ill"], [n.btn_hh_well, "well"]]:
		var op: String = pair[1]
		pair[0].pressed.connect(func(): _mind({"cmd": "household", "op": op,
				"id": _picked(n.ppl_res), "n": 4, "days": 2}))


func _wire_world(n: Dictionary) -> void:
	n.btn_clock_fixed.pressed.connect(
			func(): _mind({"cmd": "clock", "mode": "fixed", "hour": n.clock_hour.value}))
	n.btn_clock_scaled.pressed.connect(func(): _mind({"cmd": "clock", "mode": "scaled",
			"rate": n.clock_rate.value, "hour": n.clock_hour.value}))
	n.btn_clock_real.pressed.connect(func(): _mind({"cmd": "clock", "mode": "real"}))
	n.btn_weekday.pressed.connect(
			func(): _mind({"cmd": "clock", "weekday": WEEKDAYS[n.weekday.selected]}))
	n.btn_school.pressed.connect(func(): _mind({"cmd": "school",
			"sub": SCHOOL_OPS[n.school_op.selected], "class": n.school_class.text.strip_edges()}))
	n.btn_lesson_start.pressed.connect(func(): _mind({"cmd": "lesson", "sub": "start",
			"id": LESSONS[n.lesson_id.selected], "teacher": LESSON_TEACHER,
			"class": n.school_class.text.strip_edges()}))
	n.btn_lesson_stop.pressed.connect(func(): _mind({"cmd": "lesson", "sub": "stop",
			"id": null, "teacher": LESSON_TEACHER, "class": ""}))
	n.btn_lesson_status.pressed.connect(func(): _mind({"cmd": "lesson", "sub": "status",
			"id": null, "teacher": LESSON_TEACHER, "class": ""}))
	n.btn_event_start.pressed.connect(
			func(): _world({"op": "event", "id": n.event_id.text.strip_edges()}))
	n.btn_event_stop.pressed.connect(func(): _world({"op": "event_stop"}))
	n.btn_populate.pressed.connect(func(): _world({"op": "populate",
			"cars": int(n.pop_cars.value), "peds": int(n.pop_peds.value),
			"npcs": n.pop_npcs.button_pressed, "trams": n.pop_trams.button_pressed}))
	n.btn_sitting_start.pressed.connect(func(): _mind({"cmd": "sitting", "op": "start",
			"matter": n.sitting_matter.text.strip_edges(), "house": "both", "as_of": null,
			"members": 0}))
	n.btn_sitting_stop.pressed.connect(func(): _mind({"cmd": "sitting", "op": "stop",
			"matter": "", "house": "both", "as_of": null, "members": 0}))
	n.btn_status.pressed.connect(func(): _mind({"cmd": "status"}))
	n.rehearsal.toggled.connect(
			func(on): _mind({"cmd": "rehearsal", "op": "start" if on else "end"}))


func _wire_shots(n: Dictionary) -> void:
	n.btn_shot_add.pressed.connect(_shot_add)
	n.btn_shot_update.pressed.connect(_shot_update)
	n.btn_shot_go.pressed.connect(_shot_go)
	n.shots_list.item_activated.connect(func(_i): _shot_go())
	n.btn_shot_del.pressed.connect(_shot_delete)
	n.btn_shot_up.pressed.connect(func(): _shot_move(-1))
	n.btn_shot_down.pressed.connect(func(): _shot_move(1))
	n.btn_path_play.pressed.connect(func(): _play_path(false))
	n.btn_path_rec.pressed.connect(func(): _play_path(true))
	n.btn_path_stop.pressed.connect(_stop_path)


func _wire_record_bar(n: Dictionary) -> void:
	n.btn_rec.pressed.connect(_toggle_record)
	n.btn_snap.pressed.connect(_snapshot)
	n.fps.item_selected.connect(func(i):
		rec.fps = int(n.fps.get_item_text(i))
		_save_settings())
	n.pace.item_selected.connect(func(i):
		rec.pace_wall_clock = i == 0
		_save_settings())
	n.audio.toggled.connect(func(on):
		rec.record_audio = on
		_save_settings())
	n.out_dir.text_submitted.connect(func(t):
		rec.out_dir = t.strip_edges()
		_save_settings()
		_log("saving to " + rec.out_dir))
	n.out_dir.focus_exited.connect(func():
		if n.out_dir.text.strip_edges() != rec.out_dir:
			rec.out_dir = n.out_dir.text.strip_edges()
			_save_settings())
	n.btn_open_dir.pressed.connect(func():
		DirAccess.make_dir_recursive_absolute(rec.out_dir)
		OS.shell_open(rec.out_dir))
	n.btn_chat.pressed.connect(_send_chat)
	n.chat_text.text_submitted.connect(func(_t): _send_chat())
	n.btn_log_clear.pressed.connect(func(): n.log.clear())


func _process(delta: float) -> void:
	if not active:
		return
	_drive_camera(delta)
	_player_t += delta
	if _player_t >= 1.0:
		_player_t = 0.0
		_refresh_player()
	_shadow_player(delta)
	_apply_local_overrides()
	_sync_pose_fields()
	_status_t += delta
	if _status_t >= 0.5:
		_status_t = 0.0
		_update_status()
	if _places.is_empty() and amb != null:
		_lists_t += delta
		if _lists_t >= 4.0:
			_fill_lists()
	_save_t += delta
	if _save_t >= 10.0:
		_save_t = 0.0
		_save_settings()


## Only while the preview has focus and no fly-through runs.
func _drive_camera(delta: float) -> void:
	var move := Vector3.ZERO
	var fast := false
	var slow := false
	if ui.preview.has_focus() and _path_tween == null:
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
			move.z -= 1.0
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
			move.z += 1.0
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
			move.x -= 1.0
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
			move.x += 1.0
		if Input.is_key_pressed(KEY_E):
			move.y += 1.0
		if Input.is_key_pressed(KEY_Q):
			move.y -= 1.0
		fast = Input.is_key_pressed(KEY_SHIFT)
		slow = Input.is_key_pressed(KEY_ALT)
	rig.tick(delta, move, fast, slow)


## Takes the body's input away and parks its camera rig.
func _refresh_player() -> void:
	var p = nc.get_indexed("players:local_player") if nc != null else null
	if p == player:
		return
	player = p if p != null and is_instance_valid(p) else null
	player_cam = null
	player_rig = null
	if player == null:
		return
	if player.has_method("set_input_enabled"):
		player.set_input_enabled(false)
	player_rig = player.get_node_or_null("CamOrigin")
	if player_rig != null:
		player_rig.set_process(false)
		player_rig.set_process_unhandled_input(false)
		player_cam = player_rig.get_node_or_null("CamLook/Camera3D")
	_on_body_mode(_body_mode)
	_log("player body found: " + player.name)


func _shadow_player(_delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	if player_cam != null and is_instance_valid(player_cam):
		player_cam.global_transform = rig.camera.global_transform
	if _body_mode == 1:
		player.global_position = rig.global_position + BODY_BELOW_CAMERA


## Body mode 0 parks the body, 1 hides it and carries it with the camera, 2 drops it under the camera.
func _on_body_mode(i: int) -> void:
	_body_mode = i
	if player == null or not is_instance_valid(player):
		return
	match i:
		0:
			player.set_physics_process(true)
			player.visible = true
		1:
			player.set_physics_process(false)
			player.visible = false
		2:
			player.set_physics_process(true)
			player.visible = true
			player.global_position = rig.global_position + BODY_BELOW_CAMERA
			if "velocity" in player:
				player.velocity = Vector3.ZERO


func _apply_local_overrides() -> void:
	if env != null and ui.n.time_local.button_pressed:
		# Every frame, because the server's world_clock keeps resetting it.
		env.time_mode = env.TimeMode.MANUAL
		env.manual_time_hours = ui.n.time_slider.value


## Does not fire the fields' signals.
func _sync_pose_fields() -> void:
	_syncing = true
	var n: Dictionary = ui.n
	_set_idle(n.pos_x, rig.global_position.x)
	_set_idle(n.pos_y, rig.global_position.y)
	_set_idle(n.pos_z, rig.global_position.z)
	_set_idle(n.yaw, wrapf(rad_to_deg(rig.rotation.y), -180.0, 180.0))
	_set_idle(n.pitch, rad_to_deg(rig.rotation.x))
	_set_idle(n.roll, rad_to_deg(rig.roll))
	_set_idle(n.speed, rig.speed)
	_set_idle(n.distance, rig.distance)
	_set_idle(n.look_height, rig.look_height)
	if n.cam_mode.selected != rig.mode:
		n.cam_mode.select(rig.mode)
	_syncing = false


func _set_idle(sb: SpinBox, v: float) -> void:
	if sb.get_line_edit().has_focus():
		return
	if absf(sb.value - v) > 0.0005:
		sb.set_value_no_signal(v)


## Switches to free flight at the fields' pose.
func _on_pose_field(_v: float) -> void:
	if _syncing:
		return
	var n: Dictionary = ui.n
	if rig.mode != rig.Mode.FREE:
		rig.set_mode(rig.Mode.FREE)
	rig.global_position = Vector3(n.pos_x.value, n.pos_y.value, n.pos_z.value)
	rig.set_look(deg_to_rad(n.yaw.value), deg_to_rad(n.pitch.value), deg_to_rad(n.roll.value))


## On connecting, also starts rehearsal if it is on.
func _update_status() -> void:
	var connected: bool = nc != null and bool(nc.get("connected"))
	if connected and not _was_connected and ui.n.rehearsal.button_pressed:
		_mind({"cmd": "rehearsal", "op": "start"})
	_was_connected = connected
	var parts: Array = []
	if _rehearsal_on:
		parts.append("REHEARSAL (the city forgets)")
	if as_world:
		parts.append("THE WORLD")
	if nc != null:
		var url := str(nc.get("server_url"))
		parts.append(url + (" · connected" if nc.get("connected") else " · connecting…"))
	if env != null:
		parts.append(str(env.get_current_time_string())
				+ (" (local)" if ui.n.time_local.button_pressed else ""))
	if weather != null:
		parts.append(str(weather.current_type()))
	if amb != null:
		var res = amb.residents()
		if res is Dictionary:
			parts.append("%d residents on the map" % res.size())
	parts.append("%d fps" % int(Engine.get_frames_per_second()))
	ui.n.status.text = "  ·  ".join(parts)
	_update_rec_ui()


func _update_rec_ui() -> void:
	if rec.recording:
		var s := int(rec.elapsed_seconds())
		ui.n.rec_time.text = "%02d:%02d" % [s / 60, s % 60]
		ui.n.rec_badge.text = "● REC %02d:%02d" % [s / 60, s % 60]
		ui.n.btn_rec.text = "■ Stop  (F9)"
	else:
		ui.n.rec_badge.text = "saving…" if rec.get("_phase") != "" else ""
		ui.n.btn_rec.text = "● Record  (F9)"


## Right drag looks, middle drag pans, wheel zooms; keys are polled in _drive_camera, so only swallowed here.
func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var e := event as InputEventMouseButton
		if e.pressed:
			ui.preview.grab_focus()
			_on_preview_press(e)
		ui.preview.accept_event()
	elif event is InputEventKey:
		ui.preview.accept_event()


func _on_preview_press(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_RIGHT:
			_looking = true
			_press_pos = e.global_position
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		MOUSE_BUTTON_MIDDLE:
			_panning = true
			_press_pos = e.global_position
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		MOUSE_BUTTON_WHEEL_UP:
			rig.zoom(1.0)
		MOUSE_BUTTON_WHEEL_DOWN:
			rig.zoom(-1.0)


## A captured cursor has no position to route by, so its mouse deltas are handled here.
func _input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseMotion and (_looking or _panning):
		if _looking:
			rig.look_delta(event.relative)
		else:
			rig.pan(event.relative)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and not event.pressed:
		if (event.button_index == MOUSE_BUTTON_RIGHT and _looking) \
				or (event.button_index == MOUSE_BUTTON_MIDDLE and _panning):
			_release_mouse()
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_hotkey(event.keycode)


## F9 records, F12 snapshots, Esc lets go of a captured mouse.
func _on_hotkey(keycode: int) -> void:
	match keycode:
		KEY_F9:
			_toggle_record()
			get_viewport().set_input_as_handled()
		KEY_F12:
			_snapshot()
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			if _looking or _panning:
				_release_mouse()
				get_viewport().set_input_as_handled()


func _release_mouse() -> void:
	_looking = false
	_panning = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Input.warp_mouse(_press_pos)


func _cam_to_player() -> void:
	if player == null or not is_instance_valid(player):
		_log("no player body yet")
		return
	_frame_body(player, 0)


func _cam_to_spawn() -> void:
	rig.set_mode(rig.Mode.FREE)
	_look_at_spawn()


func _look_at_spawn() -> void:
	var sp = ws.get_node_or_null("SpawnPoint")
	var at: Vector3 = sp.global_position if sp != null else Vector3.ZERO
	rig.global_position = at + SPAWN_VIEW_OFFSET
	rig.point_at(at + Vector3.UP * 0.6)


func _cam_to_resident(id: String, how: int) -> void:
	if id == "" or amb == null:
		return
	var body = amb.resident_body(id) if amb.has_method("resident_body") else null
	if body == null:
		_log(id + " has no body on the map right now")
		return
	_frame_body(body, how)


## how: 0 stands in front of it, 1 orbits, 2 follows.
func _frame_body(body: Node3D, how: int) -> void:
	var head: Vector3 = body.global_position + Vector3.UP * rig.look_height
	match how:
		0:
			rig.set_mode(rig.Mode.FREE)
			var front: Vector3 = -body.global_transform.basis.z.normalized()
			rig.global_position = body.global_position + front * rig.distance \
					+ Vector3.UP * (rig.look_height + 0.3)
			rig.point_at(head)
		1:
			rig.aim_at(body, head, rig.Mode.ORBIT)
		2:
			rig.aim_at(body, head, rig.Mode.FOLLOW)


func _cam_to_place(i: int, orbit: bool) -> void:
	if i < 0 or i >= _places.size():
		return
	var p: Dictionary = _places[i]
	var at: Vector3 = p.gpos
	if orbit:
		rig.aim_at(null, at + Vector3.UP * 0.4, rig.Mode.ORBIT)
	else:
		rig.set_mode(rig.Mode.FREE)
		rig.global_position = at + Vector3(0, 1.4, 2.8)
		rig.point_at(at + Vector3.UP * 0.4)


func _paste_pose() -> void:
	var d = JSON.parse_string(DisplayServer.clipboard_get())
	if d is Dictionary and d.has("pos"):
		rig.set_pose(d)
	else:
		_log("clipboard holds no pose")


func _set_local_hour(h: float) -> void:
	ui.n.time_local.button_pressed = true
	ui.n.time_slider.value = h


## Leaving the local hour runs on from it until the next world_clock.
func _on_time_local(on: bool) -> void:
	if not on and env != null:
		env.time_mode = env.TimeMode.ACCELERATED
		env.accelerated_time_offset = env.manual_time_hours / 24.0
	elif on and env != null:
		ui.n.time_slider.set_value_no_signal(fmod(float(env.current_time) * 24.0, 24.0))
		ui.n.time_label.text = _hhmm(ui.n.time_slider.value)


func _on_weather(i: int) -> void:
	if weather == null:
		return
	weather.set_weather("" if i == 0 else WEATHERS[i])


func _hhmm(h: float) -> String:
	return "%02d:%02d" % [int(h) % 24, int(fmod(h, 1.0) * 60.0)]


## Keeps the selections.
func _fill_lists() -> void:
	if amb == null:
		return
	_residents = _collect_residents()
	_residents.sort()
	for ob in [ui.n.cam_res, ui.n.ppl_res]:
		_fill_options(ob, _residents, true)
	_places = _collect_places()
	_places.sort_custom(func(a, b): return a.kind + a.id < b.kind + b.id)
	var labels: Array = []
	for p in _places:
		labels.append("%s · %s" % [p.kind, p.id])
	for ob in [ui.n.cam_place, ui.n.ppl_place]:
		_fill_options(ob, labels, true)
	_log("lists: %d people, %d places" % [_residents.size(), _places.size()])


## Without the r_ prefix or events.
func _collect_residents() -> Array:
	var keys := {}
	var defs = amb.resident_defs()
	if defs is Dictionary:
		for k in defs.keys():
			keys[str(k)] = true
	var bodies = amb.residents()
	if bodies is Dictionary:
		for k in bodies.keys():
			keys[str(k)] = true
	var ids: Array = []
	for k in keys.keys():
		var id: String = k
		if id.begins_with("r_"):
			id = id.substr(2)
		if id.begins_with("evt_"):
			continue
		ids.append(id)
	return ids


## {id, kind, gpos}, gpos in world space.
func _collect_places() -> Array:
	var places: Array = []
	if amb.get("places") == null:
		return places
	for p in amb.places.collect_places():
		if not (p is Dictionary) or not p.has("pos"):
			continue
		var pos = p.pos
		var lp := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		places.append({"id": str(p.get("id", "")), "kind": str(p.get("kind", "")),
				"gpos": ws.to_global(lp)})
	return places


func _fill_options(ob: OptionButton, labels: Array, keep: bool) -> void:
	var was: int = ob.selected
	ob.clear()
	for label in labels:
		ob.add_item(label)
	if keep and was >= 0 and was < labels.size():
		ob.select(was)


func _picked(ob: OptionButton) -> String:
	if ob.selected < 0 or ob.selected >= _residents.size():
		_log("pick a person first (Refresh if the list is empty)")
		return ""
	return _residents[ob.selected]


func _picked_place(ob: OptionButton) -> String:
	if ob.selected < 0 or ob.selected >= _places.size():
		_log("pick a place first (Refresh if the list is empty)")
		return ""
	return _places[ob.selected].id


func _mind(cmd: Dictionary) -> void:
	if nc == null or not nc.get("connected"):
		_log("still connecting to the server; not sent — " + JSON.stringify(cmd))
		return
	cmd["type"] = "mind_cmd"
	nc.send_json(cmd)
	_log("→ " + JSON.stringify(cmd))


## Runs here when this window is the world process, else sends it to the server.
func _world(cmd: Dictionary) -> void:
	if as_world and amb != null and amb.has_method("handle_world_cmd"):
		amb.handle_world_cmd(cmd)
		_log("world (here): " + JSON.stringify(cmd))
		return
	if nc == null or not nc.get("connected"):
		_log("still connecting to the server; not sent — " + JSON.stringify(cmd))
		return
	cmd["type"] = "world_cmd"
	nc.send_json(cmd)
	_log("→ world " + JSON.stringify(cmd))


## Plain-text replies are only logged.
func _on_mind_reply(data) -> void:
	if not (data is Dictionary):
		return
	var ok: bool = bool(data.get("ok", false))
	_log(("← ok: " if ok else "← FAILED: ") + str(data.get("text", "")))
	var text := str(data.get("text", "")).strip_edges()
	var parsed = JSON.parse_string(text) \
			if (text.begins_with("{") or text.begins_with("[")) else null
	if parsed is Dictionary and parsed.has("rehearsal"):
		var r = parsed.rehearsal
		_rehearsal_on = bool(r.get("active", false)) if r is Dictionary else bool(r)
	if parsed is Dictionary and parsed.has("residents") and parsed.residents is Array:
		_merge_residents(parsed.residents)


func _merge_residents(ids: Array) -> void:
	var known := {}
	for r in _residents:
		known[r] = true
	var added := 0
	for r in ids:
		var id := str(r)
		if id.begins_with("r_"):
			id = id.substr(2)
		if not known.has(id):
			_residents.append(id)
			added += 1
	if added == 0:
		return
	_residents.sort()
	for ob in [ui.n.cam_res, ui.n.ppl_res]:
		_fill_options(ob, _residents, false)


func _say(voiced: bool) -> void:
	var id := _picked(ui.n.ppl_res)
	var text: String = ui.n.say_text.text.strip_edges()
	if id == "" or text == "":
		return
	_mind({"cmd": "say", "id": id, "text": text, "convert": voiced, "voice": voiced})


## Sends nothing if a place is missing.
func _plan(intents: Array) -> void:
	var id := _picked(ui.n.ppl_res)
	if id == "":
		return
	for it in intents:
		if it.has("place") and str(it.place) == "":
			return
	_mind({"cmd": "plan", "id": id, "intents": intents})


## Commands included.
func _send_chat() -> void:
	var text: String = ui.n.chat_text.text.strip_edges()
	if text == "":
		return
	ui.n.chat_text.text = ""
	if chat_ui != null and chat_ui.has_method("submit_text"):
		chat_ui.submit_text(text)
	elif nc != null:
		nc.chat.send(text)
	_log("chat: " + text)


func _shot_add() -> void:
	var name: String = ui.n.shot_name.text.strip_edges()
	if name == "":
		name = "shot %d" % (_shots.size() + 1)
	_shots.append({"name": name, "pose": rig.get_pose()})
	ui.n.shot_name.text = ""
	_refresh_shots(_shots.size() - 1)
	_save_shots()


func _shot_index() -> int:
	var sel: PackedInt32Array = ui.n.shots_list.get_selected_items()
	return sel[0] if sel.size() > 0 else -1


func _shot_update() -> void:
	var i := _shot_index()
	if i < 0:
		return
	_shots[i].pose = rig.get_pose()
	var name: String = ui.n.shot_name.text.strip_edges()
	if name != "":
		_shots[i].name = name
	_refresh_shots(i)
	_save_shots()


func _shot_go() -> void:
	var i := _shot_index()
	if i >= 0:
		rig.set_pose(_shots[i].pose)


func _shot_delete() -> void:
	var i := _shot_index()
	if i < 0:
		return
	_shots.remove_at(i)
	_refresh_shots(mini(i, _shots.size() - 1))
	_save_shots()


func _shot_move(d: int) -> void:
	var i := _shot_index()
	var j := i + d
	if i < 0 or j < 0 or j >= _shots.size():
		return
	var tmp = _shots[i]
	_shots[i] = _shots[j]
	_shots[j] = tmp
	_refresh_shots(j)
	_save_shots()


func _refresh_shots(select: int) -> void:
	var l: ItemList = ui.n.shots_list
	l.clear()
	for s in _shots:
		var p: Dictionary = s.pose
		l.add_item("%s   (%.1f, %.1f, %.1f)" % [s.name, p.pos[0], p.pos[1], p.pos[2]])
	if select >= 0 and select < _shots.size():
		l.select(select)


func _play_path(record: bool) -> void:
	if _shots.size() < 2:
		_log("a fly-through needs at least two shots")
		return
	_stop_path()
	rig.set_pose(_shots[0].pose)
	if record:
		if not rec.start():
			return
		_path_recording = true
	var secs: float = ui.n.leg_secs.value
	var ease: bool = ui.n.ease.button_pressed
	_path_tween = create_tween()
	for i in range(1, _shots.size()):
		var t := _path_tween.tween_method(
				_lerp_leg.bind(_shots[i - 1].pose, _shots[i].pose), 0.0, 1.0, secs)
		if ease:
			t.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_path_tween.finished.connect(_on_path_done)
	_log("flying %d shots, %.1f s each" % [_shots.size(), secs])


func _lerp_leg(t: float, a: Dictionary, b: Dictionary) -> void:
	rig.apply_lerp(a, b, t)


func _on_path_done() -> void:
	_path_tween = null
	if _path_recording:
		_path_recording = false
		rec.stop()


func _stop_path() -> void:
	if _path_tween != null:
		_path_tween.kill()
		_on_path_done()


func _toggle_record() -> void:
	if rec.recording:
		rec.stop()
	else:
		rec.start()
	_update_rec_ui()


func _snapshot() -> void:
	var p: String = rec.snapshot()
	_log("snapshot " + p if p != "" else "snapshot failed")


## STUDIO_OUT_DIR overrides the output folder.
func _load_settings() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://studio"))
	var cf := ConfigFile.new()
	var have := cf.load(SETTINGS_PATH) == OK
	rec.out_dir = str(cf.get_value("record", "out_dir", "")) if have else ""
	if rec.out_dir == "":
		rec.out_dir = OS.get_system_dir(OS.SYSTEM_DIR_MOVIES).path_join(Identity.value("studio_dir"))
	if OS.get_environment("STUDIO_OUT_DIR") != "":
		rec.out_dir = OS.get_environment("STUDIO_OUT_DIR")
	rec.fps = int(cf.get_value("record", "fps", 30))
	rec.pace_wall_clock = bool(cf.get_value("record", "wall_clock", true))
	rec.record_audio = bool(cf.get_value("record", "audio", true))
	var n: Dictionary = ui.n
	n.out_dir.text = rec.out_dir
	for i in n.fps.item_count:
		if int(n.fps.get_item_text(i)) == rec.fps:
			n.fps.select(i)
	n.pace.select(0 if rec.pace_wall_clock else 1)
	n.audio.set_pressed_no_signal(rec.record_audio)
	var pose = cf.get_value("camera", "pose", null)
	if pose is Dictionary and pose.has("pos"):
		rig.set_pose(pose)
	n.fov.set_value_no_signal(rig.camera.fov)
	n.fov_label.text = "%d°" % int(rig.camera.fov)


func _save_settings() -> void:
	if _selftest:
		return
	var cf := ConfigFile.new()
	cf.set_value("record", "out_dir", rec.out_dir)
	cf.set_value("record", "fps", rec.fps)
	cf.set_value("record", "wall_clock", rec.pace_wall_clock)
	cf.set_value("record", "audio", rec.record_audio)
	cf.set_value("camera", "pose", rig.get_pose())
	cf.save(SETTINGS_PATH)


func _load_shots() -> void:
	if not FileAccess.file_exists(SHOTS_PATH):
		return
	var f := FileAccess.open(SHOTS_PATH, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	if d is Array:
		_shots = []
		for s in d:
			if s is Dictionary and s.has("pose"):
				_shots.append(s)
		_refresh_shots(-1)


func _save_shots() -> void:
	var f := FileAccess.open(SHOTS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_shots, "\t"))


func _log(text: String) -> void:
	print("[Studio] " + text)
	if ui != null:
		var t := Time.get_time_dict_from_system()
		ui.n.log.append_text("[%02d:%02d:%02d] %s\n" % [
				t.hour, t.minute, t.second, text.replace("[", "[lb]")])


## Quits with 0 on success.
func _run_selftest() -> void:
	await get_tree().create_timer(4.0).timeout
	var png: String = rec.snapshot()
	print("[Studio] selftest snapshot: " + png)
	var win_img := get_viewport().get_texture().get_image()
	if win_img != null:
		win_img.save_png(rec.out_dir.path_join("studio_window.png"))
		print("[Studio] selftest window: " + rec.out_dir.path_join("studio_window.png") + " "
				+ str(ui.size) + " preview " + str(ui.preview.size))
	rig.set_mode(rig.Mode.ORBIT)
	rig.spin_deg = 40.0
	if not rec.start():
		print("[Studio] SELFTEST FAIL: recorder did not start")
		get_tree().quit(1)
		return
	await get_tree().create_timer(3.0).timeout
	rec.stop()
	var res = await rec.finished
	var ok: bool = bool(res[1]) and png != "" and rec.frames > 0
	print("[Studio] SELFTEST %s: %s (%d frames) %s" % [
			"OK" if ok else "FAIL", res[0], rec.frames, res[2]])
	get_tree().quit(0 if ok else 1)
