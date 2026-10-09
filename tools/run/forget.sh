#!/bin/bash
# THE CITY FORGETS — clear everything a run left behind, keep who the city is.
#
# Drag this into a terminal and press return. It clears the memories, the life
# state, the school's lesson progress, the clock, the chamber, the parked
# residents' copies of all that, and the disk of a resident's own computer.
# The residents themselves, their cards, the households, the places, the
# timetable and the lore all stay. It backs up first, into one dated folder
# that is never overwritten.
#
#   tools/run/forget.sh                 back up, then clear data/world
#   tools/run/forget.sh --world <dir>   clear some other world (a bundle, a run)
#   tools/run/forget.sh --dry-run       say what would go, touch nothing
#   tools/run/forget.sh --no-backup     skip the backup (a throwaway copy)
#   tools/run/forget.sh --quiet         errors only
#
# The work itself is tools/run/forget.py, so that a Windows server (which has no
# bash) clears itself exactly the same way — bundle_server.sh puts that file
# and a forget.bat beside main.py. What counts as "written by a run" is one
# list, server/core/paths.py CLEAN_PATTERNS, which a --clean start reads
# too; it used to be spelled out in each place and drifted.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${SERVER_PY:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "[forget] need python3" >&2; exit 1; }
exec "$PY" "$HERE/tools/run/forget.py" "$@"
