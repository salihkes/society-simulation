#!/bin/bash
# Serve the published country map with pck_server's own handler on a spare
# port, then run test_region_files.gd against it. Publish first:
# tools/bake/publish_region.sh
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
. "$ROOT/tools/env.sh"
PY="${PYTHON:-$GAME_VENV_PY}"
[ -x "$PY" ] || PY=python3
PORT="${REGION_TEST_PORT:-18099}"
cd "$ROOT/server" || exit 1
"$PY" -c "
import asyncio, pck_server
async def main():
    s = await asyncio.start_server(pck_server.handle_http_request, '127.0.0.1', $PORT)
    async with s: await s.serve_forever()
asyncio.run(main())" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.1; done
REGION_TEST_URL="http://127.0.0.1:$PORT/pck/region/" \
  "$GODOT" --headless --path "$HERE" -s tests/test_region_files.gd
