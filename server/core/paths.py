#!/usr/bin/env python
"""Where the server's files live (data/, assets/, config/) as absolute paths; a frozen build reads assets from its bundle."""

import os
import sys

_SERVER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _resource_dir():
    """Folder of read-only shipped content: the bundle when frozen, else the server folder."""
    if getattr(sys, "frozen", False):
        return getattr(sys, "_MEIPASS", os.path.dirname(sys.executable))
    return _SERVER_DIR


def _runtime_dir():
    """Folder of writable state and config: beside the executable when frozen, else the server folder."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return _SERVER_DIR


RESOURCE_DIR = _resource_dir()
RUNTIME_DIR = _runtime_dir()

ASSETS_DIR = os.path.join(RESOURCE_DIR, "assets")
DATA_DIR = os.path.abspath(os.environ.get("GAME_DATA_DIR")
                           or os.path.join(RUNTIME_DIR, "data"))
CONFIG_DIR = os.path.join(RUNTIME_DIR, "config")
WEB_DIR = os.path.abspath(os.environ.get("GAME_WEB_DIR")
                          or os.path.join(_SERVER_DIR, "..", "web"))


def assets(*parts):
    return os.path.join(ASSETS_DIR, *parts)


def data(*parts):
    return os.path.join(DATA_DIR, *parts)


def logs(*parts):
    return os.path.join(DATA_DIR, "logs", *parts)


def config(*parts):
    return os.path.join(CONFIG_DIR, *parts)


def web(*parts):
    """The website's static files (ui/, play/); GAME_WEB_DIR overrides <repo>/web."""
    return os.path.join(WEB_DIR, *parts)


def ensure_runtime_dirs():
    for path in (
        DATA_DIR,
        os.path.join(DATA_DIR, "users"),
        os.path.join(DATA_DIR, "plots"),
        os.path.join(DATA_DIR, "logs"),
        CONFIG_DIR,
    ):
        os.makedirs(path, exist_ok=True)


# GAME_WORLD picks the world folder; _READONLY runs on a scratch copy, _CLEAN on one stripped of CLEAN_PATTERNS.
_TRUE_WORDS = ("1", "true", "yes", "on")


def _env_flag(name):
    return os.environ.get(name, "").strip().lower() in _TRUE_WORDS


WORLD_SOURCE_DIR = os.path.abspath(os.environ.get("GAME_WORLD")
                                   or os.path.join(DATA_DIR, "world"))
WORLD_READONLY = _env_flag("GAME_WORLD_READONLY")
WORLD_CLEAN = _env_flag("GAME_WORLD_CLEAN")
if WORLD_CLEAN:
    WORLD_READONLY = True

# What a run writes inside the world folder; everything else defines the city.
CLEAN_PATTERNS = (
    "memory/*.jsonl",           # the raw streams: everything anyone noticed
    "memory/r_*",               # each resident's MEMORY.md and facts
    "memory/ambient",           # kept perception
    "memory/memory.db*",        # search index, vectors, activation, journal, meetings
    "resident_life.json",       # goals, concerns, relationships, pending actions
    "school_state*.json",       # lesson progress, the period, whether assembly was held
    "clock_progress.json",      # where the clock stopped
    "parliament_state.json",    # the chamber between sittings
    "parked/memory/*",          # the same, for residents not currently in the city
    "parked/resident_life.json",
    "script_leftovers.log",     # the conlang filter's rejects
    "residents.json.bak*",      # backups of hand edits
    "computers/*.img",          # a resident's own machine, files and all
)


def clean_targets(world: str) -> list:
    """Absolute paths inside `world` matching CLEAN_PATTERNS, sorted, none inside another (a double delete raises)."""
    import glob
    found = set()
    for pattern in CLEAN_PATTERNS:
        for p in glob.glob(os.path.join(world, pattern)):
            found.add(os.path.normpath(p))
    out = []
    for p in sorted(found):        # a parent sorts before its contents
        if any(p.startswith(kept + os.sep) for kept in out):
            continue
        out.append(p)
    return out


WORLD_DIR = None            # the folder the mind runs on; set by open_world()
_SCRATCH_PREFIX = "game-world-"


def _pid_alive(pid: int) -> bool:
    """True if a process with this id exists (even one we may not signal)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _sweep_stale_scratch():
    """Delete scratch copies whose recorded pid is dead (left by a killed run)."""
    import shutil
    import tempfile
    base = tempfile.gettempdir()
    try:
        names = os.listdir(base)
    except OSError:
        return
    for name in names:
        if not name.startswith(_SCRATCH_PREFIX):
            continue
        d = os.path.join(base, name)
        try:
            with open(os.path.join(d, "pid"), encoding="utf-8") as f:
                pid = int(f.read().strip() or 0)
        except (OSError, ValueError):
            continue
        if pid and not _pid_alive(pid):
            shutil.rmtree(d, ignore_errors=True)
            print(f"[World] removed a dead run's scratch copy: {d}")


def _strip_state(world: str):
    """Remove every CLEAN_PATTERNS path from a scratch copy, keeping the folders they live in."""
    import shutil
    gone = []
    for p in clean_targets(world):
        if os.path.isdir(p):
            shutil.rmtree(p)
        else:
            os.remove(p)
        gone.append(os.path.relpath(p, world))
    for d in ("memory", os.path.join("parked", "memory")):
        if os.path.isdir(os.path.join(world, os.path.dirname(d) or ".")):
            os.makedirs(os.path.join(world, d), exist_ok=True)
    print(f"[World] CLEAN start: no memories, no state — removed from the copy: "
          f"{len(gone)} path(s)" + (f" ({', '.join(gone[:6])}…)" if len(gone) > 6 else
                                    (f" ({', '.join(gone)})" if gone else " (nothing to remove)")))


def _copy_tree(src: str, dst: str):
    """Copy the world into an existing empty folder (on macOS `cp -c` clones, instant for disk images)."""
    import shutil
    import subprocess
    if sys.platform == "darwin":
        r = subprocess.run(["cp", "-Rc", os.path.join(src, "."), dst], capture_output=True)
        if r.returncode == 0:
            return
        shutil.rmtree(dst, ignore_errors=True)   # a partial clone: start over
        os.makedirs(dst)
    shutil.copytree(src, dst, dirs_exist_ok=True)


def _discard_at_exit(scratch: str, src: str):
    """Delete the scratch folder when the process exits, SIGTERM included."""
    import atexit
    import shutil
    import signal

    def _discard():
        shutil.rmtree(scratch, ignore_errors=True)
        print(f"[World] read-only run over: scratch copy discarded, {src} untouched")

    def _on_term(signum, frame):
        raise SystemExit(0)

    atexit.register(_discard)
    # SIGTERM would end the process without running atexit; make it a normal exit.
    if signal.getsignal(signal.SIGTERM) in (signal.SIG_DFL, None):
        signal.signal(signal.SIGTERM, _on_term)


def _open_scratch_world(src: str) -> str:
    """Copy `src` into a new scratch folder (stripped when WORLD_CLEAN) and return the copy."""
    import tempfile
    _sweep_stale_scratch()
    scratch = tempfile.mkdtemp(prefix=_SCRATCH_PREFIX)
    with open(os.path.join(scratch, "pid"), "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))
    world = os.path.join(scratch, "world")
    os.makedirs(world)
    _copy_tree(src, world)
    if WORLD_CLEAN:
        _strip_state(world)
    _discard_at_exit(scratch, src)
    return world


def open_world() -> str:
    """The folder the mind runs on: WORLD_SOURCE_DIR, or a scratch copy of it when read-only."""
    global WORLD_DIR
    if WORLD_DIR is not None:
        return WORLD_DIR
    src = WORLD_SOURCE_DIR
    if not WORLD_READONLY:
        WORLD_DIR = src
        if src != os.path.join(DATA_DIR, "world"):
            print(f"[World] running on an external world: {src}" +
                  ("" if os.path.isdir(src) else " (new — it will be created)"))
        return WORLD_DIR
    if not os.path.isdir(src):
        raise SystemExit(f"[World] GAME_WORLD_READONLY is set but there is no world "
                         f"to copy at {src}")
    WORLD_DIR = _open_scratch_world(src)
    print(f"[World] READ-ONLY run: {src} is never written; the mind works on a copy at\n"
          f"[World]   {WORLD_DIR}\n"
          f"[World]   (discarded on shutdown; the machine room, if it runs, keeps its own\n"
          f"[World]   images — restart it with ROOM_IMAGES={WORLD_DIR}/computers "
          f"to spare those too)")
    return WORLD_DIR
