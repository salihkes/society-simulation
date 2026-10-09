"""Inspect actual pool requests without a network or model service."""
import asyncio
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock

spec = importlib.util.spec_from_file_location("llm_requests", Path(__file__).parents[1] / "mind/llm.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Response:
    status = 200

    def __init__(self, payload):
        self.payload = payload

    async def __aenter__(self):
        await asyncio.sleep(0)
        return self

    async def __aexit__(self, *args):
        pass

    async def json(self):
        return self.payload


class Session:
    def __init__(self, payload):
        self.payload = payload
        self.calls = []

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return Response(self.payload)


class Requests(unittest.IsolatedAsyncioTestCase):
    async def test_local_and_cloud_ignore_legacy_generation_overrides(self):
        for url in ("http://localhost:8085", "https://openrouter.ai/api"):
            for tier in ("bg", "live", "night"):
                with self.subTest(url=url, tier=tier), tempfile.TemporaryDirectory() as root:
                    cfg = Path(root) / "llm.json"
                    cfg.write_text(json.dumps({"endpoints": [{"url": url, "model": "m", "night_model": "n",
                        "body": {"temperature": 0.1, "max_tokens": 1, "reasoning": {"enabled": False},
                                 "chat_template_kwargs": {"enable_thinking": False}}}]}))
                    llm = module.LocalLLM(config_path=str(cfg))
                    llm.endpoints[0].available = True
                    llm.is_night = lambda: True
                    session = Session({"choices": [{"message": {"content": "full answer"}}]})
                    llm._sess = AsyncMock(return_value=session)
                    self.assertEqual(await llm.chat("system", [{"role": "user", "content": "hello"}],
                                                    max_tokens=1, tier=tier), "full answer")
                    _, request = session.calls[0]
                    # night_model is deprecated: night work runs on the endpoint's model.
                    self.assertEqual(request["json"], {"model": "m",
                        "messages": [{"role": "system", "content": "system"}, {"role": "user", "content": "hello"}]})
                    self.assertNotIn("timeout", request)
                    self.assertEqual(llm.inflight, 0)

    async def test_embeddings_and_reranking_inherit_unlimited_session(self):
        with tempfile.TemporaryDirectory() as root:
            cfg = Path(root) / "llm.json"
            cfg.write_text(json.dumps({"endpoints": [{"url": "http://localhost:1", "embed_model": "embedding",
                                                       "rerank_model": "reranker"}]}))
            llm = module.LocalLLM(config_path=str(cfg))
            llm.endpoints[0].available = True
            session = Session({"data": [{"embedding": [1.0, 0.0]}]})
            llm._sess = AsyncMock(return_value=session)
            self.assertEqual(len(await llm.embed(["hello"])), 1)
            session.payload = {"results": [{"index": 0, "relevance_score": 0.8}]}
            self.assertEqual(await llm.rerank("hello", ["hello"]), [0.8])
            self.assertTrue(all("timeout" not in kwargs for _, kwargs in session.calls))
