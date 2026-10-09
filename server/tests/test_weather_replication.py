"""Exercise real server join/relay code without starting network/AI services."""
import base64
import json
from pathlib import Path
import struct
import unittest
import sys
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from world.snow import SnowCache  # noqa: E402
from net import connection, state, world  # noqa: E402

from mind import regions  # noqa: E402

HOME = regions.home()


class Socket:
    def __init__(self):
        self.messages = []

    async def send(self, message):
        self.messages.append(json.loads(message))


class WeatherReplicationTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.state = {"type": "rain", "source": "rain", "atmosphere": {"cloud": 0.57}, "rain": 0.3}
        self.owner, self.peer = Socket(), Socket()
        self.context = dict(
            clients={1: {"websocket": self.owner}, 2: {"websocket": self.peer}},
            ambient_state={}, npc_authority_client_id=1, snow_cache=SnowCache(),
        )
        for name in ("objects", "monsters", "ships", "plots_config", "plot_objects", "map_state",
                     "npc_transforms", "npc_schedules", "npc_audio_playback"):
            self.context[name] = {}
        for name, value in self.context.items():
            self._patch(state, name, value)
        self._patch(connection, "VOICE_CHAT_SERVER_URL", "")
        self._patch(connection, "get_world_environment", lambda: {"weather": {"type": "rain"}})
        self._patch(connection, "get_plot_info_for_client", lambda _: {})
        self._patch(connection, "get_manifest_for_client", lambda **_: {})
        self._patch(connection, "update_npc_authority", AsyncMock())
        self.context["relay"] = lambda client_id, data: world.on_amb_state(client_id, None, data)
        self.context["_admit_client"] = connection.admit_client

    def _patch(self, target, name, value):
        patcher = patch.object(target, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _set(self, name, value):
        """Replace a piece of server state for the rest of the test."""
        self.context[name] = value
        setattr(state, name, value)

    async def test_only_owner_can_replicate_weather_and_citizen_reactions(self):
        packet = {"weather": self.state, "res": {"r_test": {"wx": {"umbrella": True}}}}
        await self.context["relay"](2, packet)
        self.assertEqual(self.context["ambient_state"], {})
        self.assertEqual(self.owner.messages, [])
        await self.context["relay"](1, packet)
        self.assertEqual(self.context["ambient_state"]["weather"], self.state)
        self.assertEqual(self.peer.messages[-1]["weather"], self.state)
        self.assertTrue(self.peer.messages[-1]["res"]["r_test"]["wx"]["umbrella"])
        self.assertEqual(self.owner.messages, [])

    async def test_join_receives_initial_config_and_empty_city_runtime(self):
        self._set("clients", {})
        self._set("ambient_state", {"weather": self.state})
        joined = Socket()
        await self.context["_admit_client"](3, joined)
        config = next(m for m in joined.messages if m["type"] == "weather_update")
        snapshot = next(m for m in joined.messages if m["type"] == "amb_state")
        self.assertTrue(config["initial"])
        self.assertEqual(config["weather"]["type"], "rain")
        self.assertEqual(snapshot["weather"], self.state)
        self.assertLess(joined.messages.index(config), joined.messages.index(snapshot))

    async def test_regional_state_survives_relay_and_late_join(self):
        regional = {"version": 1, "epoch": "world-one", "config": {"type": "rain"}, "elapsed": 2000,
                    "states": {"the_city": {"type": "snow", "temperature_c": -12,
                               "humidity_percent": 90, "sea_ice": .4, "freshwater_ice": .8},
                               HOME: {"type": "rain", "temperature_c": 10,
                               "humidity_percent": 80, "sea_ice": 0, "freshwater_ice": 0}}}
        packet = {**self.state, "regional": regional}
        await self.context["relay"](1, {"weather": packet})
        self.assertEqual(self.peer.messages[-1]["weather"]["regional"], regional)
        self._set("clients", {})
        joined = Socket()
        await self.context["_admit_client"](4, joined, "world")
        restored = next(m for m in joined.messages if m["type"] == "amb_state")
        self.assertEqual(restored["weather"]["regional"], regional)

    async def test_headless_join_also_receives_initial_weather(self):
        self._set("clients", {})
        joined = Socket()
        await self.context["_admit_client"](4, joined, "world")
        self.assertTrue(next(m for m in joined.messages if m["type"] == "weather_update")["initial"])
        self.assertEqual(self.context["clients"][4]["role"], "world")

    async def test_join_restores_snow_after_atmosphere_only_updates(self):
        snow = {"epoch": "snow-cover", "first": 1, "last": 1, "start": 1,
                "full": True, "depth": .12, "fall": 0, "time": 1,
                "data": base64.b64encode(struct.pack("<10f", 1, 0, 2, 0, .14, .28, .07, 0, 1, 0)).decode()}
        await self.context["relay"](1, {"weather": {**self.state, "snow": snow}})
        await self.context["relay"](1, {"weather": self.state})
        self._set("clients", {})
        joined = Socket()
        await self.context["_admit_client"](4, joined, "world")
        catchup = next(m for m in joined.messages if m["type"] == "amb_state")
        self.assertTrue(catchup["initial"])
        self.assertTrue(catchup["weather"]["snow"]["full"])
        self.assertEqual(catchup["weather"]["snow"]["data"], snow["data"])
