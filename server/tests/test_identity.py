"""The client and server identity files agree on what they share."""
import json
import os
import unittest

from core import identity

CLIENT_DATA = os.path.join(os.path.dirname(__file__), "..", "..", "client", "data")
SERVER_CONFIG = os.path.join(os.path.dirname(__file__), "..", "config")


def _client_identity():
    """The client file matching the server's: both real, or both examples."""
    real = os.path.exists(os.path.join(SERVER_CONFIG, "identity.json"))
    return os.path.join(CLIENT_DATA, "identity.json" if real else "identity.example.json")


class IdentityAgreement(unittest.TestCase):
    def setUp(self):
        path = _client_identity()
        if not os.path.exists(path):
            self.skipTest(f"no {path}")
        with open(path, encoding="utf-8") as f:
            self.client = json.load(f)

    def test_client_key(self):
        self.assertEqual(self.client["client_key"], identity.get("client_key"))

    def test_public_server_on_domain(self):
        domain = identity.get("external_domain")
        self.assertTrue(any(domain in url for url in self.client["servers"]))
        self.assertIn(domain, self.client["voice_url"])
        self.assertIn(domain, self.client["cinema_url"])

    def test_home_region(self):
        self.assertEqual(self.client["home_region"],
                         identity.get("fallback_regions")["home"])


if __name__ == "__main__":
    unittest.main()
