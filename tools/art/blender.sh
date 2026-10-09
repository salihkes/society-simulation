#!/bin/bash
# BLENDER: build in studs, like Studio with F3X.
#
# Opens Blender with the "Studs" tab in the 3D view sidebar (press N):
# 0.2-stud move steps, 5° rotate steps, New Part, Material + Color,
# CanCollide, Export for Godot. tools/art/blender/studs.py explains each knob.
#
#   tools/art/blender.sh                   a new file
#   tools/art/blender.sh ~/Desktop/x.blend open this one
set -e
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
[ -x "$BLENDER" ] || { echo "[blender] Blender not found at $BLENDER (set BLENDER=…)" >&2; exit 1; }
exec "$BLENDER" "$@" --python "$HERE/tools/art/blender/studs.py"
