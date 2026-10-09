"""The real sky over the home region, and when the city declines to listen to it.

No network: `observe` is stubbed everywhere. The one thing worth being sure
of is that an automatic feed never quietly clears a weather someone chose.
"""
import asyncio
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))

from mind import realweather                                  # noqa: E402
from mind.realweather import WMO, RealWeather, observe        # noqa: E402
from mind.weather import WorldWeather                         # noqa: E402
from core import identity                                               # noqa: E402

REGION = identity.get("real_weather_region")
LABEL = identity.get("real_weather_label")
OTHER = next((r["id"] for r in realweather.regions.catalog()["regions"] if r["id"] != REGION), None)

SKY = {"type": "rain", "temperature_c": 14.2, "humidity_percent": 88.0,
       "wind_kph": 11.0, "observed": "2026-09-22T06:00"}


class MappingTest(unittest.TestCase):
    def test_every_code_maps_to_a_word_the_city_has(self):
        allowed = set(("clear", "partly", "overcast", "fog", "drizzle",
                       "rain", "storm", "windy", "snow"))
        self.assertTrue(set(WMO.values()) <= allowed, set(WMO.values()) - allowed)

    def test_the_ordinary_codes_are_covered(self):
        self.assertEqual(WMO[0], "clear")
        self.assertEqual(WMO[3], "overcast")
        self.assertEqual(WMO[65], "rain")
        self.assertEqual(WMO[75], "snow")
        self.assertEqual(WMO[95], "storm")

    def test_a_gale_under_a_plain_sky_is_windy(self):
        """There is no WMO code for wind: a clear sky over a gale reads 0."""
        payload = {"current": {"temperature_2m": 12.0, "relative_humidity_2m": 50,
                               "weather_code": 0, "wind_speed_10m": 45.0, "time": "t"}}
        with patch.object(realweather.urllib.request, "urlopen") as fake:
            fake.return_value.__enter__.return_value = __import__("io").StringIO(json.dumps(payload))
            self.assertEqual(observe()["type"], "windy")

    def test_an_unreachable_sky_is_not_a_reading(self):
        with patch.object(realweather.urllib.request, "urlopen", side_effect=OSError("no route")):
            self.assertIsNone(observe())

    def test_an_implausible_reading_is_refused(self):
        payload = {"current": {"temperature_2m": 999.0, "relative_humidity_2m": 50,
                               "weather_code": 0, "wind_speed_10m": 1.0, "time": "t"}}
        with patch.object(realweather.urllib.request, "urlopen") as fake:
            fake.return_value.__enter__.return_value = __import__("io").StringIO(json.dumps(payload))
            self.assertIsNone(observe())


class ApplyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "world_environment.json"
        self.path.write_text(json.dumps({"weather": {"type": "auto"}}))
        self.weather = WorldWeather(self.path)

    def region(self):
        return (json.loads(self.path.read_text())["weather"].get("regions") or {}).get(REGION, {})

    def run_tick(self, sky=SKY):
        feed = RealWeather(self.weather)
        with patch.object(realweather, "observe", return_value=sky):
            asyncio.run(feed.tick())
        return feed

    def test_it_writes_the_sky_into_the_marked_region_only(self):
        self.run_tick()
        r = self.region()
        self.assertEqual(r["type"], "rain")
        self.assertEqual(r["temperature_c"], 14.2)
        self.assertEqual(r["source"], LABEL)
        others = json.loads(self.path.read_text())["weather"].get("regions", {})
        self.assertEqual(list(others), [REGION],
                         "the invented regions keep their own simulated weather")

    def test_the_world_default_is_left_on_auto(self):
        self.run_tick()
        self.assertEqual(json.loads(self.path.read_text())["weather"]["type"], "auto")

    def test_a_weather_set_by_hand_is_not_overwritten(self):
        """A staged storm must survive the next quarter of an hour."""
        self.weather.set("storm", region=REGION, temperature_c=3.0)
        self.assertNotIn("source", self.region())
        self.run_tick()
        self.assertEqual(self.region()["type"], "storm", "the real sky cleared a staged storm")
        self.assertEqual(self.region()["temperature_c"], 3.0)

    def test_it_does_update_what_it_wrote_itself(self):
        self.run_tick()
        self.run_tick(dict(SKY, type="snow", temperature_c=-2.0))
        self.assertEqual(self.region()["type"], "snow")

    def test_an_unreachable_sky_changes_nothing(self):
        self.run_tick()
        before = self.region()
        feed = RealWeather(self.weather)
        with patch.object(realweather, "observe", return_value=None):
            asyncio.run(feed.tick())
        self.assertEqual(self.region(), before)

    @unittest.skipIf(OTHER is None, "the region catalog has one region")
    def test_each_marked_region_reads_its_own_place(self):
        seen = []
        def fake(region=None):
            seen.append(region)
            return SKY
        with patch.object(realweather.regions, "real_weather_regions", return_value=[REGION, OTHER]), \
                patch.object(realweather, "observe", side_effect=fake):
            asyncio.run(RealWeather(self.weather).tick())
        self.assertEqual(seen, [REGION, OTHER])
        regions = json.loads(self.path.read_text())["weather"]["regions"]
        self.assertEqual(regions[OTHER]["source"], "real")
        self.assertEqual(regions[REGION]["source"], LABEL)

    @unittest.skipIf(OTHER is None, "the region catalog has one region")
    def test_a_region_reads_at_its_catalog_lonlat(self):
        lat, lon = realweather._latlon(OTHER)
        self.assertEqual((lon, lat), realweather.regions.lonlat(OTHER))

    def test_it_can_be_switched_off(self):
        with patch.object(realweather, "enabled", return_value=False):
            self.run_tick()
        self.assertEqual(self.region(), {}, "off means off")


if __name__ == "__main__":
    unittest.main()
