extends SceneTree
## Kept for old command lines. The pack list now lives in tools/packs.json and is
## built by tools/pack_builder.gd — this forwards there:
##   godot --headless --path . --script res://tools/build_packs_cli.gd [-- name ...]

const PackBuilder := preload("res://tools/pack_builder.gd")

func _init() -> void:
	print("[Packs] build_art_packs_cli.gd is superseded by build_packs_cli.gd; forwarding.")
	PackBuilder.build_all(OS.get_cmdline_user_args())
	quit(0)
