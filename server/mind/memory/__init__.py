"""Durable, selective memory for the residents: raw stream, a shelf of facts, recall and nightly consolidation."""
import os
import time

from .consolidate import Consolidator
from .embed import Embedder
from .recall import recall as _recall
from .store import MemoryStore

EMBED_REPROBE = 300.0      # seconds between checks for an embedding model


class Memory:
    def __init__(self, data_dir: str, llm, display_name=None, card=None, known=None):
        self.store = MemoryStore(os.path.join(data_dir, "memory"))
        self.llm = llm
        self.embedder = Embedder(llm)
        self._embedder_on = None
        self._embed_probed = 0.0
        self.consolidator = Consolidator(self.store, llm, None, display_name, card, known)
        self._busy: set = set()

    async def _emb(self):
        """The embedder, or None; re-probed every EMBED_REPROBE seconds so a model that comes up later turns the dense lane on."""
        now = time.time()
        if self._embedder_on is None or now - self._embed_probed > EMBED_REPROBE:
            self._embed_probed = now
            self._embedder_on = await self.embedder.probe()
            self.consolidator.embedder = self.embedder if self._embedder_on else None
        return self.embedder if self._embedder_on else None

    async def recall(self, who: str, query: str, anchors=None, top_k: int = 5) -> list:
        return await _recall(self.store, await self._emb(), who, query, anchors,
                             top_k=top_k, llm=self.llm)

    async def context(self, who: str, query: str, anchors=None, top_k: int = 5) -> str:
        """Prompt block: the durable memories that matter for this moment."""
        mems = await self.recall(who, query, anchors, top_k)
        if not mems:
            return ""
        lines = []
        for m in mems:
            body = m["content"].split("\n\nRelated:")[0].split("\n\nSources:")[0].strip()
            when = time.strftime("%Y-%m-%d", time.localtime(m["created"]))
            lines.append(f"- ({m['type']}, {when}) {body[:400]}")
        return "\n".join(lines)

    async def consolidate(self, who: str, tier: str = "night", model: str = "") -> dict:
        """Run one consolidation pass for who; skipped if one is already running."""
        if who in self._busy:
            return {"who": who, "skipped": "busy"}
        self._busy.add(who)
        try:
            await self._emb()
            return await self.consolidator.run(who, tier=tier, model=model)
        finally:
            self._busy.discard(who)

    def raw_count_since_harvest(self, who: str) -> int:
        """Raw stream entries not yet harvested (capped at 100000)."""
        return len(self.store.raw_since(who, self.store.harvested_ts(who), limit=100000))
