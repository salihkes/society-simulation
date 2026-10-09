"""Households on the mind's side: the store, the needs, the life verbs, the
day at home. No model service, city process, or real resident data."""
import asyncio
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import AsyncMock

ROOT = Path(__file__).parents[1]

spec = importlib.util.spec_from_file_location("life_under_test", ROOT / "mind/life.py")
life_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(life_module)
ResidentLife = life_module.ResidentLife

spec = importlib.util.spec_from_file_location("home_under_test", ROOT / "mind/home.py")
home = importlib.util.module_from_spec(spec)
spec.loader.exec_module(home)
spec = importlib.util.spec_from_file_location("store_under_test", ROOT / "mind/store.py")
store_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store_module)
WorldStore = store_module.WorldStore


HOUSEHOLD = {
    "house": "TheHome", "door": "FrontDoor", "name": "the flat",
    "members": {"alice": "child", "mum": "parent"},
    "rooms": {"Living": "shared", "AliceRoom": "alice", "Hall": "threshold"},
    "meals": [{"name": "breakfast", "hour": 7.3, "cook": "mum"}],
}


class StoreTest(unittest.TestCase):
    def test_households_load_and_travel_with_the_residents(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "households.json").write_text(json.dumps({"flat": HOUSEHOLD}), encoding="utf-8")
            (Path(tmp) / "residents.json").write_text(json.dumps({"alice": {"student": True}}), encoding="utf-8")
            store = WorldStore(tmp)
            self.assertEqual(store.households["flat"]["door"], "FrontDoor")
            self.assertEqual(store.residents_message()["households"]["flat"]["members"]["mum"], "parent")
            self.assertEqual(store.household_of("r_alice")[0], "flat")
            self.assertEqual(store.household_of("nobody"), (None, None))
            (Path(tmp) / "households.json").write_text("{}", encoding="utf-8")
            self.assertTrue(store.reload_households())
            self.assertEqual(store.households, {})


class NeedsTest(unittest.TestCase):
    def test_a_use_restores_what_it_names_and_nothing_else(self):
        needs = {"hunger": 0.9, "hygiene": 0.8, "fun": 0.5, "eat_block_until": -1.0}
        life_state = {"fatigue": 0.7}
        home.apply_restores(needs, life_state, {"hygiene": 1.0, "energy": 0.5, "fun": "0.2", "nonsense": 1, "hunger": "x"})
        self.assertEqual(needs["hygiene"], 0.0)
        self.assertAlmostEqual(needs["fun"], 0.3)
        self.assertEqual(needs["hunger"], 0.9)
        self.assertAlmostEqual(life_state["fatigue"], 0.2)
        self.assertNotIn("nonsense", needs)
        self.assertEqual(needs["eat_block_until"], -1.0)

    def test_every_need_has_hours_to_decay_over(self):
        for k, hrs in home.NEED_HOURS.items():
            self.assertGreater(hrs, 0.0, k)

    def test_a_person_has_only_the_needs_something_answers(self):
        self.assertEqual(home.answerable_needs(True, False), {"hunger", *home.NEED_HOURS})
        self.assertEqual(home.answerable_needs(False, True), {"hunger"})
        self.assertEqual(home.answerable_needs(False, False), set())


class HomeIntentsTest(unittest.TestCase):
    def test_a_day_at_home_goes_to_their_own_room_by_the_door(self):
        intents = home.home_intents({"routine": []}, HOUSEHOLD, "r_alice", "ill in bed", True)
        self.assertEqual(intents, [{"at": 0.0, "do": "sleep", "marker": "AliceRoom", "name": "ill in bed",
                                    "door": "FrontDoor", "use": "sleep"}])
        shared = home.home_intents({}, HOUSEHOLD, "r_mum", "school closed today", False)
        self.assertEqual(shared[0]["marker"], "Living")
        self.assertEqual(shared[0]["do"], "stay")

    def test_without_a_household_the_routine_names_home(self):
        resident = {"routine": [{"hour": 8, "pos": [1, 2, 3]}, {"hour": 22, "marker": "BedRoom", "door": "FrontDoor"}]}
        intents = home.home_intents(resident, None, "r_bob", "ill in bed", True)
        self.assertEqual((intents[0]["marker"], intents[0]["door"]), ("BedRoom", "FrontDoor"))
        self.assertEqual(home.home_intents({"routine": [{"hour": 8, "pos": [1, 2, 3]}]}, None, "r_bob", "x", True), [])


class LifeVerbsTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        resident = {"id": "alice", "student": True, "friends": ["bob"]}
        store = types.SimpleNamespace(residents={"alice": resident}, places={"park": {"kind": "district"}},
                                      remember=lambda who, event: None)
        clock = types.SimpleNamespace(day=lambda: 100, hour=lambda: 9.0)
        self.mind = types.SimpleNamespace(data_dir=self.tmp.name, clock=clock, store=store, send_world=AsyncMock())
        self.brain = types.SimpleNamespace(mind=self.mind, needs={"r_alice": {"hunger": .4, "fun": .9, "eat_block_until": -1.0}},
            health={"r_alice": {"ill": True}}, lesson=None,
            _resident=lambda key: resident if key == "r_alice" else {},
            _places_for=lambda r, places: places, _persona=lambda k: "A curious student",
            _display_name=lambda k: k, _model_for=lambda k: "", _render=AsyncMock(side_effect=lambda k, text: text),
            _voice_for=lambda k: "alice", tts=types.SimpleNamespace(synth=AsyncMock(return_value="")),
            memory=types.SimpleNamespace(context=AsyncMock(return_value="")),
            school=types.SimpleNamespace(cfg={"school": "School"}, status=lambda h: {}, place_of=lambda k: "School",
                                         status_for=lambda k, h: {}, lesson_of=lambda k: None, day_of_lesson=lambda l: None),
            llm=types.SimpleNamespace(available=True, chat=AsyncMock()),
            _spawn=lambda coro: asyncio.create_task(coro))
        self.life = ResidentLife(self.brain)
        self.view = {"school": "", "phase": "city", "seated": False, "nearby": {},
                     "available": ["continue", "use", "welcome", "visit"], "manual": False,
                     "home": "flat", "at_home": True, "house": "flat",
                     "objects": {"boho_bed#sleep": {"use": "sleep", "label": "sleep", "restores": {"energy": 1}, "free": 1}},
                     "knocking": ["r_bob"], "households": {"household:other": "the other flat"}}
        self.life.observe("r_alice", {"life_view": self.view})

    def test_home_verbs_are_checked_against_what_the_world_offers(self):
        view = self.life.situation("r_alice")
        self.assertEqual(view["needs"], {"hunger": .4, "fun": .9})
        self.assertTrue(view["ill"])
        ok = self.life.validate("r_alice", {"action": {"do": "use", "object": "boho_bed#sleep", "seconds": 120}}, view)
        self.assertEqual(ok, {"do": "use", "seconds": 120, "object": "boho_bed#sleep"})
        ok = self.life.validate("r_alice", {"action": {"do": "visit", "household": "household:other", "seconds": 90}}, view)
        self.assertEqual(ok["household"], "household:other")
        ok = self.life.validate("r_alice", {"action": {"do": "welcome", "target": "r_bob", "seconds": 10}}, view)
        self.assertEqual(ok["target"], "r_bob")
        for bad in ({"do": "use", "object": "boho_bed2#sleep"}, {"do": "visit", "household": "household:mine"},
                    {"do": "welcome", "target": "r_carol"}):
            with self.assertRaises(ValueError):
                self.life.validate("r_alice", {"action": dict(bad, seconds=30)}, view)

    def test_a_knock_or_a_worry_wakes_the_person(self):
        self.life.observe("r_alice", {"knock": "r_bob", "household": "flat"})
        self.assertIn("r_alice", self.life.wake_requested)
        self.assertTrue(any(e.get("knock") == "r_bob" for e in self.life.state("r_alice")["events"]))
        self.life.wake_requested.clear()
        self.life.observe("r_alice", {"missed_meal": ["r_bob"], "meal": "dinner"})
        self.assertNotIn("r_alice", self.life.wake_requested)
        self.assertTrue(any(e.get("missed_meal") for e in self.life.state("r_alice")["events"]))


if __name__ == "__main__":
    unittest.main()
