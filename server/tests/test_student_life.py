"""No model service, city process, or real resident data is touched."""
import asyncio
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import types
import unittest
from unittest.mock import AsyncMock

spec = importlib.util.spec_from_file_location("student_life_under_test", Path(__file__).parents[1] / "mind/life.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
StudentLife = module.StudentLife


class LifeTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.records = []
        self.tasks = []
        resident = {"id": "alice", "student": True, "friends": ["bob"]}
        store = types.SimpleNamespace(residents={"alice": resident}, places={"park": {"kind": "district"}, "cafe": {"kind": "restaurant"}},
            remember=lambda who, event: self.records.append((who, event)),
            # the real store splits perception from events; the stub keeps both
            observe=lambda who, event: self.records.append((who, event)))
        clock = types.SimpleNamespace(day=lambda: 100, hour=lambda: 9.0)
        self.mind = types.SimpleNamespace(data_dir=self.tmp.name, clock=clock, store=store, send_world=AsyncMock())
        self.brain = types.SimpleNamespace(mind=self.mind, needs={"r_alice": {"hunger": .4}}, lesson=None,
            _resident=lambda key: resident if key in ("r_alice", "r_bob") else {},
            _places_for=lambda r, places: places, _persona=lambda k: "A curious student",
            _display_name=lambda k: k, _model_for=lambda k: "", _render=AsyncMock(side_effect=lambda k, text: text),
            _voice_for=lambda k: "alice", tts=types.SimpleNamespace(synth=AsyncMock(return_value="")),
            memory=types.SimpleNamespace(context=AsyncMock(return_value="A friend helped yesterday.")),
            school=types.SimpleNamespace(cfg={"school": "School"}, status=lambda h: {"period": 1},
                                         place_of=lambda k: "School", status_for=lambda k, h: {"period": 1},
                                         lesson_of=lambda k: self.brain.lesson, day_of_lesson=lambda l: None),
            llm=types.SimpleNamespace(available=True, chat=AsyncMock()),
            _spawn=lambda coro: self.tasks.append(asyncio.create_task(coro)))
        self.life = StudentLife(self.brain)
        self.view = {"school": "School", "phase": "class", "seated": True,
            "nearby": {"r_bob": "Bob"}, "available": ["continue", "say", "approach", "study", "go", "eat"], "manual": False}
        self.life.observe("r_alice", {"life_view": self.view})

    async def asyncTearDown(self):
        for task in self.tasks:
            if not task.done():
                task.cancel()
        if self.tasks:
            await asyncio.gather(*self.tasks, return_exceptions=True)

    def decision(self, verb="study", **extra):
        return {"action": {"do": verb, "seconds": 30, **extra}, "goal": "Understand the lesson", "reason": "Yesterday was confusing"}

    async def test_observation_decision_action_result_persisted(self):
        self.brain.llm.chat.return_value = json.dumps(self.decision())
        await self.life.decide("r_alice")
        msg = self.mind.send_world.call_args.args[0]
        self.assertEqual(msg["action"]["do"], "study")
        self.assertIsNotNone(self.life.state("r_alice")["pending"])
        self.life.observe("r_alice", {"life_result": {"id": msg["action_id"], "status": "completed", "reason": "studied"}})
        restored = StudentLife(self.brain)
        self.assertIsNone(restored.state("r_alice")["pending"])
        self.assertEqual(restored.state("r_alice")["goal"], "Understand the lesson")
        self.assertEqual(restored.state("r_alice")["hunger"], .4)
        self.assertTrue(any("life_outcome" in e for _, e in self.records))

    async def test_invalid_actions_do_not_cross_boundary(self):
        view = self.life.situation("r_alice")
        for action in [self.decision("fly"), self.decision("say", target="r_missing", text="hello"),
                       self.decision("go", place="private_bedroom"), self.decision("eat", place="park"),
                       {"action": {"do": "study", "seconds": float("nan")}}]:
            with self.assertRaises(ValueError):
                self.life.validate("r_alice", action, view)
        self.mind.send_world.assert_not_called()

    async def test_director_invalidates_inflight_decision(self):
        started, proceed = asyncio.Event(), asyncio.Event()
        async def slow(*args, **kwargs):
            started.set()
            await proceed.wait()
            return json.dumps(self.decision())
        self.brain.llm.chat.side_effect = slow
        task = asyncio.create_task(self.life.decide("r_alice"))
        await started.wait()
        await self.life.command({"op": "pause", "id": "alice"})
        proceed.set()
        await task
        self.assertEqual(self.life.state("r_alice")["mode"], "manual")
        self.assertFalse(any(c.args[0]["cmd"] == "life" for c in self.mind.send_world.call_args_list))

    async def test_manual_order_and_release(self):
        await self.life.command({"op": "order", "id": "alice", "action": {"do": "study", "seconds": 90}})
        self.assertTrue(self.mind.send_world.call_args.args[0]["director"])
        await self.life.command({"op": "resume", "id": "alice"})
        self.assertEqual(self.life.state("r_alice")["mode"], "auto")
        self.assertIsNone(self.life.state("r_alice")["pending"])
        self.assertTrue(any(c.args[0]["cmd"] == "life_cancel" for c in self.mind.send_world.call_args_list))

    async def test_failure_is_input_to_next_decision(self):
        await self.life.execute("r_alice", {"do": "approach", "target": "r_bob", "seconds": 30})
        ident = self.life.state("r_alice")["pending"]["id"]
        self.life.observe("r_alice", {"life_result": {"id": ident, "status": "failed", "reason": "person moved away"}})
        self.brain.llm.chat.return_value = json.dumps(self.decision("continue"))
        await self.life.decide("r_alice")
        payload = json.loads(self.brain.llm.chat.call_args.args[1][0]["content"])
        self.assertEqual(payload["private_life"]["last_result"]["reason"], "person moved away")

    async def test_restart_does_not_replay_a_spoken_line(self):
        await self.life.execute("r_alice", {"do": "say", "target": "r_bob", "text": "こんにちは", "seconds": 20})
        restored = StudentLife(self.brain)
        self.assertIsNone(restored.state("r_alice")["pending"])
        self.assertEqual(restored.state("r_alice")["last_result"]["status"], "interrupted")
        with self.assertRaises(ValueError):
            restored.situation("r_alice")

    async def test_memory_is_only_from_physical_class_attendance(self):
        lesson = types.SimpleNamespace(id="math", school="School", pos=3, heard_by={}, running=True, paused=types.SimpleNamespace(is_set=lambda: True))
        self.brain.lesson = lesson
        self.life.lesson_heard(lesson, "A triangle has three sides")
        self.assertEqual(len(self.records), 1)
        self.life.views["r_alice"] = (time.monotonic(), dict(self.view, seated=False))
        self.life.lesson_heard(lesson, "A new explanation")
        self.assertEqual(len(self.records), 1)
        self.assertEqual(lesson.heard_by, {"r_alice": 1})
        self.life.views["r_alice"] = (time.monotonic(), self.view)
        self.brain.llm.chat.return_value = json.dumps(dict(self.decision(), learning={"lesson": "math", "note": "I should ask about triangles"}))
        await self.life.decide("r_alice")
        self.assertIn("triangles", self.life.state("r_alice")["learning"]["math"])

    async def test_learning_cannot_overwrite_an_old_or_different_lesson(self):
        lesson = types.SimpleNamespace(id="theatre", school="School", pos=3, heard_by={}, running=True, paused=types.SimpleNamespace(is_set=lambda: True))
        self.brain.lesson = lesson
        self.life.lesson_heard(lesson, "A dialogue has two speakers")
        self.brain.llm.chat.return_value = json.dumps(dict(self.decision(), learning={"lesson": "chemistry", "note": "Activation energy"}))
        await self.life.decide("r_alice")
        self.assertEqual(self.life.state("r_alice")["learning"], {})
        lesson.running = False
        self.brain.llm.chat.return_value = json.dumps(dict(self.decision(), learning={"lesson": "theatre", "note": "Activation energy"}))
        await self.life.decide("r_alice")
        self.assertEqual(self.life.state("r_alice")["learning"], {})

    async def test_meal_waits_for_the_restaurant_result(self):
        await self.life.execute("r_alice", {"do": "eat", "place": "cafe", "seconds": 10})
        pending = self.life.state("r_alice")["pending"]
        self.assertIsNone(pending["deadline"])
        await self.life.tick()
        self.assertEqual(self.life.state("r_alice")["pending"]["id"], pending["id"])
        self.life.observe("r_alice", {"life_result": {"id": pending["id"], "status": "completed", "reason": "ate"}})
        self.assertIsNone(self.life.state("r_alice")["pending"])

    async def test_teacher_only_receives_successful_question(self):
        self.brain.lesson = types.SimpleNamespace(running=True, paused=types.SimpleNamespace(is_set=lambda: True), on_question=lambda *a: self.records.append(a))
        await self.life.execute("r_alice", {"do": "ask", "text": "どうして？", "seconds": 20})
        ident = self.life.state("r_alice")["pending"]["id"]
        self.life.observe("r_alice", {"life_result": {"id": "stale", "status": "completed"}})
        self.assertEqual(len(self.records), 0)
        self.life.observe("r_alice", {"life_result": {"id": ident, "status": "completed"}})
        self.assertIn(("r_alice", "どうして？"), self.records)
        before = len(self.records)
        self.life.observe("r_alice", {"life_result": {"id": ident, "status": "completed"}})
        self.assertEqual(len(self.records), before)

    async def test_no_world_or_model_does_not_spawn_decisions(self):
        self.life.views["r_alice"] = (time.monotonic() - 30, self.view)
        await self.life.tick()
        self.assertEqual(self.tasks, [])
        self.life.observe("r_alice", {"life_view": self.view})
        self.brain.llm.available = False
        await self.life.tick()
        self.assertEqual(self.tasks, [])

    async def test_world_reset_invalidates_perception_and_pending(self):
        await self.life.execute("r_alice", {"do": "study", "seconds": 30})
        self.life.on_reset()
        self.assertEqual(self.life.views, {})
        self.assertIsNone(self.life.state("r_alice")["pending"])

    async def test_stale_world_action_is_not_sent_after_speech_generation(self):
        started, proceed = asyncio.Event(), asyncio.Event()
        async def slow(*args):
            started.set()
            await proceed.wait()
            return ""
        self.brain.tts.synth.side_effect = slow
        task = asyncio.create_task(self.life.execute("r_alice", {"do": "say", "target": "r_bob", "text": "hello", "seconds": 30}))
        await started.wait()
        await self.life.command({"op": "pause", "id": "alice"})
        proceed.set()
        await task
        self.assertFalse(any(c.args[0]["cmd"] == "life" for c in self.mind.send_world.call_args_list))

    async def test_invitation_requires_the_other_person_to_accept(self):
        self.mind.store.residents["bob"] = {"student": True}
        self.life.observe("r_bob", {"life_view": dict(self.view, nearby={"r_alice": "Alice"})})
        action = {"do": "invite", "target": "r_bob", "place": "park", "at": 16.0,
                  "day": 100, "text": "放課後、公園で会いませんか。", "seconds": 20}
        await self.life.execute("r_alice", action)
        ident = self.life.state("r_alice")["pending"]["id"]
        self.life.observe("r_alice", {"life_result": {"id": ident, "status": "completed"}})
        self.assertEqual(self.life.state("r_alice")["commitments"], [])
        self.assertIn(ident, self.life.state("r_bob")["invitations"])
        response = self.life.validate("r_bob", {"action": {"do": "accept", "invitation": ident,
            "target": "r_alice", "text": "はい、会いましょう。"}}, self.life.situation("r_bob"))
        await self.life.execute("r_bob", response)
        reply_id = self.life.state("r_bob")["pending"]["id"]
        self.life.observe("r_bob", {"life_result": {"id": reply_id, "status": "completed"}})
        self.assertEqual(len(self.life.state("r_alice")["commitments"]), 1)
        self.assertEqual(self.life.state("r_alice")["commitments"], self.life.state("r_bob")["commitments"])

    async def test_declining_does_not_create_shared_plan(self):
        self.mind.store.residents["bob"] = {}
        self.life.state("r_alice")["invitations"]["offer"] = {
            "id": "offer", "from": "r_bob", "to": "r_alice", "place": "park",
            "day": 100, "at": 16.0, "status": "offered"}
        action = self.life.validate("r_alice", {"action": {"do": "decline", "invitation": "offer",
            "target": "r_bob", "text": "今日は難しいです。"}}, self.life.situation("r_alice"))
        self.life.social_result("r_alice", {"action": action})
        self.assertEqual(self.life.state("r_alice")["commitments"], [])
        self.assertEqual(self.life.state("r_alice")["invitations"]["offer"]["status"], "declined")

    async def test_residents_without_redundant_id_field_have_agency(self):
        self.brain._resident = lambda key: {"student": True} if key == "r_alice" else {}
        self.assertTrue(self.life.managed("r_alice"))
        self.assertFalse(self.life.managed("r_missing"))
        self.brain._resident = lambda key: {}  # adults without student flag too
        self.assertTrue(self.life.managed("r_alice"))

    async def test_private_routine_coordinates_are_named_not_model_generated(self):
        self.brain._resident = lambda key: {"routine": [{"name": "home", "pos": [1, 2, 3]}]}
        view = self.life.situation("r_alice")
        action = self.life.validate("r_alice", self.decision("go", place="routine:0"), view)
        await self.life.execute("r_alice", action)
        self.assertEqual(self.mind.send_world.call_args.args[0]["destination"], [1, 2, 3])

    async def test_model_can_repair_malformed_decision(self):
        self.brain.llm.chat.side_effect = ['{"action": broken}', json.dumps(self.decision())]
        await self.life.decide("r_alice")
        self.assertEqual(self.brain.llm.chat.call_count, 2)
        self.assertEqual(self.life.state("r_alice")["pending"]["action"]["do"], "study")
        self.assertIn('could not be used', self.brain.llm.chat.call_args.args[1][-1]['content'])

    async def test_duplicate_decisions_are_not_accepted_as_one(self):
        with self.assertRaises(ValueError):
            module.parse_decision('{"action":{"do":"study"}} {"action":{"do":"go"}}')
        self.assertEqual(module.parse_decision('{"action":{"do":"study"}}\n<end_of_turn>')["action"]["do"], "study")

    async def test_needs_follow_observed_activity_only_while_world_is_present(self):
        self.brain.llm.available = False
        await self.life.tick()
        self.mind.clock.hour = lambda: 10.0
        await self.life.tick()
        tired = self.life.state("r_alice")["fatigue"]
        self.assertGreater(tired, .2)
        self.life.observe("r_alice", {"life_view": dict(self.view, activity="sleep")})
        self.mind.clock.hour = lambda: 11.0
        await self.life.tick()
        rested = self.life.state("r_alice")["fatigue"]
        self.assertLess(rested, tired)
        self.life.views["r_alice"] = (0, self.view)
        self.mind.clock.hour = lambda: 12.0
        await self.life.tick()
        self.assertEqual(self.life.state("r_alice")["fatigue"], rested)

    async def test_corrupt_save_not_overwritten(self):
        Path(self.life.path).write_text("broken json")
        with self.assertRaises(ValueError):
            StudentLife(self.brain)
        self.assertEqual(Path(self.life.path).read_text(), "broken json")

if __name__ == "__main__":
    unittest.main()
