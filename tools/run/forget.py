#!/usr/bin/env python3
"""THE CITY FORGETS — clear everything a run left behind, keep who the city is.

There are two kinds of file in data/world. One kind says what the city IS: the
residents, their cards, the households, the places, the timetable, the lore.
The other is what a run WROTE: memories, the life state, how far each class
got through its lessons, where the clock stopped, the disk of a resident's own
computer. Only the second kind is cleared here, and which is which is decided
in one place — paths.CLEAN_PATTERNS.

It matters that the second kind goes together. Clearing the memories alone
leaves a school that resumes on beat 67 of an equation lesson for pupils who
have never sat one, and a clock that starts in the middle of the last
afternoon. That is not a fresh city, it is a confused one, and it reads
exactly like a server nobody updated.

Everything is backed up first, into one dated folder that is never
overwritten. On macOS the copy is a clone, so the machine room's disk images
(256 MB apparent, sparse) cost nothing.

    python3 tools/run/forget.py                 back up, then clear data/world
    python3 tools/run/forget.py --world DIR     clear some other world
    python3 tools/run/forget.py --dry-run       say what would go, touch nothing
    python3 tools/run/forget.py --no-backup     skip the backup (a throwaway copy)
    python3 tools/run/forget.py --quiet         errors only

This file runs from two places: tools/ in the repo, and beside main.py in a
server bundle (tools/deploy/bundle_server.sh puts it there with forget.bat, so a
Windows machine can start the city over without copying anything).
"""

import argparse
import os
import shutil
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# In the repo this is tools/run/forget.py and the server is two levels up in
# server; in a bundle it sits next to main.py and core/.
_SIBLING = os.path.normpath(os.path.join(HERE, "..", "..", "server"))
SERVER = _SIBLING if os.path.isfile(os.path.join(_SIBLING, "core", "paths.py")) else HERE
sys.path.insert(0, SERVER)

try:
    from core import paths
except ImportError:
    sys.exit(f"[forget] cannot find core/paths.py (looked in {SERVER}) — "
             "run this from the repo's tools/ or from a server bundle.")

DEFAULT_WORLD = os.path.join(SERVER, "data", "world")
BACKUP_ROOT = os.path.join(SERVER, "data", ".backups")


def _clone(src: str, dst: str):
    """Copy a file or folder. On APFS `cp -Rc` clones — instant, no extra
    disk, which is what makes backing up a 256 MB sparse disk image free."""
    if sys.platform == "darwin":
        if subprocess.run(["cp", "-Rc", src, dst], capture_output=True).returncode == 0:
            return
    if os.path.isdir(src):
        shutil.copytree(src, dst, dirs_exist_ok=True)
    else:
        shutil.copy2(src, dst)


def _running(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.3)
        return s.connect_ex(("127.0.0.1", port)) == 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", default=DEFAULT_WORLD, help="the world folder to clear")
    ap.add_argument("--dry-run", "-n", action="store_true", help="say what would go, touch nothing")
    ap.add_argument("--no-backup", action="store_true", help="skip the backup (a throwaway copy)")
    ap.add_argument("--quiet", "-q", action="store_true", help="errors only")
    args = ap.parse_args(argv)

    def say(*a):
        if not args.quiet:
            print(*a)

    world = os.path.abspath(args.world)
    if not os.path.isdir(os.path.join(world, "memory")):
        sys.stderr.write(f"[forget] {world} is not a world (no memory/)\n")
        return 1

    # The live city must not be running: it holds the memory database open and
    # writes the state files on the way out, which would put half of this back.
    if world == os.path.abspath(DEFAULT_WORLD):
        port = int(os.environ.get("GAME_PORT", "2053"))
        if _running(port):
            sys.stderr.write(f"[forget] the city is running on port {port} — "
                             "stop it first (Ctrl-C, or tools/run/oneday.sh stop).\n")
            return 1

    targets = paths.clean_targets(world)
    say(f"[forget] {world}")
    if not targets:
        say("[forget] already clean — nothing a run wrote is left.")
        return 0

    streams = len([t for t in targets if t.endswith(".jsonl")])
    shelves = len([t for t in targets if os.path.isdir(t) and os.path.basename(t).startswith("r_")])
    facts = sum(len([f for f in files if f.endswith(".md")])
                for t in targets if os.path.isdir(t) for _, _, files in os.walk(t))
    say(f"[forget]   {streams} raw streams · {shelves} shelves · {facts} memories")
    say(f"[forget]   {len(targets)} paths to clear:")
    for t in targets:
        say("[forget]     " + os.path.relpath(t, world))

    if args.dry_run:
        say("[forget] --dry-run: nothing touched.")
        return 0

    dest = ""
    if not args.no_backup:
        dest = os.path.join(BACKUP_ROOT, "forget-" + time.strftime("%Y-%m-%d-%H%M%S"))
        os.makedirs(dest, exist_ok=True)
        say(f"[forget] backing up to {dest}")
        for t in targets:
            rel = os.path.relpath(t, world)
            out = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            _clone(t, out)

    for t in targets:
        if os.path.isdir(t):
            shutil.rmtree(t)
        else:
            os.remove(t)
    # The folders themselves are expected by everything that writes into them.
    for d in ("memory", os.path.join("parked", "memory")):
        parent = os.path.dirname(os.path.join(world, d))
        if os.path.isdir(parent):
            os.makedirs(os.path.join(world, d), exist_ok=True)

    say("[forget] cleared. The city remembers nothing and is still itself:")
    if not args.quiet:
        import json

        def count(name, key=None):
            try:
                with open(os.path.join(world, name), encoding="utf-8") as f:
                    d = json.load(f)
                return len(d.get(key, d) if key else d)
            except Exception:
                return "?"
        cards = len([f for f in os.listdir(os.path.join(world, "cards"))
                     if f.endswith(".md") and f != "README.md"]) \
            if os.path.isdir(os.path.join(world, "cards")) else 0
        print(f"[forget]   residents {count('residents.json')} · cards {cards} · "
              f"households {count('households.json', 'households')} · places {count('places.json')}")
    if dest:
        say(f"[forget]   the backup is at {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
