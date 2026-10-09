class_name TheaterScreen
extends Node3D
## Video screen drawn as an OpenXR composition layer: sharpest picture, but never occluded. Quest only; +Z faces the viewer.

signal media_ready(width: int, height: int, duration_ms: int)
signal playback_finished
signal playback_failed(message: String)

const AndroidPlayer := preload("res://src/media/android_media_player.gd")

## Max size in world meters; the picture is aspect-fitted inside this box.
@export var screen_size := Vector2(8.0, 4.5)
@export var surface_resolution := Vector2i(1920, 1080)
@export var loop := true
@export_range(0.0, 1.0) var volume := 1.0
## Opened automatically on ready.
@export var autoplay_source := ""

var _layer: OpenXRCompositionLayerQuad
var _surface = null
var _player = null
var _pending := ""


func _ready() -> void:
	var xr := XRServer.find_interface("OpenXR")
	if not AndroidPlayer.is_supported() or xr == null or not xr.is_initialized():
		return
	_layer = OpenXRCompositionLayerQuad.new()
	_layer.use_android_surface = true
	_layer.android_surface_size = surface_resolution
	_layer.quad_size = screen_size
	_layer.sort_order = 1
	add_child(_layer)
	if not autoplay_source.is_empty():
		open(autoplay_source)


## Queues `source`; it opens once the layer's Android surface exists.
func open(source: String) -> void:
	if _layer == null:
		playback_failed.emit("TheaterScreen needs the Quest build")
		return
	_pending = source


func play() -> void:
	if _player: _player.play()


func pause() -> void:
	if _player: _player.pause()


func stop() -> void:
	if _player: _player.stop()


func _exit_tree() -> void:
	if _player:
		_player.release()
		_player = null


func _process(_delta: float) -> void:
	if _player:
		_player.poll()
	if _pending.is_empty() or _layer == null:
		return
	if _surface == null:
		_surface = _layer.get_android_surface()
	if _surface == null:
		return
	var src := _pending
	_pending = ""
	if _player:
		_player.release()
	_player = AndroidPlayer.new()
	_player.prepared.connect(func(w, h, dur):
		if w > 0 and h > 0:
			var k: float = minf(screen_size.x / w, screen_size.y / h)
			_layer.quad_size = Vector2(w, h) * k
		_player.set_volume(volume)
		_player.play()
		media_ready.emit(w, h, dur))
	_player.completed.connect(func(): playback_finished.emit())
	_player.failed.connect(func(msg): playback_failed.emit(msg))
	_player.open(src, _surface, loop)
