#!/bin/bash
# THE CITY: the server and the one world process, as a single unit.
#
# The server without a world has a paused city — residents stop,
# nothing ticks, and the only sign is a line in the log. The two belong up
# together, so this starts the server, waits until it is actually listening,
# starts the world against it, and keeps both alive: if either falls over it
# is restarted, and Ctrl-C (or SIGTERM, as a service manager sends) takes
# both down in order, world first so it can say goodbye.
#
#   tools/run/city.sh                        local, plain ws on 127.0.0.1:2053
#   tools/run/city.sh --ssl                  production certs from .env
#   tools/run/city.sh --world /path/to/world --readonly
#   tools/run/city.sh --clean                the city with NO memories, no state (a scratch copy;
#                                        the real world untouched, the copy gone at shutdown)
#   tools/run/city.sh --scene res://assets/scenes/workspace.tscn
#   tools/run/city.sh --once                 do not restart either; first exit stops both
#
# Every other flag goes to server/run.sh, so --world, --readonly and
# --ssl work exactly as they do there. --scene goes to the world instead.
#
# Under systemd or launchd, run it in the foreground and let the supervisor
# restart the whole unit; --once suits that, since the supervisor is then the
# only thing deciding what a crash means.
#
# With --ssl the world still needs to reach the server: set GAME_SERVER
# to a URL the certificate actually covers (wss://your.domain/mv), or the
# world's TLS handshake fails against 127.0.0.1.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${GAME_HOST:-127.0.0.1}"
PORT="${GAME_PORT:-2053}"
SERVER_CMD="${SERVER_CMD:-$HERE/server/run.sh}"
WORLD_CMD="${WORLD_CMD:-$HERE/tools/run/world.sh}"
RESTART=1
DELAY="${GAME_RESTART_DELAY:-5}"
SCENE=""
SSL=0
SERVER_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --once) RESTART=0 ;;
    --scene) shift; SCENE="${1:-}"; [ -n "$SCENE" ] || { echo "[city] --scene needs a path" >&2; exit 2; } ;;
    --scene=*) SCENE="${1#--scene=}" ;;
    --restart-delay) shift; DELAY="${1:-5}" ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --ssl) SSL=1; SERVER_ARGS+=("$1") ;;
    *) SERVER_ARGS+=("$1") ;;
  esac
  shift
done

# The world reaches the server over loopback unless told otherwise.
if [ -z "${GAME_SERVER:-}" ]; then
  if [ "$SSL" = 1 ]; then
    echo "[city] --ssl without GAME_SERVER: the world will try wss://$HOST:$PORT," >&2
    echo "[city] which your certificate probably does not cover. Set GAME_SERVER." >&2
    export GAME_SERVER="wss://$HOST:$PORT"
  else
    export GAME_SERVER="ws://$HOST:$PORT"
  fi
fi

STOP="${TMPDIR:-/tmp}/game_city.$$.stop"
rm -f "$STOP"
SERVER_PID=""
WORLD_PID=""

# Deliberately NOT `set -m`: job control in a non-interactive shell put each
# half in its own process group but stopped SIGINT reaching this script's
# trap at all, so Ctrl-C left both halves running. Instead each half is
# stopped by walking its process tree, which needs no job control and cannot
# leave the venv's python or Godot orphaned.

say() { printf '[city] %s\n' "$1" >&2; }

prefix() {
  label="$1"
  while IFS= read -r line; do
    printf '[%s] %s\n' "$label" "$line"
  done
}

port_open() {
  (exec 3<>"/dev/tcp/$HOST/$PORT") 2>/dev/null
}

# Run one half, restarting it for as long as the other is meant to be up.
supervise() {
  label="$1"; shift
  (
    while :; do
      "$@" 2>&1 | prefix "$label"
      code=${PIPESTATUS[0]}
      [ -e "$STOP" ] && exit 0
      if [ "$RESTART" != 1 ]; then
        printf '[city] %s exited (%s); stopping the city\n' "$label" "$code" >&2
        : > "$STOP"
        exit "$code"
      fi
      printf '[city] %s exited (%s); restarting in %ss\n' "$label" "$code" "$DELAY" >&2
      sleep "$DELAY"
      [ -e "$STOP" ] && exit 0
    done
  ) &
}

alive() {  # $1 = pid
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

# Signal a process and everything under it, children first. run.sh and
# world.sh exec into python and Godot, and the prefix reader is a sibling, so
# nothing here may be left behind.
kill_tree() {  # $1 = pid, $2 = signal
  [ -n "$1" ] || return 0
  for _child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$_child" "$2"
  done
  kill "-$2" "$1" 2>/dev/null
}

tree_alive() {  # $1 = pid
  [ -n "$1" ] || return 1
  alive "$1" && return 0
  [ -n "$(pgrep -P "$1" 2>/dev/null)" ]
}

stop_city() {
  trap - INT TERM EXIT
  # Written before anything is signalled, so a supervisor whose child dies
  # during the shutdown does not cheerfully restart it.
  : > "$STOP"
  say "stopping"
  # The world first: it drops its connection while the server can still hear it.
  kill_tree "$WORLD_PID" TERM
  kill_tree "$SERVER_PID" TERM
  n=0
  while [ "$n" -lt 40 ]; do
    tree_alive "$WORLD_PID" || tree_alive "$SERVER_PID" || break
    sleep 0.5
    n=$((n + 1))
  done
  kill_tree "$WORLD_PID" KILL
  kill_tree "$SERVER_PID" KILL
  rm -f "$STOP"
  say "stopped"
}
trap 'stop_city; exit 130' INT
trap 'stop_city; exit 143' TERM
trap 'stop_city' EXIT

# ── refuse to make a mess of an already-running city ──────────────────
if port_open; then
  say "something is already listening on $HOST:$PORT — the server is already up?"
  exit 1
fi
if pgrep -qf "Godot.*--world" 2>/dev/null; then
  say "a world process is already running. Exactly one may run: with two, the"
  say "older keeps authority and the newer one's code never takes effect."
  exit 1
fi

# ── The server ───────────────────────────────────────────────────────────
say "starting the server"
supervise server "$SERVER_CMD" ${SERVER_ARGS[@]+"${SERVER_ARGS[@]}"}
SERVER_PID=$!

say "waiting for it to listen on $HOST:$PORT"
waited=0
until port_open; do
  sleep 0.5
  waited=$((waited + 1))
  if ! tree_alive "$SERVER_PID"; then
    say "the server stopped before it was listening"
    exit 1
  fi
  if [ "$waited" -gt 240 ]; then
    say "the server was not listening after 120s; giving up"
    exit 1
  fi
done
say "the server is listening"

# ── the world ─────────────────────────────────────────────────────────
WORLD_ARGS=()
[ -n "$SCENE" ] && WORLD_ARGS=(--scene "$SCENE")
say "starting the world (it loads the city scene; expect ~40s and ~2.6 GB)"
supervise world "$WORLD_CMD" ${WORLD_ARGS[@]+"${WORLD_ARGS[@]}"}
WORLD_PID=$!

say "the city is up. Ctrl-C stops both."

# ── hold, and notice if either half goes ──────────────────────────────
while :; do
  sleep 1
  [ -e "$STOP" ] && break
  tree_alive "$SERVER_PID" || break
  tree_alive "$WORLD_PID" || break
done
stop_city
