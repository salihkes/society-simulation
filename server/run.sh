#!/bin/bash
# Server launcher. Makes a venv on the local disk (from the offline packages
# in GAME_PACKAGES when set, else python3 and pip), then runs the server.
# Loopback by default (no SSL): the world process and local clients talk
# ws://127.0.0.1:2053. Pass --ssl to use the .env certs.
#   server/run.sh            local, plain ws
#   server/run.sh --ssl      production (certs from .env)
# Where the world (data/world) lives for this run, and whether it may change:
#   --readonly                         data/world is never written: the mind runs on
#                                      a scratch copy that is deleted at shutdown
#   --world /path/to/world             an external world, read and written in place
#   --world /path/to/world --readonly  an external world, left untouched
#   --clean                            begin with NO memories and no state: the city as
#                                      defined, nobody remembers anything; a scratch copy
#                                      like --readonly, gone at shutdown
# The flags set GAME_WORLD / GAME_WORLD_READONLY=1, which work on their
# own too (and reach the other programs the same way).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/../tools/env.sh" ] && . "$HERE/../tools/env.sh"
PKGS="${GAME_PACKAGES:-}"
DATA="${GAME_DATA:-$HOME/.local/share/game}"
VENV="$DATA/venv"
PY="$VENV/bin/python"

pip_install() {
  if [ -n "$PKGS" ]; then
    "$VENV/bin/pip" install -q --no-index --find-links "$PKGS/any" --find-links "$PKGS/macos-arm64" "$@"
  else
    "$VENV/bin/pip" install -q "$@"
  fi
}

if [ ! -x "$PY" ]; then
  echo "[server] making the venv in $DATA" >&2
  mkdir -p "$DATA"
  if [ -n "$PKGS" ]; then
    PY313="$DATA/python/bin/python3.13"
    if [ ! -x "$PY313" ]; then
      tar -xzf "$PKGS"/interpreters/cpython-3.13.*aarch64-apple-darwin-install_only.tar.gz -C "$DATA"
    fi
    "$PY313" -m venv "$VENV"
  else
    python3 -m venv "$VENV"
  fi
  pip_install websockets aiohttp python-frontmatter pyyaml numpy
fi

# The city library (mind/library.py) imports the librarian project's search,
# encyclopaedia and map machinery in-process, so this venv needs what that
# package imports. Checked every launch, not only when the venv is first made.
if ! "$PY" -c "import flask, sqlite_vec" >/dev/null 2>&1; then
  echo "[server] adding the library's dependencies to $VENV" >&2
  pip_install flask sqlite-vec markdown pypdf chardet httpx requests mcp libzim pillow mutagen watchdog \
    || echo "[server] WARNING: could not install them — the shelves stay shut, the city keeps its lore" >&2
fi
# The website's 2FA (pyotp) and QR codes (qrcode); without them 2FA is off and QR codes are text.
if ! "$PY" -c "import pyotp, qrcode" >/dev/null 2>&1; then
  echo "[server] adding the website's 2FA and QR packages to $VENV" >&2
  pip_install pyotp qrcode \
    || echo "[server] WARNING: no pyotp/qrcode — the website runs without 2FA and QR codes" >&2
fi
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
SSL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ssl) SSL=1 ;;
    --world=*) set -- --world "${1#--world=}" "${@:2}"; continue ;;
    --world)
      shift
      [ -n "${1:-}" ] || { echo "[server] --world needs a folder" >&2; exit 2; }
      case "$1" in /*) GAME_WORLD="$1" ;; *) GAME_WORLD="$PWD/$1" ;; esac
      export GAME_WORLD ;;
    --readonly|--read-only|--ephemeral) export GAME_WORLD_READONLY=1 ;;
    --clean|--fresh|--amnesia) export GAME_WORLD_CLEAN=1 GAME_WORLD_READONLY=1 ;;
    *) echo "[server] unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ "$SSL" != 1 ]; then
  # main.py only applies .env values for variables that are unset — an
  # empty value here therefore wins and keeps the server on plain ws.
  export SSL_CERT_PATH="" SSL_KEY_PATH=""
fi
cd "$HERE"
exec "$PY" main.py
