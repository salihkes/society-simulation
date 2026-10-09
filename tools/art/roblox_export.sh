#!/bin/bash
# ROBLOX EXPORT: every model named Export_… becomes its own OBJ.
#
# Installs the "Export_ to OBJ" button into Roblox Studio's Plugins tab and
# waits for it. In Studio press the button: each Model / Folder / Part whose
# name starts with Export_ is written as Export_Name.obj + .mtl, in studs,
# centred on the model's pivot, one material per Material + Color.
#
#   tools/art/roblox_export.sh                    files go to ~/Desktop/Roblox Export
#   tools/art/roblox_export.sh ~/Desktop/Shop     … to this folder
#
# The first press, Studio asks to allow HTTP to localhost: allow it.
# Restart Studio once after the first install so it picks the plugin up.
# Studio's Output window and this terminal both list anything skipped.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGINS="$HOME/Documents/Roblox/Plugins"
mkdir -p "$PLUGINS"
if ! cmp -s "$HERE/roblox_export/ExportOBJ.lua" "$PLUGINS/ExportOBJ.lua"; then
  cp "$HERE/roblox_export/ExportOBJ.lua" "$PLUGINS/ExportOBJ.lua"
  echo "[roblox_export] plugin installed to $PLUGINS — restart Studio if it is open"
fi
exec python3 "$HERE/roblox_export/server.py" "${1:-$HOME/Desktop/Roblox Export}"
