@tool
extends Node3D
## CRT television built from a CRTPreset; the origin is the cabinet's bottom centre and the screen faces -Z.

@export var preset: CRTPreset:
	set(v):
		preset = v
		if is_inside_tree() and _glass_mat != null:
			_apply_preset()
@export var reel: VideoStream
## Absolute Theora path, used when `reel` is empty; a sibling .mp3 or .ogg is the sound.
@export_global_file("*.ogv") var reel_path := ""
## Played through the set's speaker; found next to `reel_path` if empty.
@export var reel_audio: AudioStream
@export var still: Texture2D
## Live texture; overrides reel and still while set (see set_source_texture).
@export var source: Texture2D
## Show the cinema channel when `reel_path` cannot be decoded (no FFmpeg, as on iOS).
@export var cinema_fallback := true
@export var cinema_url := ""
@export var cinema_always := false
@export var autoplay := true
@export var loop := true
@export var powered := true
@export var build_cabinet := true
@export_range(0.0, 4.0) var glow_scale := 1.0

@onready var _signal: SubViewport = $Signal
@onready var _player: VideoStreamPlayer = $Signal/Source
@onready var _decode: ColorRect = $Signal/Decode
@onready var _glass: MeshInstance3D = $Glass
@onready var _cabinet: Node3D = $Cabinet
@onready var _glow: OmniLight3D = $Glow
@onready var _whine: AudioStreamPlayer3D = $Whine
@onready var _thunk: AudioStreamPlayer3D = $Thunk
@onready var _speaker: AudioStreamPlayer3D = $Speaker

const MIX_RATE := 44100
var _dec_mat: ShaderMaterial
var _glass_mat: ShaderMaterial
var _glow_acc := 0.0
var _fitted := false
var _energy := 0.0
var _tween: Tween
var _degauss_tween: Tween
var _glass_size := Vector2(0.53, 0.40)
var _src_scale := Vector2.ONE   # where the source picture sits in the raster
var _src_offset := Vector2.ZERO
var _lum_target := 0.3   # average picture luminance, sampled a few times a second
var _lum := 0.3          # the same, smoothed like a sagging supply
var _warm_scale := 1.0   # raster size during warm-up

# The cinema channel, used where no video decoder exists.
var _cinema: CinemaStream
var _cinema_tex: Texture2D

# FFmpeg reel sound: captured from a private bus, replayed on the 3D speaker.
var _capture: AudioEffectCapture
var _gen_playback: AudioStreamGeneratorPlayback


func _ready() -> void:
	if preset == null:
		preset = CRTPreset.new()
	# The packed scene's materials are shared by every instance; each set needs its own.
	_dec_mat = _decode.material.duplicate()
	_decode.material = _dec_mat
	_glass_mat = _glass.material_override.duplicate()
	_glass.material_override = _glass_mat
	_apply_preset()
	if Engine.is_editor_hint():
		# In the editor: the cabinet, the glass and a still picture, no sound.
		_signal.render_target_update_mode = SubViewport.UPDATE_ONCE
		_dec_mat.set_shader_parameter("source_tex", still if still != null else test_pattern())
		_dec_mat.set_shader_parameter("signal_present", 1.0)
		_set_glass("energy", 1.0)
		return
	_signal.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_apply_source()
	_glow.light_energy = 0.0
	_set_glass("energy", 0.0)
	_set_glass("squeeze", Vector2.ONE)
	if powered:
		_energy = 1.0
		_set_glass("energy", 1.0)
		_start_whine()


func _apply_preset() -> void:
	var p := preset
	var lines := 480
	var cycles := 188.3
	var phase := PI
	var frame_rate := 29.97
	var refresh := 59.94
	var pal := 0
	var whine_hz := 15734.0
	if p.standard == CRTPreset.Standard.PAL:
		lines = 576
		cycles = 230.5
		phase = PI * 1.5
		frame_rate = 25.0
		refresh = 50.0
		pal = 1
		whine_hz = 15625.0
	_signal.size = Vector2i(720, lines)
	_dec_mat.set_shader_parameter("samples", Vector2(720.0, float(lines)))
	_dec_mat.set_shader_parameter("cycles_per_line", cycles)
	_dec_mat.set_shader_parameter("line_phase", phase)
	_dec_mat.set_shader_parameter("frame_phase", phase)
	_dec_mat.set_shader_parameter("frame_rate", frame_rate)
	_dec_mat.set_shader_parameter("pal", pal)
	_apply_decoder(p)
	_apply_tube(p, lines, refresh)
	_build_case(p)
	_whine.stream = _synth_whine(whine_hz, refresh)
	_whine.volume_db = p.whine_db
	_thunk.stream = _synth_thunk()


func _apply_decoder(p: CRTPreset) -> void:
	_dec_mat.set_shader_parameter("cable", int(p.cable))
	_dec_mat.set_shader_parameter("luma_cut", p.luma_cut)
	_dec_mat.set_shader_parameter("i_cut", p.i_cut)
	_dec_mat.set_shader_parameter("q_cut", p.q_cut)
	_dec_mat.set_shader_parameter("prefilter", 1 if p.prefilter else 0)
	_dec_mat.set_shader_parameter("tape_wear", p.tape_wear)
	_dec_mat.set_shader_parameter("rgb_cut", p.rgb_cut)
	_dec_mat.set_shader_parameter("comb", p.comb)
	_dec_mat.set_shader_parameter("peaking", p.peaking)
	_dec_mat.set_shader_parameter("saturation", p.saturation)
	_dec_mat.set_shader_parameter("contrast", p.contrast)
	_dec_mat.set_shader_parameter("black_lift", p.black_lift)
	_dec_mat.set_shader_parameter("white_point", p.white_point)
	_dec_mat.set_shader_parameter("noise", p.noise)
	_dec_mat.set_shader_parameter("ghost", p.ghost)


func _apply_tube(p: CRTPreset, lines: int, refresh: float) -> void:
	_glass_mat.set_shader_parameter("signal_tex", _signal.get_texture())
	_glass_mat.set_shader_parameter("tilt", deg_to_rad(p.tilt))
	_glass_mat.set_shader_parameter("glass_tint", p.glass_tint)
	_glass_mat.set_shader_parameter("roughness", p.roughness)
	_glass_mat.set_shader_parameter("brightness", p.brightness)
	_glass_mat.set_shader_parameter("crt_gamma", p.crt_gamma)
	_glass_mat.set_shader_parameter("overscan", p.overscan)
	_glass_mat.set_shader_parameter("geometry", p.geometry)
	_glass_mat.set_shader_parameter("corner", p.corner)
	_glass_mat.set_shader_parameter("lines", float(lines))
	_glass_mat.set_shader_parameter("refresh", refresh)
	_glass_mat.set_shader_parameter("progressive", 1 if p.progressive else 0)
	_glass_mat.set_shader_parameter("scanline", p.scanline)
	_glass_mat.set_shader_parameter("beam_min", p.beam_min)
	_glass_mat.set_shader_parameter("beam_max", p.beam_max)
	_glass_mat.set_shader_parameter("interlace_flicker", p.interlace_flicker)
	_glass_mat.set_shader_parameter("mask_type", int(p.mask))
	_glass_mat.set_shader_parameter("mask_pitch", p.mask_pitch)
	_glass_mat.set_shader_parameter("mask_strength", p.mask_strength)
	_glass_mat.set_shader_parameter("damper_wires", p.damper_wires)
	_glass_mat.set_shader_parameter("halation", p.halation)
	_glass_mat.set_shader_parameter("halation_radius", p.halation_radius)
	_glass_mat.set_shader_parameter("bloom_spread", p.bloom_spread)
	_glass_mat.set_shader_parameter("focus_falloff", p.focus_falloff)
	_glass_mat.set_shader_parameter("convergence", p.convergence)
	_glass_mat.set_shader_parameter("phosphor", p.phosphor)
	_glass_mat.set_shader_parameter("degauss", 0.0)
	_glass_mat.set_shader_parameter("raster_scale", Vector2.ONE)


func _build_case(p: CRTPreset) -> void:
	for c in _cabinet.get_children():
		_cabinet.remove_child(c)
		c.queue_free()
	_glass_size = p.screen_size
	_glass.position = Vector3(0, p.chin + p.bezel + p.screen_size.y * 0.5, 0)
	var fitted := p.model != null and _fit_model(p)
	if not fitted and build_cabinet:
		_build_cabinet(p)
	_glass.mesh = _build_glass_mesh(_glass_size, p.curve, 32, 24)
	_glass_mat.set_shader_parameter("size", _glass_size)
	_glow.position = _glass.position + Vector3(0, 0, -0.15)
	_glow.omni_range = 1.5 + p.screen_size.x * 4.0


## Live texture, cinema channel, reel, then still; _fit_reel hands over a reel's texture later.
func _apply_source() -> void:
	_player.stop()
	_speaker.stop()
	_fitted = false
	var present := 1.0
	var stream := reel
	var sound := reel_audio
	_capture = null
	if stream == null and reel_path != "" and not (cinema_always and cinema_fallback):
		stream = _stream_for_path(reel_path)
		if sound == null and _capture == null:
			sound = _sibling_sound(reel_path)
	var want_cinema := source == null and stream == null and cinema_fallback \
		and (cinema_always or reel_path != "")
	if not want_cinema:
		_stop_cinema()
	if source != null:
		_set_source_tex(source)
	elif want_cinema:
		# Snow until the channel's first frame (_on_cinema_frame).
		_start_cinema()
		present = 0.0
	elif stream != null:
		_player.stream = stream
		_player.loop = loop
		_speaker.stream = sound
		if autoplay:
			_player.play()
			if sound != null:
				_speaker.play()
	elif still != null:
		_set_source_tex(still)
	else:
		present = 0.0
	_dec_mat.set_shader_parameter("signal_present", present)
	if _energy > 0.5:
		_start_whine()


## Theora for .ogv, else FFmpeg when present (its sound routed to the speaker), else null.
func _stream_for_path(path: String) -> VideoStream:
	if path.get_extension().to_lower() == "ogv":
		var vs := VideoStreamTheora.new()
		vs.file = path
		return vs
	if ClassDB.class_exists("FFmpegVideoStream"):
		# Any container or codec FFmpeg knows, and network streams (m3u8).
		var stream = ClassDB.instantiate("FFmpegVideoStream")
		stream.set("file", path)
		_route_player_audio()
		return stream
	if not cinema_fallback:
		push_warning("CRTTV: '%s' needs the FFmpeg extension (addons/ffmpeg); only .ogv plays without it" % path)
	return null


static func _sibling_sound(path: String) -> AudioStream:
	var base := path.get_basename()
	if FileAccess.file_exists(base + ".mp3"):
		return AudioStreamMP3.load_from_file(base + ".mp3")
	elif FileAccess.file_exists(base + ".ogg"):
		return AudioStreamOggVorbis.load_from_file(base + ".ogg")
	return null


func _start_cinema() -> void:
	if _cinema != null:
		return
	_cinema = CinemaStream.new()
	_cinema.audio_player = _speaker
	add_child(_cinema)
	_cinema.frame.connect(_on_cinema_frame)
	_cinema.open(cinema_url)


## The stream updates the texture in place except on the first frame or a size change.
func _on_cinema_frame() -> void:
	if _cinema.texture == null or _cinema.texture == _cinema_tex:
		return
	_cinema_tex = _cinema.texture
	_set_source_tex(_cinema_tex)
	_dec_mat.set_shader_parameter("signal_present", 1.0)


func _stop_cinema() -> void:
	if _cinema == null:
		return
	_cinema.close("source changed")
	_cinema.queue_free()
	_cinema = null
	_cinema_tex = null


## VideoStreamPlayer audio is not positional, so a private capture bus feeds it to the 3D speaker.
func _route_player_audio() -> void:
	if AudioServer.get_bus_index("CRTSink") < 0:
		AudioServer.add_bus()
		var sink := AudioServer.bus_count - 1
		AudioServer.set_bus_name(sink, "CRTSink")
		AudioServer.set_bus_mute(sink, true)
	var bus_name := "CRT_%d" % get_instance_id()
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "CRTSink")
		_capture = AudioEffectCapture.new()
		_capture.buffer_length = 0.5
		AudioServer.add_bus_effect(idx, _capture)
	else:
		_capture = AudioServer.get_bus_effect(idx, 0) as AudioEffectCapture
	_player.bus = bus_name
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = AudioServer.get_mix_rate()
	gen.buffer_length = 0.3
	_speaker.stream = gen
	_gen_playback = null
	_speaker.play()


func _pump_captured_audio() -> void:
	if _capture == null:
		return
	# A 3D player becomes active a frame after play().
	if not _speaker.playing:
		_speaker.play()
		_gen_playback = null
		return
	if _gen_playback == null:
		_gen_playback = _speaker.get_stream_playback()
		if _gen_playback == null:
			return
	var n := mini(_capture.get_frames_available(), _gen_playback.get_frames_available())
	if n > 0:
		_gen_playback.push_buffer(_capture.get_buffer(n))


## Keeps the shape as seen on the glass; a texture of exactly raster size fills it as a signal.
func _set_source_tex(tex: Texture2D) -> void:
	_dec_mat.set_shader_parameter("source_tex", tex)
	var vs := tex.get_size()
	var box := Vector2(_signal.size)
	if vs.x <= 0.0 or vs.y <= 0.0 or box.x <= 0.0 or box.y <= 0.0:
		return
	var sz := box
	if vs != box:
		var glass: float = _glass_size.x / maxf(_glass_size.y, 1e-6)   # raster's shape as displayed
		var sample: float = glass * box.y / box.x                       # one sample's width over its height
		var want: float = (vs.x / vs.y) / sample                        # the source's shape, in samples
		sz = Vector2(box.y * want, box.y)                               # fit the height...
		if sz.x > box.x:
			sz = Vector2(box.x, box.x / want)                           # ...then the width if it is wider
	_src_scale = sz / box
	_src_offset = (box - sz) * 0.5 / box
	_dec_mat.set_shader_parameter("src_scale", _src_scale)
	_dec_mat.set_shader_parameter("src_offset", _src_offset)
	_fitted = true


## Colour bars over 1-4 sample gratings and a fine checker, to show bandwidth, bleed and dot crawl.
static func test_pattern(w := 720, h := 480) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			img.set_pixel(x, y, _test_pattern_pixel(x, y, w, h))
	return ImageTexture.create_from_image(img)


static func _test_pattern_pixel(x: int, y: int, w: int, h: int) -> Color:
	var bars := [Color(1, 1, 1), Color(1, 1, 0), Color(0, 1, 1), Color(0, 1, 0), Color(1, 0, 1), Color(1, 0, 0), Color(0, 0, 1)]
	if y < h * 0.55:
		return bars[mini(int(float(x) / w * 7.0), 6)] * 0.75
	if y < h * 0.7:
		var pitch := mini(int(float(x) / w * 4.0), 3) + 1
		return Color.WHITE if (x / pitch) % 2 == 0 else Color.BLACK
	if y < h * 0.85:
		# Fine checker and a red/blue edge.
		if x < w / 2:
			return Color.WHITE if ((x / 2) + (y / 2)) % 2 == 0 else Color.BLACK
		return Color(0.9, 0.1, 0.1) if (x / 40) % 2 == 0 else Color(0.1, 0.1, 0.9)
	var g := float(x) / w
	return Color(g, g, g)


## Centre of the picture, in world space (for cameras and lights).
func screen_centre() -> Vector3:
	return _glass.global_position


## uv in 0..1, or (-1, -1) on a miss; ignores the tube's bulge.
func picture_uv_from_ray(origin: Vector3, dir: Vector3) -> Vector2:
	var miss := Vector2(-1, -1)
	var inv := _glass.global_transform.affine_inverse()
	var o := inv * origin
	var d := inv.basis * dir
	if absf(d.z) < 1e-6:
		return miss
	var t := -o.z / d.z
	if t <= 0.0:
		return miss
	var hit := o + d * t
	# Mesh: x = (0.5 - u) * w, y = (0.5 - v) * h (see _build_glass_mesh).
	var uv := Vector2(0.5 - hit.x / _glass_size.x, 0.5 - hit.y / _glass_size.y)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return miss
	var p := (uv - Vector2(0.5, 0.5)) * 2.0
	var tilt := deg_to_rad(preset.tilt) if preset != null else 0.0
	if tilt != 0.0:
		var q := p * _glass_size
		q = Vector2(cos(tilt) * q.x - sin(tilt) * q.y, sin(tilt) * q.x + cos(tilt) * q.y)
		p = q / _glass_size
	var geometry: float = preset.geometry if preset != null else 0.0
	var overscan: float = preset.overscan if preset != null else 0.0
	var pp := p * (1.0 + geometry * p.dot(p)) * (1.0 - overscan)
	var puv := pp * 0.5 + Vector2(0.5, 0.5)
	var suv := (puv - _src_offset) / _src_scale
	if suv.x < 0.0 or suv.x > 1.0 or suv.y < 0.0 or suv.y > 1.0:
		return miss
	return suv


## Turns the model to face -Z, scales it to screen_size.x, hides its screen part and seats our glass there.
func _fit_model(p: CRTPreset) -> bool:
	var inst: Node3D = p.model.instantiate()
	_cabinet.add_child(inst)
	var screen := inst.find_child(p.model_screen, true, false) as MeshInstance3D
	if screen == null:
		push_warning("CRTTV: model has no MeshInstance3D named '%s'; using the placeholder cabinet" % p.model_screen)
		_cabinet.remove_child(inst)
		inst.queue_free()
		return false
	var basis := _turn_to_forward(p.model_front.normalized())
	inst.transform = Transform3D(basis, Vector3.ZERO)
	var saabb := _aabb_in(screen, self)
	var scale := p.screen_size.x / maxf(saabb.size.x, 1e-6)
	inst.transform = Transform3D(basis.scaled(Vector3.ONE * scale), Vector3.ZERO)
	var whole := AABB()
	var first := true
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var a := _aabb_in(mi, self)
		whole = a if first else whole.merge(a)
		first = false
	inst.position.y -= whole.position.y
	saabb = _aabb_in(screen, self)
	screen.visible = false
	_glass_size = Vector2(saabb.size.x, saabb.size.y)
	# Seat on the rim plane, not the bounding box: modelled bulges are deeper than a real tube's.
	var rim_z := _rim_depth(screen, saabb)
	_glass.position = Vector3(saabb.get_center().x, saabb.get_center().y, rim_z)
	return true


static func _turn_to_forward(fwd: Vector3) -> Basis:
	if fwd.dot(Vector3.FORWARD) >= 0.9999:
		return Basis()
	var axis := fwd.cross(Vector3.FORWARD)
	if axis.length() < 1e-4:
		axis = Vector3.UP
	return Basis(axis.normalized(), fwd.angle_to(Vector3.FORWARD))


## Mean depth (this node's z) of the screen part's outermost vertices.
func _rim_depth(mi: MeshInstance3D, box: AABB) -> float:
	var xf := global_transform.affine_inverse() * mi.global_transform
	var c := box.get_center()
	var sum := 0.0
	var n := 0
	for si in mi.mesh.get_surface_count():
		var verts: PackedVector3Array = mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
		for v in verts:
			var w := xf * v
			if absf(w.x - c.x) > box.size.x * 0.47 or absf(w.y - c.y) > box.size.y * 0.47:
				sum += w.z
				n += 1
	if n == 0:
		return box.position.z + box.size.z
	return sum / n


func _aabb_in(mi: MeshInstance3D, ref: Node3D) -> AABB:
	var xf := ref.global_transform.affine_inverse() * mi.global_transform
	return xf * mi.get_aabb()


## null goes back to the reel or still.
func set_source_texture(tex: Texture2D) -> void:
	source = tex
	_apply_source()


func play() -> void:
	if _player.stream != null and source == null:
		_player.play()
		if _speaker.stream != null and _capture == null:
			_speaker.play(0.0)


func stop() -> void:
	_player.stop()
	_speaker.stop()


## Degauss thunk and whine, then the picture warms up over `warmup` seconds.
func power_on() -> void:
	if _energy > 0.99:
		return
	powered = true
	if _tween:
		_tween.kill()
	_thunk.play()
	_start_whine()
	_set_glass("squeeze", Vector2.ONE)
	# The purity stains fade over the next seconds, so they still show when the picture comes up.
	_set_glass("degauss", preset.degauss)
	if _degauss_tween:
		_degauss_tween.kill()
	_degauss_tween = create_tween()
	_degauss_tween.tween_method(_set_degauss, preset.degauss, 0.0, preset.warmup + 4.0).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	# After warm-up the picture comes up dim and small, overshoots, settles.
	_tween = create_tween()
	_tween.tween_interval(preset.warmup)
	_tween.tween_method(_set_energy, 0.0, 0.6, 0.35)
	_tween.parallel().tween_method(_set_warm_scale, 0.94, 0.99, 0.35)
	_tween.tween_method(_set_energy, 0.6, 1.12, 2.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_method(_set_warm_scale, 0.99, 1.006, 2.0)
	_tween.tween_method(_set_energy, 1.12, 1.0, 1.5)
	_tween.parallel().tween_method(_set_warm_scale, 1.006, 1.0, 1.5)


func _set_degauss(v: float) -> void:
	_set_glass("degauss", v)


func _set_warm_scale(v: float) -> void:
	_warm_scale = v


func power_off() -> void:
	if _energy < 0.01:
		return
	powered = false
	if _tween:
		_tween.kill()
	_whine.stop()
	_tween = create_tween()
	_tween.tween_method(_set_squeeze_y, 1.0, 0.004, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.parallel().tween_method(_set_energy, 1.0, 1.6, 0.35)
	_tween.tween_method(_set_squeeze_x, 1.0, 0.004, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.parallel().tween_method(_set_energy, 1.6, 0.0, 0.6)


## The speaker's volume follows it.
func _set_energy(v: float) -> void:
	_energy = v
	_set_glass("energy", v)
	_speaker.volume_db = preset_speaker_db() + linear_to_db(clampf(v, 0.0, 1.0) + 1e-4)


func preset_speaker_db() -> float:
	return -8.0 if preset == null else preset.speaker_db


func _set_squeeze_y(v: float) -> void:
	_set_glass("squeeze", Vector2(1.0, v))


func _set_squeeze_x(v: float) -> void:
	_set_glass("squeeze", Vector2(v, 0.004))


## Fits the whole picture for a vertical `fov_deg` and viewport `aspect`.
func viewing_transform(fov_deg: float, aspect: float, margin := 1.08) -> Transform3D:
	var xf := _glass.global_transform
	var scale := xf.basis.get_scale()
	var w: float = _glass_size.x * absf(scale.x) * margin
	var h: float = _glass_size.y * absf(scale.y) * margin
	var half_fov := deg_to_rad(maxf(1.0, fov_deg)) * 0.5
	var dist: float = (h * 0.5) / tan(half_fov)
	if aspect > 0.001:
		# Godot keeps the vertical fov, so a narrow window needs more room.
		dist = maxf(dist, (w * 0.5) / (tan(half_fov) * aspect))
	var forward: Vector3 = -xf.basis.z.normalized()
	var eye: Vector3 = xf.origin + forward * dist
	var up: Vector3 = xf.basis.y.normalized()
	return Transform3D(Basis.looking_at(xf.origin - eye, up), eye)


## Same as screen_centre().
func screen_center() -> Vector3:
	return screen_centre()


func _set_glass(name: String, v) -> void:
	_glass_mat.set_shader_parameter(name, v)


func _start_whine() -> void:
	if _whine.stream != null and not _whine.playing:
		_whine.play()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _fitted and source == null and _player.is_playing():
		_fit_reel()
	if _capture != null:
		_pump_captured_audio()
	elif _player.is_playing() and _speaker.stream != null:
		_sync_speaker()
	_glow_acc += delta
	if _glow_acc >= 0.2:
		_glow_acc = 0.0
		_sample_picture()
	# Breathing: the high voltage sags on a bright picture and the raster grows.
	_lum = lerpf(_lum, _lum_target, 1.0 - exp(-delta * 4.0))
	var scale := (1.0 + preset.breathing * (_lum - 0.3)) * _warm_scale
	_set_glass("raster_scale", Vector2(scale, scale))


## Restarts the reel's separate sound when the reel loops.
func _sync_speaker() -> void:
	if _speaker.playing and _player.stream_position + 0.05 < _speaker.get_playback_position() - 1.0:
		_speaker.play(_player.stream_position)
	elif not _speaker.playing:
		_speaker.play(_player.stream_position)


## Drives the room glow and the breathing.
func _sample_picture() -> void:
	if _energy <= 0.01:
		_glow.light_energy = 0.0
		return
	var img := _signal.get_texture().get_image()
	img.resize(8, 6, Image.INTERPOLATE_BILINEAR)
	var sum := Color(0, 0, 0)
	for y in 6:
		for x in 8:
			sum += img.get_pixel(x, y)
	var avg := sum / 48.0
	var lum := avg.r * 0.299 + avg.g * 0.587 + avg.b * 0.114
	_lum_target = lum
	var seen: Vector3 = preset.phosphor * Vector3(avg.r, avg.g, avg.b)
	_glow.light_color = Color(seen.x, seen.y, seen.z).lightened(0.35) if lum > 0.02 else Color.WHITE
	_glow.light_energy = preset.glow * glow_scale * lum * _energy * (0.5 + preset.screen_size.x)


## The reel's texture appears a frame or two after play(); letterbox it into 4:3.
func _fit_reel() -> void:
	var vt := _player.get_video_texture()
	if vt == null or vt.get_size().x <= 0:
		return
	_set_source_tex(vt)


## z(x, y) = -(cx (1 - qx^2) + cy (1 - qy^2)), bulging towards -Z; uv as seen from the front.
func _build_glass_mesh(sz: Vector2, curve: Vector2, nx: int, ny: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in ny + 1:
		var v := float(j) / ny
		var y := (0.5 - v) * sz.y
		var qy := (v - 0.5) * 2.0
		for i in nx + 1:
			var u := float(i) / nx
			var x := (0.5 - u) * sz.x      # screen-right is -X when facing -Z
			var qx := (u - 0.5) * 2.0
			var z := -(curve.x * (1.0 - qx * qx) + curve.y * (1.0 - qy * qy))
			var nrm := Vector3(-4.0 * curve.x * qx / sz.x, 4.0 * curve.y * qy / sz.y, -1.0).normalized()
			st.set_normal(nrm)
			st.set_uv(Vector2(u, v))
			st.add_vertex(Vector3(x, y, z))
	for j in ny:
		for i in nx:
			var a := j * (nx + 1) + i
			var b := a + 1
			var c := a + nx + 1
			var d := c + 1
			# Godot front faces wind clockwise as seen from the front.
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(b)
			st.add_index(d)
			st.add_index(c)
	st.generate_tangents()
	return st.commit()


func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color, rough := 0.6) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	m.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = rough
	m.material_override = mat
	m.position = pos
	parent.add_child(m)
	return m


func _build_cabinet(p: CRTPreset) -> void:
	var w := p.screen_size.x
	var h := p.screen_size.y
	var b := p.bezel
	var d := p.cabinet_depth
	var chin := p.chin
	var cy := chin + b + h * 0.5
	var total_h := h + 2.0 * b + chin
	var t := 0.03   # bezel thickness (front to back)
	var front := -0.012
	_box(_cabinet, Vector3(w + 2.0 * b, total_h, d), Vector3(0, total_h * 0.5, front + t + d * 0.5), p.body_color, 0.7)
	# The bottom bezel bar carries the chin.
	var bz := front + t * 0.5
	_box(_cabinet, Vector3(w + 2.0 * b, b, t), Vector3(0, cy + h * 0.5 + b * 0.5, bz), p.bezel_color, 0.45)
	_box(_cabinet, Vector3(w + 2.0 * b, b + chin, t), Vector3(0, (b + chin) * 0.5, bz), p.bezel_color, 0.45)
	_box(_cabinet, Vector3(b, h, t), Vector3(-w * 0.5 - b * 0.5, cy, bz), p.bezel_color, 0.45)
	_box(_cabinet, Vector3(b, h, t), Vector3(w * 0.5 + b * 0.5, cy, bz), p.bezel_color, 0.45)
	var ctrl_y := maxf(chin, b) * 0.5
	match p.controls:
		CRTPreset.Controls.FLAP:
			# The strip of buttons and the flap over the front sockets.
			_box(_cabinet, Vector3(w * 0.42, ctrl_y * 0.9, 0.004), Vector3(w * 0.05, ctrl_y, front - 0.002), p.bezel_color.darkened(0.35), 0.5)
			_box(_cabinet, Vector3(w * 0.16, ctrl_y * 0.6, 0.003), Vector3(-w * 0.3, ctrl_y, front - 0.0015), p.bezel_color.darkened(0.15), 0.5)
		CRTPreset.Controls.KNOBS:
			var kr := minf(ctrl_y * 0.42, w * 0.03)
			for i in 5:
				_add_knob(kr, Vector3(-w * 0.32 + i * w * 0.11, ctrl_y, front - 0.003))


func _add_knob(radius: float, pos: Vector3) -> void:
	var k := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = 0.006
	k.mesh = cm
	var km := StandardMaterial3D.new()
	km.albedo_color = Color(0.12, 0.12, 0.12)
	km.roughness = 0.5
	k.material_override = km
	k.rotation_degrees = Vector3(90, 0, 0)
	k.position = pos
	_cabinet.add_child(k)


## Line-rate whine plus field-rate hum, one second of whole cycles so it loops seamlessly.
func _synth_whine(line_hz: float, field_hz: float) -> AudioStreamWAV:
	var n := MIX_RATE
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / MIX_RATE
		var v := sin(TAU * line_hz * t) * 0.7 + sin(TAU * field_hz * t) * 0.25 + sin(TAU * field_hz * 2.0 * t) * 0.05
		var s := int(clampf(v, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, s)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n
	return wav


func _synth_thunk() -> AudioStreamWAV:
	var n := int(MIX_RATE * 0.45)
	var data := PackedByteArray()
	data.resize(n * 2)
	var seed := 12345
	for i in n:
		var t := float(i) / MIX_RATE
		var env := exp(-t * 9.0)
		var f := 140.0 * exp(-t * 4.0) + 35.0
		seed = (seed * 1103515245 + 12345) & 0x7fffffff
		var noise := (float(seed) / 0x7fffffff - 0.5) * exp(-t * 30.0) * 0.6
		var v := (sin(TAU * f * t) * 0.8 + noise) * env
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav
