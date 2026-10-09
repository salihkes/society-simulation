#!/bin/bash
# THE SERVER, PACKED FOR SOMEWHERE ELSE.
#
# Assembles the smallest thing that is still the city's server AND still a
# working one: the Python, the mind, the city it knows, and the school's
# recordings. The 2.7 GB in server is mostly things a headless
# client never asks for. The world that goes in here is a fresh one: the
# residents and their places without a single memory, so nothing of this
# machine's runs travels with it.
#
# The lessons come too. They were left out for a while, on the grounds that
# they are "only needed to run a lesson" — which sounds like an extra and is
# not one: the school runs a lesson every period of every school day, and a
# server without them rings its bells over silent classrooms. 642 MB is a
# reason to copy them efficiently, not a reason to ship a school that cannot
# teach. On macOS the copy is a clone, so building costs nothing locally.
#
# Left out by default, and why:
#   assets/pck (1.4 GB)   streamed packs, for BROWSER clients only. A desktop
#                         or headless build already carries its content.
#   assets/pck_stale      previous packs, kept around, never served.
#   data/runs, data/logs  earlier runs and their logs.
#
#   tools/deploy/bundle_server.sh                  the server and its school
#   tools/deploy/bundle_server.sh --no-lessons     without them: the target has them
#   tools/deploy/bundle_server.sh --with-packs     + the streamed packs, for web play
#   tools/deploy/bundle_server.sh --out <dir>      somewhere other than build/server

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$HERE/server"
OUT="$HERE/build/server"
PACKS=0
LESSONS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --with-packs) PACKS=1 ;;
    --no-lessons) LESSONS=0 ;;
    --with-lessons) LESSONS=1 ;;   # they come anyway; kept so old notes still work
    --out) shift; OUT="${1:?--out needs a folder}" ;;
    *) echo "[bundle] unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

rm -rf "$OUT"; mkdir -p "$OUT"
echo "[bundle] → $OUT"

cp "$SRC"/*.py "$OUT"/ 2>/dev/null
cp "$SRC"/requirements.txt "$OUT"/ 2>/dev/null
mkdir -p "$OUT/mind"; cp -R "$SRC/mind/." "$OUT/mind/"
mkdir -p "$OUT/net"; cp -R "$SRC/net/." "$OUT/net/"
for pkg in core accounts world services web; do
  mkdir -p "$OUT/$pkg"; cp -R "$SRC/$pkg/." "$OUT/$pkg/"
done
mkdir -p "$OUT/config"; cp -R "$SRC/config/." "$OUT/config/"
rm -f "$OUT/config/secrets.json"   # each server makes its own session secret
mkdir -p "$OUT/data"; cp -R "$SRC/data/world" "$OUT/data/world"
[ -d "$SRC/data/users" ] && cp -R "$SRC/data/users" "$OUT/data/users"
mkdir -p "$OUT/assets"
# The small state files that live beside data/world, not inside it; never the accounts or posts.
for f in "$SRC"/data/*.json; do
  case "$(basename "$f")" in user_database.json|invites.json|community.json) continue ;; esac
  [ -f "$f" ] && cp "$f" "$OUT/data/"
done
# The world's regions (time zones, weather sources) are defined in the game;
# mind/regions.py reads this copy when the game project is not beside it.
cp "$HERE/client/assets/world/region/regions.json" "$OUT/data/regions.json"
# The manifest only goes in WITH the packs. On its own it promises a browser
# client five required downloads that are not there, and the client waits at
# "Contacting the server…" forever for them.
find "$OUT" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null
find "$OUT" -name "*.pyc" -delete 2>/dev/null

# A bundle is a fresh city: it carries who the residents are and nothing that
# happened to them here. tools/run/forget.sh owns that distinction — it used to be
# spelled out again in this file, and drifted, so a bundle arrived on a new
# machine with no memories but with this machine's school halfway through an
# equation lesson and its clock stopped in the afternoon.
"$HERE/tools/run/forget.sh" --world "$OUT/data/world" --no-backup --quiet \
  || { echo "[bundle] could not clear the copied world" >&2; exit 1; }
echo "[bundle] the copied world is fresh: no memories, no life state, no school or clock progress"

if [ "$PACKS" = 1 ]; then
  echo "[bundle] + streamed packs (browser clients)"
  mkdir -p "$OUT/assets/pck"; cp -R "$SRC/assets/pck/." "$OUT/assets/pck/"
  cp "$SRC/assets/pck_manifest.json" "$OUT/assets/" 2>/dev/null
  # The country map for browsers (tools/bake/publish_region.sh), cloned on APFS.
  if [ -f "$SRC/assets/region/index.json" ]; then
    mkdir -p "$OUT/assets/region"
    cp -Rc "$SRC/assets/region/." "$OUT/assets/region/" 2>/dev/null || cp -R "$SRC/assets/region/." "$OUT/assets/region/"
  fi
fi
# The world's regions (assets/world/region/regions.json): the bundle ships
# without the game, and mind/regions.py reads this copy there.
cp "$HERE/client/assets/world/region/regions.json" "$OUT/data/regions.json"
if [ "$LESSONS" = 1 ]; then
  mkdir -p "$OUT/lessons"
  # 642 MB of 24 kHz WAV. On APFS `cp -c` clones it: instant, no extra disk,
  # so including the school by default costs nothing until it is transferred.
  cp -Rc "$SRC/lessons/." "$OUT/lessons/" 2>/dev/null || cp -R "$SRC/lessons/." "$OUT/lessons/"
  rm -rf "$OUT/lessons/__pycache__"
  echo "[bundle] + the school: $(ls -d "$OUT"/lessons/*/ 2>/dev/null | grep -vc __pycache__) lessons, $(du -sh "$OUT/lessons" | cut -f1)"
else
  echo "[bundle] --no-lessons: the school has no recordings here; the target needs its own"
fi

cat > "$OUT/start.sh" <<'RUN'
#!/bin/bash
# The server. First run makes a venv beside this script and installs what it needs.
cd "$(dirname "$0")"
PY=.venv/bin/python
if [ ! -x "$PY" ]; then
  python3 -m venv .venv || { echo "need python3 (3.11+)"; exit 1; }
  .venv/bin/pip install -q --upgrade pip
  .venv/bin/pip install -q websockets aiohttp python-frontmatter pyyaml numpy pyotp qrcode
fi
export PYTHONUNBUFFERED=1
# Loopback, no TLS. main.py only applies .env values that are unset, so empty
# ones here keep it on plain ws.
export SSL_CERT_PATH="" SSL_KEY_PATH=""
exec "$PY" main.py "$@"
RUN
chmod +x "$OUT/start.sh"

cat > "$OUT/start.bat" <<'RUN'
@echo off
REM The server on Windows. First run makes a venv beside this script.
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  python -m venv .venv || goto :nopy
  .venv\Scripts\pip install -q --upgrade pip
  .venv\Scripts\pip install -q websockets aiohttp python-frontmatter pyyaml numpy pyotp qrcode
)
set PYTHONUNBUFFERED=1
set SSL_CERT_PATH=
set SSL_KEY_PATH=
.venv\Scripts\python main.py %*
goto :eof
:nopy
echo Need Python 3.11+ on PATH.
RUN

# Starting over on the server itself, without copying a bundle across again.
# The same code and the same list as tools/run/forget.sh here, so "fresh" cannot
# come to mean two different things on two machines.
cp "$HERE/tools/run/forget.py" "$OUT/forget.py"
cat > "$OUT/forget.bat" <<'RUN'
@echo off
REM THE CITY FORGETS — clear the memories, the life state, the school's
REM progress and the clock; keep the residents, the places and the timetable.
REM Backs up into data\.backups first. Stop the server before running this.
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
  .venv\Scripts\python forget.py %*
) else (
  python forget.py %*
)
RUN

cat > "$OUT/README.md" <<'MD'
# The city's server

The mind and the record: accounts, the clock, who the residents are, what they
remember, and the brain that decides what they do next. The world process (the
headless client) connects to this and is the city's body.

```
./start.sh          Linux / macOS   — makes a venv on first run
start.bat           Windows
```

It listens on `ws://0.0.0.0:2053`. Point a headless client at it:

```
world.bat ws://<this machine>:2053
```

## Starting the city over

This bundle's world arrives fresh: nobody remembers anything, no class is
halfway through a lesson, the clock has not run. To get back to that after it
has been lived in — with the server stopped:

```
python3 forget.py        Linux / macOS
forget.bat               Windows
```

It backs up into `data/.backups/` first and never overwrites an old backup.
The residents, their cards, the households, the places and the timetable all
stay; what a run wrote goes. `--dry-run` says what would go and touches
nothing.

## The two halves

The server alone has a **paused city** — residents stop and nothing
ticks, and the only sign is one line in the log. It needs exactly one world
process connected to it. Run two and the older one silently stays authority.

## What is not here

- `assets/pck` — streamed packs for browser clients. A desktop or headless
  build carries its own content, so this is only needed for web play.
  (`tools/deploy/bundle_server.sh --with-packs`)

The school's recorded lessons ARE here, in `lessons/`, unless this bundle was
built with `--no-lessons`. The school runs one every period, so without them
the bells ring over silent classrooms and the log says the lesson is not
built yet.

## Two things to know on a machine with another domain

`config/identity.json` has `external_domain`, which is what the pack
server hands browser clients as a download address. A headless client never
asks for packs, so it does not care — but for web play on a homelab, edit that.

Output goes to `data/logs/latest.log`, not to the terminal: `core/log.py`
takes stdout once that folder exists. `tail -f data/logs/latest.log`.

## The model

Without one, the residents' routines still run and the city still moves; the
harvest, the relationship notes and the reflection are all model work and
simply do not happen. `data/world/llm.json` is where the machines are listed;
OpenRouter is in there, switched off, and wants `OPENROUTER_API_KEY` set.
MD

echo
echo "[bundle] done: $(du -sh "$OUT" | cut -f1)"
find "$OUT" -maxdepth 1 -mindepth 1 | sed 's|.*/|   |' | sort
