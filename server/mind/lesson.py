"""A lesson: a recorded lecture the teacher performs beat by beat, with questions answered, deferred or refused live."""
import asyncio
import base64
import json
import os
import random
import re
import time
import wave

from core import identity

# Field holding a beat's written board text in the lesson data.
WRITTEN_FIELD = identity.get("lesson_written_field")
SPEECH = identity.get("speech_language")
SPEECH_RULES = identity.get("speech_rules")

DECIDE_PROMPT = """You are {NAME}, teaching a lesson. You are at beat {NOW} of {TOTAL}: "{NOW_TAG}".
A student, {STUDENT}, just asked: {QUESTION}

Beats of the lesson that may contain the answer (number, when, tag, text):
{CANDIDATES}

Decide, and reply ONLY JSON:
- if a beat AHEAD answers it: {{"action": "defer", "beat": <n>, "text": "<one or two friendly sentences in {SPEECH}: you will get there soon, hold the thought>"}}
- if a beat already covered or covers it: {{"action": "answer", "beat": <n>, "text": "<the answer in 1-3 sentences of spoken {SPEECH}, from that beat>"}}
- if today's lesson does not cover it: {{"action": "not_in_lesson", "text": "<honest, warm, one or two sentences in {SPEECH}; offer after class>"}}
Speak {SPEECH}, no names of languages. {SPEECH_RULES}"""

CALLBACK_PROMPT = """You are {NAME}, teaching. The lesson has reached the point that answers what {STUDENT} \
asked earlier: "{QUESTION}". You are about to explain beat {BEAT}: "{BEAT_TEXT}"
Say ONE or two sentences in {SPEECH} that call {STUDENT} by name, remind them of their question, \
and lead into the explanation. Reply ONLY JSON: {{"text": "..."}}"""


def _wav_seconds(path: str) -> float:
    """Length of a WAV file in seconds; 0.0 when unreadable."""
    try:
        with wave.open(path) as w:
            return w.getnframes() / float(w.getframerate())
    except Exception:
        return 0.0


def _b64_seconds(audio: str) -> float:
    """Length of base64 16-bit mono 24 kHz WAV audio (44-byte header) in seconds."""
    return (len(base64.b64decode(audio)) - 44) / (2 * 24000.0)


def _pupil_seconds(ja: str, audio: str) -> float:
    """How long a pupil's line lasts: the audio's length (at least 1.5 s), else an estimate."""
    dur = 2.5 + len(ja) * 0.14
    if audio:
        try:
            dur = max(1.5, _b64_seconds(audio))
        except Exception:
            pass
    return dur


def _grams(text: str) -> set:
    """ASCII words and CJK character 2-grams of text."""
    t = re.sub(r"\s+", "", text or "")
    out = set(re.findall(r"[A-Za-z0-9]+", text or ""))
    out |= {t[i:i + 2] for i in range(len(t) - 1) if re.search(r"[ぁ-ヿ㐀-鿿]", t[i:i + 2])}
    return out


class Lesson:
    def __init__(self, mind, brain, lesson_dir: str, teacher_key: str, gap: float = 0.9,
                 school: str = "School", students=None, start_at: int = 0):
        self.mind = mind
        self.brain = brain
        self.school = school
        self.students = list(students or [])
        self.subject = ""                 # set by the school day that runs it
        self.asked_by_pupil = []          # [{"who", "text"}], for the record at the end
        self.heard_by = {}                # managed pupils who physically heard this playback
        self.dir = lesson_dir
        self.id = os.path.basename(lesson_dir.rstrip("/"))
        self.teacher = teacher_key
        self.gap = gap
        with open(os.path.join(lesson_dir, "beats.json"), encoding="utf-8") as f:
            self.beats = json.load(f)
        with open(os.path.join(lesson_dir, "beats.ja.json"), encoding="utf-8") as f:
            self.ja = json.load(f)
        self.beats = [b for b in self.beats if b["id"] in self.ja]
        self.pos = max(0, min(int(start_at), len(self.beats)))   # NEXT beat to speak
        self.start_at = self.pos
        self.deferred: list = []          # {"beat": n, "student": name, "question": q}
        self.pending: list = []           # questions waiting for the beat to end
        self.task = None
        self.running = False
        self.started = 0.0
        self.ready = asyncio.Event()      # the teacher holds the lectern
        self.paused = asyncio.Event()     # set = speaking; cleared = break
        self.paused.set()
        self.seat_pupils = True           # False: the school day seats them
        self.hands: list = []             # players who raised a hand (usernames)
        # Authored pupil questions (questions.json): asked at ask_at, answered by the next beat.
        self.pool: list = []
        try:
            with open(os.path.join(lesson_dir, "questions.json"), encoding="utf-8") as f:
                self.pool = list((json.load(f) or {}).get("questions", []))
        except Exception:
            self.pool = []
        self.asked_pool: set = set()
        self.question_chance = 0.45
        self.cold_call_chance = 0.5       # with players seated: the teacher asks them instead

    def start(self):
        """Start playback unless it is running; returns the task."""
        if self.task is None or self.task.done():
            self.running = True
            self.started = time.time()
            self.task = asyncio.create_task(self._run())
        return self.task

    def stop(self):
        self.running = False
        if self.task and not self.task.done():
            self.task.cancel()

    def pause(self):
        """Hold the lesson before the next beat (a break)."""
        self.paused.clear()

    def resume(self):
        self.paused.set()

    def status(self) -> dict:
        return {"lesson": self.id, "teacher": self.teacher, "beat": self.pos, "total": len(self.beats),
                "running": self.running, "deferred": len(self.deferred), "pending": len(self.pending)}

    async def _say(self, ja: str, written: str = "", clip: str = "", secs: float = None):
        """The teacher says one line (clip if given, else TTS); returns its duration."""
        text = written or await self.brain._render(self.teacher, ja)
        audio = ""
        if clip and os.path.exists(clip):
            with open(clip, "rb") as f:
                audio = base64.b64encode(f.read()).decode("ascii")
            dur = _wav_seconds(clip)
        else:
            audio = await self.brain.tts.synth(self.brain._voice_for(self.teacher), ja)
            dur = secs or (2.5 + len(ja) * 0.14)
            if audio:
                try:
                    dur = max(dur * 0.5, _b64_seconds(audio))
                except Exception:
                    pass
        await self.mind.say(self.teacher, text, audio)
        return dur

    async def _run(self):
        """Seat the class, play every beat with its questions, then dismiss."""
        try:
            print(f"[Lesson] {self.id} starts, {len(self.beats)} beats, teacher {self.teacher}")
            await self._assemble()
            while self.running and self.pos < len(self.beats):
                await self.paused.wait()
                await self._play_beat()
            if self.pos >= len(self.beats):
                print(f"[Lesson] {self.id} finished")
                dur = await self._say(self.mind.lines.get("lesson_end"))
                await asyncio.sleep(dur + 1.0)
        except asyncio.CancelledError:
            pass
        finally:
            self.running = False
            try:
                self._remember_the_lesson()
            except Exception as e:
                print(f"[Lesson] {self.id}: could not write the lesson down: {e}")
            try:
                await self.mind.push_intents(self.teacher, [{"do": "dismiss", "place": self.school}])
            except Exception:
                pass

    async def _assemble(self):
        """Send the teacher to the lectern and (if ours) pupils to desks; wait up to 120 s for the teacher, then 3 s."""
        await self.mind.push_intents(self.teacher, [{"do": "teach", "place": self.school}])
        if self.seat_pupils:
            for s in self.students:
                await self.mind.push_intents(s, [{"do": "attend", "place": self.school}])
        try:
            await asyncio.wait_for(self.ready.wait(), timeout=120.0)
        except asyncio.TimeoutError:
            print(f"[Lesson] teacher never reached the lectern; starting anyway")
        await asyncio.sleep(3.0)

    async def _play_beat(self):
        """Keep promises due at this beat, say it, then take hands and questions."""
        for d in [d for d in self.deferred if d["beat"] == self.pos + 1]:
            self.deferred.remove(d)
            await self._callback(d)
        b = self.beats[self.pos]
        e = self.ja[b["id"]]
        clip = os.path.join(self.dir, "clips", b["id"] + ".wav")
        dur = await self._say(e["ja"], e.get(WRITTEN_FIELD, ""), clip)
        self.pos += 1
        self.brain.life.lesson_heard(self, e["ja"])
        await asyncio.sleep(dur + self.gap)
        while self.hands:
            await self._hand(self.hands.pop(0))
        while self.pending:
            q = self.pending.pop(0)
            await self._handle(q)
        await self._pupil_question()

    def _remember_the_lesson(self):
        """Write one class_over record per pupil who heard it (their own part only) and one for the teacher."""
        life = self.brain.life
        asked = {}
        for q in self.asked_by_pupil:
            asked.setdefault(q["who"], []).append(q["text"])
        for who in self.students:
            heard = self.heard_by.get(who, 0) if life.managed(who) else self.pos - self.start_at
            if not heard:
                continue
            note = (life.state(who).get("learning") or {}).get(self.id, "") if life.managed(who) else ""
            rec = {"did": "class_over", "lesson": self.id, "subject": self.subject,
                   "teacher": self.teacher, "place": self.school, "beats": len(self.beats), "heard_beats": heard}
            mine = asked.get(who) or []
            if mine:
                rec["i_asked"] = mine[:3]
            if note:
                rec["my_note"] = note[:700]
            self.mind.store.observe(who, rec)
        if self.pos == self.start_at:
            return
        attendees = [s for s in self.students if not life.managed(s) or self.heard_by.get(s)]
        self.mind.store.observe(self.teacher, {
            "did": "taught", "lesson": self.id, "subject": self.subject,
            "place": self.school, "beats": len(self.beats),
            "questions": sum(len(v) for v in asked.values()), "pupils": len(attendees)})

    def on_question(self, student: str, text: str):
        """Queue a question for after the current beat."""
        self.pending.append({"student": student, "question": text, "t": time.time()})

    async def ask_as(self, student_key: str, ja: str) -> str:
        """A pupil says a given question (mindctl ask), queued like any other; returns the written text."""
        name = self.brain._display_name(student_key)
        text = await self.brain._render(student_key, ja)
        audio = await self.brain.tts.synth(self.brain._voice_for(student_key), ja)
        dur = _pupil_seconds(ja, audio)
        print(f"[Lesson] {name} asks (manual): {ja}")
        await self.mind.say(student_key, text, audio)
        self.mind.store.remember(student_key, {"lesson": self.id, "asked_in_class": ja, "beat": self.pos})
        self.asked_by_pupil.append({"who": student_key, "text": ja})
        await asyncio.sleep(min(dur, 12.0) + 0.3)
        self.pending.append({"student": name, "question": ja, "t": time.time()})
        return text

    def on_hand(self, student: str):
        """Queue a raised hand for after the current beat."""
        if student not in self.hands:
            self.hands.append(student)

    async def _hand(self, student: str):
        """Give a raised hand the floor and wait up to 25 s for its question."""
        print(f"[Lesson] {student} raised a hand")
        await self.mind.say_line(self.teacher, "hand_yes", 2.5)
        deadline = time.time() + 25.0
        while time.time() < deadline:
            for q in self.pending:
                if q["student"] == student:
                    return           # answered by the pending pass after this
            await asyncio.sleep(0.5)
        await self.mind.say_line(self.teacher, "hand_go_on", 2.0)
        await asyncio.sleep(2.2)

    async def _cold_call(self, ja: str, seated: list):
        """Put a pool question to seated players, wait up to 22 s for a typed answer and thank any answer."""
        print(f"[Lesson] cold call to {', '.join(seated)}: {ja}")
        cache = os.path.join(self.dir, "clips_q")
        os.makedirs(cache, exist_ok=True)
        cpath = os.path.join(cache, f"t_{self.pos:04d}.wav")
        clip = cpath if os.path.exists(cpath) else ""
        dur = await self._say(ja, "", clip)
        if not clip:
            await self._cache_teacher_clip(ja, cpath)
        await asyncio.sleep(dur + 0.3)
        await self.mind.say_line(self.teacher, "ask_class", 2.5)
        deadline = time.time() + 22.0
        answered = None
        while time.time() < deadline and answered is None:
            for q in list(self.pending):
                if q["student"] in seated:
                    answered = q
                    self.pending.remove(q)
                    break
            await asyncio.sleep(0.5)
        if answered is not None:
            print(f"[Lesson] {answered['student']} answered: {answered['question']}")
            self.mind.store.remember(self.teacher, {"lesson": self.id, "asked_class": ja,
                                                     "answered_by": answered["student"], "answer": answered["question"]})
            await self.mind.say_line(self.teacher, "thanks", 1.8)
            await asyncio.sleep(2.0)
        else:
            self.mind.store.remember(self.teacher, {"lesson": self.id, "asked_class": ja, "answered_by": None})
        await self.mind.say_line(self.teacher, "q_bridge", 3.0)
        await asyncio.sleep(3.2)

    async def _cache_teacher_clip(self, ja: str, cpath: str):
        """Synthesize the teacher saying ja and save it to cpath; failures are ignored."""
        try:
            audio = await self.brain.tts.synth(self.brain._voice_for(self.teacher), ja)
            if audio:
                with open(cpath, "wb") as f:
                    f.write(base64.b64decode(audio))
        except Exception:
            pass

    async def _pupil_question(self):
        """Have a pool question due at this beat asked by a pupil (or put to seated players)."""
        due = [q for q in self.pool if int(q.get("ask_at", 0)) == self.pos and id(q) not in self.asked_pool]
        if not due or not self.students:
            return
        q = due[0]
        self.asked_pool.add(id(q))
        ja = str(q.get("q", "")).strip()
        if not ja:
            return
        seated = sorted(u for u, room in getattr(self.brain, "seated_players", {}).items() if room in ("", self.school))
        if seated and random.random() < self.cold_call_chance:
            await self._cold_call(ja, seated)
            return
        if random.random() > self.question_chance:
            return
        candidates = [s for s in self.students if not self.brain.life.managed(s)]
        if not candidates:
            return
        student = random.choice(candidates)
        text = await self.brain._render(student, ja)
        audio = await self._pupil_audio(student, ja)
        dur = _pupil_seconds(ja, audio)
        print(f"[Lesson] {student} asks (pool): {ja}")
        await self.mind.say(student, text, audio)
        self.mind.store.remember(student, {"lesson": self.id, "asked_in_class": ja, "beat": self.pos})
        self.asked_by_pupil.append({"who": student, "text": ja})
        self.mind.store.remember(self.teacher, {"lesson": self.id, "asked": student, "question": ja, "action": "next_beat"})
        await asyncio.sleep(dur + 0.6)
        await self.mind.say_line(self.teacher, "q_bridge", 3.0)
        await asyncio.sleep(3.2)

    async def _pupil_audio(self, student: str, ja: str) -> str:
        """A pupil's voiced pool question, cached in clips_q/ per beat and voice."""
        cache = os.path.join(self.dir, "clips_q")
        os.makedirs(cache, exist_ok=True)
        voice = self.brain._voice_for(student)
        cpath = os.path.join(cache, f"{self.pos:04d}_{voice}.wav")
        if os.path.exists(cpath):
            with open(cpath, "rb") as f:
                return base64.b64encode(f.read()).decode("ascii")
        audio = await self.brain.tts.synth(voice, ja)
        if audio:
            try:
                with open(cpath, "wb") as f:
                    f.write(base64.b64decode(audio))
            except Exception:
                pass
        return audio

    def _candidates(self, question: str, k: int = 6) -> list:
        """Indices of the k beats most like the question, plus the current beat and neighbours."""
        q = _grams(question)
        scored = []
        for i, b in enumerate(self.beats):
            e = self.ja[b["id"]]
            g = _grams(e["ja"] + " " + e.get("tag", "") + " " + b.get("tr", ""))
            s = len(q & g)
            if s:
                scored.append((s, i))
        scored.sort(reverse=True)
        idx = [i for _, i in scored[:k]]
        for i in (self.pos - 1, self.pos, self.pos + 1):
            if 0 <= i < len(self.beats) and i not in idx:
                idx.append(i)
        return sorted(idx)

    async def _handle(self, q: dict):
        """Ask the model how to handle a question, then answer or defer it."""
        student, question = q["student"], q["question"]
        now = max(self.pos - 1, 0)
        cands = self._candidates(question)
        lines = []
        for i in cands:
            when = "past" if i < now else ("now" if i == now else "ahead")
            e = self.ja[self.beats[i]["id"]]
            lines.append(f"{i + 1}. ({when}) [{e.get('tag', '')}] {e['ja'][:200]}")
        raw = await self.brain.llm.chat(
            "You are a teacher deciding how to handle a question. Reply with JSON only.",
            [{"role": "user", "content": DECIDE_PROMPT.format(
                NAME=self.brain._display_name(self.teacher), NOW=now + 1, TOTAL=len(self.beats),
                NOW_TAG=self.ja[self.beats[now]["id"]].get("tag", ""), STUDENT=student,
                QUESTION=question, CANDIDATES="\n".join(lines),
                SPEECH=SPEECH, SPEECH_RULES=SPEECH_RULES)}])
        m = re.search(r"\{.*\}", raw or "", re.S)
        try:
            d = json.loads(m.group(0)) if m else {}
        except Exception:
            d = {}
        action = str(d.get("action", "not_in_lesson"))
        text = str(d.get("text", "")).strip() or self.mind.lines.get("lesson_later")
        beat = int(d.get("beat", 0) or 0)
        # An answer more than one beat ahead is always deferred, to keep the lesson's order.
        if action == "answer" and beat > self.pos + 1:
            action = "defer"
            text = self.mind.lines.get("lesson_defer", student=student)
        if action == "defer" and beat > self.pos:
            self.deferred.append({"beat": beat, "student": student, "question": question})
        elif action == "defer":
            action = "answer"
        print(f"[Lesson] {student} asked: {question} → {action}" + (f" (beat {beat})" if beat else "") + f": {text}")
        self.mind.store.remember(self.teacher, {"lesson": self.id, "asked": student, "question": question,
                                                 "action": action, "beat": beat, "said": text})
        dur = await self._say(text)
        await asyncio.sleep(dur + self.gap)

    async def _callback(self, d: dict):
        """Call a deferred student back at the beat that answers them."""
        b = self.beats[d["beat"] - 1]
        raw = await self.brain.llm.chat(
            "You are a teacher keeping a promise to a student. Reply with JSON only.",
            [{"role": "user", "content": CALLBACK_PROMPT.format(
                NAME=self.brain._display_name(self.teacher), STUDENT=d["student"], QUESTION=d["question"],
                BEAT=d["beat"], BEAT_TEXT=self.ja[b["id"]]["ja"][:200], SPEECH=SPEECH)}])
        m = re.search(r"\{.*\}", raw or "", re.S)
        try:
            text = str(json.loads(m.group(0)).get("text", "")).strip() if m else ""
        except Exception:
            text = ""
        text = text or self.mind.lines.get("lesson_callback", student=d["student"])
        print(f"[Lesson] callback for {d['student']} at beat {d['beat']}: {text}")
        self.mind.store.remember(self.teacher, {"lesson": self.id, "called": d["student"], "beat": d["beat"], "said": text})
        dur = await self._say(text)
        await asyncio.sleep(dur + self.gap)
