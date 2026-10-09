"""Needs nothing can answer are not a person's to have: no household, no
hygiene/comfort/fun/bladder; nowhere to eat, no hunger. The model is not
consulted; the rules are."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

AVAILABLE = all(importlib.util.find_spec(n) for n in ('aiohttp', 'frontmatter'))

RESIDENTS = [{"id": "mum", "life": False}, {"id": "loner", "life": False}]
HOUSEHOLDS = {"flat": {"house": "Home", "door": "Door", "name": "the flat",
                       "members": {"mum": "parent"}, "rooms": {"Living": "shared"}}}
PLACES = [{"id": "Diner", "kind": "restaurant", "open": [11.0, 23.5], "name": "Diner"}]


async def mind_with(root, places):
    sys.path.insert(0, str(Path(__file__).parents[1]))
    from mind import Mind
    (Path(root) / 'cards').mkdir(exist_ok=True)
    (Path(root) / 'clock.json').write_text('{"mode":"fixed","hour":9.0,"weekday":"mon"}')
    (Path(root) / 'households.json').write_text(json.dumps(HOUSEHOLDS))
    async def send(msg): pass
    m = Mind(root, send, send)
    await m.on_world_report({'workspace': 'test', 'places': places, 'residents': RESIDENTS})
    m.brain.llm.probe = AsyncMock(return_value=False)
    m.brain.llm.chat = AsyncMock(return_value="")
    return m


@unittest.skipUnless(AVAILABLE, 'run with the server venv for application integration checks')
class NeedsFollowTheHome(unittest.IsolatedAsyncioTestCase):

    async def test_without_a_household_only_hunger_is_kept_and_it_climbs(self):
        with tempfile.TemporaryDirectory() as root:
            m = await mind_with(root, PLACES)
            self.assertEqual(set(m.brain._need('r_mum')) - {'eat_block_until'},
                             {'hunger', 'hygiene', 'comfort', 'fun', 'bladder'})
            loner = m.brain._need('r_loner')
            self.assertEqual(set(loner) - {'eat_block_until'}, {'hunger'})
            before = loner['hunger']
            m.brain._last_hour, m.brain._last_day = 8.0, m.clock.day()
            await m.brain.tick()
            loner = m.brain.needs['r_loner']
            self.assertGreater(loner['hunger'], before)
            self.assertNotIn('bladder', loner, 'a need nothing answers must not come back on a tick')

    async def test_a_saved_value_for_a_need_they_cannot_have_is_dropped(self):
        with tempfile.TemporaryDirectory() as root:
            m = await mind_with(root, PLACES)
            m.brain.needs['r_loner'].update(bladder=1.0, hygiene=1.0)
            self.assertNotIn('bladder', m.brain._need('r_loner'))
            self.assertNotIn('hygiene', m.brain._need('r_loner'))

    async def test_nowhere_to_eat_and_no_home_means_no_hunger(self):
        with tempfile.TemporaryDirectory() as root:
            m = await mind_with(root, [])
            self.assertNotIn('hunger', m.brain._need('r_loner'))
            m.brain._last_hour, m.brain._last_day = 8.0, m.clock.day()
            await m.brain.tick()   # no KeyError, no meal pushed
            self.assertNotIn('hunger', m.brain.needs['r_loner'])
            await m.brain.react('r_loner', {'did': 'ate'})
            self.assertNotIn('hunger', m.brain.needs['r_loner'])
            self.assertIn('hunger', m.brain._need('r_mum'), 'a household feeds its own')


if __name__ == '__main__':
    unittest.main()
