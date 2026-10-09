class_name WebViewSurface
extends RefCounted
## Android WebView (WebBridge.java) drawn into an OpenXR layer surface; every call is a no-op when closed.

## android.view.KeyEvent codes.
const KEY_ENTER := 66
const KEY_BACKSPACE := 67

var size := Vector2i(1440, 900)

var _bridge = null


static func is_supported() -> bool:
	return bridge_class() != null


## The WebBridge Java class, or null off Android or when it is missing.
static func bridge_class():
	if not OS.has_feature("android"):
		return null
	var cls = JavaClassWrapper.wrap(Identity.value("android_package") + ".WebBridge")
	JavaClassWrapper.get_exception()
	return cls


## `surface` is the JavaObject from OpenXRCompositionLayerQuad.get_android_surface().
func open(surface, surface_size: Vector2i, start_url := "") -> bool:
	if surface == null:
		return false
	_bridge = bridge_class()
	if _bridge == null:
		return false
	var runtime = Engine.get_singleton("AndroidRuntime")
	if runtime == null:
		_bridge = null
		return false
	size = surface_size
	_bridge.init(runtime.getActivity())
	_bridge.open(surface, size.x, size.y, start_url)
	if JavaClassWrapper.get_exception():
		_bridge = null
		return false
	return true


func is_open() -> bool:
	return _bridge != null


func load_url(url: String) -> void:
	if _bridge: _bridge.loadUrl(url)


func back() -> void:
	if _bridge: _bridge.goBack()


func forward() -> void:
	if _bridge: _bridge.goForward()


func reload() -> void:
	if _bridge: _bridge.reload()


func stop_loading() -> void:
	if _bridge: _bridge.stopLoading()


## uv is 0..1 across the picture; action 0 down, 1 up, 2 move, 3 cancel.
func touch(action: int, uv: Vector2) -> void:
	if _bridge == null:
		return
	_bridge.touch(action, uv.x * size.x, uv.y * size.y)


func scroll_by(dx: int, dy: int) -> void:
	if _bridge: _bridge.scrollBy(dx, dy)


func set_text_zoom(percent: int) -> void:
	if _bridge: _bridge.setTextZoom(clampi(percent, 60, 300))


func type_text(text: String) -> void:
	if _bridge and not text.is_empty(): _bridge.typeText(text)


func key(code: int) -> void:
	if _bridge: _bridge.keyCode(code)


func is_ready() -> bool:
	return _bridge != null and bool(_bridge.isReady())


func is_loading() -> bool:
	return _bridge != null and bool(_bridge.isLoading())


func progress() -> int:
	return int(_bridge.getProgress()) if _bridge else 0


func url() -> String:
	return str(_bridge.getUrl()) if _bridge else ""


func title() -> String:
	return str(_bridge.getTitle()) if _bridge else ""


func error() -> String:
	return str(_bridge.getError()) if _bridge else ""


func input_focused() -> bool:
	return _bridge != null and bool(_bridge.isInputFocused())


func can_go_back() -> bool:
	return _bridge != null and bool(_bridge.canGoBack())


func can_go_forward() -> bool:
	return _bridge != null and bool(_bridge.canGoForward())


func close() -> void:
	if _bridge:
		_bridge.close()
		JavaClassWrapper.get_exception()
		_bridge = null
