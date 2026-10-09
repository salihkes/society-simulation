extends SceneTree
## Headless entry point for the streamed-pack build (tools/pack_builder.gd):
##   godot --headless --path . --script res://tools/build_packs_cli.gd
## Optionally limit to specific packs:
##   godot ... --script res://tools/build_packs_cli.gd -- home_city street_props

const PackBuilder := preload("res://tools/pack_builder.gd")

func _init() -> void:
	PackBuilder.build_all(OS.get_cmdline_user_args())
	quit(0)
