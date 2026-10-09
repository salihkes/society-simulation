"""Several classes, several rooms: bells, seats, roll call and the day's
state stay per class. Real Mind/Brain wiring, temporary files, no model."""
import asyncio
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

AVAILABLE = all(importlib.util.find_spec(n) for n in ('aiohttp', 'frontmatter'))

PERIOD = {"start": 8.5, "end": 9.25, "subject": "kimya", "lesson": "", "teacher": "r_t1"}
SCHOOL = {"school": "School", "teacher": "r_t1", "days": [0, 1, 2, 3, 4, 5, 6],
          "periods": {"mon": [PERIOD]}, "lessons": [], "rites": False, "roll_call": True,
          "absent_chance": 0, "late_chance": 0, "skip_chance": 0,
          "classes": {"A": {"place": "School"},
                      "B": {"place": "School/B", "periods": {"mon": [dict(PERIOD, subject="fizik", teacher="r_t2")]}}}}
RESIDENTS = [{"id": "t1", "teacher": True, "life": False}, {"id": "t2", "teacher": True, "life": False},
             {"id": "s1", "student": True, "class": "A", "life": False, "name": "ハル"},
             {"id": "s2", "student": True, "class": "B", "life": False, "name": "ミオ"},
             {"id": "s3", "student": True, "life": False, "name": "レン"}]     # no class: the first


@unittest.skipUnless(AVAILABLE, 'run with the server venv for application integration checks')
class SchoolClasses(unittest.IsolatedAsyncioTestCase):
    async def test_two_rooms_run_their_own_period(self):
        sys.path.insert(0, str(Path(__file__).parents[1]))
        from mind import Mind
        real_sleep = asyncio.sleep
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / 'cards').mkdir()
            (Path(root) / 'clock.json').write_text('{"mode":"fixed","hour":8.6,"weekday":"mon"}')
            (Path(root) / 'school.json').write_text(json.dumps(SCHOOL))
            outbound = []
            async def send(msg): outbound.append(msg)
            m = Mind(root, send, send)
            try:
                await m.on_world_report({'workspace': 'test', 'places': [], 'residents': RESIDENTS})
                school = m.brain.school
                self.assertEqual(list(school.days), ['A', 'B'])
                self.assertEqual(school.day_of('r_s2').name, 'B')
                self.assertEqual(school.day_of('r_s3').name, 'A', 'a pupil without a class sits in the first')
                self.assertIsNone(school.day_of('r_parent'), 'unrelated adults do not inherit the first class')
                self.assertEqual(school.status_for('r_parent', 8.6), {})
                self.assertEqual(school.place_of('r_parent'), '')
                self.assertFalse(school.in_class('r_parent'))
                self.assertEqual(sorted(school.day('A').pupils()), ['r_s1', 'r_s3'])
                self.assertEqual(school.day('B').pupils(), ['r_s2'])
                with patch('mind.school.asyncio.sleep', lambda s: real_sleep(0.01)):
                    await school.tick(8.6)
                    for _ in range(60):               # the after-bell tasks (roll call) run on their own
                        await real_sleep(0.02)
                    self.assertTrue(all(d.in_period for d in school.days.values()))
                    self.assertEqual(school.place_of('r_t2'), 'School/B', "a teacher's room is the one they teach in")
                    self.assertEqual(school.place_of('r_t1'), 'School')
                    cmds = {(x['school'], x['cmd']) for x in outbound if x['type'] == 'school_cmd'}
                    self.assertTrue({('School', 'bell'), ('School/B', 'bell'), ('School', 'class'), ('School/B', 'class')} <= cmds, cmds)
                    plans = {(x['id'], i['do'], i['place']) for x in outbound if x['type'] == 'res_plan' for i in x['intents']}
                    self.assertIn(('r_s1', 'attend', 'School'), plans)
                    self.assertIn(('r_s3', 'attend', 'School'), plans)
                    self.assertIn(('r_s2', 'attend', 'School/B'), plans)
                    self.assertNotIn(('r_s2', 'attend', 'School'), plans)
                    self.assertIn(('r_t1', 'teach', 'School'), plans)
                    self.assertIn(('r_t2', 'teach', 'School/B'), plans)
                    says = {(x['id'], x['line']) for x in outbound if x['type'] == 'npc_say'}
                    self.assertIn(('r_t1', 'name_s1'), says)
                    self.assertIn(('r_t2', 'name_s2'), says)
                    self.assertNotIn(('r_t1', 'name_s2'), says, 'a teacher reads only their own class')
                    self.assertNotIn(('r_t2', 'name_s1'), says)
                    # The bell at the end: each room dismisses its own.
                    outbound.clear()
                    await school.tick(9.3)
                    for _ in range(20):
                        await real_sleep(0.02)
                    plans = {(x['id'], i['do'], i['place']) for x in outbound if x['type'] == 'res_plan' for i in x['intents']}
                    self.assertIn(('r_s2', 'dismiss', 'School/B'), plans)
                    self.assertIn(('r_s1', 'dismiss', 'School'), plans)
                    self.assertFalse(any(d.in_period for d in school.days.values()))
                # State files stay apart.
                self.assertTrue((Path(root) / 'school_state.json').exists())
                self.assertTrue((Path(root) / 'school_state_B.json').exists())
                status = school.status(8.6)
                self.assertEqual(set(status), {'A', 'B'})
                self.assertEqual(status['B']['place'], 'School/B')
            finally:
                for d in school.days.values():
                    for t in d._late_tasks:
                        t.cancel()

    async def test_reopened_period_reads_the_roll_once(self):
        """The world reconnecting re-opens the period; the first opening's
        roll call and lesson start must not run on under the second."""
        sys.path.insert(0, str(Path(__file__).parents[1]))
        from mind import Mind
        real_sleep = asyncio.sleep
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / 'cards').mkdir()
            (Path(root) / 'clock.json').write_text('{"mode":"fixed","hour":8.6,"weekday":"mon"}')
            (Path(root) / 'school.json').write_text(json.dumps(SCHOOL))
            outbound = []
            async def send(msg): outbound.append(msg)
            m = Mind(root, send, send)
            school = m.brain.school
            try:
                await m.on_world_report({'workspace': 'test', 'places': [], 'residents': RESIDENTS})
                with patch('mind.school.asyncio.sleep', lambda s: real_sleep(0.01)):
                    await school.tick(8.6)
                    school.on_world_reset()           # the world came back fresh
                    await school.tick(8.6)            # the period opens again
                    for _ in range(80):
                        await real_sleep(0.02)
                    names = [x for x in outbound if x['type'] == 'npc_say' and x['id'] == 'r_t1' and x['line'] == 'name_s1']
                    self.assertEqual(len(names), 1, 'one roll call per opening that survives')
                    starts = [x for x in outbound if x['type'] == 'npc_say' and x['line'] == 'rc_start']
                    self.assertEqual(len(starts), 2, 'one per class, once')
            finally:
                for d in school.days.values():
                    for t in d._late_tasks:
                        t.cancel()

    async def test_monday_gathers_then_assembles_every_class(self):
        """Monday: at 'gather' every class sends its pupils to the yard; at
        'at' every class starts its ceremony — the first class too."""
        sys.path.insert(0, str(Path(__file__).parents[1]))
        from mind import Mind
        real_sleep = asyncio.sleep
        cfg = dict(SCHOOL, assembly={"morning": {"day": 0, "at": 8.2, "gather": 7.9}})
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / 'cards').mkdir()
            (Path(root) / 'clock.json').write_text('{"mode":"fixed","hour":7.8,"weekday":"mon"}')
            (Path(root) / 'school.json').write_text(json.dumps(cfg))
            outbound = []
            async def send(msg): outbound.append(msg)
            m = Mind(root, send, send)
            school = m.brain.school
            try:
                await m.on_world_report({'workspace': 'test', 'places': [], 'residents': RESIDENTS})
                with patch('mind.school.asyncio.sleep', lambda s: real_sleep(0.01)):
                    for h in (7.8, 7.85, 7.95, 8.05, 8.15, 8.25):
                        await school.tick(h)
                        for _ in range(10):
                            await real_sleep(0.02)
                    cmds = [(x['school'], x['cmd']) for x in outbound if x['type'] == 'school_cmd']
                    self.assertEqual(cmds.count(('School', 'gather')), 1)
                    self.assertEqual(cmds.count(('School/B', 'gather')), 1)
                    self.assertEqual(cmds.count(('School', 'assembly_am')), 1, cmds)
                    self.assertEqual(cmds.count(('School/B', 'assembly_am')), 1, cmds)
                    plans = {(x['id'], i['do'], i['place']) for x in outbound if x['type'] == 'res_plan' for i in x['intents']}
                    self.assertIn(('r_s2', 'attend', 'School/B'), plans)
                    self.assertIn(('r_t2', 'teach', 'School/B'), plans)
            finally:
                for d in school.days.values():
                    for t in d._late_tasks:
                        t.cancel()

    def test_timetable_has_no_teacher_in_two_rooms(self):
        tool = Path(__file__).parents[2] / 'tools' / 'art' / 'school'
        timetable = Path(__file__).parents[1] / 'data' / 'world' / 'school.json'
        if not (tool / 'make_timetable.py').exists() or not timetable.exists():
            self.skipTest("no world timetable or its tool")
        sys.path.insert(0, str(tool))
        import make_timetable
        with open(timetable, encoding='utf-8') as f:
            cfg = json.load(f)
        self.assertEqual(make_timetable.clashes(cfg), [])


if __name__ == "__main__":
    unittest.main()
