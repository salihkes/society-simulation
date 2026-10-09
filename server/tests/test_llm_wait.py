"""The pool's wait-for-a-slot: no server, no network."""
import asyncio
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("llm_under_test", Path(__file__).parents[1] / "mind/llm.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WaitTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        cfg = Path(self.tmp.name) / "llm.json"
        cfg.write_text(json.dumps({"endpoints": [{"name": "one", "url": "http://127.0.0.1:1", "model": "m",
                                                  "max_inflight": 1, "rank_live": 1, "rank_bg": 1}]}))
        self.llm = module.LocalLLM(config_path=str(cfg))
        self.ep = self.llm.endpoints[0]
        self.ep.available = True
        self.ep.last_probe = 1e12          # never re-probe in a test
        self.ep.inflight = 1               # saturated

    async def test_background_call_without_wait_is_skipped_at_once(self):
        t = asyncio.get_event_loop().time()
        self.assertEqual(await self.llm.chat("s", [], tier="bg"), "")
        self.assertLess(asyncio.get_event_loop().time() - t, 0.5)

    async def test_waits_until_a_slot_frees(self):
        async def free_soon():
            await asyncio.sleep(0.3)
            self.ep.inflight = 0
        asyncio.create_task(free_soon())
        self.assertIs(await self.llm._wait_free("bg", "", 5.0), self.ep)

    async def test_gives_up_after_the_budget(self):
        self.assertIsNone(await self.llm._wait_free("bg", "", 1.2))

    async def test_inference_has_no_client_deadline(self):
        session = await self.llm._sess()
        try:
            for field in ("total", "connect", "sock_connect", "sock_read"):
                self.assertIsNone(getattr(session.timeout, field))
        finally:
            await self.llm.close()


if __name__ == "__main__":
    unittest.main()
