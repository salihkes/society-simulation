@tool
extends EditorScript
## Builds a mountable .pck for every heavy art model folder so the server can
## deliver it at runtime instead of baking it into the game. This is the art-map
## sibling of build_character_packs.gd (which does the same for custom
## characters), and it is why res://assets/art/models is EXCLUDED from the game
## export (see export_presets.cfg) — that ~161 MB of terrain/monument/etc. ships
## as on-demand PCKs, keeping the base build small.
##
## HOW TO RUN
##   Editor:   open this file in the Godot script editor and choose
##             File ▸ Run (Ctrl+Shift+X). Watch the Output panel.
##   Headless: godot --headless --path . --script res://tools/build_art_packs_cli.gd
##
## The implementation lives in tools/art_pack_builder.gd (shared with the CLI
## entry point). What it does, in short:
##
##   For each folder under res://assets/art/models/<name>/ it writes <name>.pck into
##   the server's asset dir:
##       ../server/assets/pck/<name>.pck
##   A folder containing a ".packgroup" marker file is a pack GROUP instead:
##   each of its subfolders becomes its own pack, <group>_<sub>.pck (used by the
##   split city under city_compare/).
##
##   Each pack carries the folder's scene/resource files (.scn/.tscn/.tres/...)
##   plus every *.import sidecar and its imported artifacts
##   (res://.godot/imported/*). That is exactly what Godot needs to resolve the
##   model at its original res:// path once the pack is mounted with
##   ProjectSettings.load_resource_pack() (done by PCKManager).
##
##   Raw source assets (.glb / .fbx / .png / .jpg) are intentionally NOT packed —
##   the game loads their imported artifacts, so the pack stays a fraction of the
##   source size.
##
## PREFERENCE / GATING
##   The pack itself carries no "required"/"priority"/"scene_path" — those live
##   in server/assets/pck_manifest.json so you can tune them without
##   re-exporting. For each pack this tool prints a suggested manifest entry
##   (with scene_path pre-filled if the folder has a main.scn/main.tscn). Paste
##   it in and set required/priority to taste. Example already shipped:
##       map      -> required:true,  priority:10   (terrain: absolutely necessary)
##       monument -> required:false, priority:50   (optional, downloads after)
##
## AFTER RUNNING
##   The server auto-discovers new .pck files (server/pck_server.py
##   get_pck_manifest), and the version string is derived from the file, so
##   re-running after a change makes every client re-download only that pack.

const ArtPackBuilder := preload("res://tools/art_pack_builder.gd")

func _run() -> void:
	ArtPackBuilder.build_all()
