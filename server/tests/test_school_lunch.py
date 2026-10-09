"""Lunch, and what hunger may not do during a lesson.

Forty-three pupils once walked out of their classes at the same moment,
all at hunger 1.00, all to the one open restaurant — which seats eight.
Two things were wrong and this pins both: the bento the school serves at
the desks never fed anybody, and the needs model never asked whether the
person it was sending to a restaurant was sitting in a lesson.
"""
import asyncio
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

AVAILABLE = all(importlib.util.find_spec(n) for n in ('aiohttp', 'frontmatter'))

MORNING = {"start": 8.5, "end": 9.25, "subject": "kimya", "lesson": "", "teacher": "r_t1"}
AFTERNOON = {"start": 12.5, "end": 13.25, "subject": "fizik", "lesson": "", "teacher": "r_t1"}
SCHOOL = {"school": "School", "teacher": "r_t1", "days": [0, 1, 2, 3, 4, 5, 6],
          "periods": {"mon": [MORNING, AFTERNOON]}, "lessons": [], "rites": False,
          "roll_call": False, "absent_chance": 0, "late_chance": 0, "skip_chance": 0}
RESIDENTS = [{"id": "t1", "teacher": True, "life": False},
             {"id": "s1", "student": True, "life": False, "name": "ハル"},
             {"id": "s2", "student": True, "life": False, "name": "ミオ"}]
PLACES = [{"id": "Diner", "kind": "restaurant", "open": [11.0, 23.5], "name": "Diner"}]


async def mind_at(root, hour):
    sys.path.insert(0, str(Path(__file__).parents[1]))
    from mind import Mind
    (Path(root) / 'cards').mkdir(exist_ok=True)
    (Path(root) / 'clock.json').write_text('{"mode":"fixed","hour":%s,"weekday":"mon"}' % hour)
    (Path(root) / 'school.json').write_text(json.dumps(SCHOOL))
    sent = []
    async def send(msg): sent.append(msg)
    m = Mind(root, send, send)
    await m.on_world_report({'workspace': 'test', 'places': PLACES, 'residents': RESIDENTS})
    # No model, and no reaching for one: these are rules, not thinking.
    m.brain.llm.probe = AsyncMock(return_value=False)
    m.brain.llm.chat = AsyncMock(return_value="")
    return m, sent


@unittest.skipUnless(AVAILABLE, 'run with the server venv for application integration checks')
class Lunch(unittest.IsolatedAsyncioTestCase):

    async def test_hunger_does_not_call_a_pupil_out_of_a_lesson(self):
        with tempfile.TemporaryDirectory() as root:
            m, _ = await mind_at(root, 12.6)          # inside the afternoon period
            await m.brain.school.tick(12.6)
            self.assertTrue(m.brain.school.in_class('r_s1'), 'the period should be running')
            for key in ('r_s1', 'r_s2'):
                m.brain._need(key)['hunger'] = 1.0    # as hungry as a person gets
            m.brain._last_hour, m.brain._last_day = 12.5, m.clock.day()
            await m.brain.tick()
            for key in ('r_s1', 'r_s2'):
                self.assertFalse(m.brain._need(key).get('eating'),
                                 f'{key} was sent to a restaurant from their desk')
            m.brain.memory.store.close()

    async def test_out_of_school_hunger_still_sends_them_to_eat(self):
        """The rule must still work; it is only lessons it may not interrupt."""
        with tempfile.TemporaryDirectory() as root:
            m, _ = await mind_at(root, 17.0)          # after the last period
            await m.brain.school.tick(17.0)
            self.assertFalse(m.brain.school.in_class('r_s1'))
            m.brain._need('r_s1')['hunger'] = 1.0
            m.brain._last_hour, m.brain._last_day = 16.9, m.clock.day()
            await m.brain.tick()
            self.assertTrue(m.brain._need('r_s1').get('eating'),
                            'a hungry pupil out of school should still go and eat')
            m.brain.memory.store.close()

    async def test_the_bento_actually_feeds_them(self):
        with tempfile.TemporaryDirectory() as root:
            m, _ = await mind_at(root, 8.6)
            day = m.brain.school.day()
            for key in ('r_s1', 'r_s2'):
                m.brain._need(key)['hunger'] = 0.95
            await day.tick(8.6)                        # morning period
            await day.tick(9.3)                        # the bell: the long gap is lunch
            for key in ('r_s1', 'r_s2'):
                self.assertEqual(m.brain._need(key)['hunger'], 0.95,
                                 'A roster is not evidence of having eaten')
            # The world seats s1 for lunch; s2 is absent. Only the real
            # meal observation may feed a pupil or enter their memory.
            await m.on_observations({'obs': [{'who': 'r_s1', 'did': 'ate', 'meal': 'bento', 'place': 'School'}]})
            self.assertEqual(m.brain._need('r_s1')['hunger'], 0.0)
            self.assertEqual(m.brain._need('r_s2')['hunger'], 0.95)
            raw = m.brain.memory.store.raw_since('r_s1', 0.0)
            self.assertTrue(any(r.get('did') == 'ate' and r.get('meal') == 'bento' for r in raw),
                            'the meal left no trace for the memory to harvest')
            m.brain.memory.store.close()


if __name__ == "__main__":
    unittest.main()
