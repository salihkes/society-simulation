"""The mind: the server's persistent side of the city (clock, world record, memory, the brain)."""
import asyncio
import json
import os
import time

from . import library
from .brain import Brain
from .computer import Computers
from .lines import Lines
from .clock import WorldClock
from .rehearsal import Rehearsal, recover as _recover_rehearsal
from .store import WorldStore
from .weather import WorldWeather
from .memory.store import is_engine_recovery


class Mind:
    def __init__(self, data_dir: str, send_all, send_world, environment_file=None):
        os.makedirs(data_dir, exist_ok=True)
        self.data_dir = data_dir
        _recover_rehearsal(data_dir)    # restore the world if a rehearsal was cut short
        self.send_all = send_all        # async (dict) -> None : every client
        self.send_world = send_world    # async (dict) -> None : the world process
        self.clock = WorldClock(os.path.join(data_dir, "clock.json"))
        self.weather = WorldWeather(environment_file or os.path.join(data_dir, "world_environment.json"))
        self.store = WorldStore(data_dir)
        self.store.clock = self.clock     # so everything it writes carries the hour
        self.lines = Lines(data_dir)
        self.brain = Brain(self)
        self.computers = Computers(self)
        self.sitting = None             # the current parliament.Sitting, if any
        self.rehearsal = Rehearsal(self)
        self._residents_mtime = self.store.residents_mtime()
        self._households_mtime = self.store.households_mtime()

    async def on_world_report(self, msg: dict):
        """Apply the world's place report and resend the residents."""
        self.store.apply_world_report(msg)
        self._residents_mtime = self.store.residents_mtime()
        await self.send_residents()
        if self.brain is not None:
            await self.brain.on_world_report()

    async def on_world_reset(self):
        if self.brain is not None:
            await self.brain.on_world_reset()

    async def send_residents(self):
        if self.store.residents:
            await self.send_world(self.store.residents_message())

    async def on_observations(self, msg: dict):
        """Stamp, route and react to a batch of world observations."""
        hour = float(msg.get("hour", self.clock.hour()))
        day = int(msg.get("day", self.clock.day()))
        for obs in msg.get("obs", []):
            if not isinstance(obs, dict):
                continue
            rec = dict(obs)
            rec["hour"] = round(hour, 2)
            rec["day"] = day
            who = str(rec.pop("who", "") or "")
            if is_engine_recovery(rec):
                self._log_recovery(who, rec)
                continue
            self.brain.life.observe(who, rec)
            if rec.get("life_view") is not None or rec.get("life_result") is not None:
                continue
            if not rec.get("ped"):
                self.store.observe(who, rec)    # pedestrians keep no memory
            if self.brain is not None:
                try:
                    await self.brain.react(who, rec)
                except Exception as e:
                    print(f"[Mind] react failed for {who}: {e}")

    def _log_recovery(self, who: str, rec: dict):
        """Append an engine-recovery record to logs/movement.jsonl."""
        try:
            from core import paths
            path = paths.logs("movement.jsonl")
        except Exception:
            path = os.path.join(self.data_dir, "..", "logs", "movement.jsonl")
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "a", encoding="utf-8") as f:
                f.write(json.dumps(dict(rec, who=who, ts=round(time.time(), 1)), ensure_ascii=False) + "\n")
        except OSError:
            pass

    async def push_intents(self, resident_key: str, intents: list, replace: bool = False):
        """Send intents to the world process unless the resident is under manual control; school intents cancel the life action."""
        key = self.brain._resident_key(resident_key)
        if self.brain.life.managed(key) and self.brain.life.state(key)["mode"] == "manual":
            return
        if any(i.get("do") in ("attend", "teach", "dismiss") for i in intents if isinstance(i, dict)):
            await self.brain.life.cancel(key, "school timetable changed")
        await self.send_world({"type": "res_plan", "id": resident_key,
                               "intents": intents, "replace": replace})

    async def say(self, resident_key: str, text: str, audio_b64: str = ""):
        """A resident speaks: bubble (and voice) on every client, world included."""
        msg = {"type": "npc_say", "id": resident_key, "text": text}
        if audio_b64:
            msg["audio"] = audio_b64
        await self.send_all(msg)

    async def say_line(self, resident_key: str, line_id: str, secs: float = 3.0):
        """A pre-recorded registry line (dialogs.json): every peer plays its own clip."""
        await self.send_all({"type": "npc_say", "id": resident_key, "line": line_id, "secs": secs})

    async def command(self, data: dict, reply):
        """Run one manual-control command (tools/run/mindctl.py); errors are replied, not raised."""
        cmd = str(data.get("cmd", ""))
        handlers = {
            "life": self._cmd_life, "say": self._cmd_say, "plan": self._cmd_plan,
            "sitting": self._cmd_sitting, "consolidate": self._cmd_consolidate,
            "clock": self._cmd_clock, "weather": self._cmd_weather,
            "computer": self._cmd_computer, "residents": self._cmd_residents,
            "lesson": self._cmd_lesson, "ask": self._cmd_ask, "lore": self._cmd_lore,
            "library": self._cmd_library, "school": self._cmd_school,
            "household": self._cmd_household, "rehearsal": self._cmd_rehearsal,
            "status": self._cmd_status,
        }
        try:
            handler = handlers.get(cmd)
            if handler is None:
                await reply({"type": "mind_reply", "ok": False, "text": f"unknown cmd '{cmd}'"})
                return
            await handler(data, reply)
        except Exception as e:
            await reply({"type": "mind_reply", "ok": False, "text": repr(e)})

    async def _cmd_life(self, data: dict, reply):
        result = await self.brain.life.command(data)
        await reply({"type": "mind_reply", "ok": True, "text": json.dumps(result, ensure_ascii=False)})

    async def _cmd_say(self, data: dict, reply):
        """Make a resident (or player avatar) say a line in the spoken language."""
        key = str(data.get("id", ""))
        key = key if key.startswith("r_") or key.startswith("p") else "r_" + key
        ja = str(data.get("text", "")).strip()
        text = await self.brain._render(key, ja) if data.get("convert", True) else ja
        audio = ""
        if data.get("voice", True):
            audio = await self.brain.tts.synth(self.brain._voice_for(key), ja)
        await self.say(key, text, audio)
        await reply({"type": "mind_reply", "ok": True, "text": text, "voiced": bool(audio)})

    async def _cmd_plan(self, data: dict, reply):
        """Send intents to a resident directly, taking them from the life loop."""
        key = str(data.get("id", ""))
        intents = data.get("intents", [])
        key = self.brain._resident_key(key)
        if self.brain.life.managed(key):
            await self.brain.life.cancel(key, "manual plan")
        await self.send_world({"type": "res_plan", "id": key, "intents": intents, "replace": bool(data.get("replace", False))})
        await reply({"type": "mind_reply", "ok": True, "text": f"{len(intents)} intent(s) → {key}"})

    async def _cmd_sitting(self, data: dict, reply):
        sub = str(data.get("op", "start"))
        if sub == "stop":
            if self.sitting:
                self.sitting.stop()
            await reply({"type": "mind_reply", "ok": True, "text": "adjourned"})
            return
        if sub == "status":
            st = self.sitting.status() if self.sitting else {"running": False}
            await reply({"type": "mind_reply", "ok": True,
                         "text": json.dumps(st, ensure_ascii=False)})
            return
        matter = str(data.get("matter", "")).strip()
        if not matter:
            await reply({"type": "mind_reply", "ok": False,
                         "text": "a sitting needs a matter"})
            return
        if self.sitting and self.sitting.running:
            await reply({"type": "mind_reply", "ok": False,
                         "text": "the house is already sitting"})
            return
        from .parliament import Sitting
        self.sitting = Sitting(self, self.brain, matter,
                               house=str(data.get("house", "both")),
                               as_of=data.get("as_of") or None,
                               members=int(data.get("members") or 0))
        self.sitting.start()
        await reply({"type": "mind_reply", "ok": True,
                     "text": f"the house is sitting: {matter[:60]}"})

    async def _cmd_consolidate(self, data: dict, reply):
        keys = [str(data["id"])] if data.get("id") else list(self.brain.needs)
        reps = []
        for k in keys:
            k = k if k.startswith("r_") else "r_" + k
            reps.append(await self.brain.memory.consolidate(k))
        await reply({"type": "mind_reply", "ok": True, "text": json.dumps(reps, ensure_ascii=False)})

    async def _cmd_clock(self, data: dict, reply):
        """Rewrite clock.json from the given fields and apply it now."""
        path = os.path.join(self.data_dir, "clock.json")
        try:
            with open(path, "r", encoding="utf-8") as f:
                cfg = json.load(f) or {}
        except Exception:
            cfg = {}
        if "mode" in data:                       # a new mode replaces hour/rate
            cfg = {k: v for k, v in cfg.items() if k == "weekday"}
        for k in ("mode", "hour", "rate", "weekday"):
            if k in data:
                cfg[k] = data[k]
        if str(cfg.get("weekday", "auto")).lower() == "auto":
            cfg.pop("weekday", None)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        self.clock.reload()
        self.clock.checkpoint()
        await self.send_all(self.clock.message())
        if self.brain is not None and "mode" in data:
            await self.brain.on_clock_jump()
        await reply({"type": "mind_reply", "ok": True, "text": json.dumps(self.clock.message())})

    async def _cmd_weather(self, data: dict, reply):
        """Set a weather preset (unless "status") and reply with the weather status."""
        preset = str(data.get("weather", "status")).strip().lower()
        if preset != "status":
            await self.send_all(self.weather.set(preset, data.get("snow"), region=data.get("region"),
                                                 temperature_c=data.get("temperature_c"),
                                                 humidity_percent=data.get("humidity_percent")))
        await reply({"type": "mind_reply", "ok": True,
                     "text": json.dumps(self.weather.status(), ensure_ascii=False)})

    async def _cmd_computer(self, data: dict, reply):
        result = await self.computers.command(data)
        await reply({"type": "mind_reply", "ok": bool(result.get("ok", True)) if isinstance(result, dict) else True,
                     "text": json.dumps(result, ensure_ascii=False, indent=1)})

    async def _cmd_residents(self, data: dict, reply):
        ok = self.store.reload_residents()
        await self.send_residents()
        await reply({"type": "mind_reply", "ok": ok, "text": f"{len(self.store.residents)} residents → world"})

    async def _cmd_lesson(self, data: dict, reply):
        sub = str(data.get("sub", "status"))
        if sub == "start":
            ldir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "lessons", str(data.get("id", "")))
            if not os.path.isdir(ldir):
                await reply({"type": "mind_reply", "ok": False, "text": f"no lesson at {ldir}"})
                return
            students = data.get("students")
            if isinstance(students, list):
                students = [s if str(s).startswith("r_") else "r_" + str(s) for s in students]
            st = await self.brain.start_lesson(ldir, str(data.get("teacher", "r_teacher_chem")), students,
                                               day=self.brain.school.day(str(data.get("class", ""))))
        elif sub == "stop":
            if data.get("class"):
                st = await self.brain.end_lesson(self.brain.school.day(str(data["class"])))
            else:
                st = [await self.brain.end_lesson(d) for d in list(self.brain.school.days.values())]
        else:
            st = [l.status() for l in self.brain.school.lessons()] or {"running": False}
        await reply({"type": "mind_reply", "ok": True, "text": json.dumps(st, ensure_ascii=False)})

    async def _cmd_ask(self, data: dict, reply):
        """A pupil asks the teacher a question in the running lesson."""
        key = str(data.get("id", ""))
        key = key if key.startswith("r_") else "r_" + key
        lesson = self.brain.school.lesson_of(key)
        if lesson is None or not lesson.running:
            await reply({"type": "mind_reply", "ok": False, "text": "no lesson is running in this pupil's class"})
            return
        if not lesson.paused.is_set():
            await reply({"type": "mind_reply", "ok": False, "text": "the lesson is paused (break)"})
            return
        text = await lesson.ask_as(key, str(data.get("text", "")).strip())
        await reply({"type": "mind_reply", "ok": True, "text": f"{key} asked: {text} — the teacher answers after the beat"})

    async def _cmd_lore(self, data: dict, reply):
        q = str(data.get("text", "")).strip()
        lore = self.brain.lore
        lore.reload()
        if q:
            hits = lore.match(q) or lore.lookup(q)
            await reply({"type": "mind_reply", "ok": True,
                         "text": "\n".join(f"{t.name}: {t.summary}" for t in hits) or "no topic matches"})
        else:
            await reply({"type": "mind_reply", "ok": True, "text": lore.brief() or "no lore yet"})

    async def _cmd_library(self, data: dict, reply):
        """List the tools a resident ("id") may use, or run one as them."""
        name = str(data.get("tool", "")).strip()
        if not name:
            names = library.tools_for(str(data.get("id", "")), {})
            head = "open" if library.available() else "shut (the city keeps to its lore)"
            await reply({"type": "mind_reply", "ok": True,
                         "text": f"the library is {head}\n" + library.describe(names)})
            return
        ctx = {"who": str(data.get("id", "")), "lore": self.brain.lore,
               "memory": self.brain.memory,
               "loop": asyncio.get_running_loop()}
        out = await asyncio.to_thread(library.execute, name,
                                      data.get("args") or {}, ctx)
        await reply({"type": "mind_reply", "ok": True, "text": out})

    async def _cmd_school(self, data: dict, reply):
        """Drive a class (or every class) by hand, open/close the school, or report."""
        sub = str(data.get("sub", "status"))
        days = [self.brain.school.day(str(data["class"]))] if data.get("class") else list(self.brain.school.days.values())
        if sub in ("bell", "class", "break", "lunch", "free", "pe", "gather", "assembly_am", "assembly_pm"):
            for d in days:
                await self.send_world({"type": "school_cmd", "school": d.place, "cmd": sub})
            await reply({"type": "mind_reply", "ok": True, "text": f"school_cmd {sub} → " + ", ".join(d.place for d in days)})
        elif sub in ("closed", "open"):
            self.brain.school.closed_override = sub == "closed"
            await self.brain.school.tick(self.clock.hour())
            await reply({"type": "mind_reply", "ok": True, "text": f"school {sub}"})
        elif sub == "assemble":
            out = [await self._assemble(d) for d in days]
            await reply({"type": "mind_reply", "ok": True, "text": "; ".join(out)})
        else:
            await reply({"type": "mind_reply", "ok": True,
                         "text": json.dumps(self.brain.school.status(self.clock.hour()), ensure_ascii=False, indent=1)})

    async def _assemble(self, d) -> str:
        """Send a class's pupils to their desks and its teacher to the lectern."""
        n = 0
        for s in d.pupils():
            await self.push_intents(s, [{"do": "attend", "place": d.place}])
            n += 1
        await self.push_intents(d._teacher(), [{"do": "teach", "place": d.place}])
        return f"{n} pupils + {d._teacher()} → {d.place}"

    async def _cmd_household(self, data: dict, reply):
        """Household status, a restock, or a resident falling ill or recovering."""
        op = str(data.get("op", "status"))
        if op == "status":
            st = {"households": self.store.households,
                  "ill": {k: v for k, v in self.brain.health.items() if v.get("ill")},
                  "needs": {k: {n: round(x, 2) for n, x in v.items() if isinstance(x, (int, float))}
                            for k, v in self.brain.needs.items()}}
            await reply({"type": "mind_reply", "ok": True, "text": json.dumps(st, ensure_ascii=False, indent=1)})
        elif op == "restock":
            hid = str(data.get("id", ""))
            if hid not in self.store.households:
                raise ValueError("unknown household")
            await self.send_world({"type": "household_cmd", "cmd": "restock", "household": hid, "n": int(data.get("n", 4))})
            await reply({"type": "mind_reply", "ok": True, "text": f"{hid} restocked"})
        elif op in ("ill", "well"):
            key = self.brain._resident_key(str(data.get("id", "")))
            if key[2:] not in self.store.residents:
                raise ValueError("unknown resident")
            if op == "ill":
                await self.brain.fall_ill(key, int(data.get("days", 2)))
            else:
                await self.brain.recover(key)
            await reply({"type": "mind_reply", "ok": True, "text": f"{key} {op}"})
        else:
            raise ValueError("unknown household operation")

    async def _cmd_rehearsal(self, data: dict, reply):
        op = str(data.get("op", "status"))
        if op == "start":
            r = self.rehearsal.start(data.get("_client"))
        elif op == "end":
            r = await self.rehearsal.end("asked")
        else:
            r = self.rehearsal.status()
        await reply({"type": "mind_reply", "ok": True, "text": json.dumps({"rehearsal": r})})

    async def _cmd_status(self, data: dict, reply):
        st = {"clock": self.clock.message(), "residents": list(self.store.residents),
              "places": len(self.store.places), "llm": self.brain.llm.available,
              "llm_model": self.brain.llm.model, "llm_endpoints": self.brain.llm.status(),
              "tts": self.brain.tts.available, "rehearsal": self.rehearsal.status(),
              "needs": {k: round(v.get("hunger", 0), 2) for k, v in self.brain.needs.items()}}
        await reply({"type": "mind_reply", "ok": True, "text": json.dumps(st, ensure_ascii=False)})

    async def _watch_loop(self):
        """Log loop hold-ups over a second and the worst every 5 minutes; GAME_LOOP_DEBUG=1 names the callback."""
        loop = asyncio.get_running_loop()
        if os.environ.get("GAME_LOOP_DEBUG"):
            _enable_loop_debug(loop)
        worst, since = 0.0, time.monotonic()
        while True:
            t = time.monotonic()
            await asyncio.sleep(1.0)
            lag = time.monotonic() - t - 1.0
            if lag > 1.0:
                print(f"[Loop] held up {lag:.1f}s")
            worst = max(worst, lag)
            if time.monotonic() - since > 300:
                print(f"[Loop] worst hold-up in the last 5 min: {worst:.1f}s")
                worst, since = 0.0, time.monotonic()

    async def _reload_changed_files(self):
        """Apply residents.json and households.json when edited by hand."""
        mt = self.store.residents_mtime()
        if mt != self._residents_mtime:
            self._residents_mtime = mt
            if self.store.reload_residents():
                print(f"[World] residents.json changed: {len(self.store.residents)} residents → world")
                await self.send_residents()
                if self.brain is not None:
                    await self.brain.on_world_report()
        hmt = self.store.households_mtime()
        if hmt != self._households_mtime:
            self._households_mtime = hmt
            if self.store.reload_households():
                print(f"[World] households.json changed: {len(self.store.households)} households → world")
                await self.send_residents()

    async def _tick(self):
        """One period: clock broadcast, file reloads, the brain and the computers."""
        self.clock.reload()
        self.clock.checkpoint()
        await self.send_all(self.clock.message())
        await self._reload_changed_files()
        if self.brain is not None:
            await self.brain.tick()
        try:
            await self.computers.tick(self.clock.hour(), self.clock.day(), self.clock.weekday())
        except Exception as e:
            print(f"[Computer] tick failed: {e}")

    async def run(self, period: float = 5.0):
        """Warm the library, watch the loop, and tick every period seconds forever."""
        asyncio.create_task(library.warm())
        asyncio.create_task(self._watch_loop())
        while True:
            try:
                await self._tick()
            except Exception as e:
                print(f"[Mind] tick failed: {e}")
            await asyncio.sleep(period)


def _enable_loop_debug(loop):
    """asyncio debug mode: log callbacks that hold the loop over 1 s."""
    import logging
    loop.set_debug(True)
    loop.slow_callback_duration = 1.0
    log = logging.getLogger("asyncio")
    h = logging.StreamHandler()
    h.setFormatter(logging.Formatter("[Loop] %(message)s"))
    log.addHandler(h)
    log.setLevel(logging.WARNING)
    print("[Loop] debug on: callbacks holding the loop over 1s are named")
