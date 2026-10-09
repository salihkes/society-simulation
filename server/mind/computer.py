"""The city's computers: personal and library sessions in the machine room, and residents' scheduled tasks."""
import asyncio
import json
import os
import re
import time
import urllib.parse

import aiohttp

from core import identity

DEFAULT_CONFIG = {
    "room": {"url": "http://127.0.0.1:8790",       # server → worker (control API)
             "public": "ws://127.0.0.1:8790",       # players → worker (view socket)
             "token": ""},
    "screen": {"w": 512, "h": 342},
    "computers": {}                                 # id → {"owner": rid, "kind": "personal"|"library"}
}
SEARCH_URL = "https://html.duckduckgo.com/html/?q={q}"
WEEKDAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
STEP_PAUSE = 6.0        # seconds a page stays on the screen
LINGER = 20.0           # seconds the screen stays on after the last step
MAX_FOLLOWS = 3
STICKIES = identity.get("computer_stickies_path")
# Bot-check pages, recognised by title or status; the reader moves on.
BLOCKED_TITLES = re.compile(r"just a moment|attention required|access denied|verify you are human|are you a robot|captcha", re.I)


def blocked(page: dict) -> bool:
    return bool(page) and (BLOCKED_TITLES.search(page.get("title", "") or "") is not None
                           or page.get("status", 0) in (403, 429, 503))


async def _reply_of(r):
    """A worker response's PNG bytes or JSON; RuntimeError for an HTTP error."""
    if r.content_type == "image/png":
        return await r.read()
    data = await r.json(content_type=None)
    if r.status >= 400:
        raise RuntimeError(data.get("error", f"HTTP {r.status}"))
    return data


def _user_of(rid: str) -> str:
    """A valid unix user name for a resident id."""
    u = re.sub(r"[^a-z0-9_-]", "_", rid.lower())[:30]
    return ("u_" + u) if not re.match(r"[a-z_]", u) else u


class Computers:
    def __init__(self, mind):
        self.mind = mind
        self.data_dir = mind.data_dir
        self.config_path = os.path.join(self.data_dir, "computers.json")
        self.tasks_dir = os.path.join(self.data_dir, "computer_tasks")
        self.cfg = dict(DEFAULT_CONFIG)
        self._cfg_mtime = None
        self.sessions = {}          # computer id → {"user","token","w","h","by","since","npc"}
        self._done = {}             # (key, task) → day it ran
        self._busy = set()          # resident keys at a computer now
        self._reload()

    def _reload(self):
        """Re-read computers.json if it changed, creating it with defaults if missing."""
        try:
            mt = os.path.getmtime(self.config_path)
        except OSError:
            mt = None
            if self._cfg_mtime is None:
                os.makedirs(self.data_dir, exist_ok=True)
                with open(self.config_path, "w", encoding="utf-8") as f:
                    json.dump(DEFAULT_CONFIG, f, indent=1, ensure_ascii=False)
                mt = os.path.getmtime(self.config_path)
        if mt != self._cfg_mtime:
            self._cfg_mtime = mt
            try:
                with open(self.config_path, encoding="utf-8") as f:
                    data = json.load(f)
                cfg = dict(DEFAULT_CONFIG)
                for k in ("room", "screen"):
                    cfg[k] = dict(DEFAULT_CONFIG[k], **data.get(k, {}))
                cfg["computers"] = dict(data.get("computers", {}))
                self.cfg = cfg
            except Exception as e:
                print(f"[Computer] computers.json unreadable: {e}")

    @property
    def room_url(self) -> str:
        return self.cfg["room"]["url"].rstrip("/")

    def computer(self, cid: str) -> dict:
        """A computer by id: from computers.json, else a world-reported place of kind "computer"."""
        self._reload()
        c = self.cfg["computers"].get(cid)
        if c is None:
            p = self.mind.store.places.get(cid) if hasattr(self.mind.store, "places") else None
            if p and p.get("kind") == "computer":
                c = {"owner": p.get("owner", ""), "kind": "library" if not p.get("owner") else "personal"}
        return dict(c) if c else {}

    def computer_of(self, key: str) -> str:
        """The id of a resident's own computer, "" if none is placed."""
        rid = key[2:] if key.startswith("r_") else key
        for cid, c in self.cfg["computers"].items():
            if c.get("owner") in (rid, key):
                return cid
        places = getattr(self.mind.store, "places", {}) or {}
        for pid, p in places.items():
            if p.get("kind") == "computer" and p.get("owner") in (rid, key):
                return pid
        return f"pc_{_user_of(rid)}"        # not placed in the world, but it exists

    def account(self, key: str) -> tuple:
        """(unix user, password) of a resident."""
        rid = key[2:] if key.startswith("r_") else key
        r = self.mind.store.residents.get(rid, {})
        pw = str((r.get("computer") or {}).get("password") or self.mind.store.card_meta(rid).get("password") or "")
        user = _user_of(rid)
        return user, (pw or user)

    async def _call(self, method: str, path: str, body=None, timeout: float = 60.0):
        """One worker request: PNG bytes or JSON; RuntimeError on failure."""
        headers = {"X-Room-Token": self.cfg["room"]["token"]}
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout)) as s:
                async with s.request(method, self.room_url + path, json=body, headers=headers) as r:
                    return await _reply_of(r)
        except aiohttp.ClientError as e:
            raise RuntimeError(f"machine room unreachable ({e.__class__.__name__})")

    async def available(self) -> bool:
        """True when the worker answers its health check."""
        try:
            d = await self._call("GET", "/health", timeout=3)
            return bool(d.get("ok"))
        except Exception:
            return False

    async def status(self) -> dict:
        """Worker sessions, ours, the configured computers and the task names."""
        try:
            live = await self._call("GET", "/sessions", timeout=5)
        except Exception as e:
            live = str(e)
        return {"room": self.room_url, "live": live, "mine": self.sessions,
                "computers": self.cfg["computers"], "tasks": self.task_names()}

    async def open(self, cid: str, user: str, password: str, autologin: bool, hold: bool, by: str) -> dict:
        """Open a session on a computer; hold marks it as a resident's."""
        sc = self.cfg["screen"]
        d = await self._call("POST", "/open", {"id": cid, "user": user, "password": password,
                                               "w": sc["w"], "h": sc["h"], "autologin": autologin, "hold": hold})
        self.sessions[cid] = {"user": user, "token": d["token"], "w": d["w"], "h": d["h"],
                              "by": by, "since": time.time(), "npc": hold, "new_image": d.get("new_image", False)}
        return d

    async def close(self, cid: str):
        """Close a session, logging failures."""
        self.sessions.pop(cid, None)
        try:
            await self._call("POST", "/close", {"id": cid}, timeout=15)
        except Exception as e:
            print(f"[Computer] close {cid}: {e}")

    async def act(self, cid: str, **a) -> dict:
        return await self._call("POST", f"/act/{cid}", a, timeout=90)

    async def shot(self, cid: str) -> bytes:
        return await self._call("GET", f"/shot/{cid}", timeout=15)

    async def files(self, user: str, op: str, path: str, text: str = "") -> dict:
        """A file operation in a user's home."""
        return await self._call("POST", f"/files/{user}", {"op": op, "path": path, "text": text}, timeout=60)

    def session_message(self, cid: str) -> dict:
        """The pc_session message that lets a client view a session."""
        s = self.sessions[cid]
        url = f"{self.cfg['room']['public'].rstrip('/')}/view/{urllib.parse.quote(cid)}?token={s['token']}"
        return {"type": "pc_session", "id": cid, "url": url, "w": s["w"], "h": s["h"],
                "owner": self.computer(cid).get("owner", ""), "user": s["user"], "npc": s["npc"]}

    async def open_for_player(self, cid: str, player: str) -> dict:
        """Open a computer for a player (watch-only while its owner uses it); returns a pc_session message, "error" on failure."""
        c = self.computer(cid)
        if not c:
            return {"type": "pc_session", "id": cid, "error": "no such computer"}
        if cid in self.sessions and self.sessions[cid]["npc"]:
            return dict(self.session_message(cid), watching=True)
        try:
            if c.get("kind") == "library":
                await self.open(cid, "library", "library", True, False, player)
            else:
                user, pw = self.account(c.get("owner", ""))
                await self.open(cid, user, pw, False, False, player)
        except Exception as e:
            print(f"[Computer] {player} could not open {cid}: {e}")
            return {"type": "pc_session", "id": cid, "error": str(e)}
        return self.session_message(cid)

    async def close_for_player(self, cid: str, player: str):
        """Close a player's session (never a resident's)."""
        s = self.sessions.get(cid)
        if s and not s["npc"]:
            await self.close(cid)

    def task_names(self) -> list:
        try:
            return sorted(f[:-5] for f in os.listdir(self.tasks_dir) if f.endswith(".json"))
        except OSError:
            return []

    def task(self, name: str) -> dict:
        with open(os.path.join(self.tasks_dir, re.sub(r"[^A-Za-z0-9_-]", "", name) + ".json"), encoding="utf-8") as f:
            return json.load(f)

    async def use(self, key: str, task_name: str, vars: dict = None) -> dict:
        """Have a resident do a task at their own computer, on screen; what they read becomes memory. Returns a report."""
        brain = self.mind.brain
        key = brain._resident_key(key)
        if key in self._busy:
            return {"ok": False, "why": "already at the computer"}
        task = self.task(task_name)
        cid = self.computer_of(key)
        user, pw = self.account(key)
        name = brain._display_name(key)
        vars = dict(vars or {}, name=name)
        report = {"ok": True, "who": key, "task": task_name, "computer": cid, "pages": [], "notes": [], "memory": ""}
        self._busy.add(key)
        try:
            await self.open(cid, user, pw, True, True, key)
        except Exception as e:
            self._busy.discard(key)
            print(f"[Computer] {name} could not sit down: {e}")
            return {"ok": False, "why": str(e)}
        r = brain._resident(key)
        try:
            await self.mind.push_intents(key, [{"do": "go", "place": "home.desk", "pos": r.get("home"), "then": "stay",
                                                 "for": 240}], replace=False)
        except Exception:
            pass
        run = {"key": key, "cid": cid, "user": user, "task": task_name, "vars": vars,
               "page": None, "notes": [], "follows": 0, "report": report}
        try:
            if vars.get("topic") == "?":
                vars["topic"] = await self._choose_topic(key, task) or name
            await asyncio.sleep(2.0)                     # the desktop comes up
            for step in task.get("steps", []):
                await self._step(run, step)
            await asyncio.sleep(LINGER)
        except Exception as e:
            report["ok"] = False
            report["why"] = str(e)
            print(f"[Computer] {name} at the computer: {e}")
        finally:
            try:
                await self.act(cid, op="closeapps")
            except Exception:
                pass
            await self.close(cid)
            self._busy.discard(key)
        print(f"[Computer] {name} did '{task_name}': {len(report['pages'])} page(s), "
              f"{len(report['notes'])} note(s){'' if report['ok'] else ' — ' + report.get('why', '')}")
        return report

    async def _step(self, run: dict, step: dict):
        """Carry out one task step; run holds the session and what was seen so far."""
        do = step.get("do")
        cid, notes = run["cid"], run["notes"]
        if do == "browse":
            run["page"] = await self.act(cid, op="browse", url=self._fill(step["url"], run["vars"]))
            run["report"]["pages"].append(run["page"].get("title") or run["page"].get("url"))
            await asyncio.sleep(float(step.get("secs", STEP_PAUSE)))
        elif do == "search":
            await self._step_search(run, step)
        elif do == "follow":
            await self._step_follow(run, step)
        elif do == "read":
            await self._step_read(run, step)
        elif do == "note":
            if notes:
                stamp = time.strftime("%Y-%m-%d")
                await self.files(run["user"], "append", step.get("file", "Documents/notes.txt"),
                                 f"{stamp}\n" + "\n".join(notes) + "\n\n")
        elif do == "sticky":
            if notes:
                await self._sticky(run["user"], "\n".join(notes))
        elif do == "wait":
            await asyncio.sleep(max(0.0, min(60.0, float(step.get("secs", 5)))))
        elif do == "act":
            await self.act(cid, **{k: v for k, v in step.items() if k != "do"})

    async def _step_search(self, run: dict, step: dict):
        """Search the web and open the result the model picks, skipping bot checks, up to three tries."""
        cid, report = run["cid"], run["report"]
        q = self._fill(step["query"], run["vars"])
        results = await self.act(cid, op="browse", url=SEARCH_URL.format(q=urllib.parse.quote(q)))
        await asyncio.sleep(3.0)
        tried = []
        for _attempt in range(3):
            url = await self._pick_link(run["key"], results, step.get("ask", f"You searched for “{q}”. Which result do you open?"), skip=tried)
            if not url:
                break
            tried.append(url)
            run["page"] = await self.act(cid, op="browse", url=url)
            if blocked(run["page"]):
                report["blocked"] = report.get("blocked", []) + [url]
                await asyncio.sleep(2.0)
                run["page"] = None
                continue
            report["pages"].append(run["page"].get("title") or run["page"].get("url"))
            await asyncio.sleep(float(step.get("secs", STEP_PAUSE)))
            break

    async def _step_follow(self, run: dict, step: dict):
        """Follow the link on the current page the model picks (at most MAX_FOLLOWS)."""
        page, report = run["page"], run["report"]
        if not page or run["follows"] >= MAX_FOLLOWS:
            return
        url = await self._pick_link(run["key"], page, step.get("ask", "Which link on this page do you follow, if any?"))
        if not url:
            return
        run["follows"] += 1
        nxt = await self.act(run["cid"], op="browse", url=url)
        if blocked(nxt):
            report["blocked"] = report.get("blocked", []) + [url]
        else:
            run["page"] = nxt
            report["pages"].append(nxt.get("title") or nxt.get("url"))
        await asyncio.sleep(float(step.get("secs", STEP_PAUSE)))

    async def _step_read(self, run: dict, step: dict):
        """Remember what the resident makes of the current page and keep any note; without a model, just the title."""
        page, key = run["page"], run["key"]
        if not page or blocked(page):
            return
        thought, note = await self._read(key, page, step.get("ask", ""))
        rec = {"did": "computer", "task": run["task"], "url": page.get("url", ""),
               "title": page.get("title", ""), "text": thought,
               "hour": round(self.mind.clock.hour(), 2), "day": self.mind.clock.day()}
        self.mind.store.remember(key, rec)
        run["report"]["memory"] = thought
        if note:
            run["notes"].append(note)
            run["report"]["notes"].append(note)

    def _fill(self, s: str, vars: dict) -> str:
        """s with {placeholders} filled from vars, URL-quoted when s is a URL."""
        return re.sub(r"\{(\w+)\}", lambda m: urllib.parse.quote(str(vars.get(m.group(1), ""))) if "://" in s else str(vars.get(m.group(1), "")), s)

    async def _choose_topic(self, key: str, task: dict) -> str:
        """A search topic the resident picks from their memories; "" without a model."""
        brain = self.mind.brain
        memory = await brain.memory.context(key, "what I wonder about", [f"resident:{key}"], top_k=6) or ""
        raw = await brain.llm.chat(
            "You are a townsperson at your computer. Reply with one line only.",
            [{"role": "user", "content": f"You are {brain._display_name(key)}.\n{brain._persona(key)[:900]}\n\n"
                                         f"What you remember:\n{memory}\n\n"
                                         f"Task: {task.get('title', task.get('name', ''))}\n"
                                         "Name ONE specific thing you want to look up right now — a person, a place, "
                                         "a song, a question. Reply with the search words only."}],
            tier="bg", wait=30)
        return raw.strip().strip("\"'「」").splitlines()[0][:80] if raw.strip() else ""

    async def _pick_link(self, key: str, page: dict, ask: str, skip: list = None) -> str:
        """The link the resident picks (the first one without a model); "" for none."""
        links = [l for l in page.get("links", [])
                 if not re.search(r"duckduckgo\.com|cloudflare\.com|/wiki/(Special|Help|Wikipedia|Talk|File):|#", l)
                 and l not in (skip or [])]
        if not links:
            return ""
        brain = self.mind.brain
        listing = "\n".join(f"{i + 1}. {l}" for i, l in enumerate(links[:25]))
        raw = await brain.llm.chat(
            "You are a townsperson at your computer, choosing a link. Reply with a number only, or 0 for none.",
            [{"role": "user", "content": f"You are {brain._display_name(key)}.\n{brain._persona(key)[:600]}\n\n"
                                         f"Page: {page.get('title', '')}\n{page.get('text', '')[:1200]}\n\nLinks:\n{listing}\n\n{ask}"}],
            tier="bg", wait=30)
        if not raw:
            return links[0]
        m = re.search(r"\d+", raw)
        n = int(m.group(0)) if m else 0
        return links[n - 1] if 1 <= n <= len(links[:25]) else ""

    async def _read(self, key: str, page: dict, ask: str) -> tuple:
        """(thought, note): 2-4 first-person sentences about the page, and one note line or ""."""
        brain = self.mind.brain
        memory = await brain.memory.context(key, page.get("title", "") or "today", [f"resident:{key}"], top_k=4) or "- nothing"
        raw = await brain.llm.chat(
            "You are a townsperson reading a web page at your own computer. Stay in character. "
            f"Write in {identity.get('speech_language')}, first person. Never quote the page at length; say what YOU noticed and think.",
            [{"role": "user", "content": f"You are {brain._display_name(key)}.\n{brain._persona(key)[:1200]}\n\n"
                                         f"What you remember:\n{memory}\n\n"
                                         f"The page ({page.get('url', '')}):\n{page.get('title', '')}\n{page.get('text', '')[:3500]}\n\n"
                                         f"{ask or 'What did you notice, and what do you make of it?'}\n"
                                         "Reply as:\nTHOUGHT: <2-4 sentences>\nNOTE: <one sentence to keep in your notes, or ->"}],
            tier="bg", wait=60)
        if not raw:
            return "", ""
        thought = note = ""
        m = re.search(r"THOUGHT:\s*(.+?)(?:\nNOTE:|\Z)", raw, re.S)
        if m:
            thought = m.group(1).strip()
        m = re.search(r"NOTE:\s*(.+)", raw)
        if m:
            note = m.group(1).strip()
            if note in ("-", "－", "なし", "none"):
                note = ""
        if not thought:
            thought = raw.strip()[:400]
        return thought, note

    async def _sticky(self, user: str, text: str):
        """Append a Sticky to the user's desktop stickies file ([sticky] key=value blocks, newlines escaped)."""
        cur = ""
        try:
            cur = (await self.files(user, "read", STICKIES)).get("text", "")
        except Exception:
            pass
        n = cur.count("[sticky]")
        block = f"[sticky]\nx={40 + (n % 4) * 30}\ny={60 + (n % 4) * 30}\ncolor={n % 6}\ntext={text.replace(chr(10), '\\n')[:900]}\n"
        await self.files(user, "write", STICKIES, cur + block)

    async def tick(self, hour: float, day: int, weekday):
        """Start at most one scheduled task that is due (each once per game day)."""
        if isinstance(weekday, int):
            weekday = WEEKDAYS[weekday % 7]
        for rid, r in list(self.mind.store.residents.items()):
            spec = r.get("computer")
            if not isinstance(spec, dict):
                continue
            t = self._due_task(rid, spec, hour, day, weekday)
            if t is None:
                continue
            name = str(t.get("task", ""))
            self._done[("r_" + rid, name)] = day
            asyncio.create_task(self.use("r_" + rid, name, dict(t.get("vars", {}))))
            return

    def _due_task(self, rid: str, spec: dict, hour: float, day: int, weekday: str):
        """The first of a resident's tasks due now and not yet run today, or None."""
        for t in spec.get("tasks", []):
            name = str(t.get("task", ""))
            at = float(t.get("at", -1))
            days = [str(d).lower()[:3] for d in t.get("days", [])]
            if not name or at < 0 or hour < at or hour > at + 1.5:
                continue
            if days and weekday not in days:
                continue
            k = ("r_" + rid, name)
            if self._done.get(k) == day or ("r_" + rid) in self._busy:
                continue
            return t
        return None

    async def command(self, data: dict) -> dict:
        """A mindctl computer command: status, use, open, close, shot, act or files."""
        op = str(data.get("op", "status"))
        if op == "status":
            return await self.status()
        if op == "use":
            vars = {}
            for kv in str(data.get("vars", "")).split(","):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    vars[k.strip()] = v.strip()
            return await self.use(str(data.get("who", "")), str(data.get("task", "")), vars)
        if op == "open":
            cid = str(data.get("id", ""))
            msg = await self.open_for_player(cid, "mindctl")
            return msg
        if op == "close":
            await self.close(str(data.get("id", "")))
            return {"ok": True}
        if op == "shot":
            cid = str(data.get("id", ""))
            png = await self.shot(cid)
            out = os.path.join(self.data_dir, "computers", f"{cid}.png")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as f:
                f.write(png)
            return {"ok": True, "png": out}
        if op == "act":
            a = json.loads(str(data.get("json", "{}")))
            return await self.act(str(data.get("id", "")), **a)
        if op == "files":
            user, _ = self.account(str(data.get("who", "")))
            return await self.files(user, str(data.get("fop", "list")), str(data.get("path", "")), str(data.get("text", "")))
        raise ValueError(f"unknown computer op {op!r}")
