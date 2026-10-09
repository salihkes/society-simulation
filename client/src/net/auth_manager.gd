extends Node
## Login state of this client: forwards login/register to the network session and re-emits its answers.

signal login_successful(username)
signal login_failed(message)
signal register_successful(username)
signal register_failed(message)

var config = ConfigFile.new()
var config_path = "user://credentials.cfg"
var current_username = ""
var is_authenticated = false


## Logging in is left to NetworkController.
func _ready():
	var err = config.load(config_path)
	if err != OK:
		return
	var saved_username = config.get_value("auth", "username", "")
	var saved_password = config.get_value("auth", "password", "")
	if saved_username != "" and saved_password != "":
		current_username = saved_username


func register(username, password):
	get_node("/root/NetworkController").session.send_register(username, password)


## remember_me is unused: the session saves credentials on success.
func login(username, password, remember_me = false):
	get_node("/root/NetworkController").session.send_login(username, password)


## Also clears the session's saved credentials.
func logout():
	is_authenticated = false
	current_username = ""

	config.set_value("auth", "username", "")
	config.set_value("auth", "password", "")
	config.save(config_path)

	var network_controller = get_node("/root/NetworkController")
	if network_controller:
		network_controller.session.clear_saved_credentials()


func handle_login_response(success, message):
	if success:
		is_authenticated = true
		emit_signal("login_successful", current_username)
	else:
		emit_signal("login_failed", message)


func handle_register_response(success, message):
	if success:
		emit_signal("register_successful", current_username)
	else:
		emit_signal("register_failed", message)


func is_logged_in():
	return is_authenticated
