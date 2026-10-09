"""Durable memory per resident: the facts/*.md files are authoritative, memory.db is derived from them."""
import json
import os
import re
import sqlite3
import threading
import time

import frontmatter

TYPES = ("episode", "fact", "insight", "relationship")
STATUSES = ("active", "dormant", "archived")
LINK_RE = re.compile(r"\[\[([^\[\]|]+?)\]\]")

SCHEMA = """
CREATE TABLE IF NOT EXISTS events(who TEXT, name TEXT, kind TEXT, weight REAL, ts REAL);
CREATE INDEX IF NOT EXISTS events_who_name ON events(who, name);
CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(who UNINDEXED, name UNINDEXED, text);
CREATE TABLE IF NOT EXISTS vectors(who TEXT, name TEXT, dim INTEGER, blob BLOB, PRIMARY KEY(who, name));
CREATE TABLE IF NOT EXISTS journal(who TEXT, ts REAL, action TEXT, detail TEXT);
CREATE TABLE IF NOT EXISTS marks(who TEXT PRIMARY KEY, harvested_ts REAL);
CREATE TABLE IF NOT EXISTS meetings(who TEXT, other TEXT, n INTEGER, last_ts REAL,
                                    PRIMARY KEY(who, other));
"""


# Records made only of these keys are perception, not events; unknown shapes count as events.
AMBIENT_KEYS = {"ts", "hour", "day", "at", "with", "d", "lost", "ped", "beat", "seated", "stood"}
AMBIENT_DID = {"go", "wait", "ride", "watch"}


# Seconds two people must be apart for the next sighting to count as another meeting.
MEET_APART = 900.0

# The engine teleporting a resident who could not walk: artefacts dropped at intake and skipped by harvest.
ENGINE_RECOVERIES = {"travel_recovered", "ride_failed"}


def is_engine_recovery(rec: dict) -> bool:
    """True for a record of a failed walk or ride the engine covered up."""
    return rec.get("did") in ENGINE_RECOVERIES or rec.get("failed") == "ride"


def is_ambient(rec: dict) -> bool:
    """True for perception rather than an event: position, company, routine movement, heard lesson beats."""
    rest = set(rec) - AMBIENT_KEYS
    if not rest:
        return True
    if "lesson_heard" in rec:
        return True
    if rest <= {"did", "place"} and rec.get("did") in AMBIENT_DID:
        return True
    return False


def slug(name: str) -> str:
    """A file-safe memory name (lowercase, kana/kanji kept, max 80 chars)."""
    s = re.sub(r"[^\w\-ぁ-ヿ㐀-鿿]+", "-", str(name).strip().lower()).strip("-")
    return s[:80] or "memory"


def links_of(content: str) -> list:
    """Slugs of the [[name]] links in content."""
    return [slug(m) for m in LINK_RE.findall(content or "")]


class MemoryStore:
    """Memory files plus the derived SQLite database, one connection per thread."""

    def __init__(self, root: str):
        self.root = root
        os.makedirs(root, exist_ok=True)
        self.db_path = os.path.join(root, "memory.db")
        self._local = threading.local()
        with self.db() as db:
            db.executescript(SCHEMA)

    def db(self) -> sqlite3.Connection:
        c = getattr(self._local, "conn", None)
        if c is None:
            c = sqlite3.connect(self.db_path, timeout=10, check_same_thread=False)
            c.row_factory = sqlite3.Row
            c.execute("PRAGMA journal_mode=WAL")
            self._local.conn = c
        return c

    def close(self):
        """Close this thread's connection (e.g. before the file is replaced); the next db() reopens it."""
        c = getattr(self._local, "conn", None)
        if c is not None:
            try:
                c.close()
            except Exception:
                pass
            self._local.conn = None

    def dir(self, who: str) -> str:
        """who's facts folder, created if missing."""
        d = os.path.join(self.root, who, "facts")
        os.makedirs(d, exist_ok=True)
        return d

    def _post_dict(self, post, fname: str, path: str) -> dict:
        """A memory file's frontmatter and body as a plain dict with defaults."""
        return {
            "name": post.get("name", fname[:-3]),
            "description": str(post.get("description", "")),
            "type": post.get("type", "episode"),
            "status": post.get("status", "active"),
            "anchors": list(post.get("anchors") or []),
            "about": list(post.get("about") or []),
            "pinned": bool(post.get("pinned", False)),
            "source": str(post.get("source", "")),
            "supersedes": list(post.get("supersedes") or []),
            "superseded_by": str(post.get("superseded_by", "") or ""),
            "content": post.content,
            "links": links_of(post.content),
            "mtime": os.path.getmtime(path),
            "created": float(post.get("created") or os.path.getmtime(path)),
        }

    def list(self, who: str, status=None) -> list:
        """who's memories by file name, optionally only those with a status."""
        if isinstance(status, str):
            status = (status,)
        out = []
        d = self.dir(who)
        for fname in sorted(os.listdir(d)):
            if not fname.endswith(".md") or fname.startswith("._"):
                continue
            path = os.path.join(d, fname)
            try:
                post = frontmatter.load(path)
            except Exception:
                continue
            m = self._post_dict(post, fname, path)
            if status and m["status"] not in status:
                continue
            out.append(m)
        return out

    def read(self, who: str, name: str):
        """One memory as a dict, or None."""
        path = os.path.join(self.dir(who), slug(name) + ".md")
        if not os.path.exists(path):
            return None
        return self._post_dict(frontmatter.load(path), slug(name) + ".md", path)

    def unique_name(self, who: str, wanted: str) -> str:
        """slug(wanted), suffixed -2, -3... until no file has it."""
        base = slug(wanted)
        name, i = base, 2
        while os.path.exists(os.path.join(self.dir(who), name + ".md")):
            name = f"{base}-{i}"
            i += 1
        return name

    def write(self, who: str, name: str, content: str, description: str = "",
              mtype=None, anchors=None, status=None, pinned=None, source=None,
              supersedes=None, superseded_by=None, created=None, about=None) -> dict:
        """Create or update; None keeps what the file already says."""
        name = slug(name)
        path = os.path.join(self.dir(who), name + ".md")
        existing = None
        if os.path.exists(path):
            try:
                existing = frontmatter.load(path)
            except Exception:
                existing = None
        meta = dict(existing.metadata) if existing else {}
        meta["name"] = name
        if mtype is not None or "type" not in meta:
            meta["type"] = mtype if mtype in TYPES else meta.get("type", "episode")
        if description:
            meta["description"] = description
        if anchors is not None:
            meta["anchors"] = sorted(set(str(a) for a in anchors))
        if about is not None:
            meta["about"] = sorted(set(str(a) for a in about))
        if status is not None and status in STATUSES:
            meta["status"] = status
        meta.setdefault("status", "active")
        if pinned is not None:
            meta["pinned"] = bool(pinned)
        if source is not None:
            meta["source"] = source
        if supersedes is not None:
            meta["supersedes"] = list(supersedes)
        if superseded_by is not None:
            meta["superseded_by"] = superseded_by
        meta.setdefault("created", float(created or time.time()))
        is_new = existing is None
        post = frontmatter.Post(content.strip() + "\n", **meta)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(frontmatter.dumps(post))
        os.replace(tmp, path)
        self._index_one(who, name, meta.get("description", ""), content)
        if is_new:
            self.record(who, name, "created")
        self.rebuild_index_file(who)
        return self._post_dict(frontmatter.load(path), name + ".md", path)

    def set_status(self, who: str, name: str, status: str):
        m = self.read(who, name)
        if m:
            self.write(who, name, m["content"], status=status)

    def archive(self, who: str, name: str, reason: str, superseded_by: str = ""):
        """Archive a memory, noting the reason in its source."""
        m = self.read(who, name)
        if m:
            self.write(who, name, m["content"], status="archived",
                       source=(m["source"] + f"; archived: {reason}").strip("; "),
                       superseded_by=superseded_by or None)

    def rebuild_index_file(self, who: str):
        """Rewrite who's MEMORY.md, one line per memory."""
        lines = ["# Memory index — " + who, ""]
        for m in self.list(who):
            flag = "" if m["status"] == "active" else f" ({m['status']})"
            pin = " 📌" if m["pinned"] else ""
            lines.append(f"- [{m['name']}](facts/{m['name']}.md){pin}{flag} — {m['type']}: {m['description']}")
        path = os.path.join(self.root, who, "MEMORY.md")
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    def index_text(self, who: str) -> str:
        """One line per active memory: name and description."""
        return "\n".join(f"- {m['name']}: {m['description']}"
                         for m in self.list(who, status="active"))

    def _index_one(self, who: str, name: str, description: str, content: str):
        db = self.db()
        db.execute("DELETE FROM facts_fts WHERE who=? AND name=?", (who, name))
        db.execute("INSERT INTO facts_fts(who, name, text) VALUES(?,?,?)",
                   (who, name, f"{description}\n{content}"))
        db.commit()

    def reindex(self, who: str):
        """Rebuild who's full-text index from the files."""
        db = self.db()
        db.execute("DELETE FROM facts_fts WHERE who=?", (who,))
        for m in self.list(who):
            db.execute("INSERT INTO facts_fts(who, name, text) VALUES(?,?,?)",
                       (who, m["name"], f"{m['description']}\n{m['content']}"))
        db.commit()

    def set_vector(self, who: str, name: str, vec):
        """Store a memory's embedding as float16."""
        import numpy as np
        arr = np.asarray(vec, dtype=np.float16)
        self.db().execute("INSERT OR REPLACE INTO vectors(who, name, dim, blob) VALUES(?,?,?,?)",
                          (who, name, int(arr.shape[0]), arr.tobytes()))
        self.db().commit()

    def vectors(self, who: str) -> dict:
        """who's embeddings by memory name, unit-normalised float32."""
        import numpy as np
        out = {}
        for r in self.db().execute("SELECT name, dim, blob FROM vectors WHERE who=?", (who,)):
            v = np.frombuffer(r["blob"], dtype=np.float16).astype(np.float32)
            n = np.linalg.norm(v)
            out[r["name"]] = v / n if n > 0 else v
        return out

    def record(self, who: str, names, kind: str, weight: float = None):
        """Log an activation event of this kind for each name."""
        from .activation import WEIGHTS
        if isinstance(names, str):
            names = [names]
        if not names:
            return
        w = WEIGHTS.get(kind, 1.0) if weight is None else weight
        now = time.time()
        self.db().executemany("INSERT INTO events(who, name, kind, weight, ts) VALUES(?,?,?,?,?)",
                              [(who, n, kind, w, now) for n in names])
        self.db().commit()

    def events(self, who: str) -> list:
        """who's activation events (name, kind, weight, ts), newest first."""
        return [(r["name"], r["kind"], r["weight"], r["ts"]) for r in self.db().execute(
            "SELECT name, kind, weight, ts FROM events WHERE who=? ORDER BY ts DESC", (who,))]

    def journal(self, who: str, action: str, detail: dict):
        self.db().execute("INSERT INTO journal(who, ts, action, detail) VALUES(?,?,?,?)",
                          (who, time.time(), action, json.dumps(detail, ensure_ascii=False)))
        self.db().commit()

    def met(self, who: str, others: list):
        """Record that who was near these people; a new meeting only after MEET_APART seconds apart."""
        now = time.time()
        self.db().executemany(
            "INSERT INTO meetings(who, other, n, last_ts) VALUES(?,?,1,?) "
            "ON CONFLICT(who, other) DO UPDATE SET "
            "n = n + CASE WHEN excluded.last_ts - last_ts > ? THEN 1 ELSE 0 END, last_ts = excluded.last_ts",
            [(who, str(o), now, MEET_APART) for o in others if o])
        self.db().commit()

    def meetings(self, who: str, other: str) -> int:
        r = self.db().execute("SELECT n FROM meetings WHERE who=? AND other=?",
                              (who, other)).fetchone()
        return int(r["n"]) if r else 0

    def harvested_ts(self, who: str) -> float:
        """Timestamp up to which who's raw stream has been harvested."""
        r = self.db().execute("SELECT harvested_ts FROM marks WHERE who=?", (who,)).fetchone()
        return float(r["harvested_ts"]) if r else 0.0

    def set_harvested_ts(self, who: str, ts: float):
        self.db().execute("INSERT OR REPLACE INTO marks(who, harvested_ts) VALUES(?,?)", (who, ts))
        self.db().commit()

    def raw_since(self, who: str, since_ts: float, limit: int = 4000) -> list:
        """The oldest limit records after since_ts, so a harvest that falls behind works through it in order."""
        path = os.path.join(self.root, who + ".jsonl")
        try:
            with open(path, "r", encoding="utf-8") as f:
                out = [rec for rec in _parsed_lines(f) if float(rec.get("ts", 0)) > since_ts]
        except FileNotFoundError:
            return []
        return out[:limit]


def _parsed_lines(f):
    """Each line of f parsed as JSON, skipping lines that do not parse."""
    for line in f:
        try:
            yield json.loads(line)
        except Exception:
            continue
