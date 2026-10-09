"""Snow deltas, catch-up, bounded retention, and malformed packet handling."""
import base64
from copy import deepcopy
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from world.snow import SnowCache


def packet(first=1, last=1, start=1, full=False, epoch="winter", time=1.0):
    records = [struct.pack("<10f", i, 0, i, 0, .14, .28, .09, 0, time, 0)
               for i in range(start, last + 1)]
    return {"epoch": epoch, "first": first, "last": last, "start": start,
            "full": full, "data": base64.b64encode(b"".join(records)).decode(),
            "depth": .12, "fall": 0, "time": time, "max": .18, "rate": .006, "melt": .002}


class SnowReplicationTest(unittest.TestCase):
    def test_delta_catch_up_and_duplicate(self):
        cache = SnowCache()
        self.assertTrue(cache.accept(packet()))
        second = packet(last=3, start=2, time=2)
        self.assertTrue(cache.accept(second))
        self.assertTrue(cache.accept(second))
        full = cache.snapshot()
        self.assertTrue(full["full"])
        self.assertEqual((full["first"], full["start"], full["last"]), (1, 1, 3))
        self.assertEqual(len(base64.b64decode(full["data"])), 3 * 40)
        joined = SnowCache()
        self.assertTrue(joined.accept(full))
        self.assertEqual(joined.snapshot(), full)

    def test_pruning_and_promotion_keep_sequence(self):
        cache = SnowCache()
        self.assertTrue(cache.accept(packet(last=3)))
        self.assertTrue(cache.accept(packet(first=2, last=4, start=4, time=2)))
        promoted = SnowCache()
        self.assertTrue(promoted.accept(cache.snapshot()))
        self.assertTrue(cache.accept(packet(first=2, last=5, start=5, time=3)))
        self.assertEqual(len(cache.records), 4 * 40)
        self.assertEqual(struct.unpack_from("<f", cache.records)[0], 2)

    def test_reset_and_no_tracks_are_valid(self):
        cache = SnowCache()
        self.assertTrue(cache.accept(packet()))
        reset = packet(first=1, last=0, start=1, epoch="new-cover", time=3)
        reset["depth"] = 0
        self.assertTrue(cache.accept(reset))
        self.assertEqual(cache.records, b"")
        weather = cache.weather_for_join({"type": "clear"})
        self.assertEqual(weather["snow"]["depth"], 0)
        self.assertEqual(weather["type"], "clear")

    def test_bad_or_stale_packets_do_not_damage_catch_up(self):
        cache = SnowCache()
        self.assertTrue(cache.accept(packet(time=10)))
        before = cache.snapshot()
        cases = [None, {}, packet(last=3, start=3, time=11), packet(time=9)]
        for key, value in (("depth", float("nan")), ("depth", 100), ("rate", -1),
                           ("data", "invalid!"), ("last", 40000)):
            bad = deepcopy(before)
            bad[key] = value
            cases.append(bad)
        bad = deepcopy(before)
        bad["data"] = base64.b64encode(struct.pack("<10f", *([float("inf")] * 10))).decode()
        cases.append(bad)
        for bad in cases:
            with self.subTest(packet=bad):
                self.assertFalse(cache.accept(bad))
                self.assertEqual(cache.snapshot(), before)

    def test_empty_weather_delta_keeps_join_history(self):
        cache = SnowCache()
        self.assertTrue(cache.accept(packet()))
        # Between snow updates, atmosphere packets intentionally omit tracks.
        joined = cache.weather_for_join({"type": "snow", "source": "snow"})
        self.assertTrue(joined["snow"]["full"])
        self.assertEqual(joined["snow"]["last"], 1)
