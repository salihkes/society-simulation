"""Persistent world record under data/world/: places, residents, households, cards and raw memory streams."""
import json
import os
import time


class WorldStore:
    clock = None            # set by Mind; stamps the game hour on what it writes
    memory = None           # set by Mind; where the meeting counter lives

    def __init__(self, root: str):
        self.root = root
        self.memory_dir = os.path.join(root, "memory")
        os.makedirs(self.memory_dir, exist_ok=True)
        self.places: dict = {}       # id -> place dict
        self.residents: dict = {}    # id -> resident def
        self.households: dict = {}   # id -> household def (data/world/households.json)
        self.workspace = ""
        self._cards: dict = {}
        self._card_meta: dict = {}
        os.makedirs(os.path.join(root, "cards"), exist_ok=True)
        self._load()

    def _path(self, name: str) -> str:
        return os.path.join(self.root, name)

    def _load(self):
        for name, attr in (("places.json", "places"), ("residents.json", "residents"), ("households.json", "households")):
            try:
                with open(self._path(name), "r", encoding="utf-8") as f:
                    setattr(self, attr, json.load(f))
            except FileNotFoundError:
                pass
            except Exception as e:
                print(f"[World] could not read {name}: {e}")

    def _save(self, name: str, data):
        tmp = self._path(name + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent="\t")
        os.replace(tmp, self._path(name))

    def apply_world_report(self, msg: dict):
        """Store the places the world reported; its residents only seed an empty file."""
        self.workspace = str(msg.get("workspace", ""))
        places = {}
        for p in msg.get("places", []):
            pid = str(p.get("id", ""))
            if pid:
                places[pid] = p
        self.places = places
        self._save("places.json", places)
        seeded = ""
        if not self.residents:
            residents = {}
            for r in msg.get("residents", []):
                rid = str(r.get("id", ""))
                if rid:
                    residents[rid] = {k: v for k, v in r.items() if k != "key"}
            if residents:
                self.residents = residents
                self._save("residents.json", residents)
                seeded = " (seeded residents.json from the world)"
        print(f"[World] report: {len(places)} places; {len(self.residents)} residents on file{seeded}")

    def residents_mtime(self) -> float:
        try:
            return os.path.getmtime(self._path("residents.json"))
        except OSError:
            return 0.0

    def reload_residents(self) -> bool:
        """Re-read residents.json; False (and nothing changed) when it is unusable."""
        try:
            with open(self._path("residents.json"), "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            print(f"[World] residents.json not applied: {e}")
            return False
        if not isinstance(data, dict):
            return False
        self.residents = data
        return True

    def residents_message(self) -> dict:
        """The world_residents message: residents with their ids, and households."""
        out = []
        for rid, r in self.residents.items():
            d = dict(r)
            d["id"] = rid
            out.append(d)
        return {"type": "world_residents", "residents": out, "households": self.households}

    def households_mtime(self) -> float:
        try:
            return os.path.getmtime(self._path("households.json"))
        except OSError:
            return 0.0

    def reload_households(self) -> bool:
        """Re-read households.json (missing means none); False when it is unusable."""
        try:
            with open(self._path("households.json"), "r", encoding="utf-8") as f:
                data = json.load(f)
        except FileNotFoundError:
            data = {}
        except Exception as e:
            print(f"[World] households.json not applied: {e}")
            return False
        if not isinstance(data, dict):
            return False
        self.households = data
        return True

    def household_of(self, rid: str):
        """(household id, definition) for a resident id, else (None, None)."""
        rid = rid[2:] if rid.startswith("r_") else rid
        for hid, h in self.households.items():
            if rid in (h.get("members") or {}):
                return hid, h
        return None, None

    def card(self, rid: str) -> tuple:
        """(name, text) of a character card, ("", "") if none; the first "# Heading" is the name, the rest the persona."""
        path = os.path.join(self.root, "cards", rid + ".md")
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            return "", ""
        cached = self._cards.get(rid)
        if cached and cached[0] == mtime:
            return cached[1], cached[2]
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read().strip()
        except OSError:
            return "", ""
        meta = {}
        if text.startswith("---"):
            try:
                import frontmatter
                post = frontmatter.loads(text)
                meta = dict(post.metadata or {})
                text = post.content.strip()
            except Exception:
                pass
        name = ""
        for line in text.splitlines():
            if line.startswith("# "):
                name = line[2:].strip()
                break
        self._cards[rid] = (mtime, name, text)
        self._card_meta[rid] = meta
        return name, text

    def card_meta(self, rid: str) -> dict:
        """Frontmatter of a card ({} if none): e.g. {"model": "…"}."""
        self.card(rid)
        return dict(self._card_meta.get(rid, {}))

    def places_of_kind(self, kind: str) -> list:
        return [p for p in self.places.values() if p.get("kind") == kind]

    def observe(self, who: str, obs: dict):
        """Route one observation: perception to notice(), events to remember(); meetings are counted for both."""
        from .memory.store import is_ambient
        self._met(who or "_world", obs)
        if is_ambient(obs):
            self.notice(who, obs)
        else:
            self.remember(who, obs)

    def notice(self, who: str, obs: dict):
        """Store perception under memory/ambient/ (never globbed as a stream), only with GAME_KEEP_AMBIENT."""
        who = who or "_world"
        if not os.environ.get("GAME_KEEP_AMBIENT"):
            return
        d = os.path.join(self.memory_dir, "ambient")
        os.makedirs(d, exist_ok=True)
        rec = self._stamp(obs)
        with open(os.path.join(d, who + ".jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    def _met(self, who: str, obs: dict):
        """Count who this person was near ("with" and "saw") in memory."""
        others = list(obs.get("with") or [])
        if obs.get("saw"):
            others.append(obs["saw"])
        if not others or self.memory is None:
            return
        try:
            self.memory.met(who, others)
        except Exception:
            pass

    def _stamp(self, obs: dict) -> dict:
        """A copy of obs with the real time and, if missing, the game hour and day."""
        rec = dict(obs)
        rec["ts"] = round(time.time(), 1)
        if self.clock is not None and ("hour" not in rec or "day" not in rec):
            rec.setdefault("hour", round(self.clock.hour(), 2))
            rec.setdefault("day", self.clock.day())
        return rec

    def remember(self, who: str, obs: dict):
        """Append an event to who's durable stream (_world when who is empty)."""
        rec = self._stamp(obs)
        path = os.path.join(self.memory_dir, (who or "_world") + ".jsonl")
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    def recent(self, who: str, n: int = 20) -> list:
        """The last observations of who's stream, read from the file's last 64 KB."""
        path = os.path.join(self.memory_dir, who + ".jsonl")
        try:
            with open(path, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                chunk = min(size, 64 * 1024)
                f.seek(size - chunk)
                data = f.read().decode("utf-8", "replace")
            lines = data.splitlines()[-n:]
            if chunk < size and lines:
                lines = lines[1:] if len(lines) > n - 1 else lines
        except FileNotFoundError:
            return []
        out = []
        for line in lines:
            try:
                out.append(json.loads(line))
            except Exception:
                pass
        return out
