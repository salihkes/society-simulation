"""The world's regions, from the game's regions.json, data/regions.json, or identity.json's fallback."""
import json
import os

from core import identity

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.environ.get("GAME_CLIENT_DIR") or os.path.normpath(os.path.join(HERE, "..", "..", "client"))
CANDIDATES = (
    os.path.join(GAME, "assets", "world", "region", "regions.json"),
    os.path.join(HERE, "..", "data", "regions.json"),
)

FALLBACK = identity.get("fallback_regions")

_cache = None


def catalog() -> dict:
    """The regions catalog, loaded once from the first usable candidate."""
    global _cache
    if _cache is None:
        _cache = _load_first()
    return _cache


def _load_first() -> dict:
    """The first candidate file with a non-empty regions list, else FALLBACK."""
    for path in CANDIDATES:
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and isinstance(data.get("regions"), list) and data["regions"]:
            return data
    print("[Regions] no regions.json found; using identity.json's fallback_regions")
    return FALLBACK


def ids() -> tuple:
    return tuple(str(r["id"]) for r in catalog()["regions"])


def home() -> str:
    return str(catalog().get("home", FALLBACK["home"]))


def region(region_id: str) -> dict:
    for r in catalog()["regions"]:
        if r.get("id") == region_id:
            return r
    return {}


def utc_offset(region_id: str = None) -> float:
    """A region's clock offset in hours (default region: home; default 0)."""
    value = region(region_id or home()).get("utc_offset", 0)
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0.0


def lonlat(region_id: str):
    ll = region(region_id).get("lonlat")
    return (float(ll[0]), float(ll[1])) if isinstance(ll, list) and len(ll) == 2 else None


def real_weather_regions() -> list:
    return [str(r["id"]) for r in catalog()["regions"] if r.get("real_weather")]
