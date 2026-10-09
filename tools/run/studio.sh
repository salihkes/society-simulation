#!/bin/bash
# STUDIO: record the city without walking it.
#
# Opens the game wrapped in a control panel: a free camera rendered at
# exactly 1024×768 (what the recorder writes, pixel for pixel), time /
# weather / slow motion for this window, the people and the world driven
# through the server, saved shots and fly-throughs. F9 records, F12 snapshots;
# clips land in ~/Movies/<studio_dir of client/data/identity.json>.
#
# Two ways in — neither restarts a running city:
#   tools/run/studio.sh                          ATTACH: a client of the running city (the local
#                                            server if it answers, else GAME_PUBLIC_SERVER)
#   tools/run/studio.sh wss://example.com/mv     … of this server
#   tools/run/studio.sh --world                  BE THE WORLD: this window is the city's authority.
#                                            A local server that answers is used; with none,
#                                            the server is started here and stopped with the studio.
#   tools/run/studio.sh --world --clean          … with a server that begins with NO memories (a
#                                            scratch copy, gone at shutdown); --readonly likewise
#   tools/run/studio.sh --scene res://…          another scene
#
# The studio records the city or nothing: it does not start without a
# server, and once open it keeps waiting for that server rather than
# playing offline. Needs ffmpeg for video (brew install ffmpeg).
set -e
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
SCENE="res://assets/scenes/workspace_local.tscn"
SERVER="${GAME_SERVER:-}"
. "$HERE/tools/env.sh"
LOCAL="ws://127.0.0.1:2053"
PUBLIC="${GAME_PUBLIC_SERVER:-}"
WORLD=0
SERVER_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --scene) SCENE="$2"; shift ;;
    --world) WORLD=1 ;;
    --clean|--fresh|--amnesia|--readonly|--read-only|--ephemeral) SERVER_ARGS+=("$1") ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    ws://*|wss://*) SERVER="$1" ;;
    *) echo "[studio] unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
say() { printf '[studio] %s\n' "$1" >&2; }
[ -x "$GODOT" ] || { say "Godot not found at $GODOT (set GODOT=…)"; exit 1; }

# Does anything listen behind a ws:// or wss:// URL? (nc with a 3 s limit;
# bash's own /dev/tcp hangs on a host that does not answer.)
answers() {  # $1 = url
  local hp host port
  hp="${1#*://}"; hp="${hp%%/*}"; host="${hp%%:*}"; port="${hp##*:}"
  if [ "$port" = "$host" ]; then
    case "$1" in wss://*) port=443 ;; *) port=80 ;; esac
  fi
  nc -z -G 3 "$host" "$port" >/dev/null 2>&1
}

# ── which server ──────────────────────────────────────────────────────
SERVER_PID=""
if [ "$WORLD" = 1 ]; then
  if pgrep -qf "Godot.*--world" 2>/dev/null; then
    say "a world process is already running on this machine. Exactly one may run:"
    say "attach to it instead (tools/run/studio.sh without --world)."
    exit 1
  fi
  if [ -n "$SERVER" ]; then
    answers "$SERVER" || { say "nothing answers at $SERVER"; exit 1; }
  elif answers "$LOCAL"; then
    if [ ${#SERVER_ARGS[@]} -gt 0 ]; then
      say "a server is already up at $LOCAL; ${SERVER_ARGS[*]} needs one of its own — stop it, or leave the flag out."
      exit 1
    fi
    SERVER="$LOCAL"
  else
    SERVER="$LOCAL"
    say "no server at $LOCAL — starting one here (${SERVER_ARGS[*]:-plain ws}); it stops with the studio"
    ( cd "$HERE/server" && exec ./run.sh ${SERVER_ARGS[@]+"${SERVER_ARGS[@]}"} ) &
    SERVER_PID=$!
    n=0
    until answers "$LOCAL"; do
      sleep 0.5; n=$((n + 1))
      kill -0 "$SERVER_PID" 2>/dev/null || { say "the server stopped before it was listening"; exit 1; }
      [ "$n" -gt 240 ] || continue
      say "the server was not listening after 120 s; giving up"; kill "$SERVER_PID" 2>/dev/null; exit 1
    done
    say "the server is listening"
  fi
else
  if [ -n "$SERVER" ]; then
    answers "$SERVER" || { say "nothing answers at $SERVER — the studio records the running city, so it needs one."; say "start it (tools/run/city.sh) or give the studio a server that is up."; exit 1; }
  elif answers "$LOCAL"; then
    SERVER="$LOCAL"
  elif [ -n "$PUBLIC" ] && answers "$PUBLIC"; then
    SERVER="$PUBLIC"
  else
    say "no server answers: not $LOCAL${PUBLIC:+, not $PUBLIC}."
    say "the studio records the running city: start one (tools/run/city.sh), pass its URL, or be the world (--world)."
    exit 1
  fi
fi

# the server started here goes down with the studio, children first.
kill_tree() {  # $1 = pid, $2 = signal
  [ -n "$1" ] || return 0
  for _c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$_c" "$2"; done
  kill "-$2" "$1" 2>/dev/null || true
}
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  say "stopping the server"
  kill_tree "$SERVER_PID" TERM
  n=0
  while kill -0 "$SERVER_PID" 2>/dev/null && [ "$n" -lt 40 ]; do sleep 0.5; n=$((n + 1)); done
  kill_tree "$SERVER_PID" KILL
  SERVER_PID=""
  return 0
}
trap 'stop_server' EXIT
trap 'stop_server; exit 130' INT
trap 'stop_server; exit 143' TERM

if ! command -v ffmpeg >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/ffmpeg ]; then
  say "ffmpeg not found: snapshots only until 'brew install ffmpeg'."
fi
ROLE=()
[ "$WORLD" = 1 ] && ROLE=(--world)
say "$SERVER — $SCENE$([ "$WORLD" = 1 ] && echo ' — this window is the world')"
[ -n "$STUDIO_DRY_RUN" ] && { say "dry run: would launch Godot -- --studio ${ROLE[*]} --server $SERVER"; exit 0; }
"$GODOT" --path "$HERE/client" "$SCENE" -- --studio ${ROLE[@]+"${ROLE[@]}"} --server "$SERVER" || true
