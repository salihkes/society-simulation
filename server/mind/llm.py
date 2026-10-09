"""LLM client: a pool of OpenAI-compatible servers from data/world/llm.json, routed per call by tier (live/bg/night)."""
import json
import os
import re
import time
import asyncio

import aiohttp

LLAMA_URL = os.environ.get("LLAMA_URL", "http://127.0.0.1:8085").rstrip("/")
MIND_MODEL = os.environ.get("MIND_MODEL", "")
PROBE_EVERY = 60.0
NIGHT_HOURS = (2, 7)     # default for llm.json "night_hours"


def _expand(value: str) -> str:
    """Resolve a "${VAR}" value from the environment, so keys stay out of llm.json."""
    m = re.fullmatch(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", value.strip())
    return os.environ.get(m.group(1), "") if m else value


_NOT_FOUND = object()      # rerank path missing: try the next one
_FAILED = object()         # request failed


def _rerank_scores(data: dict, n: int) -> list:
    """Scores by document index from a rerank response; 0.0 where missing."""
    scores = [0.0] * n
    for row in data.get("results", data.get("data", [])):
        try:
            scores[int(row["index"])] = float(row.get("relevance_score", row.get("score", 0.0)))
        except (KeyError, ValueError, TypeError, IndexError):
            continue
    return scores


class Endpoint:
    def __init__(self, cfg: dict):
        self.name = str(cfg.get("name") or cfg.get("url"))
        self.url = str(cfg.get("url", LLAMA_URL)).rstrip("/")
        self.model = str(cfg.get("model", ""))
        self.night_model = str(cfg.get("night_model", ""))
        self.model_aliases = dict(cfg.get("model_aliases") or {})
        # Optional: otherwise any served model named "*embed*" / "*rerank*" is used.
        self.embed_model = str(cfg.get("embed_model", ""))
        self.rerank_model = str(cfg.get("rerank_model", ""))
        self.api_key = _expand(str(cfg.get("api_key", "")))
        # A disabled endpoint is never probed or chosen.
        self.enabled = bool(cfg.get("enabled", True))
        # A "body" key is ignored: generation always uses provider defaults.
        self.max_inflight = int(cfg.get("max_inflight", 1))
        self.rank = {"live": float(cfg.get("rank_live", 1)), "bg": float(cfg.get("rank_bg", 1)),
                     "night": float(cfg.get("rank_night", 1 if self.night_model else 0))}
        self.available = None
        self.models: list = []
        self.inflight = 0
        self.night_inflight = 0
        self.last_probe = 0.0
        self.fail_at = 0.0
        self.latency = 0.0           # last request, seconds

    def serves(self, model: str) -> bool:
        """True when model is empty, the model list is unknown, or it is served."""
        return not model or not self.models or self.resolve_model(model) in self.models

    def resolve_model(self, model: str) -> str:
        """The endpoint's own name for a model (via model_aliases)."""
        return str(self.model_aliases.get(model, model))

    def headers(self) -> dict:
        return {"Authorization": "Bearer " + self.api_key} if self.api_key else {}


class LocalLLM:
    def __init__(self, url: str = LLAMA_URL, model: str = MIND_MODEL, config_path: str = None):
        self.config_path = config_path or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                                       "data", "world", "llm.json")
        self._cfg_mtime = None
        self.endpoints: list = []
        self._single = Endpoint({"name": "default", "url": url, "model": model})
        self._session = None
        self.reload()

    def reload(self):
        """Re-read llm.json if it changed, keeping live state of unchanged endpoints."""
        try:
            mtime = os.path.getmtime(self.config_path)
        except OSError:
            mtime = None
        if mtime == self._cfg_mtime and self.endpoints:
            return
        self._cfg_mtime = mtime
        eps = []
        off = []
        self.night_hours = NIGHT_HOURS
        if mtime is not None:
            try:
                self._read_config(eps, off)
            except Exception as e:
                print(f"[LLM] llm.json not applied: {e}")
        if not eps:
            eps = [self._single]
        old = {e.url: e for e in self.endpoints}
        for e in eps:
            o = old.get(e.url)
            if o is not None:
                e.available, e.models, e.inflight, e.night_inflight, e.last_probe = \
                    o.available, o.models, o.inflight, o.night_inflight, o.last_probe
        self.endpoints = eps
        print("[LLM] endpoints: " + ", ".join(f"{e.name} ({e.url}) live={e.model or '?'}"
                                              + (f" night={e.night_model}" if e.night_model else "") for e in eps))
        if off:
            print("[LLM] configured but off: " + ", ".join(off) + "  (\"enabled\": true to use)")

    def _read_config(self, eps: list, off: list):
        """Parse llm.json into enabled endpoints (eps) and disabled names (off)."""
        with open(self.config_path, encoding="utf-8") as f:
            cfg = json.load(f) or {}
        nh = cfg.get("night_hours")
        if isinstance(nh, list) and len(nh) == 2:
            self.night_hours = (int(nh[0]), int(nh[1]))
        for e in cfg.get("endpoints", []):
            if not e.get("url"):
                continue
            ep = Endpoint(e)
            if not ep.enabled:
                off.append(ep.name)
                continue
            eps.append(ep)

    @property
    def available(self) -> bool:
        return any(e.available for e in self.endpoints)

    @property
    def model(self) -> str:
        """The model the best live endpoint would use."""
        best = self._best(["live"])
        return best.model if best else ""

    @property
    def inflight(self) -> int:
        return sum(e.inflight for e in self.endpoints)

    def status(self) -> list:
        return [{"name": e.name, "url": e.url, "up": bool(e.available), "model": e.model,
                 "night_model": e.night_model,
                 "embed": e.embed_model or next((n for n in e.models if "embed" in n.lower()), ""),
                 "rerank": e.rerank_model or next((n for n in e.models if "rerank" in n.lower()), ""),
                 "inflight": e.inflight, "last_s": round(e.latency, 1)}
                for e in self.endpoints]

    async def _sess(self) -> aiohttp.ClientSession:
        """The shared HTTP session, with no total timeout."""
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None))
        return self._session

    async def _probe_one(self, e: Endpoint) -> bool:
        """Ask one endpoint for its model list; marks it up or down."""
        e.last_probe = time.time()
        try:
            s = await self._sess()
            async with s.get(e.url + "/v1/models", headers=e.headers(),
                             timeout=aiohttp.ClientTimeout(total=5)) as r:
                if r.status != 200:
                    e.available = False
                    return False
                data = await r.json()
            names = [m.get("id") for m in data.get("data", []) if m.get("id")]
            e.models = names
            if not e.model and names:
                e.model = names[0]
                print(f"[LLM] {e.name}: using model '{e.model}' (first of {names})")
            elif e.model and names and e.model not in names:
                print(f"[LLM] {e.name}: model '{e.model}' not served; server has {names}")
            was = e.available
            e.available = True
            if was is False:
                print(f"[LLM] {e.name} is back")
            return True
        except Exception:
            if e.available is not False:
                print(f"[LLM] {e.name} ({e.url}) is not answering")
            e.available = False
            return False

    async def probe(self) -> bool:
        """Is any server up? Cheap; re-probes each endpoint at most once a minute."""
        self.reload()
        now = time.time()
        for e in self.endpoints:
            if e.available is None or now - e.last_probe > PROBE_EVERY:
                await self._probe_one(e)
        return self.available

    async def close(self):
        if self._session is not None and not self._session.closed:
            await self._session.close()

    def _best(self, tiers: list, model: str = "", allow_saturated: bool = False):
        """The best available endpoint ranked for all tiers and serving model."""
        best, best_key = None, None
        for e in self.endpoints:
            if not e.available or not e.serves(model):
                continue
            if any(e.rank.get(t, 0) <= 0 for t in tiers):
                continue
            free = e.inflight < e.max_inflight
            if not free and not allow_saturated:
                continue
            # A night job running here: others first for live/bg traffic.
            busy_night = e.night_inflight > 0 and "night" not in tiers
            key = (0 if busy_night else 1, 1 if free else 0, e.rank.get(tiers[0], 0), -e.inflight)
            if best_key is None or key > best_key:
                best, best_key = e, key
        return best

    def _pick(self, tier: str, model: str) -> Endpoint:
        if tier == "bg":
            return self._best(["bg"], model)          # a free slot or nothing
        e = self._best(["live"], model)
        if e is None:
            e = self._best(["live"], model, allow_saturated=True)   # a player waits: queue on the least loaded
        return e

    async def _wait_free(self, tier: str, model: str, budget: float):
        """Poll once a second for a free endpoint (re-probing when all are down) up to budget seconds; None if none frees."""
        deadline = time.monotonic() + budget
        while True:
            e = self._pick(tier, model)
            if e is not None:
                return e
            if time.monotonic() >= deadline:
                return None
            if not self.available:
                await self.probe()
            await asyncio.sleep(1.0)

    def _serving(self, kind: str):
        """(endpoint, model) of the first up endpoint serving an "embed"/"rerank" model, else (None, "")."""
        for e in self.endpoints:
            if not e.available:
                continue
            named = getattr(e, kind + "_model", "")
            if named and e.serves(named):
                return e, named
            found = next((n for n in e.models if kind in n.lower()), "")
            if found:
                return e, found
        return None, ""

    async def embed(self, texts: list):
        """Unit-normalised vectors for texts, or None when no embedder answers."""
        import numpy as np
        if not self.available:
            await self.probe()
        e, model = self._serving("embed")
        if e is None or not texts:
            return None
        try:
            s = await self._sess()
            async with s.post(e.url + "/v1/embeddings", headers=e.headers(),
                              json={"model": model, "input": list(texts)}) as r:
                if r.status != 200:
                    print(f"[LLM] {e.name} embeddings HTTP {r.status}")
                    return None
                data = await r.json()
        except Exception as ex:
            print(f"[LLM] {e.name} embeddings failed: {type(ex).__name__}")
            return None
        out = []
        for item in data.get("data", []):
            v = np.asarray(item.get("embedding", []), dtype=np.float32)
            n = np.linalg.norm(v)
            out.append(v / n if n > 0 else v)
        return out if len(out) == len(texts) else None

    async def rerank(self, query: str, documents: list):
        """A cross-encoder score per document, or None when no reranker answers."""
        if not documents:
            return []
        if not self.available:
            await self.probe()
        e, model = self._serving("rerank")
        if e is None:
            return None
        body = {"model": model, "query": query, "documents": list(documents)}
        for path in ("/v1/rerank", "/rerank"):
            data = await self._post_rerank(e, path, body)
            if data is _NOT_FOUND:
                continue
            if data is _FAILED:
                return None
            return _rerank_scores(data, len(documents))
        return None

    async def _post_rerank(self, e: Endpoint, path: str, body: dict):
        """The rerank response JSON, _NOT_FOUND on HTTP 404, or _FAILED."""
        try:
            s = await self._sess()
            async with s.post(e.url + path, json=body, headers=e.headers()) as r:
                if r.status == 404:
                    return _NOT_FOUND
                if r.status != 200:
                    print(f"[LLM] {e.name} rerank HTTP {r.status}")
                    return _FAILED
                return await r.json()
        except Exception as ex:
            print(f"[LLM] {e.name} rerank failed: {type(ex).__name__}")
            return _FAILED

    async def chat(self, system: str, messages: list, max_tokens: int = None, priority: bool = True,
                   tier: str = None, model: str = "", wait: float = 0.0) -> str:
        """A chat completion's text, or "" when unavailable, slotless (bg) or failed after a retry; max_tokens is never sent."""
        tier = tier or ("live" if priority else "bg")
        if tier == "night":
            tier = "live"
        if not self.available:
            await self.probe()
        tried = set()
        for _attempt in range(2):
            e = self._pick(tier, model)
            if e is None and wait > 0 and tier == "bg":
                e = await self._wait_free(tier, model, wait)
            if e is None or e.url in tried:
                return ""
            tried.add(e.url)
            use_model = e.resolve_model(model) if (model and e.serves(model)) else e.model
            body = {
                "model": use_model,
                "messages": [{"role": "system", "content": system}] + messages,
            }
            data = await self._post_chat(e, body)
            if data is _FAILED:
                continue
            try:
                content = data["choices"][0]["message"]["content"] or ""
            except (KeyError, IndexError):
                return ""
            if tier != "bg":
                print(f"[LLM] {tier} on {e.name}/{use_model}: {e.latency:.1f}s")
            return content.strip()
        return ""

    async def _post_chat(self, e: Endpoint, body: dict):
        """The completion JSON from one endpoint, or _FAILED (an exception marks it down)."""
        e.inflight += 1
        t0 = time.time()
        try:
            s = await self._sess()
            async with s.post(e.url + "/v1/chat/completions", json=body, headers=e.headers()) as r:
                if r.status != 200:
                    txt = await r.text()
                    print(f"[LLM] {e.name} HTTP {r.status}: {txt[:200]}")
                    return _FAILED
                return await r.json()
        except Exception as ex:
            print(f"[LLM] {e.name} request failed: {type(ex).__name__}: {str(ex)[:120]}")
            e.available = False
            e.fail_at = time.time()
            return _FAILED
        finally:
            e.inflight -= 1
            e.latency = time.time() - t0
