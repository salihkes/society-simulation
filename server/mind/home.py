"""The mind's side of a home: needs a house answers, what a use restores, a day at home as intents."""

# Game hours for a home need to go from fresh (0) to pressing (1); hunger has its own rule in brain.py.
NEED_HOURS = {"hygiene": 16.0, "comfort": 6.0, "fun": 10.0, "bladder": 4.0}


def answerable_needs(has_home: bool, can_eat_out: bool) -> set:
    """Only the needs something can answer; an unanswerable need would climb to 1 and stay."""
    out = set(NEED_HOURS) if has_home else set()
    if has_home or can_eat_out:
        out.add("hunger")
    return out


def apply_restores(needs: dict, life_state, restores: dict):
    """Lower the needs a used object restores; "energy" lowers fatigue."""
    for k, v in (restores or {}).items():
        try:
            v = float(v)
        except (TypeError, ValueError):
            continue
        if k == "energy":
            if isinstance(life_state, dict):
                life_state["fatigue"] = max(0.0, float(life_state.get("fatigue", 0.0)) - v)
        elif k in needs and isinstance(needs.get(k), (int, float)) and not isinstance(needs.get(k), bool):
            needs[k] = max(0.0, float(needs[k]) - v)


def _household_room(household: dict, rid: str) -> str:
    """The room a household gives this person: their own, else the first shared."""
    room, shared = "", ""
    for name, who in (household.get("rooms") or {}).items():
        if who == "shared" and not shared:
            shared = name
        elif who not in ("shared", "threshold", "guest") and rid in [w.strip() for w in str(who).split(",")]:
            room = name
    return room or shared


def home_intents(resident: dict, household, key: str, why: str, in_bed: bool) -> list:
    """A day at home: the person's household room, else their routine's home marker, by its door."""
    rid = key[2:] if key.startswith("r_") else key
    room, door = "", ""
    if household:
        door = str(household.get("door", ""))
        room = _household_room(household, rid)
    if not room:
        for e in (resident or {}).get("routine", []):
            if e.get("marker") and e.get("door"):
                room, door = str(e["marker"]), str(e["door"])
                break
    if not room:
        return []
    intent = {"at": 0.0, "do": "sleep" if in_bed else "stay", "marker": room, "name": why}
    if door:
        intent["door"] = door
    if in_bed:
        intent["use"] = "sleep"
    return [intent]
