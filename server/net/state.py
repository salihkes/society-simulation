"""Shared runtime state of the game server; use it as state.x so reassigned values stay shared."""

import json

from world.snow import SnowCache

clients = {}            # client_id -> record: websocket, username, position, ...
next_id = 1             # id handed to the next connection

objects = {}            # net_id -> {"transform": {...}}
ships = {}              # net_id -> origin, basis, velocity, name, hull_hp, shield_hp
monsters = {}           # net_id -> {"species", "position", "rotation", "texture", "owner_id"}

# The world process when connected, else the lowest-id player (npc.update_npc_authority).
npc_authority_client_id = -1
npc_transforms = {}     # npc_id -> {"x", "y", "z", "rot_y"}, for late joiners
npc_schedules = {}      # npc_id -> [{"hour", "waypoint", "action", "reason"}, ...]
npc_schedules_fetched = set()   # npc_ids whose schedule was fetched this run
npc_audio_playback = {}  # npc_id -> {"path", "started_at", "duration"}

# Latest ambient snapshot from the authority: peds, cars, trams, res, sigs,
# rest, sch, lifts, evt, weather.
ambient_state = {}
snow_cache = SnowCache()

pending_treaties = {}   # treaty_id -> {"proposer", "target", "expires_at"}
map_state = {"owners": [], "provinces": []}

plots_config = {}       # plot_id -> {"plot_id", "owner", "name"}
plot_geometry = {}      # plot_id -> polygon, floor, ceiling
plot_objects = {}       # plot_id -> {net_id -> object}

auth_manager = None     # AuthManager, set by startup.load_state()
world_mind = None       # mind.Mind, set by startup.load_state()


def is_world(client) -> bool:
    """True for the headless world process, which is never listed as a player."""
    return client.get("role") == "world"


async def broadcast(msg: dict, skip=None):
    """Send `msg` to every client but `skip`; a failed send raises."""
    payload = json.dumps(msg)
    for cid, client in list(clients.items()):
        if cid != skip:
            await client["websocket"].send(payload)


async def relay(msg: dict, skip=None):
    """Send `msg` to every client but `skip`, ignoring clients that fail."""
    payload = json.dumps(msg)
    for cid, client in list(clients.items()):
        if cid == skip:
            continue
        try:
            await client["websocket"].send(payload)
        except Exception:
            pass


async def send_all(msg: dict):
    """Send to every client, ignoring failures (the mind's broadcast)."""
    await relay(msg)


async def send_world(msg: dict):
    """Send to the NPC authority, if any (the mind's channel to the world)."""
    target = clients.get(npc_authority_client_id)
    if target is None:
        return
    try:
        await target["websocket"].send(json.dumps(msg))
    except Exception:
        pass


async def send_to(client_id: int, msg: dict):
    """Send to one client, ignoring a missing client or a failed send."""
    c = clients.get(client_id)
    if c is None:
        return
    try:
        await c["websocket"].send(json.dumps(msg))
    except Exception:
        pass


async def system_message(websocket, text: str):
    await websocket.send(json.dumps({"type": "system_message", "message": text}))
