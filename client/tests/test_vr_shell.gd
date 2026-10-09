extends SceneTree
## Real copied shell + game adapter: window lifecycle, command routing,
## media/library pages, drive discovery, and local-rig selection.
const PanelScript = preload("res://src/ui/vr_chat_panel.gd")
const CHAT := "res://assets/ui/chat_ui.tscn"
const DrivesScript = preload("res://src/core/drives.gd")
const Catalog = preload("res://src/media/media_catalog.gd")

class Body extends CharacterBody3D:
	var is_remote_player := false
	var is_vr_mode := true

var failures := 0
var sent: Array[String] = []

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + label)

func _initialize() -> void:
	run.call_deferred()

func rig(remote: bool) -> Body:
	var body := Body.new()
	body.is_remote_player = remote
	var origin := XROrigin3D.new()
	origin.name = "XROrigin3D"
	body.add_child(origin)
	var cam := XRCamera3D.new()
	cam.name = "XRCamera3D"
	origin.add_child(cam)
	var hand := XRController3D.new()
	hand.name = "RightHand"
	origin.add_child(hand)
	return body

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var remote := rig(true)
	world.add_child(remote)
	var local := rig(false)
	world.add_child(local)
	local.scale = Vector3.ONE * 0.2
	var chat = (load(CHAT) as PackedScene).instantiate()
	world.add_child(chat)
	chat.message_sent.connect(func(message): sent.append(message))
	var panel := PanelScript.new()
	world.add_child(panel)
	panel.attach_chat(chat)
	panel.set_panel_visible(true)
	await process_frame
	check(panel.camera() == local.get_node("XROrigin3D/XRCamera3D"), "local camera wins over remote rig")
	check(panel.pointer._find_right_hand() == local.get_node("XROrigin3D/RightHand"), "local controller wins over remote rig")
	check(is_equal_approx(panel.world_scale(), panel.camera().global_basis.x.length()), "perceived panel size follows tracked camera scale")
	check(panel.shell.get_node("%MediaVRButton") != null, "original VR media filter exists")
	check(panel.shell.get_node("PlaybackPill") != null, "original playback controls exist")
	var movement := VRMovement.new()
	movement.character = local
	movement.xr_origin = local.get_node("XROrigin3D")
	movement.xr_camera = local.get_node("XROrigin3D/XRCamera3D")
	var before := movement.xr_camera.global_position
	movement.rotation_input = 1.0
	movement._snap_turn()
	check(is_equal_approx(movement.xr_origin.rotation.y, deg_to_rad(-30)), "source controller snaps 30 degrees")
	check(movement.xr_camera.global_position.is_equal_approx(before), "snap preserves tracked head position")
	movement._snap_turn()
	check(is_equal_approx(movement.xr_origin.rotation.y, deg_to_rad(-30)), "held stick gives only one snap")
	movement.rotation_input = 0.0
	movement._snap_turn()
	panel.pointer._hovering = true
	panel.pointer._scrolling = true
	movement.rotation_input = 1.0
	movement._snap_turn()
	check(is_equal_approx(movement.xr_origin.rotation.y, deg_to_rad(-30)), "shell scrolling suppresses turning")
	panel.pointer.cancel_press()
	movement._snap_turn()
	check(is_equal_approx(movement.xr_origin.rotation.y, deg_to_rad(-30)), "leaving scroll still requires recenter")
	movement.rotation_input = 0.0
	movement._snap_turn()
	movement.rotation_input = -1.0
	movement._snap_turn()
	check(is_zero_approx(movement.xr_origin.rotation.y), "recenter re-arms snap")
	var second = panel.spawn_window()
	await process_frame
	check(second != null and second.shell != null and second.chat_ui.vr_panel == second, "second complete shell owns its command target")
	second.chat_ui.submit_text("from second window")
	check(sent == ["from second window"], "extra window routes chat to primary network connection")
	second.chat_ui.submit_text("/media play /tmp/a video 360.mp4")
	check(second.shell.is_player_open() and not panel.shell.is_player_open(), "media command targets the submitting window")
	check(second.video.screen_mode == 2, "filename selects original 360 projection")
	second.shell.close_player_page()
	panel.spawn_window()
	panel.spawn_window()
	check(panel.all_windows().size() == 4 and panel.spawn_window() == null, "original four-window limit")
	panel.set_panel_visible(false)
	for window in panel.all_windows():
		check(not window.panel_visible, "primary hides every window")
	panel.set_panel_visible(true)
	second.shell.get_node("%CommandInput").grab_focus()
	await process_frame
	check(second.sub_viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS,
		"focused field does not render the full shell every headset frame")
	second.sub_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	second.request_redraw()
	check(second.sub_viewport.render_target_update_mode == SubViewport.UPDATE_ONCE,
		"typing still requests an immediate redraw while focused")
	second.set_panel_visible(false)
	check(second.sub_viewport.gui_get_focus_owner() == null, "hiding window releases shell keyboard focus")
	second._on_keyboard_focus(false)
	check(second.sub_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"late focus signal cannot redraw a hidden window")
	second.close_window()
	await process_frame
	check(panel.all_windows().size() == 3, "closing extra window removes it from pointer targets")
	var fixture := "/tmp/game-vr-library-test"
	DirAccess.make_dir_recursive_absolute(fixture)
	var file := FileAccess.open(fixture.path_join("sample.txt"), FileAccess.WRITE)
	file.store_string("Copied library reader smoke test")
	file.close()
	var drives := DrivesScript.new()
	drives.extra_roots = PackedStringArray([fixture])
	world.add_child(drives)
	var found := false
	for drive in drives.drives():
		found = found or drive.root == fixture
	check(found, "mounted/extra drive roots are browsable")
	check(not Catalog.list_dir(fixture).files.is_empty(), "original catalog discovers drive files")
	panel.shell.browser.enter_location(fixture)
	panel.shell.show_page("Media")
	await process_frame
	check(panel.shell.get_node("%MediaList").get_child_count() >= 2, "original library renders folder entries")
	DirAccess.remove_absolute(fixture.path_join("sample.txt"))
	DirAccess.remove_absolute(fixture)
	drives.scan_now()
	check(drives.drives().filter(func(d): return d.root == fixture).is_empty(), "unmounted drive is removed")
	world.queue_free()
	await process_frame
	await process_frame
	print("VR SHELL: %d failures" % failures)
	quit(1 if failures else 0)
