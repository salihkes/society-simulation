"""Rehearsal: snapshot the world folder, then restore it city-wide on end() or the owner's disconnect."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

MARKER = "REHEARSAL"
PREFIX = "game-rehearsal-"
KEEP = ("computers",)   # disk images a running VM may hold open


def _clone(src: str, dst: str):
    """Copy a file or tree, as an APFS clone on macOS when possible."""
    if sys.platform == "darwin":
        r = subprocess.run(["cp", "-Rc", src, dst], capture_output=True)
        if r.returncode == 0:
            return
    if os.path.isdir(src) and not os.path.islink(src):
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst, follow_symlinks=False)


def _put_back(world: str, snapshot: str):
    """Replace the world's entries (except KEEP and the marker) with the snapshot's."""
    for name in os.listdir(world):
        if name in KEEP or name == MARKER:
            continue
        p = os.path.join(world, name)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        else:
            os.remove(p)
    for name in os.listdir(snapshot):
        if name in KEEP:
            continue
        _clone(os.path.join(snapshot, name), os.path.join(world, name))


def recover(world: str):
    """At start: if a rehearsal marker remains, restore its snapshot and drop it."""
    marker = os.path.join(world, MARKER)
    if not os.path.exists(marker):
        return
    info = {}
    try:
        with open(marker, encoding="utf-8") as f:
            info = json.load(f) or {}
    except Exception:
        pass
    snap = str(info.get("snapshot", ""))
    if snap and os.path.isdir(snap):
        _put_back(world, snap)
        shutil.rmtree(os.path.dirname(snap), ignore_errors=True)
        print(f"[Rehearsal] the last run ended mid-rehearsal: the world was put back from {snap}")
    else:
        print(f"[Rehearsal] a marker without its snapshot ({snap or 'none'}): the last rehearsal's changes STAYED")
    os.remove(marker)


class Rehearsal:
    def __init__(self, mind):
        self.mind = mind
        self.snapshot = ""
        self.by = None
        self.since = 0.0

    def active(self) -> bool:
        return self.snapshot != ""

    def status(self) -> dict:
        return {"active": self.active(), "since": self.since, "by": self.by, "snapshot": self.snapshot}

    def start(self, by=None) -> dict:
        """Snapshot the world and begin a rehearsal owned by client by."""
        if self.active():
            st = self.status()
            st["already"] = True
            return st
        world = self.mind.data_dir
        base = tempfile.mkdtemp(prefix=PREFIX)
        snap = os.path.join(base, "world")
        os.makedirs(snap)
        for name in os.listdir(world):
            if name in KEEP or name == MARKER:
                continue
            _clone(os.path.join(world, name), os.path.join(snap, name))
        self.snapshot = snap
        self.by = by
        self.since = time.time()
        with open(os.path.join(world, MARKER), "w", encoding="utf-8") as f:
            json.dump({"snapshot": snap, "since": self.since, "by": by}, f)
        print(f"[Rehearsal] begins: the city will forget everything from now (snapshot {snap})")
        return self.status()

    async def end(self, reason: str = "") -> dict:
        if not self.active():
            return {"active": False}
        snap = self.snapshot
        since = self.since
        self.snapshot = ""
        self.by = None
        brain = self.mind.brain
        if brain is not None:
            brain.memory.store.close()
        world = self.mind.data_dir
        _put_back(world, snap)
        marker = os.path.join(world, MARKER)
        if os.path.exists(marker):
            os.remove(marker)
        shutil.rmtree(os.path.dirname(snap), ignore_errors=True)
        await self._reload()
        forgot = int(time.time() - since)
        print(f"[Rehearsal] over ({reason or 'asked'}): {forgot} s forgotten, the world is as it was")
        return {"active": False, "restored": True, "forgot_seconds": forgot}

    async def client_left(self, client_id):
        if self.active() and self.by == client_id:
            await self.end("the studio left")

    async def _reload(self):
        """Reload what the mind holds in memory from the restored files and broadcast it."""
        m = self.mind
        m.store._load()
        m.store.reload_residents()
        m.store.reload_households()
        m._residents_mtime = m.store.residents_mtime()
        m._households_mtime = m.store.households_mtime()
        m.clock._mtime = None
        m.clock.reload()
        b = m.brain
        if b is not None:
            for d in b.school.days.values():
                d._load_state()
            b.life.reload()
            b.needs.clear()
        await m.send_residents()
        await m.send_all(m.clock.message())
