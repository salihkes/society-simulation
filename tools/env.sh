# Per-machine settings for the launchers: tools/local.env (gitignored), then these defaults.
_tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ -f "$_tools_dir/local.env" ] && . "$_tools_dir/local.env"
unset _tools_dir
export GAME_DATA="${GAME_DATA:-$HOME/.local/share/game}"
GAME_VENV_PY="$GAME_DATA/venv/bin/python"
