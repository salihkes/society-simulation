"""The memory pipeline, on a real-shaped raw stream, with no model and no network.

These are the tests whose absence let the harvest quietly do nothing for the
whole life of the world. Every one of them fails against the code as it was:

  * a day of household life with nobody speaking produced no memory at all,
    because the gate looked for the word "said" and the renderer dropped
    every record that was not speech;
  * the harvest mark was set from the end of the FILE while the window held
    only its last few hundred records, so a resident who fell behind had the
    backlog marked remembered without it ever being read;
  * the window ran backwards, so a backlog was never caught up.
"""
import json
import sys
import os
import tempfile
import time
import unittest
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))

from mind.memory.consolidate import Consolidator, render_log, is_ambient, _line   # noqa: E402
from mind.memory.store import MemoryStore                                  # noqa: E402
from mind.store import WorldStore                                          # noqa: E402
from mind.lesson import Lesson                                            # noqa: E402


def snapshot(hour, *names):
    """What the world reports every few seconds: where they are, who is near."""
    return {"at": [], "with": list(names), "hour": hour}


RELATION_DEFAULT = json.dumps({"description": "a note",
                               "content": "We get on well enough."})


def household_day(hour=18.0):
    """An evening at home: no speech, no restaurant. The day the old harvest
    threw away."""
    return [
        snapshot(hour, "r_dad"),
        snapshot(hour, "r_dad"),
        {"life_decision": {"do": "use", "object": "boho_stove"}, "hour": hour,
         "reason": "I want to cook before the others get hungry"},
        {"did": "use", "object": "boho_stove", "restores": {"hunger": 1.0}, "hour": hour},
        snapshot(hour + 0.1, "r_dad", "r_kid"),
        {"did": "carry", "household": "family", "object": "groceries", "hour": hour + 0.2},
        {"life_outcome": {"status": "failed", "reason": "no walking route to the lift"},
         "hour": hour + 0.3},
        {"did": "rest", "hour": hour + 0.4},
        {"did": "sleep", "hour": hour + 4.0},
    ]


def school_day():
    return [
        {"assembly": "morning", "anthem": True, "hour": 8.2},
        {"did": "attend", "hour": 8.5},
        {"lesson_heard": "光合成は葉緑体で起こる", "hour": 8.7},
        {"asked_in_class": "夜はどうなりますか", "hour": 8.8},
        {"roll_call": "r_student_13", "absent": True, "hour": 8.9},
        {"did": "yard_break", "hour": 10.0},
    ]


class StubLLM:
    """A model that answers each step of the sleep, so the pipeline can be
    tested without one. Consolidation asks three different questions and a
    stub that answers them all the same way silently breaks the later two."""
    RELATION = json.dumps({"description": "a note", "content": "We get on well enough."})
    REFLECT = json.dumps({"insights": []})

    def __init__(self, reply="", relation=None, reflect=None):
        self.reply = reply
        self.relation = RELATION_DEFAULT if relation is None else relation
        self.reflect = reflect if reflect is not None else StubLLM.REFLECT
        self.prompts = []

    async def chat(self, system, messages, max_tokens=220, **kw):
        prompt = messages[0]["content"]
        self.prompts.append(prompt)
        if "notes about people they know" in prompt:
            return self.relation
        if "reflection step" in prompt:
            return self.reflect
        return self.reply

    async def rerank(self, query, documents):
        return None


class RenderTest(unittest.TestCase):
    def test_perception_snapshots_are_ambient(self):
        self.assertTrue(is_ambient(snapshot(13.0, "r_neighbour")))
        self.assertTrue(is_ambient({"at": [], "with": [], "hour": 13.0}))
        self.assertFalse(is_ambient({"did": "eat", "place": "Diner", "hour": 13.0}))
        self.assertFalse(is_ambient({"life_decision": {"do": "rest"}, "hour": 13.0}))

    def test_a_household_evening_is_salient_without_anyone_speaking(self):
        lines, salient = render_log(household_day())
        self.assertGreaterEqual(salient, 3, f"nothing salient found in:\n" + "\n".join(lines))
        joined = "\n".join(lines)
        self.assertIn("boho_stove", joined)          # the reason for acting survives
        self.assertIn("did not work out", joined)    # and so does the failure
        self.assertIn("I slept", joined)

    def test_the_reason_a_resident_gave_is_kept(self):
        lines, _ = render_log(household_day())
        self.assertTrue(any("my unverified reason was: I want to cook" in l for l in lines),
                        "private reasons must remain beliefs rather than physical evidence")

    def test_seeking_a_meal_is_not_remembered_as_having_eaten(self):
        lines, _ = render_log([{"did": "eat", "place": "Diner", "hour": 13.0},
                               {"did": "left_hungry", "place": "Diner", "hour": 13.1}])
        self.assertFalse(any("I ate" in line for line in lines))
        self.assertTrue(any("sought a meal" in line for line in lines))
        lines, _ = render_log([{"did": "ate", "place": "Diner", "hour": 13.2}])
        self.assertTrue(any("I ate" in line for line in lines))

    def test_overhearing_is_not_being_spoken_to(self):
        """A priest told the philosophy teacher that hunger tires the heart.
        A passer-by wrote it down as "r_priest_orth told me" — because every
        heard line reached the model as speech directed at the listener."""
        addressed = {"heard": "r_priest_orth", "text": "お元気ですか", "addressed": True, "hour": 8.5}
        overheard = {"heard": "r_priest_orth", "text": "お元気ですか", "hour": 8.5}
        self.assertIn("said to me", _line(addressed))
        self.assertIn("I overheard", _line(overheard))
        self.assertNotIn("said to me", _line(overheard))

    def test_school_is_legible(self):
        lines, salient = render_log(school_day())
        joined = "\n".join(lines)
        self.assertIn("assembly", joined)
        self.assertIn("I put my hand up in class", joined, "what the pupil did is the day")
        self.assertIn("r_student_13 was absent", joined)
        self.assertGreaterEqual(salient, 4)

    def test_what_a_lesson_leaves_behind_is_the_pupil_s_own_part_in_it(self):
        """The record written when the lesson ends: that they sat through it,
        what they asked, and what they made of it — in their words."""
        rec = {"did": "class_over", "lesson": "kimya-11", "subject": "kimya",
               "teacher": "r_teacher_chem", "place": "School", "beats": 40,
               "i_asked": ["エンタルピー変化がマイナスなのは、なぜ発熱反応なんですか？"],
               "my_note": "活性化エネルギーの逆反応で迷った。もう一度整理する。", "hour": 9.2}
        lines, salient = render_log([rec])
        line = lines[0]
        self.assertIn("I sat through kimya", line)
        self.assertIn("and asked", line)
        self.assertIn("what I made of it", line)
        self.assertEqual(salient, 1)

    def test_the_teacher_remembers_having_taught(self):
        lines, _ = render_log([{"did": "taught", "lesson": "kimya-11", "subject": "kimya",
                                "pupils": 18, "questions": 2, "hour": 9.2}])
        self.assertIn("I taught kimya to 18 pupils", lines[0])
        self.assertIn("2 question", lines[0])

    def test_leaving_a_room_is_not_evidence_of_hearing_a_lesson(self):
        lines, _ = render_log([{"did": "class_over", "place": "School/12C"}])
        self.assertIn("I left the classroom", lines[0])
        self.assertNotIn("sat through", lines[0])

    def test_absent_student_does_not_remember_attending(self):
        records = []
        lesson = Lesson.__new__(Lesson)
        lesson.brain = types.SimpleNamespace(life=types.SimpleNamespace(
            managed=lambda who: True, state=lambda who: {"learning": {"math": "My note"}}))
        lesson.mind = types.SimpleNamespace(store=types.SimpleNamespace(observe=lambda who, rec: records.append((who, rec))))
        lesson.students = ["present", "absent"]
        lesson.heard_by = {"present": 2}
        lesson.asked_by_pupil = []
        lesson.id, lesson.subject, lesson.teacher, lesson.school = "math", "math", "teacher", "School"
        lesson.beats, lesson.pos, lesson.start_at = [1, 2, 3, 4], 3, 0
        lesson._remember_the_lesson()
        self.assertEqual([who for who, rec in records], ["present", "teacher"])
        self.assertIn("I heard part of math", render_log([records[0][1]])[0][0])
        self.assertEqual(records[-1][1]["pupils"], 1)
        records.clear()
        lesson.pos = 0
        lesson.heard_by = {}
        lesson._remember_the_lesson()
        self.assertEqual(records, [])

    def test_a_lesson_is_heard_but_not_carried_out_of_the_room(self):
        """Nobody remembers a lecture verbatim. One student's pending records
        were 22,111 characters of chemistry out of 25,563, which filled the
        harvest prompt to its cap and evicted the rest of their day. The words
        are live context; what the lesson leaves behind is written when it
        ends (mind/lesson.py: _remember_the_lesson)."""
        beat = {"lesson_heard": "光合成は葉緑体で起こる", "lesson": "bio-10", "beat": 3, "hour": 8.7}
        self.assertTrue(is_ambient(beat))
        lines, _ = render_log(school_day())
        self.assertNotIn("光合成", "\n".join(lines))

    def test_company_collapses_instead_of_drowning_the_day(self):
        recs = [snapshot(13.0, "r_neighbour") for _ in range(300)]
        recs += [{"did": "eat", "place": "Diner", "hour": 13.0}]
        lines, salient = render_log(recs)
        self.assertLessEqual(len(lines), 4, f"300 snapshots became {len(lines)} lines")
        self.assertEqual(salient, 1)

    def test_a_repeated_decision_is_one_decision(self):
        d = {"life_decision": {"do": "go", "place": "Diner"}, "reason": "hungry", "hour": 13.0}
        lines, salient = render_log([dict(d) for _ in range(20)])
        self.assertEqual(salient, 1, f"got {salient}: {lines}")


class HarvestTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = MemoryStore(self.tmp.name)
        self.addCleanup(self.store.close)
        self.who = "r_test"

    def write_stream(self, recs, t0=1000.0):
        path = Path(self.tmp.name) / f"{self.who}.jsonl"
        with open(path, "a", encoding="utf-8") as f:
            for i, r in enumerate(recs):
                f.write(json.dumps(dict(r, ts=t0 + i), ensure_ascii=False) + "\n")
        return t0 + len(recs) - 1

    async def test_a_silent_household_day_still_produces_a_memory(self):
        """The regression that mattered: 398 of 400 runs harvested nothing."""
        self.write_stream(household_day())
        llm = StubLLM(json.dumps({"facts": [{
            "name": "cooked-for-the-family", "type": "episode",
            "description": "I cooked before the others got hungry",
            "content": "I used the stove to cook before the others got hungry.",
            "anchors": ["resident:r_dad"], "links": []}], "confirms": []}))
        c = Consolidator(self.store, llm, None, lambda w: "Lily", lambda w: "a mother")
        report = await c.run(self.who, today="2026-09-22", tier="bg")
        self.assertEqual(report.get("error"), None, report.get("error"))
        self.assertEqual(report["harvested"], 1, report)
        self.assertTrue(self.store.read(self.who, "cooked-for-the-family"))

    async def test_the_mark_never_passes_a_record_that_was_not_read(self):
        """It used to be set from the end of the file, so a backlog beyond the
        window was marked remembered without being looked at."""
        end = self.write_stream(household_day() * 800)      # 7,200 — larger than one window
        llm = StubLLM(json.dumps({"facts": [], "confirms": []}))
        c = Consolidator(self.store, llm, None)
        c.tier = "bg"
        await c._harvest(self.who, "2026-09-22", {})
        mark = self.store.harvested_ts(self.who)
        self.assertGreater(mark, 0.0, "the mark did not move at all")
        self.assertLess(mark, end, "the mark jumped past records nobody read")

    async def test_a_model_that_answers_nothing_does_not_lose_the_window(self):
        """A failed call must leave the mark where it was: the alternative is
        forgetting a day because a machine was busy."""
        self.write_stream(household_day())
        c = Consolidator(self.store, StubLLM(""), None)
        c.tier = "bg"
        await c._harvest(self.who, "2026-09-22", {})
        self.assertEqual(self.store.harvested_ts(self.who), 0.0,
                         "the window was given up on after one bad answer")

    async def test_a_backlog_is_walked_forward_until_it_is_caught_up(self):
        end = self.write_stream(household_day() * 1200)     # 10,800 records
        llm = StubLLM(json.dumps({"facts": [], "confirms": []}))
        c = Consolidator(self.store, llm, None)
        c.tier = "bg"
        marks = []
        for _ in range(6):
            await c._harvest(self.who, "2026-09-22", {})
            marks.append(self.store.harvested_ts(self.who))
        self.assertEqual(marks, sorted(marks), "the mark went backwards")
        self.assertEqual(marks[-1], end, f"never caught up: {marks[-1]} of {end}")

    async def test_a_window_of_pure_walking_about_spends_no_model_call(self):
        self.write_stream([snapshot(13.0, "r_neighbour") for _ in range(500)])
        llm = StubLLM("should not be called")
        c = Consolidator(self.store, llm, None)
        c.tier = "bg"
        report = {}
        await c._harvest(self.who, "2026-09-22", report)
        self.assertEqual(llm.prompts, [], "a day of standing about is not worth a call")
        self.assertGreater(self.store.harvested_ts(self.who), 0.0)

    async def test_a_relationship_note_needs_more_than_standing_nearby(self):
        """A resident got five notes about five people that all told the same
        story about a tram, because every fact was anchored to whoever was
        standing around when it happened. Anchors find a memory; `about`
        says who it concerns, and only that earns a relationship note."""
        self.write_stream(household_day())
        llm = StubLLM(json.dumps({"facts": [{
            "name": "the-lift-again", "type": "episode",
            "description": "the lift was broken",
            "content": "The lift was out again and I had to carry the shopping up.",
            "anchors": ["resident:r_uncle", "resident:r_neighbour", "place:Lift"],
            "about": [], "links": []}], "confirms": []}))
        c = Consolidator(self.store, llm, None, lambda w: "Lily", lambda w: "")
        report = await c.run(self.who, today="2026-09-22", tier="bg")
        self.assertEqual(report["harvested"], 1)
        self.assertEqual(report["relations"], 0,
                         "a memory about a lift wrote notes about the bystanders")
        self.assertIsNone(self.store.read(self.who, "relationship-r_uncle"))

    async def test_someone_a_memory_is_about_does_get_a_note(self):
        self.write_stream(household_day())
        llm = StubLLM(json.dumps({"facts": [{
            "name": "marshall-helped", "type": "episode",
            "description": "Marshall carried the shopping with me",
            "content": "Marshall met me at the door and carried the shopping in.",
            "anchors": ["resident:r_dad"],
            "about": ["resident:r_dad"], "links": []}], "confirms": []}))
        c = Consolidator(self.store, llm, None, lambda w: "Lily", lambda w: "")
        await c.run(self.who, today="2026-09-22", tier="bg")
        self.assertTrue(self.store.read(self.who, "relationship-r_dad"))

    async def test_the_prompt_asks_for_english(self):
        self.write_stream(household_day())
        llm = StubLLM(json.dumps({"facts": [], "confirms": []}))
        c = Consolidator(self.store, llm, None)
        c.tier = "bg"
        await c._harvest(self.who, "2026-09-22", {})
        self.assertTrue(llm.prompts, "the model was never asked")
        self.assertIn("ENGLISH", llm.prompts[0])
        self.assertNotIn("Write in Japanese", llm.prompts[0])


class IngestionSplitTest(unittest.TestCase):
    """Perception and events are two streams. They used to be one, and the
    durable record was 96% 'standing near somebody'."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.world = WorldStore(self.tmp.name)
        self.mem = MemoryStore(os.path.join(self.tmp.name, "memory"))
        self.addCleanup(self.mem.close)
        self.world.memory = self.mem

    def durable(self, who):
        p = Path(self.tmp.name) / "memory" / (who + ".jsonl")
        return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []

    def test_perception_never_reaches_the_durable_stream(self):
        for _ in range(200):
            self.world.observe("r_a", snapshot(13.0, "r_b"))
        self.assertEqual(self.durable("r_a"), [],
                         "perception snapshots must not flood durable memory")

    def test_what_happened_does_reach_it(self):
        for rec in household_day():
            self.world.observe("r_a", rec)
        kept = self.durable("r_a")
        self.assertTrue(kept)
        self.assertFalse(any(is_ambient(r) for r in kept))
        self.assertTrue(any("life_decision" in r for r in kept))
        self.assertTrue(any(r.get("did") == "sleep" for r in kept))

    def test_a_resident_now_remembers_the_conversation_they_are_in(self):
        """`_exchange()` reads the last 40 records to continue a conversation.
        With perception in the same file it found none — measured: 8 of 74
        residents had any speech in their last 40 — so every reply greeted
        the player as a stranger."""
        for i in range(300):
            self.world.observe("r_a", snapshot(13.0, "r_b"))
            if i % 100 == 0:
                self.world.observe("r_a", {"heard": "player:guest1", "text": "こんにちは",
                                           "addressed": True, "hour": 13.0})
        last40 = self.world.recent("r_a", 40)
        speech = [r for r in last40 if "heard" in r or "said" in r]
        self.assertTrue(speech, "the conversation is still invisible to _exchange()")

    def test_meetings_are_counted_without_rereading_the_stream(self):
        # Twelve reports of standing together, seconds apart, are one meeting:
        # the world reports who is near every few seconds, and counting each
        # report made two classmates' shared morning "32 meetings".
        for _ in range(12):
            self.world.observe("r_a", snapshot(13.0, "r_b", "r_c"))
        self.world.observe("r_a", {"saw": "r_d", "hour": 13.0, "at": ["square"]})
        self.assertEqual(self.mem.meetings("r_a", "r_b"), 1)
        self.assertEqual(self.mem.meetings("r_a", "r_c"), 1)
        self.assertEqual(self.mem.meetings("r_a", "r_d"), 1)
        self.assertEqual(self.mem.meetings("r_a", "r_zzz"), 0)
        # Apart for longer than MEET_APART, then together again: a second meeting.
        from mind.memory.store import MEET_APART
        self.mem.db().execute("UPDATE meetings SET last_ts = last_ts - ? WHERE who='r_a' AND other='r_b'",
                              (MEET_APART + 60,))
        self.world.observe("r_a", snapshot(15.0, "r_b"))
        self.assertEqual(self.mem.meetings("r_a", "r_b"), 2)
        self.assertEqual(self.mem.meetings("r_a", "r_c"), 1)

    def test_an_unknown_record_shape_is_kept_not_dropped(self):
        self.world.observe("r_a", {"some_new_system": "value", "hour": 13.0})
        self.assertEqual(len(self.durable("r_a")), 1,
                         "a shape the classifier does not know must default to durable")


if __name__ == "__main__":
    unittest.main()
