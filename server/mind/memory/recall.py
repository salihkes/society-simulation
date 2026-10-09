"""Per-turn recall: anchor, keyword and dense lanes fused by RRF, weighted by activation, reranked, spread one hop."""
import re

from . import activation

RRF_K = 60


def _fts_query(q: str) -> str:
    """An FTS5 OR-query of the words in q, plus 2-grams of CJK words."""
    terms = re.findall(r"[\w']+", q or "", re.UNICODE)
    # CJK text has no spaces: add 2-grams so Japanese words still match.
    grams = []
    for t in terms:
        if re.search(r"[ぁ-ヿ㐀-鿿]", t) and len(t) > 2:
            grams += [t[i:i + 2] for i in range(len(t) - 1)]
    terms = (terms + grams)[:24]
    return " OR ".join('"' + t.replace('"', '') + '"' for t in terms) if terms else '""'


def _lex_lane(store, who: str, query: str, limit=24) -> list:
    """Memory names matching the query by keyword, best first; [] on error."""
    try:
        rows = store.db().execute(
            "SELECT name FROM facts_fts WHERE facts_fts MATCH ? AND who=? "
            "ORDER BY bm25(facts_fts) LIMIT ?", (_fts_query(query), who, limit)).fetchall()
        return [r["name"] for r in rows]
    except Exception:
        return []


async def _dense_lane(store, embedder, who, query, mems, min_score) -> list:
    """(name, similarity) of memories close to the query, best first."""
    if embedder is None or not query:
        return []
    vecs = store.vectors(who)
    if not vecs:
        return []
    qv = await embedder.embed([query])
    if not qv:
        return []
    scored = sorted(((float(v @ qv[0]), n) for n, v in vecs.items()
                     if v.shape[0] == qv[0].shape[0]), reverse=True)
    return [(n, s) for s, n in scored if s >= min_score and n in mems]


async def _rerank(llm, query, ranked, mems, act):
    """Reorder ranked by a cross-encoder; returns (ranked, set of reranked names)."""
    if llm is None or not query or len(ranked) <= 1:
        return ranked, set()
    try:
        docs = [f"{mems[n]['description']}\n{mems[n]['content'][:1500]}" for n in ranked]
        scores = await llm.rerank(query, docs)
        if scores and len(scores) == len(ranked):
            rr = {n: s * (0.75 + 0.25 * act.get(n, 0.5)) for n, s in zip(ranked, scores)}
            ranked = sorted(ranked, key=lambda n: -rr[n])
            return ranked, set(ranked)
    except Exception as e:
        print(f"[Memory] reranker skipped: {type(e).__name__}: {e}")
    return ranked, set()


def _reasons(n, anchored, dense_names, lex, reranked) -> list:
    """Why a ranked memory qualifies; empty when no lane found it."""
    why = []
    if n in anchored:
        why.append("anchored")
    if n in dense_names:
        why.append("semantic")
    if n in lex:
        why.append("keyword")
    if n in reranked and why:
        why.append("reranked")
    return why


def _spread(picked, reasons, mems, cap):
    """Append linked memories of the picked ones until cap is reached."""
    for n in list(picked):
        for ln in mems.get(n, {}).get("links", []):
            if len(picked) >= cap:
                break
            if ln in mems and ln not in picked:
                picked.append(ln)
                reasons[ln] = f"linked from {n}"


async def recall(store, embedder, who: str, query: str, anchors=None,
                 top_k: int = 5, min_score: float = 0.30, spread_max: int = 2,
                 llm=None) -> list:
    """The memories relevant to this query with "score" and "reason"; each unpinned one is recorded as recalled."""
    anchors = set(anchors or [])
    mems = {m["name"]: m for m in store.list(who, status="active")}
    if not mems:
        return []
    dense = await _dense_lane(store, embedder, who, query, mems, min_score)
    lex = [n for n in _lex_lane(store, who, query) if n in mems] if query else []
    anchored = [n for n, m in mems.items() if anchors & set(m["anchors"])] if anchors else []
    pinned = [n for n, m in mems.items() if m["pinned"]]
    fused: dict = {}

    def fuse(names, weight=1.0):
        for rank, n in enumerate(names):
            fused[n] = fused.get(n, 0.0) + weight / (RRF_K + rank + 1)
    fuse([n for n, _ in dense])
    fuse(lex)
    fuse(sorted(anchored), weight=2.0)
    act = activation.normalized(store, who)

    def score(n):
        return fused.get(n, 0.0) * (0.55 + 0.45 * act.get(n, 0.5))
    ranked = sorted(fused, key=lambda n: -score(n))[:16]
    ranked, reranked = await _rerank(llm, query, ranked, mems, act)

    picked = list(pinned)
    reasons = {n: "pinned" for n in pinned}
    dense_names = {n for n, _ in dense}
    for n in ranked:
        if len(picked) >= top_k + len(pinned):
            break
        if n in picked:
            continue
        why = _reasons(n, anchored, dense_names, lex, reranked)
        if not why:
            continue
        picked.append(n)
        reasons[n] = "+".join(why)
    _spread(picked, reasons, mems, top_k + len(pinned) + spread_max)
    out = []
    for n in picked:
        m = dict(mems[n])
        m["score"] = round(float(score(n)), 4)
        m["reason"] = reasons[n]
        out.append(m)
    if out:
        store.record(who, [m["name"] for m in out if m["reason"] != "pinned"], "recalled")
    return out
