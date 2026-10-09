"""The city library: the CITY_TOOLS a resident can use to look things up, partly from the librarian project."""
import asyncio
import os
import sys
import time

from core import identity

LIBRARIAN_DIR = os.environ.get(
    "GAME_LIBRARIAN_DIR",
    identity.get("librarian_dir"))

_state = None          # None = not tried yet, False = unavailable, True = ready
_why = ""              # why it is unavailable, for the log
_toolspec = None
_ragsearch = None
_providers = None


def _boot() -> bool:
    """Import the librarian's modules once; True when they are usable."""
    global _state, _why, _toolspec, _ragsearch, _providers
    if _state is not None:
        return _state
    if not os.path.isdir(LIBRARIAN_DIR):
        _state, _why = False, f"no librarian at {LIBRARIAN_DIR} (drive not mounted?)"
        print(f"[Library] {_why} — the city keeps to its own lore")
        return False
    if LIBRARIAN_DIR not in sys.path:
        sys.path.insert(0, LIBRARIAN_DIR)
    t0 = time.time()
    try:
        from app.llm import toolspec as _ts, tools_native as _tn
        from app.rag import search as _rs
        from app.llm import providers as _pr
        _tn.register_all()
        _toolspec, _ragsearch, _providers = _ts, _rs, _pr
    except Exception as e:
        _state, _why = False, f"{type(e).__name__}: {e}"
        print(f"[Library] unavailable ({_why}) — the city keeps to its own lore")
        return False
    _state = True
    print(f"[Library] shelves open in {time.time() - t0:.2f}s "
          f"({len(_toolspec.all_tools())} borrowed tools, {len(CITY_TOOLS)} offered)")
    return True


def available() -> bool:
    return _boot()


async def warm():
    """Run one search off the event loop so the index loads at boot, not mid-answer."""
    if not _boot():
        return
    t0 = time.time()
    try:
        await asyncio.to_thread(_ragsearch.search, "the city by the sea", top_k=1)
        print(f"[Library] index warm in {time.time() - t0:.1f}s")
    except Exception as e:
        print(f"[Library] warm-up failed ({e}) — the first look-up will be slow")


# Tool functions take (args, ctx); ctx carries who is asking, which the model cannot set.

def _obj(props: dict, required: list) -> dict:
    return {"type": "object", "properties": props, "required": required}


def _borrow(name: str, args: dict, ctx: dict) -> str:
    """Run one of the librarian's own tools and hand back its observation."""
    ctx = dict(ctx or {})
    ctx.setdefault("user_id", 1)          # the librarian's single user
    out = _toolspec.execute(name, args, ctx)
    return out.get("observation", "")


def _t_lore(args, ctx):
    """The lore topic body for args["topic"]."""
    lore = ctx.get("lore")
    if lore is None:
        return "You know nothing beyond what you already said."
    topics = lore.lookup(str(args.get("topic", "")))
    if not topics:
        return ("Nothing in the city's common knowledge covers that. "
                "Say honestly that you do not know it.")
    return "\n\n".join(t.body for t in topics)


def _t_recall(args, ctx):
    """The asking resident's own memories about args["about"] (ctx["who"] only)."""
    mem, who = ctx.get("memory"), ctx.get("who")
    if mem is None or not who:
        return "You cannot bring anything to mind just now."
    loop = ctx.get("loop")
    coro = mem.context(who, str(args.get("about", "")), None, 4)
    try:
        if loop is not None:
            text = asyncio.run_coroutine_threadsafe(coro, loop).result(6)
        else:
            text = asyncio.run(coro)
    except Exception as e:
        return f"Nothing comes to mind ({type(e).__name__})."
    return text or "You do not remember anything about that."


def _t_look_up(args, ctx):
    return _borrow("search_library", {
        "query": args.get("query", ""),
        "top_k": min(int(args.get("top_k", 4) or 4), 6),
        "path_prefix": args.get("among", "") or None,
    }, ctx)


def _t_encyclopaedia(args, ctx):
    return _borrow("kiwix_search", {"query": args.get("query", ""),
                                    "zim": args.get("shelf", "") or None,
                                    "limit": 5}, ctx)


def _t_read_article(args, ctx):
    return _borrow("kiwix_read", {"zim": args.get("shelf", ""),
                                  "path": args.get("path", "")}, ctx)


def _t_read(args, ctx):
    return _borrow("read_file", {"path": args.get("path", ""),
                                 "max_chars": 4000}, ctx)


def _t_find_place(args, ctx):
    return _borrow("map_search", {"query": args.get("query", ""),
                                  "near": args.get("near", "") or None,
                                  "limit": 5}, ctx)


def _t_way_between(args, ctx):
    return _borrow("route", {"from_lat": args.get("from_lat"),
                             "from_lon": args.get("from_lon"),
                             "to_lat": args.get("to_lat"),
                             "to_lon": args.get("to_lon"),
                             "profile": args.get("on_foot") and "foot" or "car"}, ctx)


# name -> (description shown to the model, schema, fn, needs the librarian)
CITY_TOOLS = {
    "lore": (
        "What everyone in the city knows about one thing (the city itself, the "
        "school, the language, a person everyone knows). Try this first: it is "
        "instant and it is what a local would simply know.",
        _obj({"topic": {"type": "string"}}, ["topic"]), _t_lore, False),
    "recall": (
        "Search YOUR OWN memory — your life, the people you know, what has "
        "happened to you. Nobody else's.",
        _obj({"about": {"type": "string"}}, ["about"]), _t_recall, False),
    "look_up": (
        "Look something up in the city library: books, papers, documents and "
        "recordings on its shelves. For a fact you would have to go and read, "
        "not one you would already know.",
        _obj({"query": {"type": "string"},
              "among": {"type": "string",
                        "description": "narrow to a shelf, e.g. Books/"},
              "top_k": {"type": "integer"}}, ["query"]), _t_look_up, True),
    "encyclopaedia": (
        "The library's encyclopaedia and dictionary, for world knowledge and "
        "word meanings — places, history, science, anything outside the city.",
        _obj({"query": {"type": "string", "description": "in English"},
              "shelf": {"type": "string",
                        "description": "wikipedia | wiktionary; omit for both"}},
             ["query"]), _t_encyclopaedia, True),
    "read_article": (
        "Read one encyclopaedia article in full (use a path encyclopaedia gave).",
        _obj({"shelf": {"type": "string"}, "path": {"type": "string"}},
             ["shelf", "path"]), _t_read_article, True),
    "read": (
        "Read a book or document from the library's shelves (use a path look_up "
        "gave you).",
        _obj({"path": {"type": "string"}}, ["path"]), _t_read, True),
    "find_place": (
        "Find a real place on the map — a city, a town, a harbour, a mountain — "
        "and get where it is. For directions, and for anyone who guides visitors.",
        _obj({"query": {"type": "string"},
              "near": {"type": "string"}}, ["query"]), _t_find_place, True),
    "way_between": (
        "How far apart two places are and how long the journey takes, by road "
        "or on foot (coordinates from find_place).",
        _obj({"from_lat": {"type": "number"}, "from_lon": {"type": "number"},
              "to_lat": {"type": "number"}, "to_lon": {"type": "number"},
              "on_foot": {"type": "boolean"}},
             ["from_lat", "from_lon", "to_lat", "to_lon"]), _t_way_between, True),
}

ALWAYS = [n for n, spec in CITY_TOOLS.items() if not spec[3]]


def tools_for(key: str = "", card_meta: dict = None) -> list:
    """The tool names this resident may use: CITY_TOOLS, else ALWAYS; a card's "tools" key narrows them ("none" for none)."""
    names = list(CITY_TOOLS) if _boot() else list(ALWAYS)
    wanted = (card_meta or {}).get("tools")
    if wanted:
        if isinstance(wanted, str):
            wanted = [w.strip() for w in wanted.split(",")]
        wanted = {str(w).strip() for w in wanted if str(w).strip()}
        if "none" in wanted:
            return []
        names = [n for n in names if n in wanted] or list(ALWAYS)
    return names


def describe(names: list) -> str:
    """The tool list as the resident reads it in their prompt."""
    lines = []
    for n in names:
        desc, schema, _fn, _needs = CITY_TOOLS[n]
        props = schema.get("properties", {})
        required = set(schema.get("required", []))
        args = ", ".join(f"{k}{'' if k in required else '?'}: {v.get('type', 'any')}"
                         for k, v in props.items())
        lines.append(f"- {n}({args}) — {desc}")
    return "\n".join(lines)


def execute(name: str, args: dict, ctx: dict) -> str:
    """Run one CITY_TOOLS tool and return its observation text; never raises."""
    spec = CITY_TOOLS.get(name)
    if spec is None:
        return (f"There is no such thing as '{name}'. You may use: "
                + ", ".join(sorted(ctx.get("allowed") or CITY_TOOLS)) + ".")
    desc, schema, fn, needs_shelves = spec
    if needs_shelves and not _boot():
        return "The library is shut today. Answer from what you already know."
    if not isinstance(args, dict):
        return f"{name} takes named arguments, as a JSON object."
    missing = [k for k in schema.get("required", []) if args.get(k) in (None, "")]
    if missing:
        return f"{name} still needs: {', '.join(missing)}. Call it again with them."
    try:
        out = fn(args, ctx)
    except Exception as e:
        return f"{name} failed ({type(e).__name__}: {e}). Answer without it."
    out = out if isinstance(out, str) else str(out)
    return out[:4000] if len(out) > 4000 else out
