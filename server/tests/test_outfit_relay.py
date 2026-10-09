"""Exercise the real transform relay handlers of both servers without starting either."""
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from net import players, state  # noqa: E402
from services.place import PlaceServer  # noqa: E402


class Socket:
    def __init__(self):
        self.messages = []

    async def send(self, text):
        self.messages.append(json.loads(text))


def main_relay(clients):
    """The main server's handler, run against `clients`."""
    async def relay(data, client_id):
        with patch.object(state, "clients", clients):
            await players.on_transform_update(client_id, None, data)
    return relay


def place_relay(clients):
    """The place server's handler, run against `clients`."""
    async def relay(data, client_id):
        server = SimpleNamespace(clients=clients)
        server._send_others = lambda cid, msg: PlaceServer._send_others(server, cid, msg)
        await PlaceServer._on_transform_update(server, client_id, None, data)
    return relay


class OutfitRelayTests(unittest.IsolatedAsyncioTestCase):
    async def test_both_servers_relay_ids_and_reject_paths(self):
        for name, make in [("main", main_relay), ("place", place_relay)]:
            with self.subTest(server=name):
                sender, receiver = Socket(), Socket()
                clients = {1: {"websocket": sender}, 2: {"websocket": receiver}}
                fn = make(clients)
                data = {"position": {"x": 0, "y": 0, "z": 0}, "rotation": {"x": 0, "y": 0, "z": 0},
                        "outfit": ["shoes", "pants", "pants"]}
                await fn(data, 1)
                self.assertEqual(receiver.messages[-1]["outfit"], ["pants", "shoes"])
                self.assertEqual(clients[1]["outfit"], ["pants", "shoes"])
                self.assertEqual(sender.messages, [])
                data["outfit"] = ["res://untrusted.glb"]
                await fn(data, 1)
                self.assertNotIn("outfit", receiver.messages[-1])
                self.assertEqual(clients[1]["outfit"], ["pants", "shoes"])
                data["outfit"] = []
                await fn(data, 1)
                self.assertEqual(receiver.messages[-1]["outfit"], [])


if __name__ == "__main__":
    unittest.main()
