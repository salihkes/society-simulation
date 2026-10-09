"""The dense recall lane: embeddings from the shared LLM pool, when it serves an embedding model."""


class Embedder:
    def __init__(self, llm):
        self.llm = llm
        self.available = None
        self.model = ""

    async def probe(self) -> bool:
        """Check whether an embedding model is served; log on/off changes."""
        if self.llm is None:
            self.available = False
            return False
        if not self.llm.available:
            await self.llm.probe()
        endpoint, model = self.llm._serving("embed")
        was = self.available
        self.available = endpoint is not None
        self.model = model
        if self.available and not was:
            print(f"[Memory] dense lane on: '{model}' at {endpoint.name}")
        elif was and not self.available:
            print("[Memory] dense lane off: no machine serves an embedding model")
        return self.available

    async def embed(self, texts: list):
        """Vectors for texts, or None when no embedding model is served."""
        if not await self.probe():
            return None
        return await self.llm.embed(texts)
