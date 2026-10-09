"""Weather persistence and the real mindctl -> Mind command path, using temporary state."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server"))
from mind import Mind
from mind.weather import WEATHER_TYPES, WorldWeather

from mind import regions  # noqa: E402

HOME = regions.home()
OTHER = next((r["id"] for r in regions.catalog()["regions"] if r["id"] != HOME), None)
CLIENT_REGIONS = ROOT / "client/assets/world/region/regions.json"

spec = importlib.util.spec_from_file_location("mindctl_weather_test", ROOT / "tools/run/mindctl.py")
mindctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mindctl)


class WeatherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "world_environment.json"
        self.weather = WorldWeather(self.path)
        # Run the real command dispatcher without starting unrelated resident services.
        self.mind = Mind.__new__(Mind)
        self.mind.weather = self.weather
        self.mind.send_all = AsyncMock()
        self.replies = []

    async def dispatch(self, cmd):
        async def reply(message):
            self.replies.append(message)
        await self.mind.command(cmd, reply)
        return self.replies[-1]

    def cli(self, *args):
        with patch.object(sys, "argv", ["mindctl.py", "weather", *args]), \
                patch.object(mindctl, "send", side_effect=self.dispatch), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
            mindctl.main()
        return result.exception.code

    def test_every_client_type_through_cli_persists_and_broadcasts(self):
        source = (ROOT / "client/src/world/environment/weather_controller.gd").read_text()
        client_types = json.loads(re.search(r"const TYPES := (\[.*\])", source)[1])
        self.assertEqual(set(WEATHER_TYPES), {"auto", *client_types})
        self.path.write_text(json.dumps({"weather": {"type": "clear", "metadata": 7}, "lighting": {"sun": 0.8}}))
        for preset in [*client_types, "auto"]:
            with self.subTest(preset=preset):
                self.assertEqual(self.cli(preset), 0)
                self.assertTrue(self.replies[-1]["ok"])
                self.assertEqual(WorldWeather(self.path).status()["configured"], preset)
                saved = json.loads(self.path.read_text())
                self.assertEqual(saved["lighting"], {"sun": 0.8})
                self.assertEqual(saved["weather"]["metadata"], 7)
                self.mind.send_all.assert_awaited_with({"type": "weather_update", "weather": saved["weather"]})
        self.assertEqual(self.weather.status()["mode"], "auto")

    def test_status_is_read_only_and_defaults_to_auto(self):
        for args in [(), ("status",)]:
            self.assertEqual(self.cli(*args), 0)
            self.assertEqual(json.loads(self.replies[-1]["text"])["configured"], "auto")
        self.assertFalse(self.path.exists())
        self.mind.send_all.assert_not_awaited()
        self.path.write_text('{"weather":{"type":"calm"}}')
        self.assertEqual(self.cli("status"), 0)
        status = json.loads(self.replies[-1]["text"])
        self.assertEqual(status["configured"], "calm")
        self.assertEqual(status["mode"], "auto")

    def test_snow_controls_persist_and_broadcast_with_one_shot_depth(self):
        self.assertEqual(self.cli("snow", "--snow-depth", "0.12", "--snow-rate", "0.01", "--snow-max", "0.2"), 0)
        snow = self.weather.status()["snow"]
        self.assertEqual(snow["depth"], 0.12)
        self.assertEqual(snow["rate"], 0.01)
        self.assertEqual(snow["max_depth"], 0.2)
        self.assertTrue(snow["command"])
        command = snow["command"]
        self.assertEqual(self.cli("snow", "--snow-rate", "0.02"), 0)
        self.assertEqual(self.weather.status()["snow"]["command"], command)
        self.assertEqual(self.cli("clear", "--snow-depth", "0"), 0)
        self.assertNotEqual(self.weather.status()["snow"]["command"], command)

    @unittest.skipIf(OTHER is None, "the region catalog has one region")
    def test_regional_cli_preserves_other_regions_and_global_defaults(self):
        self.assertEqual(self.cli("clear", "--temperature", "12", "--humidity", "40"), 0)
        self.assertEqual(self.cli("snow", "--region", OTHER, "--temperature", "-12", "--humidity", "90"), 0)
        self.assertEqual(self.cli("rain", "--region", HOME, "--temperature", "8"), 0)
        saved = json.loads(self.path.read_text())["weather"]
        self.assertEqual(saved["type"], "clear")
        self.assertEqual(saved["temperature_c"], 12)
        self.assertEqual(saved["regions"][OTHER], {"type": "snow", "temperature_c": -12, "humidity_percent": 90})
        self.assertEqual(saved["regions"][HOME]["temperature_c"], 8)
        self.mind.send_all.assert_awaited_with({"type": "weather_update", "weather": saved})
        self.assertEqual(self.cli("auto", "--region", OTHER), 0)
        region = self.weather.status()["regions"][OTHER]
        self.assertEqual(region, {"type": "auto", "temperature_c": None, "humidity_percent": None})
        self.assertEqual(self.cli("auto"), 0)
        self.assertIsNone(self.weather.status()["temperature_c"])

    def test_invalid_regional_values_are_atomic(self):
        self.assertEqual(self.cli("clear"), 0)
        before = self.path.read_bytes()
        for args in (("--temperature", "nan"), ("--temperature", "61"), ("--humidity", "101"),
                     ("--humidity", "-1"), ("--region", "missing")):
            self.assertEqual(self.cli("snow", *args), 1)
            self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.cli("status", "--humidity", "30"), 2)

    @unittest.skipUnless(CLIENT_REGIONS.exists(), "no client regions.json")
    def test_region_catalog_matches_client(self):
        from mind.weather import REGIONS
        catalog = json.loads(CLIENT_REGIONS.read_text())
        self.assertEqual(REGIONS, tuple(r["id"] for r in catalog["regions"]))
        # The weather shader's field holds exactly this many stations.
        shader = (ROOT / "client/src/world/environment/regional_field.gdshaderinc").read_text()
        self.assertIn("regional_values[%d]" % len(REGIONS), shader)

    def test_bad_snow_settings_do_not_overwrite_state(self):
        self.assertEqual(self.cli("snow", "--snow-depth", "0.12"), 0)
        before = self.path.read_bytes()
        for option, value in (("--snow-depth", "-1"), ("--snow-depth", "2"), ("--snow-rate", "nan")):
            self.assertEqual(self.cli("snow", option, value), 1)
            self.assertEqual(self.path.read_bytes(), before)

    def test_invalid_selection_rejected_by_cli_and_server(self):
        import asyncio
        self.assertEqual(self.cli("hurricane"), 2)
        self.assertEqual(self.replies, [])
        result = asyncio.run(self.dispatch({"cmd": "weather", "weather": "hurricane"}))
        self.assertFalse(result["ok"])
        self.assertFalse(self.path.exists())
        self.mind.send_all.assert_not_awaited()

    def test_bad_json_is_reported_without_overwriting_or_broadcasting(self):
        self.path.write_text('{"unfinished":')
        self.assertEqual(self.cli("rain"), 1)
        self.assertFalse(self.replies[-1]["ok"])
        self.assertEqual(self.path.read_text(), '{"unfinished":')
        self.mind.send_all.assert_not_awaited()

    def test_failed_replace_preserves_previous_weather(self):
        self.weather.set("rain")
        before = self.path.read_bytes()
        with patch("mind.weather.os.replace", side_effect=OSError("disk error")):
            self.assertEqual(self.cli("storm"), 1)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])
        self.mind.send_all.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
