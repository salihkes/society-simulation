extends Node
## Names the game window after identity.json's window_title.


func _ready() -> void:
	get_window().title = str(Identity.value("window_title"))
