#!/bin/bash
# The WORLD process: the city game running headless as the server's one
# authoritative simulation (ARCHITECTURE.md). It connects with role "world",
# never spawns a player, keeps retrying until the server is up, and is
# always elected ambient authority. Players connect to the same server.
#   tools/run/world.sh                          → ws://127.0.0.1:2053
#   GAME_SERVER=wss://host/mv tools/run/world.sh
#   tools/run/world.sh --scene res://assets/scenes/workspace.tscn
set -e
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
SCENE="res://assets/scenes/workspace_local.tscn"
if [ "${1:-}" = "--scene" ]; then SCENE="$2"; shift 2; fi
SERVER="${GAME_SERVER:-ws://127.0.0.1:2053}"
# --xr-mode off: headless still tries to bring up OpenXR and logs six
# errors finding no runtime. tools/dev/check_life.py has always passed it.
exec "$GODOT" --headless --xr-mode off --path "$HERE/client" "$SCENE" -- --world --server "$SERVER" "$@"
