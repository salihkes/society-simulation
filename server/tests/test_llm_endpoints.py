"""The pool's configuration: what is in it, what is switched off, and what
each machine is sent. No network — nothing here calls a model.
"""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("llm_cfg_under_test",
                                              Path(__file__).parents[1] / "mind/llm.py")
llm_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(llm_mod)

LOCAL = {"name": "lan", "url": "http://10.0.0.2:9931", "model": "gemma-local",
         "max_inflight": 2, "rank_live": 2, "rank_bg": 2, "rank_night": 2}
OPENROUTER = {"name": "openrouter", "url": "https://openrouter.ai/api", "enabled": False,
              "api_key": "${OPENROUTER_API_KEY}", "model": "google/gemma-4-26b-a4b-it",
              "night_model": "qwen/qwen3.6-35b-a3b",
              "embed_model": "qwen/qwen3-embedding-8b",
              "rerank_model": "qwen/qwen3-reranker-8b",
              "body": {"reasoning": {"enabled": False}},
              "max_inflight": 4, "rank_live": 0.5, "rank_bg": 0.5, "rank_night": 0.5}


def pool(*endpoints):
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump({"endpoints": list(endpoints)}, f)
    f.close()
    return llm_mod.LocalLLM(config_path=f.name)


class EndpointConfigTest(unittest.TestCase):
    def test_a_disabled_endpoint_is_not_in_the_pool(self):
        p = pool(LOCAL, OPENROUTER)
        self.assertEqual([e.name for e in p.endpoints], ["lan"])

    def test_enabling_it_puts_it_in(self):
        p = pool(LOCAL, dict(OPENROUTER, enabled=True))
        self.assertEqual([e.name for e in p.endpoints], ["lan", "openrouter"])

    def test_the_key_comes_from_the_environment_not_the_file(self):
        os.environ["OPENROUTER_API_KEY"] = "sk-or-test"
        try:
            e = pool(dict(OPENROUTER, enabled=True)).endpoints[0]
            self.assertEqual(e.api_key, "sk-or-test")
            self.assertEqual(e.headers(), {"Authorization": "Bearer sk-or-test"})
        finally:
            del os.environ["OPENROUTER_API_KEY"]

    def test_a_missing_key_is_empty_not_the_literal_placeholder(self):
        os.environ.pop("OPENROUTER_API_KEY", None)
        e = pool(dict(OPENROUTER, enabled=True)).endpoints[0]
        self.assertEqual(e.api_key, "")
        self.assertEqual(e.headers(), {})

    def test_provider_model_alias_preserves_character_selection(self):
        p = pool(dict(OPENROUTER, enabled=True,
                      model_aliases={"qwen-local": "qwen/qwen3.6-35b-a3b"}))
        remote = p.endpoints[0]
        remote.models = ["qwen/qwen3.6-35b-a3b"]
        remote.available = True
        self.assertIs(p._best(["live"], "qwen-local"), remote)
        self.assertEqual(remote.resolve_model("qwen-local"), "qwen/qwen3.6-35b-a3b")

    def test_openrouter_serves_all_three_jobs_from_one_endpoint(self):
        p = pool(dict(OPENROUTER, enabled=True))
        e = p.endpoints[0]
        e.available = True
        e.models = []                       # not probed; named models must still resolve
        self.assertEqual(p._serving("embed")[1], "qwen/qwen3-embedding-8b")
        self.assertEqual(p._serving("rerank")[1], "qwen/qwen3-reranker-8b")

    def test_the_local_machines_are_preferred_while_they_are_up(self):
        p = pool(LOCAL, dict(OPENROUTER, enabled=True))
        for e in p.endpoints:
            e.available = True
        self.assertEqual(p._best(["live"]).name, "lan")
        p.endpoints[0].available = False    # lan goes down
        self.assertEqual(p._best(["live"]).name, "openrouter")

    def test_local_config_has_openrouter_credentials_by_reference(self):
        # llm.json is gitignored — it names this machine's model servers. On a
        # fresh clone there is nothing to check, and that is not a failure.
        path = Path(__file__).parents[1] / "data/world/llm.json"
        if not path.exists():
            self.skipTest("no local llm.json (it is gitignored); nothing to check")
        cfg = json.load(open(path))
        o = next(e for e in cfg["endpoints"] if e["name"] == "openrouter")
        self.assertEqual(o["api_key"], "${OPENROUTER_API_KEY}", "no key in the file")
        for k in ("model", "embed_model", "rerank_model"):
            self.assertTrue(o.get(k), f"{k} not configured")


if __name__ == "__main__":
    unittest.main()
