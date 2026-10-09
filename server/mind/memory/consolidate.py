"""Consolidation, a resident's nightly sleep: harvest, relationships, reflect, decay; nothing is deleted."""
import argparse
import asyncio
import difflib
import json
import os
import re
import time

from . import activation
from .store import AMBIENT_KEYS, is_ambient, is_engine_recovery  # noqa: F401  (re-exported)

HARVEST_PROMPT = """You are the memory of {NAME}, a resident of a small city, writing the day's \
diary into durable memories. Today is {DATE}. Below is who {NAME} is, the raw log of what {NAME} \
noticed, did and said, and the index of memories already kept.

Lines starting with "I said" are {NAME}'s OWN words — never attribute them to anyone else, and \
never turn {NAME}'s own background into a fact about a visitor. Lines "X said to me" are X's words.
Decision reasons are private beliefs, not witnessed events. Do not turn a reason's
claims into an episode unless a physical observation independently supports them.
Starting an action does not mean completing it: seeking food is not having eaten.

## Who {NAME} is
{CARD}

Extract at most {MAX_FACTS} things worth remembering next week: people met (visitors are \
"player:<name>", neighbours are "r_<id>"), what was said and by whom, places and habits, how \
{NAME} felt, what {NAME} decided and why, and what did not work. Skip anything trivial \
(walking around, standing near someone with nothing said). An empty list is a good answer.

Write in ENGLISH, plainly, as {NAME}'s own recollection in the first person — the way a person \
remembers, never "the log shows" or "records remain". Speech keeps its original wording inside \
the quotes (in the language it was spoken); the remembering around it is English. Nobody reads \
these files as the city's script — they are read back to you, so plain English serves {NAME} \
best. Keep names and ids exactly as given.

If the log RE-STATES something already in the index, do not duplicate it — list its name under \
"confirms".

Reply with ONLY this JSON:
{{"facts": [{{"name": "short-kebab-slug-in-english", "type": "episode|fact",
  "description": "one short line in English", "content": "1-3 sentences in English",
  "anchors": ["person:<player name>", "resident:<r_id>", "place:<place>"],
  "about": ["resident:<r_id>"], "links": []}}],
 "confirms": ["existing-name"]}}

"type": episode = a dated thing that happened; fact = something standing (a habit, a \
preference, who someone is). "anchors": every entity the memory touches, so it can be found \
later. "about": ONLY people the memory is genuinely about — they spoke, they acted, they were \
the reason for it. Standing near someone all afternoon is not being about them; if the memory \
concerns nobody in particular, "about" is empty, and that is the usual answer. "links": names \
from the index this relates to.

## Memory index
{INDEX}

## Today's log
{LOG}"""

RELATION_PROMPT = """You keep {NAME}'s notes about people they know. Update the note about {WHO}. \
Today is {DATE}. Keep it to 2-4 sentences in English: who this person is to {NAME}, how they \
have treated each other, the tone between them, what {NAME} would bring up next time. Merge \
the old note with the new facts; drop nothing that still holds. Write in English; quoted speech \
keeps its original wording.

Old note: {OLD}

New facts about {WHO}:
{FACTS}

Reply ONLY JSON: {{"description": "one line in English", "content": "the note"}}"""

REFLECT_PROMPT = """You are the reflection step of {NAME}'s memory. Below are dated memories \
(episodes) from {NAME}'s life in the city. Today is {DATE}.

Write at most {MAX} higher-level insights that the episodes, taken together, support — \
patterns, standing feelings, how relationships are going. Every insight must cite the episodes \
it rests on. Do not invent beyond the episodes. Zero insights is a fine answer. English.

Reply ONLY JSON: {{"insights": [{{"name": "short-kebab-slug-in-english",
"description": "one line", "content": "the insight, 2-4 sentences",
"sources": ["episode-name"]}}]}}

## Episodes
{EPISODES}"""

MAX_FACTS = 5
HARVEST_WINDOW = 4000      # records read in one harvest; a backlog is walked a window at a time
MIN_SALIENT = 3            # things that happened, below which the window is not worth a call
GEN_WAIT = 90.0            # seconds a harvest will queue for a slot rather than be dropped
REFLECT_MIN_EPISODES = 6
DORMANCY_DAYS = 30
DORMANCY_ACTIVATION = 0.25
EPISODE_RETIREMENT_DAYS = 14
CONFIRM_RATIO = 0.86
CONFIRM_COS = 0.92


def _objects(text: str) -> list:
    """Every complete {...} in `text`, brace-matched and string-aware."""
    out, depth, start, instr, esc = [], 0, None, False, False
    for i, ch in enumerate(text):
        if instr:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                instr = False
            continue
        if ch == '"':
            instr = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                out.append(text[start:i + 1])
                start = None
    return out


def _salvage(text: str):
    """The complete fact objects of a truncated harvest reply, or None."""
    head = text.split('"facts"', 1)[-1]
    facts = []
    for chunk in _objects(head):
        try:
            obj = json.loads(chunk)
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get("content"):
            facts.append(obj)
    return {"facts": facts, "confirms": [], "truncated": True} if facts else None


def _parse_json(text):
    """The JSON object in a model reply, salvaging complete facts if it is cut off."""
    if not text:
        return None
    text = text.strip()
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return _salvage(text)
    try:
        return json.loads(m.group(0))
    except Exception:
        try:
            return json.loads(m.group(0).replace("\n", " "))
        except Exception:
            return _salvage(text)


# Rendering the raw stream as a first-person day; the ambient/event split is store.is_ambient.
MOVEMENT = ("I set off", "I went")
BUCKET = 0.25              # game hours; company and repetition collapse inside one


def _hhmm(h) -> str:
    """A game hour as HH:MM, "" when it is not a number."""
    return f"{int(h):02d}:{int((h % 1) * 60):02d}" if isinstance(h, (int, float)) else ""


def _line(rec: dict) -> str:
    """One remembered line for one record, or "" when there is nothing in it."""
    t = _hhmm(rec.get("hour"))
    t = t + " " if t else ""
    for render in (_speech_line, _choice_line, _home_line, _school_line, _moving_line):
        line = render(rec, t)
        if line is not None:
            return line
    return ""


def _speech_line(rec: dict, t: str):
    """What was said, heard or asked; None when the record is not speech."""
    g = rec.get
    if "heard" in rec:
        where = " in class" if g("in_class") else ""
        how = " (quietly)" if g("whisper") else ""
        # Addressed and overheard speech must not be confused.
        if g("addressed"):
            return f"{t}{rec['heard']} said to me{where}{how}: {g('text', '')}"
        return f"{t}I overheard {rec['heard']}{where} say: {g('text', '')}"
    if "said" in rec:
        to = g("to") or g("with") or ""
        return f"{t}I said to {to}: {rec['said']}"
    if "asked_in_class" in rec:
        return f"{t}I put my hand up in class and asked: {rec['asked_in_class']}"
    if "asked_class" in rec:
        who = g("answered_by") or "nobody"
        return f"{t}I asked the class: {rec['asked_class']} — answered by {who}"
    if "question" in rec and g("asked"):
        return f"{t}{rec['asked']} asked me: {rec['question']}"
    if "called" in rec:
        return f"{t}I called on {rec['called']}: {g('said', '')}"
    if "lesson_heard" in rec:
        return f"{t}in the lesson I heard: {rec['lesson_heard']}"
    return None


def _choice_line(rec: dict, t: str):
    """A decision with its reason, or its outcome; None otherwise."""
    if "life_decision" in rec and isinstance(rec["life_decision"], dict):
        d = rec["life_decision"]
        what = " ".join(str(d.get(k, "")) for k in ("do", "target", "place", "object", "household") if d.get(k))
        why = str(rec.get("reason", "")).strip()
        line = f"{t}I decided to {what}".rstrip()
        return f"{line} — my unverified reason was: {why}" if why else line
    if "life_outcome" in rec and isinstance(rec["life_outcome"], dict):
        o = rec["life_outcome"]
        if o.get("status") == "failed":
            why = str(o.get("reason", "")).strip()
            return f"{t}it did not work out" + (f": {why}" if why else "")
        if o.get("status") == "completed":
            return f"{t}the world confirmed my action completed: {o.get('reason', '')}"
        return ""
    return None


def _home_line(rec: dict, t: str):
    """Meals, rest, sleep, illness and things used at home; None otherwise."""
    g = rec.get
    did = g("did")
    if did == "eat":
        return f"{t}I sought a meal at {g('place') or g('household') or 'a restaurant'}; I had not finished eating"
    if did == "ate":
        where = g("place") or g("household") or ""
        return f"{t}I ate" + (f" at {where}" if where else "")
    if did == "left_hungry":
        where = g("place") or ""
        return f"{t}I could not get a meal" + (f" at {where}" if where else "")
    if did == "use" or g("restores"):
        obj = g("object", "something")
        return f"{t}at home I used the {obj}"
    if did == "carry":
        return f"{t}I brought the shopping home"
    if did == "rest":
        return f"{t}I rested"
    if did == "sleep" or g("slept"):
        return f"{t}I slept"
    if g("cared_by"):
        return f"{t}I was ill in bed; {rec['cared_by']} sat with me"
    return None


def _school_line(rec: dict, t: str):
    g = rec.get
    did = g("did")
    if did == "attend":
        return f"{t}I took my desk for the lesson"
    if did == "teach":
        return f"{t}I taught the lesson"
    if did == "class_over":
        return _class_over_line(rec, t)
    if did == "taught":
        subject = g("subject") or g("lesson") or "a lesson"
        asked = int(g("questions") or 0)
        return (f"{t}I taught {subject} to {g('pupils', 0)} pupils"
                + (f"; {asked} question(s) from the room" if asked else "; nobody asked anything"))
    if did == "yard_break":
        return f"{t}I went out to the yard for the break"
    if g("roll_call"):
        return f"{t}at roll call {rec['roll_call']} was absent"
    if g("late"):
        return f"{t}I was late to the lesson"
    if g("skipped") == "class":
        return f"{t}I did not go to the lesson"
    if g("free_period"):
        return f"{t}a free period"
    if g("assembly"):
        return f"{t}the morning assembly" + (" — we sang" if g("anthem") else "")
    return None


def _class_over_line(rec: dict, t: str) -> str:
    """A finished lesson: that it happened, what I asked and what I made of it."""
    g = rec.get
    if not g("lesson") and not g("subject"):
        return f"{t}I left the classroom"
    subject = g("subject") or g("lesson") or "the lesson"
    partial = "heard_beats" in rec and rec["heard_beats"] < g("beats", 0)
    line = f"{t}I heard part of {subject}" if partial else f"{t}I sat through {subject}"
    if g("i_asked"):
        line += " and asked: " + "; ".join(str(q) for q in rec["i_asked"])
    if g("my_note"):
        line += f" — what I made of it: {rec['my_note']}"
    return line


def _moving_line(rec: dict, t: str):
    """Meeting people and moving about; None otherwise."""
    g = rec.get
    if "saw" in rec:
        where = f" at {', '.join(rec['at'])}" if g("at") else ""
        return f"{t}{rec['saw']} came up to me{where}"
    if g("planned"):
        return f"{t}I planned the day: " + "; ".join(str(x) for x in rec["planned"])
    if g("failed"):
        return f"{t}I could not manage {rec['failed']} at {g('place', '')}".rstrip()
    if g("going"):
        return f"{t}I set off for {rec['going']}" + (f" ({rec['place']})" if g("place") else "")
    if g("with"):
        return f"{t}I was near {', '.join(rec['with'])}"
    return None


def render_log(recs: list, max_lines: int = 200) -> tuple:
    """(lines, salient): the records as a day told in order, company and repeats collapsed per quarter hour."""
    company: dict = {}          # bucket hour -> everyone seen near, that quarter hour
    events: list = []           # (hour, line, salient)
    seen: set = set()           # (bucket, line) — said once per quarter hour is enough

    for rec in recs:
        h = float(rec.get("hour", 0.0) or 0.0)
        bucket = int(h / BUCKET) * BUCKET
        if is_engine_recovery(rec):
            continue
        if is_ambient(rec):
            names = {str(n) for n in (rec.get("with") or [])}
            if names:
                company.setdefault(bucket, set()).update(names)
            continue
        line = _line(rec)
        if not line:
            continue
        body = line.split(" ", 1)[1] if " " in line else line
        key = (bucket, body[:140])
        if key in seen:
            continue
        seen.add(key)
        events.append((h, line, not any(m in line for m in MOVEMENT)))

    for bucket, names in company.items():
        events.append((bucket, f"{_hhmm(bucket)} I was near {', '.join(sorted(names))}", False))

    events.sort(key=lambda e: e[0])
    return [e[1] for e in events][-max_lines:], sum(1 for e in events if e[2])


class Consolidator:
    def __init__(self, store, llm, embedder=None, display_name=None, card=None, known=None):
        self.store = store
        self.llm = llm
        self.embedder = embedder
        self.display_name = display_name or (lambda who: who)
        self.card = card or (lambda who: "")
        # known(id) -> bool: guards relationship notes against invented resident ids.
        self.known = known

    async def _gen(self, prompt: str) -> str:
        """One model call that waits up to GEN_WAIT seconds for a slot; counts usage."""
        t0 = time.monotonic()
        out = await self.llm.chat("You are a careful memory system. Reply with JSON only.",
                                  [{"role": "user", "content": prompt}],
                                  tier=self.tier, wait=GEN_WAIT, model=getattr(self, "model", ""))
        self.calls = getattr(self, "calls", 0) + 1
        self.model_secs = getattr(self, "model_secs", 0.0) + (time.monotonic() - t0)
        self.prompt_chars = getattr(self, "prompt_chars", 0) + len(prompt)
        if not out:
            self.starved = getattr(self, "starved", 0) + 1
        return out

    async def run(self, who: str, today: str = None, tier: str = "night", model: str = "") -> dict:
        """Run every step for who and return a report (also journaled); model is the resident's own."""
        self.tier = tier
        self.model = model
        self.starved = 0
        today = today or time.strftime("%Y-%m-%d")
        report = {"who": who, "harvested": 0, "confirmed": 0, "relations": 0,
                  "insights": 0, "dormant": 0, "woken": 0, "archived": 0}
        self.calls, self.model_secs, self.prompt_chars = 0, 0.0, 0
        steps = {}
        t = time.monotonic()
        try:
            new = await self._harvest(who, today, report)
            steps["harvest"] = time.monotonic() - t
            t = time.monotonic()
            await self._relationships(who, today, new, report)
            steps["relations"] = time.monotonic() - t
            t = time.monotonic()
            await self._reflect(who, today, report)
            steps["reflect"] = time.monotonic() - t
            t = time.monotonic()
            self._decay(who, report)
            steps["decay"] = time.monotonic() - t
        except Exception as e:
            report["error"] = repr(e)
        report["secs"] = round(sum(steps.values()), 1)
        report["steps"] = {k: round(v, 1) for k, v in steps.items()}
        report["calls"] = self.calls
        report["model_secs"] = round(self.model_secs, 1)
        report["prompt_kchars"] = round(self.prompt_chars / 1000, 1)
        if self.starved:
            report["no_model"] = self.starved
        self.store.journal(who, "run", report)
        return report

    async def _harvest(self, who: str, today: str, report: dict) -> list:
        """Turn the next window of the raw stream into durable memories; returns the names written."""
        since = self.store.harvested_ts(who)
        raw = self.store.raw_since(who, since, limit=HARVEST_WINDOW)
        if not raw:
            return []
        # The mark moves only to the end of what was actually read.
        window_end = float(raw[-1].get("ts", since))
        lines, salient = render_log(raw)
        if salient < MIN_SALIENT:
            # Nothing happened: move the mark without a model call.
            self.store.set_harvested_ts(who, window_end)
            report["passed_over"] = report.get("passed_over", 0) + len(raw)
            return []
        log = "\n".join(lines)[:7000]
        name = self.display_name(who)
        out = _parse_json(await self._gen(HARVEST_PROMPT.format(
            NAME=name, DATE=today, MAX_FACTS=MAX_FACTS, CARD=self.card(who) or "(no card yet)",
            INDEX=self.store.index_text(who) or "(empty)", LOG=log)))
        if out is None:
            return []                      # the model said nothing: keep the mark, try again
        self.store.set_harvested_ts(who, window_end)
        report["read"] = report.get("read", 0) + len(raw)
        for cname in out.get("confirms") or []:
            if self.store.read(who, cname):
                self.store.record(who, cname, "confirmed")
                self.store.journal(who, "confirm", {"name": cname})
                report["confirmed"] += 1
        existing = self.store.list(who, status="active")
        vecs = self.store.vectors(who) if self.embedder else {}
        new_names = []
        for fact in (out.get("facts") or [])[:MAX_FACTS]:
            content = str(fact.get("content") or "").strip()
            if not content:
                continue
            dup = self._near_duplicate(content, existing) or await self._similar(content, vecs)
            if dup:
                self.store.record(who, dup, "confirmed")
                self.store.journal(who, "confirm", {"name": dup, "via": "similarity"})
                report["confirmed"] += 1
                continue
            new_names.append(await self._write_fact(who, fact, content, today))
            report["harvested"] += 1
        return new_names

    async def _similar(self, content: str, vecs: dict):
        """The name of a memory whose vector is within CONFIRM_COS of content, or None."""
        if not vecs:
            return None
        fv = await self.embedder.embed([content])
        if not fv:
            return None
        best = max(((float(v @ fv[0]), n) for n, v in vecs.items()), default=(0, None))
        return best[1] if best[0] >= CONFIRM_COS else None

    async def _write_fact(self, who: str, fact: dict, content: str, today: str) -> str:
        """Write one harvested fact (with its links and vector); returns its name."""
        links = [l for l in (fact.get("links") or []) if self.store.read(who, l)]
        if links:
            content += "\n\nRelated: " + " ".join(f"[[{l}]]" for l in links)
        mname = self.store.unique_name(who, fact.get("name") or content[:40])
        m = self.store.write(
            who, mname, content, description=str(fact.get("description") or "")[:120],
            mtype=fact.get("type") if fact.get("type") in ("episode", "fact") else "episode",
            anchors=[a for a in (fact.get("anchors") or []) if isinstance(a, str)],
            about=[a for a in (fact.get("about") or []) if isinstance(a, str)],
            source=f"harvested {today}")
        if self.embedder:
            fv = await self.embedder.embed([content])
            if fv:
                self.store.set_vector(who, m["name"], fv[0])
        self.store.journal(who, "harvest", {"name": m["name"], "type": m["type"],
                                             "description": m["description"]})
        return m["name"]

    @staticmethod
    def _near_duplicate(content: str, existing: list):
        """The name of an existing memory lexically near content, or None."""
        best, best_r = None, 0.0
        for m in existing:
            r = difflib.SequenceMatcher(None, content, m["content"][:400]).ratio()
            if r > best_r:
                best, best_r = m["name"], r
        return best if best_r >= CONFIRM_RATIO else None

    def _by_person(self, who: str, new_names: list) -> dict:
        """New memories grouped by the people they are about ("about", not anchors)."""
        by_person: dict = {}
        for n in new_names:
            m = self.store.read(who, n)
            if not m:
                continue
            for a in m.get("about") or []:
                if a.startswith("person:") or a.startswith("resident:"):
                    by_person.setdefault(a, []).append(m)
        return by_person

    async def _relationships(self, who: str, today: str, new_names: list, report: dict):
        """Rewrite the relationship note of each person the new memories are about."""
        by_person = self._by_person(who, new_names)
        for anchor, facts in by_person.items():
            label = anchor.split(":", 1)[1]
            if anchor.startswith("resident:") and self.known is not None \
                    and not (self.known(label) or self.known("r_" + label)):
                self.store.journal(who, "relationship_skipped", {"unknown": label})
                continue
            rname = "relationship-" + label
            old = self.store.read(who, rname)
            meetings = self.store.meetings(who, label) or self.store.meetings(who, "r_" + label)
            person = self.display_name(label) if anchor.startswith("resident:") else label
            out = _parse_json(await self._gen(RELATION_PROMPT.format(
                NAME=self.display_name(who), WHO=person, DATE=today,
                OLD=(old["content"] if old else "(none yet)"),
                FACTS="\n".join(f"- {f['content'][:300]}" for f in facts))))
            if not out or not str(out.get("content", "")).strip():
                continue
            content = str(out["content"]).strip() + f"\n\n(meetings so far: {meetings})\n\nRelated: " \
                + " ".join(f"[[{f['name']}]]" for f in facts)
            self.store.write(who, rname, content, description=str(out.get("description", ""))[:120],
                             mtype="relationship", anchors=[anchor], pinned=None,
                             source=f"relationship note, updated {today}")
            self.store.journal(who, "relationship", {"name": rname, "facts": [f["name"] for f in facts]})
            report["relations"] += 1

    async def _reflect(self, who: str, today: str, report: dict):
        """Write up to 3 insights over the oldest 20 open episodes; sources get superseded."""
        episodes = [m for m in self.store.list(who, status="active")
                    if m["type"] == "episode" and not m["superseded_by"]]
        if len(episodes) < REFLECT_MIN_EPISODES:
            return
        episodes = sorted(episodes, key=lambda m: m["created"])[:20]
        listing = "\n".join(
            f"- [{m['name']}] ({time.strftime('%Y-%m-%d', time.localtime(m['created']))}) {m['content'][:300]}"
            for m in episodes)
        out = _parse_json(await self._gen(REFLECT_PROMPT.format(
            NAME=self.display_name(who), DATE=today, MAX=3, EPISODES=listing)))
        by_name = {m["name"]: m for m in episodes}
        for ins in (out or {}).get("insights", [])[:3]:
            content = str(ins.get("content") or "").strip()
            sources = [s for s in (ins.get("sources") or []) if s in by_name]
            if not content or not sources:
                continue
            content += "\n\nSources: " + " ".join(f"[[{s}]]" for s in sources)
            name = self.store.unique_name(who, ins.get("name") or content[:40])
            self.store.write(who, name, content, description=str(ins.get("description") or "")[:120],
                             mtype="insight", source=f"reflection over {len(sources)} episodes, {today}")
            for s in sources:
                self.store.write(who, s, by_name[s]["content"], superseded_by=name)
                self.store.record(who, s, "confirmed")
            self.store.journal(who, "reflect", {"name": name, "sources": sources})
            report["insights"] += 1

    def _decay(self, who: str, report: dict):
        """Archive absorbed cold episodes, make cold old memories dormant, wake touched ones."""
        mems = self.store.list(who)
        activation.seed_missing(self.store, who, {m["name"]: m["created"] for m in mems})
        act = activation.normalized(self.store, who)
        touch = activation.last_touch(self.store, who)
        now = time.time()
        for m in mems:
            cold = act.get(m["name"], 0.0) < DORMANCY_ACTIVATION
            if m["status"] == "active" and not m["pinned"] and m["type"] != "relationship":
                if m["type"] == "episode" and m["superseded_by"] and cold \
                        and now - m["created"] > EPISODE_RETIREMENT_DAYS * 86400:
                    self.store.archive(who, m["name"], f"absorbed into [[{m['superseded_by']}]]",
                                       superseded_by=m["superseded_by"])
                    report["archived"] += 1
                elif cold and now - m["created"] > DORMANCY_DAYS * 86400:
                    self.store.set_status(who, m["name"], "dormant")
                    report["dormant"] += 1
            elif m["status"] == "dormant" and touch.get(m["name"], 0) > now - 7 * 86400:
                self.store.set_status(who, m["name"], "active")
                report["woken"] += 1


def _world_namers(data: str):
    """(display_name, card) functions from the world's residents and cards, or (None, None)."""
    try:
        from ..store import WorldStore
        world = WorldStore(data)
    except Exception as e:
        print(f"(no residents.json/cards here: {e})")
        return None, None

    def display(who):
        rid = who[2:] if who.startswith("r_") else who
        name, _ = world.card(rid)
        return name or str((world.residents.get(rid) or {}).get("name") or rid)

    def card(who):
        rid = who[2:] if who.startswith("r_") else who
        return world.card(rid)[1] or ""
    return display, card


def _cli():
    ap = argparse.ArgumentParser(description="Run a resident's memory consolidation now.")
    ap.add_argument("--who", help="resident key (r_<name>); default: everyone with a raw stream")
    ap.add_argument("--data", default=None, help="data/world dir (default: next to this package)")
    ap.add_argument("--reset-marks", action="store_true",
                    help="read the whole stream again from the beginning. Nothing was ever "
                         "deleted — the mark simply ran ahead of what was read — so this "
                         "recovers a history that was skipped rather than lost.")
    ap.add_argument("--passes", type=int, default=1,
                    help="how many windows to walk per resident (a long backlog needs several)")
    args = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    data = args.data or os.path.normpath(os.path.join(here, "..", "..", "data", "world"))
    from .store import MemoryStore
    from .embed import Embedder
    from ..llm import LocalLLM
    store = MemoryStore(os.path.join(data, "memory"))
    whos = [args.who] if args.who else sorted(
        f[:-6] for f in os.listdir(os.path.join(data, "memory")) if f.endswith(".jsonl") and f.startswith("r_"))

    async def main():
        llm = LocalLLM()
        if not await llm.probe():
            print("no llama-server; nothing to do")
            return
        emb = Embedder(llm)
        display, card = _world_namers(data)
        c = Consolidator(store, llm, emb if await emb.probe() else None, display, card)
        for who in whos:
            if args.reset_marks:
                store.set_harvested_ts(who, 0.0)
            for n in range(max(1, args.passes)):
                report = await c.run(who)
                print(json.dumps(report, ensure_ascii=False))
                if not store.raw_since(who, store.harvested_ts(who), limit=1):
                    break          # caught up with the stream
        await llm.close()
    asyncio.run(main())


if __name__ == "__main__":
    _cli()
