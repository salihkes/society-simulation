"""The brain: turns what residents notice into what they do and say (rules always, the model when an LLM is up)."""
import asyncio
import hashlib
import json
import os
import random
import re
import time
import traceback

from core import identity

from .home import NEED_HOURS, answerable_needs, apply_restores, home_intents
from .llm import LocalLLM
from . import library
from . import react
from .lore import Lore
from .lesson import Lesson
from .life import ResidentLife
from .school import DEFAULT_TEACHER, School
from .memory import Memory
from .language import Script
from .tts import TTS

HARVEST_RETRY = 3600.0     # seconds before a day-time harvest that yielded nothing is tried again
HUNGER_HOURS = 5.0          # empty stomach after this many game hours
HUNGER_EAT_AT = 0.8         # go eat above this
EAT_RETRY_HOURS = 1.0       # after a failed/aborted meal
ILL_CHANCE = float(os.environ.get("MIND_ILL_CHANCE", "0.01"))   # per resident per day, rolled at dawn
ILL_DAYS = 2                # bed rest before recovery; every visit at the bedside shortens it
REPLY_GAP_S = 6.0           # a resident answers at most this often
TALK_GAP_S = 600.0          # a pair of residents chats at most this often
TALK_CHANCE = 0.5
TALK_SLOTS = 2              # conversations in flight at once, city-wide
SPEECH = identity.get("speech_language")
SPEECH_RULES = identity.get("speech_rules")


class Brain:
    def __init__(self, mind):
        self.mind = mind
        self.llm = LocalLLM(config_path=os.path.join(mind.data_dir, "llm.json"))
        self.lore = Lore(mind.data_dir)
        self.script = Script(mind.data_dir)
        self.tts = TTS()
        self.memory = Memory(mind.data_dir, self.llm, self._display_name,
                             lambda key: self._persona(key)[:1500] + "\n\nCommon knowledge of the city (never contradict it):\n" + self.lore.brief(),
                             known=lambda key: bool(self._resident(key)))
        mind.store.memory = self.memory.store
        self._consolidated_day = None
        self._consolidating = False
        self._harvest_tried = {}         # key -> when a full day was last harvested by day
        self._planned_day = None
        self.seated_players: dict = {}     # username -> room, for players at a desk right now
        self.school = School(self)
        self.needs: dict = {}       # key -> {"hunger": 0..1, "eat_block_until": hour, <NEED_HOURS keys>: 0..1}
        self.health: dict = {}      # key -> {"ill": bool, "since": day, "days": n, "care": visits}
        self._ill_rolled_day = None
        self._last_hour = None
        self._last_day = None
        self._probe_at = 0.0
        self._reply_busy: dict = {}     # key -> last reply time (real)
        self._talk_at: dict = {}        # "a|b" -> last talk time (real)
        self._tasks: set = set()
        self.life = ResidentLife(self)

    async def on_world_report(self):
        """Give every unscripted resident their needs."""
        for rid, r in self.mind.store.residents.items():
            if r.get("script"):
                continue   # service staff work, they don't dine
            self._need(self._resident_key(rid))

    def _need(self, key: str, restaurants=None) -> dict:
        """This person's needs, limited to those something can answer (home.answerable_needs)."""
        n = self.needs.setdefault(key, {"eat_block_until": -1.0})
        if restaurants is None:
            restaurants = self.mind.store.places_of_kind("restaurant")
        _, household = self.mind.store.household_of(key)
        have = answerable_needs(household is not None,
                                bool(restaurants) or bool(self._resident(key).get("student")))
        for k in ("hunger", *NEED_HOURS):
            if k not in have:
                n.pop(k, None)
            elif k not in n:
                n[k] = self.life.state(key).get("hunger", 0.3) if k == "hunger" else 0.2
        return n

    async def _stay_home(self, key: str, why: str, in_bed: bool):
        """Send a resident to spend the day in their room (in bed if in_bed)."""
        _, household = self.mind.store.household_of(key)
        intents = home_intents(self._resident(key), household, key, why, in_bed)
        if intents:
            await self.mind.push_intents(key, intents, replace=True)

    async def fall_ill(self, key: str, days: int = ILL_DAYS):
        """Make a resident ill in bed at home for some days."""
        h = self.health.setdefault(key, {})
        if h.get("ill"):
            return
        h.update(ill=True, since=self.mind.clock.day(), days=max(1, int(days)), care=0)
        print(f"[Health] {key} is ill for {h['days']} day(s)")
        await self.life.cancel(key, "taken ill")
        self.life.event(key, {"ill": True, "days": h["days"]})
        await self.mind.send_world({"type": "household_cmd", "cmd": "ill", "id": key})
        await self._stay_home(key, "ill in bed", True)

    async def recover(self, key: str):
        """End a resident's illness and get them up."""
        h = self.health.get(key)
        if not h or not h.get("ill"):
            return
        h["ill"] = False
        print(f"[Health] {key} is well again")
        self.life.event(key, {"recovered": True})
        await self.mind.send_world({"type": "household_cmd", "cmd": "well", "id": key})
        await self.mind.push_intents(key, [], replace=True)

    async def _illness(self, hour: float, day: int):
        """In the morning: recover those whose time is up, keep the rest in bed, roll ILL_CHANCE for everyone else."""
        for key, h in list(self.health.items()):
            if not h.get("ill"):
                continue
            # Every visit at the bedside is worth half a day.
            if day - int(h.get("since", day)) + 0.5 * int(h.get("care", 0)) >= int(h.get("days", ILL_DAYS)) and 6.0 <= hour < 9.0:
                await self.recover(key)
            elif 6.0 <= hour < 7.0 and h.get("kept_day") != day:
                h["kept_day"] = day
                await self._stay_home(key, "ill in bed", True)
        if ILL_CHANCE <= 0.0 or not (6.0 <= hour < 7.0) or self._ill_rolled_day == day:
            return
        self._ill_rolled_day = day
        for key in list(self.needs):
            if self.health.get(key, {}).get("ill") or self._resident(key).get("script"):
                continue
            if random.random() < ILL_CHANCE:
                await self.fall_ill(key)

    async def school_closed_day(self, school_day):
        """The school is shut: its pupils hear so and stay home today."""
        for key in school_day.pupils():
            self.life.event(key, {"school_closed": True, "class": school_day.name})
            await self._stay_home(key, "school closed today", False)

    def _resident_key(self, rid: str) -> str:
        """A resident key ("r_" prefix) for an id."""
        return rid if rid.startswith("r_") else "r_" + rid

    def _resident(self, key: str) -> dict:
        """A resident's definition (residents.json is keyed by id, not "r_<id>")."""
        rid = key[2:] if key.startswith("r_") else key
        return dict(self.mind.store.residents.get(rid, {}), id=rid)

    def _display_name(self, key: str) -> str:
        """The card's name, else the resident's name, else the id."""
        r = self._resident(key)
        rid = str(r.get("id") or key)
        name, _ = self.mind.store.card(rid)
        return name or str(r.get("name") or rid)

    async def on_clock_jump(self):
        """The clock was set by hand: drop hour blocks, allow a not-yet-due assembly again, and let everyone think again."""
        self._last_hour = None
        self._planned_day = -1
        for n in self.needs.values():
            n["eat_block_until"] = -1.0
            n.pop("eating", None)
        hour = self.mind.clock.hour()
        for d in self.school.days.values():
            d._last_tick_hour = None
            asm = (d.cfg.get("assembly") or {}).get("morning") or {}
            if asm and hour < float(asm.get("gather", float(asm.get("at", 8.2)) - 0.35)):
                d._assembly_day = None
                d._gather_day = None
        self.life.on_clock_jump()
        print(f"[Brain] the clock was set to {hour:.2f}: the hour starts over for everyone")

    async def tick(self):
        now = time.time()
        if now - self._probe_at > 60.0:
            self._probe_at = now
            await self.llm.probe()
        await self.life.tick()
        hour = self.mind.clock.hour()
        day = self.mind.clock.day()
        if self.llm.available and not self._consolidating:
            self._schedule_consolidation(hour, day)
        try:
            await self.school.tick(hour)
        except Exception as e:
            print(f"[School] tick failed: {e}")
        if self.llm.available and 5.0 <= hour < 7.0 and self._planned_day != day:
            self._planned_day = day
            self._spawn(self._plan_all())
        if self._last_hour is None:
            self._last_hour, self._last_day = hour, day
            return
        dt = (day - self._last_day) * 24.0 + (hour - self._last_hour)
        self._last_hour, self._last_day = hour, day
        if dt <= 0.0 or dt > 6.0:
            return   # clock jumped (mode change): don't starve anyone
        await self._needs_tick(hour, dt)
        try:
            await self._illness(hour, day)
        except Exception as e:
            print(f"[Health] tick failed: {e}")

    def _schedule_consolidation(self, hour: float, day: int):
        """Everyone's sleep once a game day between 3 and 6, else a day-time harvest of one full stream (HARVEST_RETRY)."""
        if 3.0 <= hour < 6.0 and self._consolidated_day != day:
            self._consolidated_day = day
            self._spawn(self._consolidate_all())
            return
        now = time.time()
        for key in list(self.needs):
            # The backoff is checked first: counting reads the whole stream.
            if now - self._harvest_tried.get(key, 0.0) > HARVEST_RETRY \
                    and self.memory.raw_count_since_harvest(key) > 80:
                self._harvest_tried[key] = now
                self._spawn(self._consolidate_all([key], tier="bg"))
                break

    async def _needs_tick(self, hour: float, dt: float):
        """Raise needs over dt game hours and, as a fallback to the life loop, send hungry residents to eat."""
        restaurants = self.mind.store.places_of_kind("restaurant")
        open_restaurants = [p for p in restaurants if self._is_open(p, hour)]
        shops = self.mind.store.places_of_kind("shop")
        open_shops = [p for p in shops if self._is_open(p, hour)]
        for key in list(self.needs):
            n = self._need(key, restaurants + shops)
            if "hunger" in n:
                n["hunger"] = min(1.0, n["hunger"] + dt / HUNGER_HOURS)
            for k, hrs in NEED_HOURS.items():
                if k in n:
                    n[k] = min(1.0, float(n[k]) + dt / hrs)
            if "hunger" not in n:
                continue  # nowhere to eat
            if self.life.managed(key) and (self.llm.available or self.life.state(key)["mode"] == "manual"):
                continue  # the life loop chooses meals
            if self.health.get(key, {}).get("ill"):
                continue  # in bed; the household feeds them
            if self.school.in_class(key):
                continue  # at their desk; lunch is their meal
            if n["hunger"] >= HUNGER_EAT_AT and (open_restaurants or open_shops) \
                    and not n.get("eating") and hour >= n.get("eat_block_until", -1.0):
                verb, place = ("eat", random.choice(open_restaurants)) if open_restaurants \
                    else ("buy", random.choice(open_shops))
                n["eating"] = True
                n["eat_block_until"] = hour + EAT_RETRY_HOURS
                print(f"[Brain] {key} is hungry ({n['hunger']:.2f}) → {verb} at {place['id']}")
                await self.mind.push_intents(key, [{"do": verb, "place": place["id"]}])

    @staticmethod
    def _is_open(place: dict, hour: float) -> bool:
        """True when a place has no opening hours or is open at hour."""
        o = place.get("open")
        if not o or len(o) < 2:
            return True
        return float(o[0]) <= hour <= float(o[1])

    async def _consolidate_all(self, keys=None, tier: str = "night"):
        """Consolidate the given residents' memories (default: everyone), one at a time."""
        self._consolidating = True
        try:
            for key in (keys or list(self.needs)):
                if self._resident(key).get("script"):
                    continue
                rep = await self.memory.consolidate(key, tier=tier, model=self._model_for(key))
                print(f"[Memory] {key}: " + ", ".join(f"{k}={v}" for k, v in rep.items() if k != "who"))
        finally:
            self._consolidating = False

    PLAN_PROMPT = (
        "You plan one day in the life of {NAME}. Today is {DATE}.\n{PERSONA}\n\n"
        "Fixed routine today (hour: activity, place):\n{ROUTINE}\n\n"
        "Places in the city you may go (use the id exactly):\n{PLACES}\n\n"
        "What {NAME} remembers:\n{MEMORY}\n\n"
        "Propose 0 to 2 extra outings that fit between routine items — a visit, a meal out, "
        "a walk somewhere for a reason that follows from the memories. Zero is a fine answer. "
        "Hours are decimal (13.5 = half past one). Reply ONLY JSON: "
        "{{\"outings\": [{{\"at\": 15.0, \"place\": \"<id>\", \"why\": \"one line in " + SPEECH + "\"}}]}}")

    async def _plan_all(self):
        """Plan the day for every resident not run by the life loop."""
        places = {p["id"]: p for p in self.mind.store.places.values()
                  if p.get("kind") in ("restaurant", "marker", "district")}
        if not places:
            return
        for key in list(self.needs):
            r = self._resident(key)
            if r.get("script") or self.life.managed(key):
                continue
            try:
                await self._plan_day(key, r, places)
            except Exception as e:
                print(f"[Plan] {key}: {e}")

    GENERIC_MARKERS = ("spawnpoint", "marker3d", "radius", "example")

    def _places_for(self, r: dict, places: dict) -> dict:
        """Where this person may go: restaurants, shops, districts, their routine's places and unowned walkable markers."""
        mine = {str(e.get("marker") or e.get("place") or "") for e in r.get("routine", [])}
        out = {}
        for pid, p in places.items():
            kind = p.get("kind")
            name = str(p.get("name") or pid).lower()
            if kind in ("restaurant", "shop", "district") or pid in mine:
                out[pid] = p
            elif kind == "marker" and p.get("walkable") and not p.get("owner") \
                    and not any(name.startswith(g) for g in self.GENERIC_MARKERS):
                out[pid] = p
        return out

    async def _plan_day(self, key: str, r: dict, places: dict):
        """Ask the model for up to two outings that fit the routine and send them."""
        places = self._places_for(r, places)
        if not places:
            return
        routine = r.get("routine", [])
        rlines = "\n".join(f"- {float(e.get('hour', 0)):.1f}: {e.get('name', '')} "
                            f"({e.get('marker') or e.get('place') or e.get('pos', '')})" for e in routine) or "- (none)"
        plist = "\n".join(f"- {pid} ({p.get('kind')})" for pid, p in list(places.items())[:40])
        memory = await self.memory.context(key, "today", [f"resident:{key}"], top_k=6) or "- nothing yet"
        raw = await self.llm.chat("You plan days for townspeople. Reply with JSON only.",
                                  [{"role": "user", "content": self.PLAN_PROMPT.format(
                                      NAME=self._display_name(key), DATE=time.strftime("%Y-%m-%d"),
                                      PERSONA=self._persona(key)[:1200], ROUTINE=rlines, PLACES=plist,
                                      MEMORY=memory)}], tier="night", model=self._model_for(key))
        try:
            data = json.loads(re.search(r"\{.*\}", raw, re.S).group(0))
        except Exception:
            return
        intents = _outings(data, places, _busy_hours(routine))
        if intents:
            print(f"[Plan] {key}: " + "; ".join(f"{i['at']:.1f} {i['do']} {i['place']} — {i['name']}" for i in intents))
            self.mind.store.remember(key, {"planned": [f"{i['at']:.1f} {i['do']} {i['place']}: {i['name']}" for i in intents]})
            await self.mind.push_intents(key, intents)

    async def start_lesson(self, lesson_dir: str, teacher_key: str = DEFAULT_TEACHER, students=None,
                           seat_pupils: bool = True, start_at: int = 0, day=None) -> dict:
        """Start a lesson in a class's room (default: the first); a running one ends first so its dismissal lands first."""
        day = day or self.school.primary
        await self.end_lesson(day)
        if students is None:
            students = day.pupils()
        day.lesson = Lesson(self.mind, self, lesson_dir, teacher_key, school=day.place,
                            students=students, start_at=start_at)
        day.lesson.seat_pupils = seat_pupils
        period = day.current_period()
        if isinstance(period, dict):
            day.lesson.subject = str(period.get("subject", ""))
        day.lesson.start()
        return day.lesson.status()

    async def end_lesson(self, day=None) -> dict:
        """Stop a class's lesson, waiting up to 10 s for it to finish, plus 1 s."""
        day = day or self.school.primary
        if day is None or day.lesson is None:
            return {"running": False}
        lesson = day.lesson
        if lesson.running:
            lesson.stop()
            if lesson.task is not None:
                try:
                    await asyncio.wait_for(asyncio.shield(lesson.task), timeout=10.0)
                except (asyncio.CancelledError, asyncio.TimeoutError, Exception):
                    pass
            await asyncio.sleep(1.0)   # let the dismissal land in the world
        return lesson.status()

    async def on_world_reset(self):
        """The world reconnected: reset life and stop lessons; each period re-opens on the next tick where it stood."""
        self.life.on_reset()
        self.school.on_world_reset()
        for lesson in self.school.lessons():
            if lesson.running:
                print(f"[Lesson] world reset — {lesson.id} paused at beat {lesson.pos}, period re-opens")
                lesson.stop()

    async def react(self, who: str, rec: dict):
        """React to one observation: needs, health, lessons, seats, replies, small talk."""
        if not who:
            return
        if rec.get("ped"):
            # A passer-by spoken to by a player answers once and remembers nothing.
            if rec.get("heard", "").startswith("player:") and rec.get("text"):
                self._spawn(self._reply(who, rec, passerby=True))
            return
        who = self._resident_key(who)
        if who.startswith("r_evt_") or self._resident(who).get("script"):
            return   # event cast and staff keep to their scripts
        self._update_body(who, rec)
        if rec.get("heard", "").startswith("player:") and rec.get("text"):
            lesson = self.school.lesson_of(who)
            if lesson is not None and lesson.running and who == lesson.teacher:
                # A teaching teacher takes only class questions, through the lesson.
                if rec.get("in_class"):
                    lesson.on_question(str(rec["heard"]).split(":", 1)[-1], str(rec["text"]))
                return
            if rec.get("addressed"):
                self._spawn(self._reply(who, rec))
        elif isinstance(rec.get("with"), list) and not self.life.managed(who):
            teaching = {l.teacher for l in self.school.lessons() if l.running}
            others = [o for o in rec["with"] if not str(o).startswith("r_evt_") and o not in teaching]
            others = [o for o in others if not self.life.managed(str(o))]
            if others and who not in teaching:
                self._spawn(self._maybe_talk(who, others, rec, whisper=bool(rec.get("whisper"))))

    def _update_body(self, who: str, rec: dict):
        """Apply an observation to needs, care, lessons and the seated players."""
        n = self._need(who)
        did = rec.get("did")
        if did in ("use", "bought") and isinstance(rec.get("restores"), dict):
            apply_restores(n, self.life.state(who) if self.life.managed(who) else None, rec["restores"])
        if rec.get("cared_by") and self.health.get(who, {}).get("ill"):
            self.health[who]["care"] = int(self.health[who].get("care", 0)) + 1
        for lesson in self.school.lessons():
            if did == "teach" and who == lesson.teacher:
                lesson.ready.set()
            if rec.get("hand") and lesson.running and who == lesson.teacher:
                lesson.on_hand(str(rec["hand"]).split(":", 1)[-1])
        if rec.get("seated"):
            at = rec.get("at")
            self.seated_players[str(rec["seated"]).split(":", 1)[-1]] = str(at[0]) if isinstance(at, list) and at else ""
        if rec.get("stood"):
            self.seated_players.pop(str(rec["stood"]).split(":", 1)[-1], None)
        if did == "ate":
            if "hunger" in n:
                n["hunger"] = 0.0
            n["eating"] = False
        elif did in ("left_hungry", "bought", "left_empty_handed") or rec.get("failed") in ("eat", "buy"):
            n["eating"] = False

    async def _bg_chat(self, system: str, messages: list) -> str:
        """A background (bg tier) chat: "" when no slot is free."""
        return await self.llm.chat(system, messages, priority=False)

    def _spawn(self, coro):
        """Run a coroutine as a tracked task whose failure is logged."""
        t = asyncio.create_task(coro)
        self._tasks.add(t)
        t.add_done_callback(self._task_done)

    def _task_done(self, t):
        self._tasks.discard(t)
        if not t.cancelled() and t.exception() is not None:
            print("[Brain] task failed: " + "".join(traceback.format_exception(t.exception())).strip()[-600:])

    def _persona(self, key: str) -> str:
        """The character card (minus notes), else the "persona" field, else a line from the routine."""
        r = self._resident(key)
        name = self._display_name(key)
        _, card = self.mind.store.card(str(r.get("id") or key))
        if card:
            return self._strip_notes(card)
        persona = str(r.get("persona", "")).strip()
        if not persona:
            stops = [str(e.get("name", "")) for e in r.get("routine", []) if e.get("name")]
            persona = f"{name}, a resident of the city." + (
                f" Your day: {', '.join(stops)}." if stops else "")
        return persona

    @staticmethod
    def _strip_notes(card: str) -> str:
        """The card without its "## Notes", "## Owner" and "## Out of character" sections."""
        out, skip = [], False
        for line in card.splitlines():
            if line.startswith("## "):
                skip = line[3:].strip().lower().startswith(("notes", "owner", "out of character"))
                if skip:
                    continue
            if not skip:
                out.append(line)
        return "\n".join(out).strip()

    def _model_for(self, key: str) -> str:
        """A character's own model (card frontmatter `model:`), else the default."""
        r = self._resident(key)
        return str(self.mind.store.card_meta(str(r.get("id") or key)).get("model", "") or "")

    def _memory_lines(self, key: str, n: int = 8) -> str:
        """The last n notable records of the raw stream, as prompt lines."""
        out = []
        for m in self.mind.store.recent(key, n):
            if "heard" in m:
                out.append(f"- {m['heard']} said: {m.get('text','')}")
            elif m.get("said"):
                to = m.get("to") or m.get("with") or "someone"
                out.append(f"- you said to {to}: {str(m['said']).replace(chr(10), ' ')[:120]}")
            elif "saw" in m:
                out.append(f"- {m['saw']} came up to you")
            elif m.get("did") == "ate":
                out.append(f"- you ate at {m.get('place','')}" + (" (your bento)" if m.get("meal") == "bento" else ""))
            elif m.get("did") == "eat":
                out.append(f"- you sought a meal at {m.get('place','')}; completion is not confirmed")
            elif m.get("did") == "football":
                out.append(f"- you played football in the school yard at break, on the {m.get('team','')} side")
            elif m.get("did") == "goal":
                out.append(f"- you scored a goal in the yard ({m.get('score','')})")
            elif m.get("did") == "match_end":
                out.append(f"- the kickabout ended {m.get('score','')}; you were on {m.get('team','')}")
            elif m.get("did") == "yard_break":
                out.append("- you spent the break in the school yard")
            elif m.get("did") == "sit":
                out.append(f"- you sat down at {m.get('place','')}")
            elif m.get("did") == "computer":
                out.append(f"- at your computer you read “{m.get('title') or m.get('url','')}”: {str(m.get('text','')).replace(chr(10), ' ')[:160]}")
            elif m.get("going"):
                out.append(f"- you went to {m.get('going')}")
        return "\n".join(out[-n:])

    def _flag_name(self, tag: str) -> dict:
        """{"en", "ja"} names of a flag tag (e.g. FRA) from data/world/flags.json."""
        path = os.path.join(self.mind.data_dir, "flags.json")
        try:
            mtime = os.path.getmtime(path)
            if getattr(self, "_flags_mtime", None) != mtime:
                with open(path, encoding="utf-8") as f:
                    self._flags = (json.load(f) or {}).get("flags", {})
                self._flags_mtime = mtime
        except Exception:
            self._flags = getattr(self, "_flags", {})
        return dict(self._flags.get(tag.upper(), {})) if tag else {}

    def _passerby_persona(self, rec: dict) -> str:
        """The persona of a passer-by: a countryball for a flag, else a local."""
        flag = str(rec.get("flag", "")).strip()
        if flag:
            name = self._flag_name(flag)
            country = f"{name.get('en', flag)} ({name.get('ja', '')})" if name else f"the country with flag tag '{flag}'"
            return (f"a countryball — a round, cheerful ball-shaped person wearing the flag of {country}. "
                    f"That country is who you are: when asked where you are from, say {name.get('ja') or flag}; "
                    f"speak from its character, proud and a little silly. You are passing through the city as a visitor.")
        return "a passer-by of the city, an ordinary local out on the street."

    def _system(self, key: str, persona: str = "", durable: str = "", lore: str = "") -> str:
        hour = self.mind.clock.hour()
        recent = (self._memory_lines(key, 6) if not persona else "") or "- nothing notable"
        return (
            f"You are {persona or self._persona(key)}\n"
            f"It is {int(hour):02d}:{int((hour % 1) * 60):02d} in the city.\n"
            f"Speak ONLY {SPEECH}, plain and natural, one or two short sentences. "
            f"No translation, no explanations, no quotes, no names of languages. {SPEECH_RULES} "
            f"You may be answered in any language; you still answer in {SPEECH}.\n"
            + identity.get("city_name_prompt") + "\n"
            + "What everyone in the city knows (one line each; you know all of it):\n"
            + self.lore.brief() + "\n"
            + (lore + "\n" if lore else "")
            + (f"What you remember (from before today):\n{durable}\n" if durable else "")
            + self.life.context(key) + "\n"
            + "Today so far:\n" + recent
        )

    async def _durable(self, key: str, query: str, rec: dict, extra_anchors=None) -> str:
        """Recalled durable memories for a prompt, anchored on where they are."""
        anchors = list(extra_anchors or [])
        for place in rec.get("at", []) or []:
            anchors.append(f"place:{place}")
        if rec.get("place"):
            anchors.append(f"place:{rec['place']}")
        try:
            mems = await self.memory.recall(key, query, anchors)
            if mems:
                print(f"[Memory] {key} recalls: " + ", ".join(f"{m['name']} ({m['reason']})" for m in mems))
            lines = []
            for m in mems:
                body = m["content"].split("\n\nRelated:")[0].split("\n\nSources:")[0].strip()
                lines.append(f"- ({m['type']}) {body[:400]}")
            return "\n".join(lines)
        except Exception as e:
            print(f"[Memory] recall failed for {key}: {e}")
            return ""

    def _voice_for(self, key: str) -> str:
        """The resident's "voice" folder, else a stable generic pick by key hash (the client hashes differently)."""
        r = self._resident(key)
        v = str(r.get("voice", "")).strip()
        if v:
            return v
        return "generic" if int(hashlib.md5(key.encode()).hexdigest(), 16) % 2 == 0 else "generic_f"

    async def _render(self, key: str, spoken: str) -> str:
        """A spoken line (joined into one) in the written script, or as spoken if conversion fails."""
        spoken = " ".join(l.strip() for l in spoken.strip().splitlines() if l.strip())
        if not spoken:
            return ""
        text, leftovers = await self.script.convert(spoken)
        if not text:
            return spoken
        return self.script.strip_leftovers(text, leftovers, f"{key}: {spoken}")

    def _exchange(self, key: str, speaker: str, n: int = 6) -> list:
        """The recent exchange with this player as chat turns, so a reply continues the conversation."""
        turns = []
        for m in self.mind.store.recent(key, 40):
            if m.get("heard") == f"player:{speaker}" and m.get("text"):
                turns.append({"role": "user", "content": f"{speaker} says to you: {m['text']}"})
            elif m.get("said") and m.get("to") == speaker:
                turns.append({"role": "assistant", "content": str(m["said"]).replace("\n", " ")})
        # A trailing user turn is the question being answered now.
        if turns and turns[-1]["role"] == "user":
            turns.pop()
        return turns[-n:]

    async def _reply(self, key: str, rec: dict, passerby: bool = False):
        """Answer a player (at most every REPLY_GAP_S), with tools for residents."""
        if not await self.llm.probe():
            return
        now = time.time()
        if now - self._reply_busy.get(key, 0.0) < REPLY_GAP_S:
            return
        self._reply_busy[key] = now
        speaker = str(rec.get("heard", "")).split(":", 1)[-1]
        persona = self._passerby_persona(rec) if passerby else ""
        durable = "" if passerby else await self._durable(key, str(rec.get("text", "")), rec,
                                                          [f"person:{speaker}"])
        history = [] if passerby else self._exchange(key, speaker)
        # Lore for where they stand, not for what was said.
        topics = self.lore.match("", rec.get("at", []))
        system = self._system(key, persona, durable, self.lore.block(topics))
        if history:
            system += "\nYou are mid-conversation with this person: do not greet again, answer what they just said."
        messages = history + [{"role": "user", "content": f"{speaker} says to you: {rec.get('text','')}"}]
        # A passer-by gets no tools; a resident may look things up first.
        names = [] if passerby else library.tools_for(key, self.mind.store.card_meta(
            str(self._resident(key).get("id") or key)))
        ja = await react.run(
            self.llm, system, messages,
            {"who": key, "lore": self.lore, "memory": self.memory},
            names=names, model=self._model_for(key), log=key)
        if not ja:
            print(f"[Brain] {key}: the model gave no reply to {speaker} (busy or failed)")
            return
        text = await self._render(key, ja)
        voice = str(rec.get("voice") or "") or self._voice_for(key)
        audio = await self.tts.synth(voice, ja)
        print(f"[Brain] {key} replies: {ja}  →  {text}" + ("  (voiced)" if audio else ""))
        if not passerby:
            self.mind.store.remember(key, {"said": ja, "to": speaker, "ts_real": now})
        await self.mind.say(key, text, audio)

    async def _maybe_talk(self, key: str, others: list, rec: dict, whisper: bool = False):
        """Maybe stage a short exchange between two residents standing together."""
        if not await self.llm.probe():
            return
        other = str(others[0])
        pair = "|".join(sorted([key, other]))
        now = time.time()
        chance = TALK_CHANCE * (0.35 if whisper else 1.0)
        if now - self._talk_at.get(pair, 0.0) < TALK_GAP_S or random.random() > chance:
            return
        self._talk_at[pair] = now
        a, b = self._display_name(key), self._display_name(other)
        where = ", ".join(rec.get("at", [])) or "the street"
        prompt = await self._talk_prompt(key, other, a, b, where, rec, whisper)
        raw = await self._bg_chat(f"You write believable small talk between two townspeople in {SPEECH}.",
                                  [{"role": "user", "content": prompt}])
        lines = _talk_lines(raw, key, other, a)
        if not lines:
            return
        lead = await self._take_talk_slot(lines)
        if lead is None:
            return
        print(f"[Brain] {key} & {other} chat at {where}: {len(lines)} lines")
        await self._stage_talk(key, other, lines, lead, whisper)

    async def _talk_prompt(self, key, other, a, b, where, rec, whisper) -> str:
        """The small-talk prompt for two residents, with lore and their memories."""
        lore_here = self.lore.block(self.lore.match("", rec.get("at", [])), full=False)
        mem_a = await self._durable(key, b, rec, [f"resident:{other}"])
        mem_b = await self._durable(other, a, rec, [f"resident:{key}"])
        if whisper:
            opening = (f"Write a WHISPERED aside of 2 lines between {a} and {b}, pupils at neighbouring desks "
                       f"during a lesson — quick, hushed, about anything but the lesson or teasing about it. ")
        else:
            opening = f"Write a short natural exchange, 4 lines, between {a} and {b}, who just met at {where}. "
        return (opening
                + f"{a}: {self._persona(key)} {b}: {self._persona(other)} "
                + (f"\n{lore_here}\n" if lore_here else "")
                + (f"\n{a} remembers:\n{mem_a}\n" if mem_a else "")
                + (f"\n{b} remembers:\n{mem_b}\n" if mem_b else "")
                + f"{SPEECH} only. Format each line as 'NAME: text' using exactly these names: "
                + f"{a} and {b}. No other text.")

    async def _take_talk_slot(self, lines: list):
        """Reserve a TALK_SLOTS slot, waiting once 8-30 s if full; returns the start delay, or None to give up."""
        now = time.time()
        self._talk_slots = [t for t in getattr(self, "_talk_slots", []) if t > now]
        if len(self._talk_slots) >= TALK_SLOTS:
            await asyncio.sleep(random.uniform(8.0, 30.0))
            now = time.time()
            self._talk_slots = [t for t in self._talk_slots if t > now]
            if len(self._talk_slots) >= TALK_SLOTS:
                return None
        total = sum(_talk_secs(l[1]) for l in lines[:6])
        lead = random.uniform(0.5, 6.0)
        self._talk_slots.append(now + lead + total)
        return lead

    async def _stage_talk(self, key: str, other: str, lines: list, lead: float, whisper: bool):
        """Send each speaker their lines as timed say intents, one line after another."""
        per = {key: [], other: []}
        prev_end = {key: 0.0, other: 0.0}      # when each speaker's last line (incl. its hold) ends
        for i, (spk, ja) in enumerate(lines[:6]):
            text = await self._render(spk, ja)
            secs = _talk_secs(ja)
            # Each line starts when every earlier one is over; a speaker's queue is sequential, so wait only the rest.
            start = lead + sum(_talk_secs(l[1]) for l in lines[:i])
            wait = start - prev_end[spk]
            if wait > 0.2:
                per[spk].append({"do": "wait", "for": wait})
            prev_end[spk] = start + secs + 2.0    # a "say" holds secs + 2 in the world
            say = {"do": "say", "text": text, "read": ja, "secs": secs}
            audio = "" if whisper else await self.tts.synth(self._voice_for(spk), ja)
            if audio:
                say["audio"] = audio
            per[spk].append(say)
            self.mind.store.remember(spk, {"said": ja, "with": other if spk == key else key})
        for spk, intents in per.items():
            if intents:
                await self.mind.push_intents(spk, intents)


def _busy_hours(routine: list) -> list:
    """(start, end) of each attend/teach routine entry, up to the next entry."""
    busy = []
    hours = sorted(routine, key=lambda e: float(e.get("hour", 0)))
    for i, e in enumerate(hours):
        if str(e.get("do", "")) in ("attend", "teach"):
            end = float(hours[i + 1].get("hour", 24)) if i + 1 < len(hours) else 24.0
            busy.append((float(e.get("hour", 0)), end))
    return busy


def _outings(data: dict, places: dict, busy: list) -> list:
    """Intents for up to two valid planned outings (6-23 h, known place, free time)."""
    intents = []
    for o in (data.get("outings") or [])[:2]:
        pid = str(o.get("place", ""))
        try:
            at = float(o.get("at", -1))
        except (TypeError, ValueError):
            continue
        if pid not in places or not (6.0 <= at <= 23.0):
            continue
        if any(b0 <= at < b1 for b0, b1 in busy):
            continue
        verb = "eat" if places[pid].get("kind") == "restaurant" else "go"
        intents.append({"at": at, "do": verb, "place": pid, "then": "wander",
                        "name": str(o.get("why", ""))[:80]})
    return intents


def _talk_secs(ja: str) -> float:
    """How long a small-talk line is held, in seconds."""
    return 4.0 + min(len(ja), 40) * 0.12


def _talk_lines(raw: str, key: str, other: str, a: str) -> list:
    """(speaker key, text) for each "NAME: text" line; lines naming a are key's."""
    lines = []
    for line in raw.splitlines():
        if ":" not in line and "：" not in line:
            continue
        nm, txt = (line.split(":", 1) if ":" in line else line.split("：", 1))
        nm, txt = nm.strip(" *-"), txt.strip()
        if txt:
            lines.append((key if nm.startswith(a) else other, txt))
    return lines
