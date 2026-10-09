"""The server's handler table matches protocol/messages.json."""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from net import connection  # noqa: E402

CONTRACT = os.path.join(os.path.dirname(__file__), "..", "..", "protocol", "messages.json")


class ProtocolContract(unittest.TestCase):
    def setUp(self):
        with open(CONTRACT, encoding="utf-8") as f:
            self.messages = json.load(f)["messages"]

    def test_every_handled_type_is_in_the_contract(self):
        missing = sorted(set(connection.HANDLERS) - set(self.messages))
        self.assertEqual(missing, [], "add these types to protocol/messages.json")

    def test_contract_names_the_same_handlers(self):
        for kind, entry in self.messages.items():
            handler = connection.HANDLERS.get(kind)
            expected = entry["server"]
            actual = None if handler is None else f"{handler.__module__.split('.')[-1]}.{handler.__name__}"
            self.assertEqual(actual, expected, kind)


if __name__ == "__main__":
    unittest.main()
