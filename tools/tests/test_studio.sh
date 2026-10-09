#!/bin/bash
# The studio's self test: opens the studio (a window; this needs a display),
# takes a snapshot, records three seconds, and quits 0 when the clip and the
# PNG exist. Runs against whatever server is up, or offline if none.
#   tools/tests/test_studio.sh
set -e
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
OUT="${STUDIO_TEST_OUT:-${TMPDIR:-/tmp}/game_studio_test}"
rm -rf "$OUT"; mkdir -p "$OUT"
# Clips go to $OUT; the self test never writes the owner's saved settings.
export STUDIO_SELFTEST=1 STUDIO_OUT_DIR="$OUT"
"$GODOT" --path "$HERE/client" --resolution 1480x920 res://assets/scenes/workspace_local.tscn \
  -- --studio --server "${GAME_SERVER:-ws://127.0.0.1:2053}" 2>&1 | tee "$OUT/log.txt" | grep -E '^\[Studio' || true
grep -q 'SELFTEST OK' "$OUT/log.txt"
