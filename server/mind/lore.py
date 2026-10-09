"""Common knowledge of the city: data/world/lore/*.md topics with name, aliases and summary frontmatter."""
import os
import re

try:
    import frontmatter
except Exception:      # optional: without it, files are read as plain text
    frontmatter = None


class Topic:
    def __init__(self, path: str):
        self.path = path
        text = open(path, encoding="utf-8").read()
        meta, body = {}, text
        if frontmatter is not None and text.startswith("---"):
            try:
                post = frontmatter.loads(text)
                meta, body = dict(post.metadata or {}), post.content
            except Exception:
                pass
        self.name = str(meta.get("name") or os.path.splitext(os.path.basename(path))[0])
        self.summary = str(meta.get("summary", "")).strip()
        aliases = meta.get("aliases") or []
        if isinstance(aliases, str):
            aliases = [a.strip() for a in aliases.split(",")]
        self.aliases = [str(a).strip() for a in aliases if str(a).strip()] + [self.name]
        self.body = body.strip()

    def hits(self, text: str) -> int:
        """Score of alias occurrences in text; aliases under 2 characters never count."""
        low = text.lower()
        n = 0
        for a in self.aliases:
            al = a.lower()
            if len(al) < 2:
                continue
            if re.search(r"[^\x00-\x7f]", al):           # no word breaks: plain substring
                if al in text:
                    n += 2 if len(al) >= 3 else 1
            elif re.search(r"\b" + re.escape(al) + r"\b", low):
                n += 2 if " " in al or len(al) >= 6 else 1
        return n


class Lore:
    """All lore topics, reloaded when the folder changes."""

    def __init__(self, data_dir: str):
        self.dir = os.path.join(data_dir, "lore")
        self.topics: dict = {}
        self._stamp = None
        self.reload()

    def _signature(self):
        try:
            return tuple(sorted((f, os.path.getmtime(os.path.join(self.dir, f)))
                                for f in os.listdir(self.dir) if f.endswith(".md") and f != "README.md"))
        except OSError:
            return ()

    def reload(self):
        sig = self._signature()
        if sig == self._stamp:
            return
        self._stamp = sig
        topics = {}
        for f, _ in sig:
            try:
                t = Topic(os.path.join(self.dir, f))
                topics[t.name] = t
            except Exception as e:
                print(f"[Lore] {f}: {e}")
        self.topics = topics
        if topics:
            print(f"[Lore] {len(topics)} topics: " + ", ".join(sorted(topics)))

    def match(self, text: str, places=None, limit: int = 2) -> list:
        """Topics whose aliases occur in the text (or name a place the speaker is at)."""
        self.reload()
        scored = []
        probe = (text or "") + " " + " ".join(str(p) for p in (places or []))
        for t in self.topics.values():
            h = t.hits(probe)
            if h:
                scored.append((h, t.name, t))
        scored.sort(key=lambda x: (-x[0], x[1]))
        return [t for _, _, t in scored[:limit]]

    def lookup(self, query: str) -> list:
        """Best topic for a free-form query, by aliases then shared words."""
        self.reload()
        best = self.match(query, limit=1)
        if best:
            return best
        q = set(re.findall(r"[a-z]{3,}", (query or "").lower()))
        scored = []
        for t in self.topics.values():
            words = set(re.findall(r"[a-z]{3,}", (t.summary + " " + t.body).lower()))
            s = len(q & words)
            if s:
                scored.append((s, t))
        scored.sort(key=lambda x: -x[0])
        return [t for _, t in scored[:1]]

    @staticmethod
    def block(topics: list, full: bool = True) -> str:
        """Prompt block of the topics' bodies (or summaries when not full)."""
        if not topics:
            return ""
        parts = []
        for t in topics:
            parts.append((t.body if full else t.summary).strip())
        return "What everyone in the city knows:\n" + "\n\n".join(parts)

    def brief(self) -> str:
        self.reload()
        return "\n".join(f"- {t.summary}" for t in sorted(self.topics.values(), key=lambda t: t.name) if t.summary)

