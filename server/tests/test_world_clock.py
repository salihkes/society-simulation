import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from datetime import date
sys.path.insert(0, str(Path(__file__).parents[1]))
from mind import clock, regions  # noqa: E402

class ClockTest(unittest.TestCase):
    def test_scaled_day_and_restart(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'clock.json'
            p.write_text(json.dumps({'mode':'scaled','hour':23,'rate':60}))
            with patch.object(clock.time, 'monotonic', return_value=1000):
                c = clock.WorldClock(str(p))
            today = c._real_day()
            self.assertEqual(c._anchor_day, today)
            with patch.object(clock.time, 'monotonic', return_value=1120):
                self.assertAlmostEqual(c.hour(), 1)
                self.assertEqual(c.day(), today+1)
                self.assertEqual(c.weekday(), date.fromordinal(today+1).weekday())
                c.checkpoint()
            with patch.object(clock.time, 'monotonic', return_value=9000):
                restored = clock.WorldClock(str(p))
                self.assertAlmostEqual(restored.hour(), 1)
                self.assertEqual(restored.day(), today+1)

    def test_new_configuration_does_not_restore_old_time(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'clock.json'
            p.write_text(json.dumps({'mode':'scaled','hour':8,'rate':60}))
            c = clock.WorldClock(str(p)); c.checkpoint()
            p.write_text(json.dumps({'mode':'scaled','hour':12,'rate':60}))
            restored = clock.WorldClock(str(p))
            self.assertAlmostEqual(restored.hour(),12,places=3)


class RegionClockTest(unittest.TestCase):
    """One instant; each region's clocks are a label over it."""
    def make(self, cfg):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        p = Path(d.name)/'clock.json'
        p.write_text(json.dumps(cfg))
        return clock.WorldClock(str(p))

    def test_real_mode_is_the_real_instant_not_the_machine_zone(self):
        with patch.object(clock.time, 'time', return_value=86400 * 20000 + 9 * 3600):
            c = self.make({'mode': 'real'})
            self.assertEqual(c.utc(), 86400 * 20000 + 9 * 3600)
            self.assertAlmostEqual(c.hour(), (9 + regions.utc_offset()) % 24)
            self.assertEqual(c.day(), 20000 + clock.EPOCH_ORDINAL)

    def test_fixed_hour_is_on_the_home_clock(self):
        c = self.make({'mode': 'fixed', 'hour': 21})
        self.assertAlmostEqual(c.hour(), 21)
        self.assertAlmostEqual((c.utc() / 3600 + regions.utc_offset()) % 24, 21)

    def test_a_region_with_another_offset_shows_another_hour(self):
        c = self.make({'mode': 'fixed', 'hour': 10})
        with patch.object(regions, 'utc_offset', side_effect=lambda r=None: -10.0 if r == 'far' else 3.0):
            self.assertAlmostEqual(c.hour(), 10)
            self.assertAlmostEqual(c.hour('far'), 21)
            self.assertEqual(c.day('far'), c.day() - 1)

    def test_message_carries_the_instant(self):
        m = self.make({'mode': 'fixed', 'hour': 6}).message()
        self.assertIn('utc', m)
        self.assertEqual(m['home'], regions.home())
        self.assertAlmostEqual((m['utc'] / 3600 + regions.utc_offset()) % 24, m['hour'], places=3)
