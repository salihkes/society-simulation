"""The school: each class's day of bells and periods, and the school that holds the classes."""
import asyncio
import json
import os
import random
import time


DEFAULT_TEACHER = "r_teacher_chem"


class SchoolDay:
    """One class's day: bells and periods on the game clock; a period resumes its lesson where it stood."""

    def __init__(self, brain, school, name: str = "", klass: dict = None, primary: bool = True):
        self.brain = brain
        self.mind = brain.mind
        self.school = school           # the School container (shared cfg)
        self.name = name               # class name ("12B"); "" for a one-room school
        self.klass = dict(klass or {}) # this class's entry: place, teacher, periods
        self.primary = primary
        self.lesson = None             # the lesson being taught in this room, if any
        self.in_period = False
        self.period_idx = -1
        self.lesson_idx = 0
        self._last_hour = None
        self.progress: dict = {}     # lesson id -> beat where it stands (across periods, resets, restarts)
        self.teacher_absent = False
        self._late_tasks: list = []
        self._assembly_day = None      # the day the morning assembly was held
        self._gather_day = None        # the day everyone was sent to the yard for it
        self._last_tick_hour = None
        self.rite = False              # the period opened with the class rising and bowing (so it closes with one)
        self.saved_deferred: list = []   # deferred questions of a lesson that was interrupted
        self.saved_lesson_id = ""
        self._closed_day = None        # the day the pupils were last told the school is shut
        self.state_path = os.path.join(self.mind.data_dir,
                                       "school_state.json" if primary else f"school_state_{name}.json")
        self._load_state()

    @property
    def cfg(self) -> dict:
        return self.school.cfg

    @property
    def place(self) -> str:
        """The room's place id in the world ("School", "School/11B")."""
        return str(self.klass.get("place") or self.cfg.get("school", "School"))

    def has_pupil(self, r: dict) -> bool:
        """True for a student of this class ("class" field; none means the first class)."""
        if not r.get("student"):
            return False
        c = str(r.get("class", "") or "")
        return c == self.name or (not c and self.primary)

    def pupils(self) -> list:
        return [self.brain._resident_key(rid) for rid, r in self.mind.store.residents.items() if self.has_pupil(r)]

    def _load_state(self):
        """Restore lesson progress, the lesson cycle, assembly days and promises."""
        try:
            with open(self.state_path, encoding="utf-8") as f:
                st = json.load(f) or {}
            self.progress = {str(k): int(v) for k, v in (st.get("progress", {}) or {}).items()}
            if st.get("lesson_id") and "resume_pos" in st and str(st["lesson_id"]) not in self.progress:
                self.progress[str(st["lesson_id"])] = int(st.get("resume_pos", 0))
            self.lesson_idx = int(st.get("lesson_idx", 0))
            self._assembly_day = st.get("assembly_day")
            self._gather_day = st.get("gather_day")
            self.saved_deferred = list(st.get("deferred", []) or [])
            self.saved_lesson_id = str(st.get("lesson_id", ""))
            print(f"[School] state: progress {self.progress}, assembly day {self._assembly_day}"
                  + (f", {len(self.saved_deferred)} promise(s) kept" if self.saved_deferred else ""))
        except Exception:
            pass

    def _save_state(self):
        lesson = self.lesson
        if lesson is not None and lesson.running:
            self.progress[lesson.id] = lesson.pos
        deferred = [dict(d) for d in lesson.deferred] if (lesson is not None and lesson.running) else self.saved_deferred
        lesson_id = lesson.id if (lesson is not None and lesson.running) else self.saved_lesson_id
        try:
            with open(self.state_path, "w", encoding="utf-8") as f:
                json.dump({"progress": self.progress, "lesson_idx": self.lesson_idx, "lesson_id": lesson_id,
                           "deferred": deferred, "assembly_day": self._assembly_day, "gather_day": self._gather_day,
                           "saved_hour": round(self.mind.clock.hour(), 2)}, f, ensure_ascii=False)
        except OSError:
            pass

    def on_world_reset(self):
        """Remember the lesson's place and promises and re-open the period next tick."""
        lesson = self.lesson
        if lesson is not None:
            self.progress[lesson.id] = lesson.pos
            self.saved_deferred = [dict(d) for d in lesson.deferred]
            self.saved_lesson_id = lesson.id
        for t in self._late_tasks:
            t.cancel()
        self._late_tasks = []
        self.in_period = False
        self._save_state()

    def _resident_by_key(self, key: str) -> dict:
        rid = key[2:] if key.startswith("r_") else key
        return self.mind.store.residents.get(rid, {})

    # Periods are [start, end] or {"start", "end", "subject", "lesson", "teacher"}; "periods" may be a weekly table.
    WEEK = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    def current_period(self):
        """The period being taught right now, or None between them."""
        periods = self._periods()
        if self.in_period and 0 <= self.period_idx < len(periods):
            return periods[self.period_idx]
        return None

    def _periods(self) -> list:
        """Today's periods as dicts with start, end, subject, lesson and teacher."""
        out = []
        periods = self.klass.get("periods") or self.cfg.get("periods", [])
        if isinstance(periods, dict):
            day = self.WEEK[self.mind.clock.weekday()]
            periods = periods.get(day) or periods.get("default") or []
        for p in periods:
            if isinstance(p, dict):
                out.append({"start": float(p.get("start", 0)), "end": float(p.get("end", 0)),
                            "subject": str(p.get("subject", "")), "lesson": str(p.get("lesson", "")),
                            "teacher": str(p.get("teacher", ""))})
            else:
                out.append({"start": float(p[0]), "end": float(p[1]), "subject": "", "lesson": "", "teacher": ""})
        return out

    def _current_period(self, hour: float):
        """Index of the period containing hour, or -1."""
        for i, p in enumerate(self._periods()):
            if p["start"] <= hour < p["end"]:
                return i
        return -1

    def status(self, hour: float) -> dict:
        """The class's timetable and lesson state for status and prompts."""
        periods = self._periods()
        idx = self._current_period(hour)
        nxt = next((p for p in periods if p["start"] > hour), None)
        lesson = self.lesson
        def hm(h):
            return f"{int(h):02d}:{int(round((h % 1) * 60)):02d}"
        return {
            "now": hm(hour),
            "class": self.name,
            "place": self.place,
            "timetable": [f"{hm(p['start'])}-{hm(p['end'])} {p['subject'] or '(lesson)'} {p['lesson']}".strip() for p in periods],
            "period": (idx + 1) if idx >= 0 else None,
            "closed": self.school.closed,
            "teacher_absent": self.teacher_absent if idx >= 0 else False,
            "next_bell": hm(nxt["start"]) if nxt else ("school is out" if periods else "no timetable"),
            "lesson": ({"id": lesson.id, "beat": lesson.pos, "total": len(lesson.beats), "running": lesson.running,
                        "paused": not lesson.paused.is_set(), "deferred": len(lesson.deferred)} if lesson else None),
            "students": len(self.pupils()),
        }

    async def _cmd(self, cmd: str):
        """Send a school_cmd for this room to the world."""
        await self.mind.send_world({"type": "school_cmd", "school": self.place, "cmd": cmd})

    def _lesson_dir(self) -> str:
        """The period's own lesson folder when the timetable names one, else the cycle's."""
        periods = self._periods()
        name = ""
        if 0 <= self.period_idx < len(periods):
            name = periods[self.period_idx]["lesson"]
        if not name:
            lessons = self.cfg.get("lessons") or []
            if not lessons:
                return ""
            name = lessons[self.lesson_idx % len(lessons)]
        return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lessons", name)

    async def tick(self, hour: float):
        if not self._periods() or not self.brain.mind.store.residents:
            return
        days = self.cfg.get("days", [0, 1, 2, 3, 4])
        if self.mind.clock.weekday() not in days or self.school.closed:
            await self._no_school(hour)
            return
        self._assembly_tick(hour)
        self._last_tick_hour = hour
        idx = self._current_period(hour)
        if idx >= 0 and self.in_period and idx != self.period_idx:
            await self._end_period(hour)
            self.in_period = False
        if idx >= 0 and not self.in_period:
            self.in_period = True
            self.period_idx = idx
            await self._start_period()
        elif idx < 0 and self.in_period:
            self.in_period = False
            await self._end_period(hour)

    async def _no_school(self, hour: float):
        """A day off or a closed school: tell the pupils once in the morning and end any open period as the day's end."""
        if self.school.closed and self._closed_day != self.mind.clock.day() and 6.0 <= hour < 9.0:
            self._closed_day = self.mind.clock.day()
            await self.brain.school_closed_day(self)
        if self.in_period:
            self.in_period = False
            self.period_idx = len(self._periods()) - 1     # so the day ends: dismiss everyone
            await self._end_period(hour)

    def _assembly_tick(self, hour: float):
        """On assembly days, start the gathering and ceremony when the running clock crosses their hours (not on a jump)."""
        asm = (self.cfg.get("assembly") or {}).get("morning") or {}
        if not asm or self.mind.clock.weekday() != int(asm.get("day", 0)):
            return
        at = float(asm.get("at", 8.2))
        gather = float(asm.get("gather", at - 0.35))
        prev = self._last_tick_hour if self._last_tick_hour is not None else hour
        if prev < gather <= hour and hour - prev < 0.25 and self._gather_day != self.mind.clock.day():
            self._gather_day = self.mind.clock.day()
            self._save_state()
            self._late_tasks.append(asyncio.create_task(self._gather()))
        if prev < at <= hour and hour - prev < 0.25 and self._assembly_day != self.mind.clock.day():
            self._assembly_day = self.mind.clock.day()
            self._save_state()
            self._late_tasks.append(asyncio.create_task(self._assembly("am")))

    def _teacher(self) -> str:
        """The period's own teacher, else the class's or school's default."""
        periods = self._periods()
        if 0 <= self.period_idx < len(periods) and periods[self.period_idx].get("teacher"):
            t = periods[self.period_idx]["teacher"]
            return t if t.startswith("r_") else "r_" + t
        return self._default_teacher()

    def _default_teacher(self) -> str:
        t = str(self.klass.get("teacher") or self.cfg.get("teacher", DEFAULT_TEACHER))
        return t if t.startswith("r_") else "r_" + t

    def _ceremony_teacher(self, kind: str) -> str:
        """Who stands with the class at an assembly: the first period's teacher ("am"), the last one's ("pm")."""
        periods = self._periods()
        teacher = ""
        if kind == "am" and periods:
            teacher = str(periods[0].get("teacher", ""))
        elif kind == "pm" and periods:
            teacher = str(periods[-1].get("teacher", ""))
        if not teacher:
            return self._default_teacher()
        return teacher if teacher.startswith("r_") else "r_" + teacher

    async def _start_period(self):
        """Ring the bell, seat the pupils who come, and start the roll call and lesson."""
        # A period opened twice must not keep the first opening's tasks running.
        for t in self._late_tasks:
            t.cancel()
        self._late_tasks = []
        teacher = self._teacher()
        school = self.place
        pupils = self.pupils()
        if self.brain.life.managed(teacher):
            _, teacher_view = self.brain.life.views.get(teacher, (0, {}))
            self.teacher_absent = self.brain.life.state(teacher)["mode"] == "manual" and not teacher_view.get("teaching", False)
        else:
            self.teacher_absent = random.random() < float(self.cfg.get("absent_chance", 0.08))
        on_time, late, skipping = self._attendance(pupils)
        print(f"[School{self._tag()}] period {self.period_idx + 1} begins — bell, {len(on_time)} on time, {len(late)} late, "
              f"{len(skipping)} skipping" + (", TEACHER ABSENT" if self.teacher_absent else ""))
        await self._cmd("bell")
        await asyncio.sleep(4.0)
        for s in on_time:
            await self.mind.push_intents(s, [{"do": "attend", "place": school}])
        for s in skipping:
            await self._skip(s)
        for s in late:
            self._late_tasks.append(asyncio.create_task(self._arrive_late(s, school)))
        await self._cmd("class")
        # Roll call and the lesson run as a task, so the day keeps ticking.
        self._late_tasks.append(asyncio.create_task(self._after_bell(teacher, on_time, pupils)))

    def _attendance(self, pupils: list) -> tuple:
        """(on_time, late, skipping): managed pupils decide (on time only if in school); others are rolled by chance."""
        late, skipping, on_time = [], [], []
        for s in pupils:
            if self.brain.life.managed(s):
                self.brain.life.event(s, {"scheduled_class_started": self.period_idx + 1,
                    "subject": self._periods()[self.period_idx]["subject"]})
                _, view = self.brain.life.views.get(s, (0, {}))
                if self.brain.life.state(s)["mode"] == "auto" and view.get("in_school"):
                    on_time.append(s)
                continue
            r = random.random()
            if r < float(self.cfg.get("skip_chance", 0.04)):
                skipping.append(s)
            elif r < float(self.cfg.get("skip_chance", 0.04)) + float(self.cfg.get("late_chance", 0.12)):
                late.append(s)
            else:
                on_time.append(s)
        return on_time, late, skipping

    async def _skip(self, s: str):
        """Send a skipping pupil somewhere else for the length of the period."""
        self.mind.store.remember(s, {"skipped": "class", "period": self.period_idx + 1})
        r = self._resident_by_key(s)
        spot = next((e["pos"] for e in r.get("routine", []) if isinstance(e.get("pos"), list)), None)
        per = self._periods()[self.period_idx]
        secs = max(60.0, (per["end"] - per["start"]) * 3600.0 / max(self.mind.clock.rate, 0.01))
        intent = {"do": "go", "then": "wander", "for": secs, "name": "skipping class"}
        if spot:
            intent["pos"] = spot
        await self.mind.push_intents(s, [intent])

    async def _after_bell(self, teacher: str, on_time: list, pupils: list):
        """After the bell: PE, a free period without a teacher, or the rites, roll call and lesson."""
        per = self._periods()[self.period_idx]
        if per["subject"].lower() in self.cfg.get("pe_subjects", ["pe"]):
            await self._pe_period(teacher, on_time)
            return
        if self.teacher_absent:
            await self._absent_teacher(pupils)
            return
        # The room rises, bows and sits before roll call.
        self.rite = True
        await asyncio.sleep(10.0 if self.cfg.get("rites", True) else 4.0)
        if self.cfg.get("roll_call", True):
            await self._roll_call(teacher, on_time)
        lesson = self.lesson
        if lesson is not None and lesson.running and lesson.pos < len(lesson.beats) \
                and lesson.teacher == teacher and os.path.basename(lesson.dir.rstrip("/")) == os.path.basename(self._lesson_dir().rstrip("/")):
            lesson.resume()
            return
        if lesson is not None and lesson.running:
            # Another subject's period: this lesson waits where it stands.
            self.progress[lesson.id] = lesson.pos
            self._save_state()
            await self.brain.end_lesson(self)
        await self._begin_lesson(teacher, pupils, lesson)

    async def _pe_period(self, teacher: str, on_time: list):
        """PE: pause the lesson, take the roll, and send the class to the yard."""
        lesson = self.lesson
        if lesson is not None and lesson.running:
            lesson.pause()
            self.progress[lesson.id] = lesson.pos
        await asyncio.sleep(3.0)
        if not self.teacher_absent and self.cfg.get("roll_call", True):
            await self._roll_call(teacher, on_time)
        print(f"[School{self._tag()}] PE — everyone to the yard")
        await self._cmd("pe")

    async def _absent_teacher(self, pupils: list):
        """No teacher: the class waits 45 s, then it is a free period."""
        lesson = self.lesson
        if lesson is not None and lesson.running:
            lesson.pause()
        await asyncio.sleep(45.0)
        if self.in_period and self.teacher_absent:
            print(f"[School{self._tag()}] no teacher came — free period")
            for s in pupils:
                self.mind.store.remember(s, {"free_period": True, "period": self.period_idx + 1})
            await self._cmd("free")

    async def _begin_lesson(self, teacher: str, pupils: list, lesson):
        """Start the period's lesson from its saved beat (the next in the cycle if finished), restoring promises."""
        ldir = self._lesson_dir()
        if not ldir or not os.path.isdir(ldir):
            return
        if not os.path.exists(os.path.join(ldir, "beats.ja.json")):
            print(f"[School{self._tag()}] lesson {os.path.basename(ldir)} is not built yet — the class sits with the teacher")
            return
        name = os.path.basename(ldir.rstrip("/"))
        start_at = int(self.progress.get(name, 0))
        if lesson is not None and not lesson.running and lesson.id == name and lesson.pos >= len(lesson.beats):
            self.lesson_idx += 1
            self.progress[name] = 0
            ldir = self._lesson_dir()
            name = os.path.basename(ldir.rstrip("/"))
            start_at = int(self.progress.get(name, 0))
        await self.brain.start_lesson(ldir, teacher, pupils, seat_pupils=False, start_at=start_at, day=self)
        if self.lesson is not None:
            self.lesson.question_chance = float(self.cfg.get("pupil_question_chance", 0.45))
            if self.saved_deferred and self.saved_lesson_id == self.lesson.id:
                self.lesson.deferred = [d for d in self.saved_deferred if int(d.get("beat", 0)) > self.lesson.pos]
                print(f"[School{self._tag()}] {len(self.lesson.deferred)} promise(s) restored to the lesson")
            self.saved_deferred = []
            self.lesson.cold_call_chance = float(self.cfg.get("cold_call_chance", 0.5))
        self._save_state()

    def _tag(self) -> str:
        """" <class>" for log lines, "" for a one-room school."""
        return f" {self.name}" if self.name else ""

    async def _roll_call(self, teacher: str, present: list):
        """The teacher reads names from pre-recorded lines; a pupil answers, a missing one is marked absent."""
        await self.mind.push_intents(teacher, [{"do": "teach", "place": self.place}])
        await asyncio.sleep(2.0)
        pupils = [(rid, r) for rid, r in self.mind.store.residents.items() if self.has_pupil(r)]
        pupils.sort(key=lambda x: str(x[1].get("name", x[0])))
        print(f"[School{self._tag()}] roll call: {len(pupils)} names, {sum(1 for rid, _ in pupils if self.brain._resident_key(rid) not in present)} absent")
        await self.mind.say_line(teacher, "rc_start", 2.5)
        await asyncio.sleep(2.6)
        for rid, r in pupils:
            key = self.brain._resident_key(rid)
            await self.mind.say_line(teacher, "name_" + rid, 1.6)
            await asyncio.sleep(1.3)
            _, physical = self.brain.life.views.get(key, (0, {}))
            actually_present = physical.get("seated", False) if self.brain.life.managed(key) else key in present
            if actually_present:
                await self.mind.say_line(key, "hai", 1.2)
                await asyncio.sleep(1.2)
            else:
                await self._mark_absent(teacher, rid, key)
        await asyncio.sleep(1.0)

    async def _mark_absent(self, teacher: str, rid: str, key: str):
        """The teacher notes an absence and the seated pupils notice it."""
        await self.mind.say_line(teacher, "rc_absent", 1.6)
        self.mind.store.remember(teacher, {"roll_call": rid, "absent": True, "period": self.period_idx + 1})
        for listener, (seen, view) in self.brain.life.views.items():
            if time.monotonic() - seen < 15 and view.get("seated") and view.get("school", self.place) == self.place:
                self.brain.life.event(listener, {"noticed_absent": key, "period": self.period_idx + 1})
        await asyncio.sleep(1.6)

    async def _assembly(self, kind: str):
        """The morning ("am") or closing ("pm") assembly: gather everyone; after the closing one, send them home."""
        school = self.place
        teacher = self._ceremony_teacher(kind)
        pupils = self.pupils()
        print(f"[School{self._tag()}] assembly ({kind}) — {len(pupils)} pupils")
        if kind == "am":
            # If the clock jumped past the gathering, gather everyone now.
            if self._gather_day != self.mind.clock.day():
                await self._gather()
                await asyncio.sleep(6.0)
            await self._cmd("assembly_" + kind)
        else:
            await self._cmd("assembly_" + kind)
        for s in pupils + [teacher]:
            self.mind.store.remember(s, {"assembly": kind, "anthem": True})
        if kind == "pm":
            await asyncio.sleep(95.0)
            await self._cmd("class")
            for s in pupils:
                await self.mind.push_intents(s, [{"do": "dismiss", "place": school}])

    async def _gather(self):
        """Before the morning assembly: open the yard and walk the class and the day's first teacher there."""
        teacher = self._ceremony_teacher("am")
        pupils = self.pupils()
        print(f"[School{self._tag()}] gathering in the yard — {len(pupils)} pupils, {teacher}")
        await self._cmd("gather")
        await asyncio.sleep(1.0)
        await self.mind.push_intents(teacher, [{"do": "teach", "place": self.place}])
        for s in pupils:
            await self.mind.push_intents(s, [{"do": "attend", "place": self.place}])

    async def _arrive_late(self, pupil: str, school: str):
        """A late pupil arrives 30-150 s into the period, if it is still on."""
        await asyncio.sleep(random.uniform(30.0, 150.0))
        if self.in_period:
            self.mind.store.remember(pupil, {"late": True, "period": self.period_idx + 1})
            await self.mind.push_intents(pupil, [{"do": "attend", "place": school}])

    async def _end_period(self, hour: float):
        """Pause the lesson, close with the rite and the bell, then break, lunch or the end of the school day."""
        last = self.period_idx >= len(self._periods()) - 1
        print(f"[School{self._tag()}] period {self.period_idx + 1} ends — bell, " + ("school is out" if last else "break"))
        for t in self._late_tasks:
            t.cancel()
        self._late_tasks = []
        lesson = self.lesson
        if lesson is not None and lesson.running:
            lesson.pause()
            self.progress[lesson.id] = lesson.pos
        if self.rite and self.cfg.get("rites", True):
            # Rise, bow and thank the teacher, then the bell.
            await self._cmd("rite_end")
            await asyncio.sleep(9.5)
        self.rite = False
        self._save_state()
        await self._cmd("bell")
        await asyncio.sleep(3.0)
        if last:
            await self._end_day()
        else:
            await self._break()

    async def _end_day(self):
        """End the lesson; hold the closing assembly on its day, else dismiss everyone."""
        await self.brain.end_lesson(self)
        closing = (self.cfg.get("assembly") or {}).get("closing") or {}
        if closing and self.mind.clock.weekday() == int(closing.get("day", 4)):
            await self._assembly("pm")
            return
        await self._cmd("class")   # nobody left to seat; clears break manners
        for s in self.pupils():
            await self.mind.push_intents(s, [{"do": "dismiss", "place": self.place}])

    async def _break(self):
        """A break; a long one is lunch, bento at the desks first, then the yard."""
        periods = self._periods()
        gap = float(periods[self.period_idx + 1]["start"]) - float(periods[self.period_idx]["end"])
        if gap < float(self.cfg.get("lunch_gap_hours", 0.75)):
            await self._cmd("break")
            return
        secs = gap * 3600.0 / max(self.mind.clock.rate, 0.01) * float(self.cfg.get("lunch_share", 0.25))
        print(f"[School{self._tag()}] lunch — bento at the desks for {secs:.0f}s, then the yard")
        # The world reports did:ate for the pupils actually at their desks.
        await self._cmd("lunch")
        self._late_tasks.append(asyncio.create_task(self._after_lunch(secs)))

    async def _after_lunch(self, secs: float):
        await asyncio.sleep(max(5.0, secs))
        if not self.in_period:
            await self._cmd("break")


class School:
    """The school: data/world/school.json and one SchoolDay per class; no "classes" means one room."""

    def __init__(self, brain):
        self.brain = brain
        self.mind = brain.mind
        self.path = os.path.join(self.mind.data_dir, "school.json")
        self.cfg: dict = {}
        self._mtime = None
        self.days: dict = {}           # class name -> SchoolDay, in timetable order
        self.closed_override = None    # mindctl "school closed"/"open" (None: school.json decides)
        self._closed_sent = None       # what the world was last told
        self.reload()

    @property
    def closed(self) -> bool:
        """True when the school is shut (mindctl override, else school.json)."""
        if self.closed_override is not None:
            return bool(self.closed_override)
        return bool(self.cfg.get("closed", False))

    def reload(self):
        """Re-read school.json if it changed, writing a default one if missing."""
        try:
            mt = os.path.getmtime(self.path)
        except OSError:
            if self.cfg:
                return
            self.cfg = {"school": "School", "teacher": DEFAULT_TEACHER,
                        "periods": [[8.5, 9.25], [9.5, 10.25], [10.5, 11.25], [11.5, 12.25],
                                    [13.25, 14.0], [14.25, 15.0], [15.25, 15.75]],
                        "lessons": []}
            with open(self.path, "w", encoding="utf-8") as f:
                json.dump(self.cfg, f, indent="\t")
            self._mtime = os.path.getmtime(self.path)
            self._sync_days()
            return
        if mt == self._mtime:
            return
        self._mtime = mt
        try:
            with open(self.path, encoding="utf-8") as f:
                self.cfg = json.load(f)
        except Exception as e:
            print(f"[School] school.json not applied: {e}")
            return
        self._sync_days()

    def _sync_days(self):
        """One SchoolDay per configured class, keeping existing ones."""
        classes = self.cfg.get("classes")
        if not isinstance(classes, dict) or not classes:
            classes = {"": {"place": self.cfg.get("school", "School")}}
        days = {}
        for i, (name, klass) in enumerate(classes.items()):
            klass = klass if isinstance(klass, dict) else {}
            if name in self.days:
                day = self.days[name]
                day.klass = dict(klass)
            else:
                day = SchoolDay(self.brain, self, name, klass, primary=(i == 0))
            days[name] = day
        for name, day in self.days.items():
            if name not in days and day.lesson is not None:
                day.lesson.stop()
        self.days = days
        if len(days) > 1:
            print(f"[School] classes: " + ", ".join(f"{n} @ {d.place}" for n, d in days.items()))

    @property
    def primary(self):
        return next(iter(self.days.values()), None)

    def day(self, name: str = ""):
        """A class by name; "" or an unknown name is the first class."""
        return self.days.get(str(name or ""), None) or self.primary

    def day_of(self, key: str):
        """A pupil's class, or the class a teacher is teaching now; else None."""
        r = self.brain._resident(key)
        if r.get("student"):
            for d in self.days.values():
                if d.has_pupil(r):
                    return d
        for d in self.days.values():
            if d.lesson is not None and d.lesson.running and d.lesson.teacher == key:
                return d
        for d in self.days.values():
            if d.in_period and d._teacher() == key:
                return d
        return None

    def in_class(self, key: str) -> bool:
        """True when this person is in a period now (managed residents: seated or teaching)."""
        if self.closed:
            return False
        day = self.day_of(key)
        if day is None or not bool(getattr(day, "in_period", False)):
            return False
        if self.brain.life.managed(key):
            seen, view = self.brain.life.views.get(key, (0, {}))
            return time.monotonic() - seen < 15 and bool(view.get("seated") or view.get("teaching"))
        return True

    def place_of(self, key: str) -> str:
        """The room of this person's class, or ""."""
        d = self.day_of(key)
        return d.place if d else ""

    def lessons(self) -> list:
        return [d.lesson for d in self.days.values() if d.lesson is not None]

    def lesson_of(self, key: str):
        """The running lesson this person teaches or attends, or None."""
        for l in self.lessons():
            if l.running and (l.teacher == key or key in l.students):
                return l
        return None

    def day_of_lesson(self, lesson):
        for d in self.days.values():
            if d.lesson is lesson:
                return d
        return None

    def status(self, hour: float) -> dict:
        """The one class's status, or every class's by name."""
        if len(self.days) == 1:
            return self.primary.status(hour)
        return {name: d.status(hour) for name, d in self.days.items()}

    def status_for(self, key: str, hour: float) -> dict:
        """The status of this person's class, or {}."""
        d = self.day_of(key)
        return d.status(hour) if d else {}

    async def tick(self, hour: float):
        """Reload, tell the world if the school opened or closed, and tick every class."""
        self.reload()
        if self.closed != self._closed_sent:
            self._closed_sent = self.closed
            for d in self.days.values():
                await self.mind.send_world({"type": "school_cmd", "school": d.place, "cmd": "closed" if self.closed else "open"})
        for d in list(self.days.values()):
            await d.tick(hour)

    def on_world_reset(self):
        """Every class re-opens its period on the next tick."""
        for d in self.days.values():
            d.on_world_reset()
