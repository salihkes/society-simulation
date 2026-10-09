#!/bin/bash
# The whole city in one terminal (ARCHITECTURE.md "Running locally"):
#   1. the server       the Python server            ws://127.0.0.1:2053
#   2. the world        the game headless, role world (tools/run/world.sh)
#   3. a player window  only with --game
# Ctrl-C, or closing the terminal, stops all of them in order and waits
# for each to exit; if one of them dies, the others are stopped too.
#
#   tools/run/up.sh                 the server + world
#   tools/run/up.sh --game          … and a player window connected to it
#   SERVER_PY=python tools/run/up.sh   use another python for the server
#   GAME_SERVER=ws://host:2053 tools/run/up.sh   world/game against another server
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
SERVER="${GAME_SERVER:-ws://127.0.0.1:2053}"
SCENE="res://assets/scenes/workspace_local.tscn"
. "$HERE/tools/env.sh"
VENV_PY="$GAME_VENV_PY"
if [ -z "$SERVER_PY" ]; then
  if [ -x "$VENV_PY" ]; then SERVER_PY="$VENV_PY"; else SERVER_PY="python3"; fi
fi
WANT_GAME=0
for a in "$@"; do
  case "$a" in
    --game) WANT_GAME=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "[up] unknown argument: $a" >&2; exit 2 ;;
  esac
done

# Output of each process, line by line with its name in front. Ignores the
# terminal's Ctrl-C so the last lines of a shutdown still get through.
label() { trap '' INT TERM HUP; while IFS= read -r line; do printf '[%s] %s\n' "$1" "$line"; done; }

NAMES=()
PIDS=()
start() {  # start <name> <command…>
  local name="$1"; shift
  ( exec "$@" ) > >(label "$name") 2>&1 &
  NAMES[${#NAMES[@]}]="$name"; PIDS[${#PIDS[@]}]="$!"
  echo "[up] $name started (pid $!)"
}

alive() { kill -0 "$1" 2>/dev/null; }

STOPPING=0
down() {  # down <signalled>: 1 = the terminal already sent Ctrl-C to everyone
  trap - EXIT INT TERM HUP
  [ "$STOPPING" = 1 ] && return
  STOPPING=1
  local already="$1" i p n t
  echo; echo "[up] stopping…"
  # Reverse order: the player window, then the world, then the server, so
  # nothing reconnects to a server that is going away.
  i=$(( ${#PIDS[@]} - 1 ))
  while [ $i -ge 0 ]; do
    p="${PIDS[$i]}"; n="${NAMES[$i]}"
    if alive "$p"; then
      echo "[up] stopping $n…"
      if [ "$already" != 1 ]; then
        kill -INT "$p" 2>/dev/null
        pkill -INT -P "$p" 2>/dev/null   # its own children (the voice worker)
      fi
      t=0
      while alive "$p" && [ $t -lt 40 ]; do sleep 0.25; t=$((t + 1)); done
      if alive "$p"; then
        kill -INT "$p" 2>/dev/null
        t=0
        while alive "$p" && [ $t -lt 20 ]; do sleep 0.25; t=$((t + 1)); done
      fi
      if alive "$p"; then
        echo "[up] $n did not stop, killing"
        pkill -KILL -P "$p" 2>/dev/null
        kill -KILL "$p" 2>/dev/null
      fi
    fi
    i=$((i - 1))
  done
  wait 2>/dev/null
  echo "[up] all stopped"
}
trap 'down 1' INT
trap 'down 0' TERM HUP
trap 'down 0' EXIT

if [ ! -x "$GODOT" ]; then echo "[up] Godot not found at $GODOT (set GODOT=…)" >&2; exit 1; fi
echo "[up] server with $SERVER_PY; world and game against $SERVER"

# The server. main.py only applies .env values for variables that are unset,
# so an empty SSL pair keeps it on plain ws for loopback (as run.sh does).
if [ "$SERVER" = "ws://127.0.0.1:2053" ]; then
  export SSL_CERT_PATH="" SSL_KEY_PATH=""
  export PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
  ( cd "$HERE/server" && exec "$SERVER_PY" main.py ) > >(label server) 2>&1 &
  NAMES[${#NAMES[@]}]=server; PIDS[${#PIDS[@]}]="$!"
  echo "[up] server started (pid $!)"
  sleep 2
else
  echo "[up] remote server given — not starting the server here"
fi

# The world: keeps retrying until the server answers, then is elected authority.
GAME_SERVER="$SERVER" start world "$HERE/tools/run/world.sh"

if [ "$WANT_GAME" = 1 ]; then
  sleep 3
  start game "$GODOT" --path "$HERE/client" "$SCENE" -- --server "$SERVER"
fi

echo "[up] running — Ctrl-C stops everything"
# Watch the processes; the first one to die brings the rest down.
while :; do
  for p in "${PIDS[@]}"; do
    if ! alive "$p"; then
      for i in "${!PIDS[@]}"; do [ "${PIDS[$i]}" = "$p" ] && echo "[up] ${NAMES[$i]} exited"; done
      exit 1
    fi
  done
  sleep 1
done
