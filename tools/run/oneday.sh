#!/bin/bash
# A MONDAY IN 24 MINUTES — the city living a whole day, so the memory system
# has a day to remember.
#
# The city's clock is normally wall-clock time, which means it has only ever
# existed at whatever hour you happen to be working: 71% of every observation
# this world has ever recorded was taken at 13:00, and hours 00, 01, 04, 05,
# 06, 09, 10 and 23 have never happened at all. Nobody ever went to morning
# class, nobody ever slept, and the nightly memory pass — which fires between
# 03:00 and 06:00 — has never once been reachable.
#
# So: run the clock at sixty times life. One game hour per real minute, a
# whole Monday in twenty-four, starting at six in the morning. School happens.
# Dinner happens. Sleep happens. Three in the morning happens, and with it the
# residents' sleep, when the day becomes memory.
#
# It runs on a COPY of the world (an instant APFS clone) and clears that copy's
# memories first, so every run is the city's first day: data/world is untouched
# and nothing carries over from an earlier debug run.
#
#   tools/run/oneday.sh              start the day, detached; you get your terminal back
#   tools/run/oneday.sh report       what the city has remembered so far
#   tools/run/oneday.sh watch        follow the clock and the memories as they form
#   tools/run/oneday.sh log          follow the raw log
#   tools/run/oneday.sh stop         end the day (the run folder stays, for reading)
#
# Join it like any other server: run the game normally and it finds
# ws://127.0.0.1:2053 by itself. Talk to people; being talked to is the single
# richest thing a resident can have happen to them.

# ── knobs ───────────────────────────────────────────────────────────────
RATE=60              # game seconds per real second: 60 = one game hour a minute
START_HOUR=6.0       # the day begins at six in the morning
WEEKDAY=mon          # which weekday the city believes it is (school runs mon-fri)
MINUTES=24           # how long to let it run before saying the day is done

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
RUNS="$HERE/server/data/runs"
LATEST="$RUNS/latest"
. "$HERE/tools/env.sh"
PY="$GAME_VENV_PY"
PORT="${GAME_PORT:-2053}"

listening() { nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; }

case "${1:-start}" in

stop)
  if [ -f "$LATEST/city.pid" ]; then
    PID="$(cat "$LATEST/city.pid")"
    echo "[oneday] stopping the city (pid $PID)…"
    # TERM, not INT. city.sh treats INT as "the terminal already interrupted
    # the whole process group", so it waits for children it never signalled —
    # which, started detached from here, nothing ever did. TERM is the path
    # that actually passes the signal down. Then the group, then the port.
    kill -TERM "$PID" 2>/dev/null
    for _ in $(seq 60); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$PID" 2>/dev/null; then
      echo "[oneday] still up; signalling the whole group"
      kill -TERM "-$(ps -o pgid= "$PID" | tr -d ' ')" 2>/dev/null
      for _ in $(seq 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
    fi
    kill -0 "$PID" 2>/dev/null && { echo "[oneday] it would not go; killing"; \
      kill -KILL "-$(ps -o pgid= "$PID" | tr -d ' ')" 2>/dev/null; kill -KILL "$PID" 2>/dev/null; }
    rm -f "$LATEST/city.pid"
  fi
  # Whatever is left holding the port is this run's; the launcher refuses to
  # start beside it, so a half-stopped city would block every later day.
  for _ in $(seq 20); do listening || break; sleep 0.5; done
  if listening; then
    echo "[oneday] something still holds :$PORT — clearing it"
    pkill -f "$PY main.py" 2>/dev/null
    pkill -f "Godot --headless.*--world" 2>/dev/null
    sleep 1
  fi
  listening && echo "[oneday] WARNING: :$PORT is still open" || echo "[oneday] port $PORT is free"
  echo "[oneday] stopped. The day it lived is still in $(readlink "$LATEST" 2>/dev/null || echo "$LATEST")"
  exit 0 ;;

report)
  exec "$PY" "$HERE/tools/run/oneday_report.py" --world "$LATEST" ;;

log)
  exec tail -f "$LATEST/city.log" ;;

watch)
  echo "[oneday] Ctrl-C stops watching; the city keeps going."
  while :; do
    "$PY" "$HERE/tools/run/oneday_report.py" --world "$LATEST" --brief
    sleep 30
  done ;;

start) ;;
*) echo "[oneday] don't know '$1' — try: start | report | watch | log | stop" >&2; exit 2 ;;
esac

# ── start ───────────────────────────────────────────────────────────────
if listening; then
  echo "[oneday] something is already listening on $PORT — stop it first (tools/run/oneday.sh stop)." >&2
  exit 1
fi
[ -x "$PY" ] || { echo "[oneday] no venv at $PY — run server/run.sh once to make it." >&2; exit 1; }

STAMP="$(date +%Y-%m-%d-%H%M%S)"
RUN="$RUNS/$STAMP"
echo "[oneday] cloning the world into $RUN"
mkdir -p "$RUNS"
cp -c -R "$HERE/server/data/world" "$RUN" 2>/dev/null || cp -R "$HERE/server/data/world" "$RUN"
ln -sfn "$RUN" "$LATEST"

# Every run starts from a clean shelf. The clone is a scratch world, so this
# never touches data/world; it only means the day being watched is the city's
# first, not a day layered on whatever an earlier debug run left behind.
rm -f  "$RUN"/memory/*.jsonl
rm -rf "$RUN"/memory/r_*/ "$RUN"/memory/ambient
rm -f  "$RUN"/memory/memory.db "$RUN"/memory/memory.db-shm "$RUN"/memory/memory.db-wal
rm -f  "$RUN/resident_life.json"
echo "[oneday] the copy starts with no memories and no resident state"

# The clock this run lives on. Written before boot so the very first tick is
# already inside the day rather than at whatever hour it is outside.
cat > "$RUN/clock.json" <<JSON
{"mode": "scaled", "rate": $RATE, "hour": $START_HOUR, "weekday": "$WEEKDAY"}
JSON
rm -f "$RUN/clock_progress.json"

# A model must be up or nothing will be remembered: the harvest, the
# relationship notes and the reflection are all model work.
cd "$HERE"
LLM_JSON="$RUN/llm.json" "$PY" - <<'PYEOF' || true
import json, os, sys, urllib.request
try:
    eps = json.load(open(os.environ["LLM_JSON"]))["endpoints"]
except Exception:
    sys.exit(0)
up = []
for e in eps:
    try:
        with urllib.request.urlopen(e["url"] + "/v1/models", timeout=3) as r:
            names = [m["id"] for m in json.load(r).get("data", [])]
        up.append((e["name"], names))
    except Exception:
        print(f"[oneday] {e['name']} ({e['url']}) is not answering")
if not up:
    print("[oneday] WARNING: no model server is up. The day will be lived but not remembered —")
    print("[oneday]          harvest, relationships and reflection are all model work.")
else:
    for name, names in up:
        emb = [n for n in names if "embed" in n.lower()]
        rr = [n for n in names if "rerank" in n.lower()]
        print(f"[oneday] {name}: {len(names)} model(s)"
              + (f", embeddings: {emb[0]}" if emb else ", NO embedding model (dense recall stays off)")
              + (f", reranker: {rr[0]}" if rr else ", no reranker"))
PYEOF

echo "[oneday] starting the city on a copy of the world…"
GAME_WORLD="$RUN" nohup "$HERE/tools/run/city.sh" --world "$RUN" --once \
  > "$RUN/city.log" 2>&1 &
echo $! > "$RUN/city.pid"

printf "[oneday] waiting for the server"
for _ in $(seq 120); do listening && break; printf "."; sleep 1; done
echo
listening || { echo "[oneday] it never came up — see $RUN/city.log" >&2; exit 1; }
echo "[oneday] the world process still has the city scene to load (~40 s)."

cat <<TXT

  ── Monday, from 06:00, one hour a minute ──────────────────────────────
  The day ends at about $MINUTES minutes from now; the residents' sleep,
  when everything becomes memory, falls near minute $(( MINUTES - 3 )).

  join it     run the game as usual — it finds ws://127.0.0.1:2053 itself
  watch it    tools/run/oneday.sh watch
  the log     tools/run/oneday.sh log
  what it     tools/run/oneday.sh report
  remembers
  end it      tools/run/oneday.sh stop

  talk to people while you are in there. Being spoken to is the richest
  thing that can happen to a resident, and it is what the harvest looks
  for first.

  this run    $RUN
TXT
