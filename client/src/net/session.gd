## Session: login, register and web SSO, the saved credentials, auto-login and the voice username.
class_name NetSession
extends RefCounted

const SSO_MAX_RETRIES := 3
const CREDENTIALS_PATH := "user://credentials.json"
const OLD_CREDENTIALS_PATH := "user://credentials.cfg"
const NetworkControllerScript := preload("res://src/net/network_controller.gd")

## The last logged-in account, for auto-login and offline play.
var saved_username := ""

var _nc: NetworkControllerScript = null
var _saved_password := ""
var _pending_login_username := ""
var _pending_login_password := ""
var _sso_retry_count := 0


func _init(controller: NetworkControllerScript):
	_nc = controller


func register_handlers() -> void:
	_nc.register_handler("login_response", _msg_login_response)
	_nc.register_handler("register_response", _msg_register_response)
	_nc.register_handler("login_success", _on_login_success)


func ensure_auth_manager():
	if _nc.get_node_or_null("/root/AuthManager"):
		return
	var auth_manager = load("res://src/net/auth_manager.gd").new()
	auth_manager.name = "AuthManager"
	_nc.get_tree().root.add_child(auth_manager)
	_nc.connect("login_response", Callable(auth_manager, "handle_login_response"))
	_nc.connect("register_response", Callable(auth_manager, "handle_register_response"))


## An old .cfg file is migrated to JSON.
func load_credentials():
	if _load_old_credentials():
		return

	if not FileAccess.file_exists(CREDENTIALS_PATH):
		print("No saved credentials found")
		return
	var file = FileAccess.open(CREDENTIALS_PATH, FileAccess.READ)
	if not file:
		return
	var json_string = file.get_as_text()
	file.close()

	var json = JSON.new()
	if json.parse(json_string) != OK:
		print("Failed to parse credentials file")
		return
	var data = json.data
	if data.has("username") and data.has("password"):
		saved_username = data.username
		_saved_password = data.password
		print("Loaded saved credentials for user: ", saved_username)
	else:
		print("Invalid credentials file format")


func _load_old_credentials() -> bool:
	if not FileAccess.file_exists(OLD_CREDENTIALS_PATH):
		return false
	var config = ConfigFile.new()
	if config.load(OLD_CREDENTIALS_PATH) != OK:
		return false
	saved_username = config.get_value("auth", "username", "")
	_saved_password = config.get_value("auth", "password", "")
	if saved_username == "" or _saved_password == "":
		return false
	print("Loaded saved credentials from OLD format (.cfg) for user: ", saved_username)
	_save_credentials(saved_username, _saved_password)
	print("Migrated credentials to new JSON format")
	return true


func _save_credentials(username: String, password: String):
	var data = {
		"username": username,
		"password": password
	}

	var json_string = JSON.stringify(data)
	var file = FileAccess.open(CREDENTIALS_PATH, FileAccess.WRITE)

	if file:
		file.store_string(json_string)
		file.close()
		print("Saved credentials for user: ", username)
	else:
		print("Failed to save credentials")


func clear_saved_credentials():
	saved_username = ""
	_saved_password = ""

	if FileAccess.file_exists(CREDENTIALS_PATH):
		DirAccess.remove_absolute(CREDENTIALS_PATH)
		print("Cleared saved credentials")
	else:
		print("No saved credentials to clear")


## Web logs in through the site's SSO; a VR headset with saved credentials logs in with them.
func auto_login():
	if OS.has_feature("web"):
		print("=== WEB SSO AUTO-LOGIN CHECK ===")
		await _nc.get_tree().create_timer(0.5).timeout
		_try_web_sso_login()
		return

	var xr_interface = XRServer.find_interface("OpenXR")
	var is_vr = xr_interface and xr_interface.is_initialized()
	if saved_username == "" or _saved_password == "" or not is_vr:
		return

	print("=== AUTO-LOGIN TRIGGERED (VR MODE) ===")
	print("Auto-logging in with saved credentials for user: ", saved_username)
	_pending_login_username = saved_username
	_pending_login_password = _saved_password

	await _nc.get_tree().create_timer(0.5).timeout
	_nc.send_json({
		"type": "login",
		"username": saved_username,
		"password": _saved_password
	})
	print("Auto-login request sent")


## The credentials are saved when login_success arrives.
func send_login(username: String, password: String):
	if not _nc.connected:
		print("Not connected to server")
		return

	_pending_login_username = username
	_pending_login_password = password

	_nc.send_json({
		"type": "login",
		"username": username,
		"password": password
	})
	print("Login request sent for user: ", username)


func send_register(username: String, password: String):
	if not _nc.connected:
		print("Not connected to server")
		return

	_nc.send_json({
		"type": "register",
		"username": username,
		"password": password
	})
	print("Register request sent for user: ", username)


func send_token_login(token: String):
	if not _nc.connected:
		print("[SSO] Not connected to server")
		return

	print("[SSO] Sending token login request...")
	_nc.send_json({
		"type": "token_login",
		"token": token
	})


func _msg_login_response(data) -> void:
	_nc.emit_signal("login_response", data.success, data.message)


func _msg_register_response(data) -> void:
	_nc.emit_signal("register_response", data.success, data.message)


## Also saves the credentials used and re-announces the name to voice chat.
func _on_login_success(data):
	_nc.local_username = data.username
	print("=== LOGIN SUCCESS ===")
	print("Login successful, username updated to: ", _nc.local_username)

	if not _nc.workspace.all_plots.is_empty():
		print("NetworkController: Login success, re-checking plots...")
		_nc.workspace.check_user_plot()

	if _pending_login_username != "" and _pending_login_password != "":
		_save_credentials(_pending_login_username, _pending_login_password)
		saved_username = _pending_login_username
		_saved_password = _pending_login_password
		print("Credentials saved for future auto-login")
		_pending_login_username = ""
		_pending_login_password = ""

	var me = _nc.players.local_player
	if is_instance_valid(me) and me.name.begins_with("Guest"):
		print("Renaming local player from '", me.name, "' to: ", _nc.local_username)
		me.name = _nc.local_username

	await _nc.get_tree().create_timer(0.2).timeout
	print("Updating voice chat with username: ", _nc.local_username)
	update_voice_username()

	_nc.login_response.emit(true, "Login successful")


## Tells every microphone player and the MicrophoneSender the current username.
func update_voice_username():
	var username: String = _nc.local_username
	print("=== _update_voice_chat_username called ===")
	print("Current username: ", username)

	if username == "":
		print("WARNING: Username is empty, skipping voice chat update")
		return

	var players = _nc.get_tree().get_nodes_in_group("players")
	print("Found ", players.size(), " players in 'players' group")
	for player in players:
		var voice_player = player.find_child("MicrophoneAudioPlayer", true, false)
		if voice_player and voice_player.has_method("update_voice_username_from_network"):
			print("  - Updating MicrophoneAudioPlayer for: ", player.name)
			voice_player.update_voice_username_from_network()

	var me = _nc.players.local_player
	if me:
		print("Checking local player: ", me.name)
		var voice_player = me.find_child("MicrophoneAudioPlayer", true, false)
		if voice_player and voice_player.has_method("update_voice_username_from_network"):
			print("  - Updating local player's MicrophoneAudioPlayer")
			voice_player.update_voice_username_from_network()

	_update_mic_sender_username()
	print("=== _update_voice_chat_username finished ===")


func _update_mic_sender_username():
	var workspace = _nc.get_tree().get_root().find_child("workspace", true, false)
	print("Looking for MicrophoneSender in workspace...")
	if not workspace:
		print("  - WARNING: Workspace not found")
		return
	var mic_sender = workspace.find_child("MicrophoneSender", true, false)
	if not mic_sender:
		print("  - WARNING: MicrophoneSender not found in workspace")
		return
	print("  - Found MicrophoneSender, updating username to: ", _nc.local_username)
	if mic_sender.has_method("update_voice_username_from_network"):
		mic_sender.update_voice_username_from_network()
	else:
		print("  - WARNING: MicrophoneSender doesn't have update_voice_username_from_network method")


## Web only.
func _try_web_sso_login():
	if not OS.has_feature("web"):
		print("[SSO] Not running in web mode, skipping SSO")
		return

	print("[SSO] Attempting web SSO login (attempt ", _sso_retry_count + 1, "/", SSO_MAX_RETRIES, ")...")
	_setup_sso_callback()


## Sets window.godotSSOResult from a page token, URL parameters or /api/game-token; read 0.5 s later.
func _setup_sso_callback():
	var callback = JavaScriptBridge.create_callback(_on_sso_token_received)
	set_meta("sso_callback", callback)

	var js_code = "\n\t\t(async function() {\n\t\t\t// Method 1: Check for pre-injected token (set by the embedding page)\n\t\t\tif (window.PBRP_SSO_TOKEN && window.PBRP_SSO_USERNAME) {\n\t\t\t\tconsole.log('[Godot SSO] Using pre-injected token for:', window.PBRP_SSO_USERNAME);\n\t\t\t\twindow.godotSSOResult = {\n\t\t\t\t\tsuccess: true, \n\t\t\t\t\ttoken: window.PBRP_SSO_TOKEN, \n\t\t\t\t\tusername: window.PBRP_SSO_USERNAME\n\t\t\t\t};\n\t\t\t\treturn;\n\t\t\t}\n\t\t\t\n\t\t\t// Method 2: Check URL parameters (for redirect scenarios)\n\t\t\tconst urlParams = new URLSearchParams(window.location.search);\n\t\t\tconst urlToken = urlParams.get('sso_token');\n\t\t\tconst urlUsername = urlParams.get('sso_username');\n\t\t\tif (urlToken && urlUsername) {\n\t\t\t\tconsole.log('[Godot SSO] Using URL token for:', urlUsername);\n\t\t\t\twindow.godotSSOResult = {\n\t\t\t\t\tsuccess: true,\n\t\t\t\t\ttoken: urlToken,\n\t\t\t\t\tusername: urlUsername\n\t\t\t\t};\n\t\t\t\treturn;\n\t\t\t}\n\t\t\t\n\t\t\t// Method 3: Fetch token from API (requires same-origin)\n\t\t\ttry {\n\t\t\t\tconsole.log('[Godot SSO] Fetching auth token from /api/game-token...');\n\t\t\t\tconst response = await fetch('/api/game-token', {\n\t\t\t\t\tmethod: 'GET',\n\t\t\t\t\tcredentials: 'same-origin',\n\t\t\t\t\theaders: {\n\t\t\t\t\t\t'Accept': 'application/json'\n\t\t\t\t\t}\n\t\t\t\t});\n\t\t\t\t\n\t\t\t\tconsole.log('[Godot SSO] Response status:', response.status);\n\t\t\t\t\n\t\t\t\tif (!response.ok) {\n\t\t\t\t\twindow.godotSSOResult = {success: false, message: 'HTTP ' + response.status + ': ' + response.statusText};\n\t\t\t\t\treturn;\n\t\t\t\t}\n\t\t\t\t\n\t\t\t\tconst data = await response.json();\n\t\t\t\tconsole.log('[Godot SSO] Response data:', data);\n\t\t\t\t\n\t\t\t\tif (data.success && data.token) {\n\t\t\t\t\twindow.godotSSOResult = {success: true, token: data.token, username: data.username};\n\t\t\t\t\tconsole.log('[Godot SSO] Token received for:', data.username);\n\t\t\t\t} else {\n\t\t\t\t\twindow.godotSSOResult = {success: false, message: data.message || 'Not authenticated on website'};\n\t\t\t\t\tconsole.log('[Godot SSO] Not authenticated:', data.message);\n\t\t\t\t}\n\t\t\t} catch (error) {\n\t\t\t\tconsole.error('[Godot SSO] Fetch error:', error);\n\t\t\t\twindow.godotSSOResult = {success: false, message: 'Fetch error: ' + (error.message || error.toString())};\n\t\t\t}\n\t\t})();\n\t"
	JavaScriptBridge.eval(js_code)

	await _nc.get_tree().create_timer(0.5).timeout
	_check_sso_result()


## Retries up to SSO_MAX_RETRIES times.
func _check_sso_result():
	var result_json = JavaScriptBridge.eval("JSON.stringify(window.godotSSOResult || {success: false, message: 'Result not set - fetch may still be pending'})")

	print("[SSO] Raw result from JS: ", result_json)

	if not result_json:
		print("[SSO] No SSO result available from JavaScript")
		return
	var json = JSON.new()
	if json.parse(result_json) != OK:
		print("[SSO] Failed to parse SSO result JSON")
		return
	var result = json.data

	if result.get("success", false):
		var token = result.get("token", "")
		var username = result.get("username", "")
		print("[SSO] Token received for user: ", username)
		_sso_retry_count = 0
		send_token_login(token)
		return

	var message = result.get("message", "No message provided")
	print("[SSO] Token retrieval failed: ", message)

	_sso_retry_count += 1
	if _sso_retry_count < SSO_MAX_RETRIES:
		print("[SSO] Retrying in 1 second... (", _sso_retry_count, "/", SSO_MAX_RETRIES, ")")
		JavaScriptBridge.eval("window.godotSSOResult = null;")
		await _nc.get_tree().create_timer(1.0).timeout
		_try_web_sso_login()
	else:
		print("[SSO] Max retries reached. This usually means:")
		print("[SSO]   1. User is not logged in on the website, OR")
		print("[SSO]   2. Game is not served from the same origin as the website")
		_sso_retry_count = 0


func _on_sso_token_received(args):
	if args.size() > 0:
		var result = args[0]
		print("[SSO] Callback received: ", result)
