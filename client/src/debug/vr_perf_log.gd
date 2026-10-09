extends Node
## Passive headset perf log on mobile; it only reads monitors and never changes state.

const EVERY := 2.0

var _t := 0.0
var _frames := 0
var _physics_start := 0


func _ready() -> void:
	if not OS.has_feature("mobile"):
		set_process(false)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	_physics_start = Engine.get_physics_frames()
	print("[Perf] passive diagnostics; process_peak includes rendering sync/draw")
	var xr := XRServer.find_interface("OpenXR")
	if xr != null:
		print("[Perf] XR refresh=%s max_fps=%d low_cpu=%s vsync=%d" % [
			str(xr.get_display_refresh_rate()) if xr.has_method("get_display_refresh_rate") else "?",
			Engine.max_fps, str(OS.low_processor_usage_mode), DisplayServer.window_get_vsync_mode()])
	else:
		print("[Perf] no OpenXR interface; max_fps=%d" % Engine.max_fps)


func _process(delta: float) -> void:
	_t += delta
	_frames += 1
	if _t < EVERY:
		return
	_t = 0.0
	var physics_now := Engine.get_physics_frames()
	var ticks_per_frame := float(physics_now - _physics_start) / _frames
	_physics_start = physics_now
	_frames = 0
	print("[Perf] fps=%.1f process_peak=%.1fms physics_peak=%.1fms physics_ticks/frame=%.2f | draw=%d prims=%d | tex=%.0fMB vram=%.0fMB | bodies=%d pairs=%d islands=%d nodes=%d" % [
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		ticks_per_frame,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
