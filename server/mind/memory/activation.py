"""ACT-R activation over memories: A = ln(sum_j w_j * (age_days_j + eps)^-0.5); nothing here deletes."""
import math
import time

WEIGHTS = {"created": 2.0, "recalled": 0.3, "read": 1.0,
           "edited": 1.5, "confirmed": 2.0}
MAX_EVENTS = 64
EPS_DAYS = 0.08
DECAY = 0.5


def raw(store, who: str) -> dict:
    """Activation A per memory name for one person."""
    now = time.time()
    per: dict = {}
    for name, kind, weight, ts in store.events(who):
        ev = per.setdefault(name, [])
        if len(ev) < MAX_EVENTS:
            ev.append((weight, ts))
    acts = {}
    for name, evs in per.items():
        mass = sum(w * (max((now - ts) / 86400.0, 0.0) + EPS_DAYS) ** -DECAY for w, ts in evs)
        acts[name] = math.log(mass) if mass > 0 else -10.0
    return acts


def normalized(store, who: str) -> dict:
    """Activation per memory name, squashed into [0, 1] by a logistic."""
    return {n: 1.0 / (1.0 + math.exp(-a)) for n, a in raw(store, who).items()}


def last_touch(store, who: str) -> dict:
    """Timestamp of the latest non-creation touch per memory name."""
    out = {}
    for name, kind, weight, ts in store.events(who):
        if kind in ("read", "recalled", "edited", "confirmed") and ts > out.get(name, 0.0):
            out[name] = ts
    return out


def seed_missing(store, who: str, name_created: dict):
    """Give a "created" event to every named memory that has no events yet."""
    have = {name for name, _, _, _ in store.events(who)}
    for name, created in name_created.items():
        if name not in have:
            store.db().execute("INSERT INTO events(who, name, kind, weight, ts) VALUES(?,?,?,?,?)",
                               (who, name, "created", WEIGHTS["created"], created))
    store.db().commit()
