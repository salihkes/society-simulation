#!/bin/bash
# The web build's self test. Exports the streamed-pack web build, then loads the
# exported pck outside a browser, mounts every pack and checks that each
# placeholder the export baked in really has a pack to come from.
#
# This is the guard against the quiet failure the streaming split invites: the
# export preset is a blocklist, so content excluded from the main pck but never
# declared in tools/packs.json vanishes from the web build without any warning.
#
#   tools/tests/test_web.sh              # build the packs too (slow, thorough)
#   SKIP_PACKS=1 tools/tests/test_web.sh # packs are already current
set -e
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || { echo "[web] Godot not found at $GODOT (set GODOT=…)" >&2; exit 1; }

if [ -z "$SKIP_PACKS" ]; then
  echo "[web] building streamed packs…"
  "$GODOT" --headless --path "$HERE/client" \
    --script res://tools/build_packs_cli.gd 2>&1 | grep '\[Packs\]' || true
fi

echo "[web] exporting 'Web Local'…"
"$GODOT" --headless --path "$HERE/client" \
  --export-release "Web Local" ../web/play/index.html 2>&1 \
  | grep 'PackStreaming' || true

PCK="$HERE/web/play/index.pck"
echo "[web] main pck: $(du -h "$PCK" | cut -f1)"

# The check must run from an empty directory: inside the project folder the
# editor binary reads the project files instead of the pck and always passes.
RUN="${TMPDIR:-/tmp}/game_web_test"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$HERE/client/tests/verify_web.gd" "$RUN/verify_web.gd"
cd "$RUN"
GAME_PCK_DIR="$HERE/server/assets/pck/" \
  "$GODOT" --headless --path . --main-pack "$PCK" -s res://verify_web.gd 2>&1 \
  | grep -E '^\[verify\]|^   res://|^\[PCK Manager\] Materialized'
