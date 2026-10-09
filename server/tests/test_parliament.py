"""Staging a sitting: which houses are sent for, who sits where. No model
service, city process, council or real resident data is touched."""
import asyncio
import importlib.util
from pathlib import Path
import types
import unittest
from unittest.mock import AsyncMock

spec = importlib.util.spec_from_file_location("parliament_under_test", Path(__file__).parents[1] / "mind/parliament.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
Sitting = module.Sitting
spec = importlib.util.spec_from_file_location("lines_under_test", Path(__file__).parents[1] / "mind/lines.py")
lines = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lines)


def _mind(places):
    store = types.SimpleNamespace(residents={"a": {"key": "r_a"}, "b": {"key": "r_b"}, "s": {"key": "r_s"}},
                                  places=places)
    return types.SimpleNamespace(store=store, push_intents=AsyncMock(), send_all=AsyncMock(), data_dir="/tmp",
                                 lines=lines.Lines(str(Path(__file__).parent)))


ROSTER = [{"id": "s", "resident": "s"}, {"id": "a", "resident": "a"}, {"id": "b", "resident": "b"}]


class SeatingTest(unittest.IsolatedAsyncioTestCase):
    def test_council_sits_beside_server(self):
        here = Path(__file__).parents[1]          # server
        council = here.parent / "council"
        self.assertEqual(module._council_dir(str(here / "mind")), str(council))
        if not council.is_dir():
            self.skipTest("no council project beside the server")
        self.assertTrue((council / module.identity.get("council_package") / "bridge.py").exists())

    def test_only_built_houses_sit_in_the_world(self):
        # The world reported a chamber with a lower house only.
        st = Sitting(_mind({"parliament": {"kind": "parliament", "seats": {"representatives": 85}}}), None, "水道")
        self.assertTrue(st._sits_in_world("representatives"))
        self.assertFalse(st._sits_in_world("councillors"))
        # No world has reported yet: every house is sent for, as before.
        st = Sitting(_mind({}), None, "水道")
        self.assertTrue(st._sits_in_world("councillors"))
        # A report without a parliament at all is the same as none.
        st = Sitting(_mind({"School": {"kind": "school"}}), None, "水道")
        self.assertTrue(st._sits_in_world("representatives"))

    async def test_the_speaker_takes_the_speakers_chair(self):
        mind = _mind({"parliament": {"seats": {"representatives": 85}}})
        st = Sitting(mind, None, "水道", speaker_key="r_s")
        await st._seat("representatives", ROSTER)
        places = {c.args[0]: c.args[1][1]["place"] for c in mind.push_intents.call_args_list}
        self.assertEqual(places["r_s"], "parliament.speaker")
        # Members are numbered without the Speaker, so chairs match the world's count.
        self.assertEqual(places["r_a"], "parliament.representatives.0")
        self.assertEqual(places["r_b"], "parliament.representatives.1")
        for c in mind.push_intents.call_args_list:
            self.assertEqual(c.args[1][0], {"do": "go", "place": "parliament.door"})
            self.assertTrue(c.kwargs.get("replace"))
        op = mind.send_all.call_args.args[0]
        self.assertEqual(op, {"type": "par", "op": "seat", "house": "representatives",
                              "members": ["r_s", "r_a", "r_b"], "speaker": "r_s"})
        self.assertEqual(st.seated, {"representatives": ["r_s", "r_a", "r_b"]})

    async def test_a_speaker_from_the_other_house_still_takes_the_chair(self):
        mind = _mind({"parliament": {"seats": {"representatives": 85}}})
        st = Sitting(mind, None, "水道", speaker_key="r_s")
        await st._seat("representatives", ROSTER[1:])      # r_s is not a representative
        await st._seat_presiding()
        self.assertEqual(mind.push_intents.call_args.args[0], "r_s")
        self.assertEqual(mind.push_intents.call_args.args[1][1]["place"], "parliament.speaker")
        self.assertEqual(mind.send_all.call_args.args[0]["house"], "speaker")
        self.assertEqual(st.seated["speaker"], ["r_s"])
        # ...and not twice when they already sit with their house.
        mind.push_intents.reset_mock()
        st2 = Sitting(mind, None, "水道", speaker_key="r_s")
        await st2._seat("representatives", ROSTER)
        mind.push_intents.reset_mock()
        await st2._seat_presiding()
        mind.push_intents.assert_not_called()

    async def test_without_a_speaker_every_member_gets_a_chair(self):
        mind = _mind({})
        st = Sitting(mind, None, "水道")
        await st._seat("representatives", ROSTER)
        places = [c.args[1][1]["place"] for c in mind.push_intents.call_args_list]
        self.assertEqual(places, ["parliament.representatives.0", "parliament.representatives.1",
                                  "parliament.representatives.2"])


class PlenaryTest(unittest.IsolatedAsyncioTestCase):
    """The order of business, with the decision already made off stage."""
    def _sitting(self, speaker="r_s"):
        mind = _mind({"parliament": {"seats": {"representatives": 85}}})
        st = Sitting(mind, None, "水道", speaker_key=speaker)
        st.seated = {"representatives": ["r_a", "r_b", "r_c", "r_d"], "speaker": ["r_s"]} if speaker else {"representatives": ["r_a", "r_b", "r_c", "r_d"]}
        st.result = {"verdict": "Passed", "record": "/x/diet_records/r.md", "houses": {
            "representatives": [
                {"name": "A", "id": "a", "vote": "Approve", "reason": "yes because"},
                {"name": "B", "id": "b", "vote": "Reject", "reason": "no because"},
                {"name": "C", "id": "c", "vote": "Approve", "reason": "also yes"},
                {"name": "D", "id": "d", "vote": "Abstain", "reason": "no answer returned"}],
            "councillors": [{"name": "X", "id": "x", "vote": "Reject", "reason": "paper only"}]}}
        st.mind.store.residents.update({"c": {"key": "r_c"}, "d": {"key": "r_d"}, "x": {"key": "r_x"}})
        self.said = []
        async def say(key, text):
            self.said.append((key, text)); return 0.0
        st._say = say
        async def line(key, brief, max_tokens=120):
            return f"{key} speaks"
        st._line = line
        return st

    async def test_order_of_business(self):
        st = self._sitting()
        await st._plenary()
        ops = [c.args[0]["op"] for c in st.mind.send_all.call_args_list]
        # open → debate (rostrum/sit per speaker) → rise → sit → result → adjourn
        self.assertEqual(ops[0], "open")
        self.assertEqual(ops[-2:], ["result", "adjourn"])
        debate = ops[1:ops.index("rise")]
        self.assertEqual(debate, ["rostrum", "sit"] * (len(debate) // 2))
        self.assertGreater(len(debate), 0)
        rise = next(c.args[0] for c in st.mind.send_all.call_args_list if c.args[0]["op"] == "rise")
        self.assertEqual(sorted(rise["members"]), ["r_a", "r_c"])   # those in favour; the abstainer does not rise
        # The chair's set phrases, verbatim, in the chair's voice.
        chair = [t for k, t in self.said if k == "r_s"]
        self.assertEqual(chair[0], "The sitting is open.")
        self.assertIn("The first item on the agenda: 水道.", chair)
        self.assertIn("The majority has risen. The motion is carried.", chair)
        self.assertEqual(chair[-1], "The sitting is adjourned.")
        # The debaters spoke from the rostrum; the abstainer and the paper house did not.
        spoke = [k for k, t in self.said if k != "r_s"]
        self.assertTrue(set(spoke) <= {"r_a", "r_b", "r_c"})
        self.assertIn("r_b", spoke)   # against is always called first when there is one
        self.assertEqual(spoke[0], "r_b")
        # Everyone seated is sent home.
        homes = [c.args[0] for c in st.mind.push_intents.call_args_list]
        self.assertEqual(sorted(homes), ["r_a", "r_b", "r_c", "r_d", "r_s"])

    async def test_other_house_reverses_and_a_vacant_chair_is_silent(self):
        st = self._sitting(speaker="")
        st.result["verdict"] = "Rejected"      # the councillors, on paper, said no
        await st._plenary()
        self.assertEqual(self.said, [c for c in self.said if c[0] != ""])
        self.assertFalse(any(k == "" for k, t in self.said))
        ops = [c.args[0]["op"] for c in st.mind.send_all.call_args_list]
        self.assertEqual(ops[-2:], ["result", "adjourn"])
        result = next(c.args[0] for c in st.mind.send_all.call_args_list if c.args[0]["op"] == "result")
        self.assertEqual(result["verdict"], "Rejected")

    def test_debaters_alternate_against_then_for(self):
        st = self._sitting()
        votes = st._votes_here()
        order = st._debaters(votes)
        self.assertEqual([v["vote"] for v in order], ["Reject", "Approve", "Approve"][:len(order)])
        self.assertTrue(all(v["reason"] != "no answer returned" for v in order))

    def test_member_cap_is_carried(self):
        st = Sitting(_mind({}), None, "水道", members=6)
        self.assertEqual(st.members, 6)


if __name__ == "__main__":
    unittest.main()
