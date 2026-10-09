"""Messages to and from the world process: the ambient city, its reports, and requests the NPC authority applies."""

import asyncio
import json
import os

from core import identity
from net import plots, state
from net.npc import update_npc_authority

# Ambient snapshot fields replicated as sent, with their empty values.
AMBIENT_FIELDS = (("peds", {}), ("cars", {}), ("trams", {}), ("res", {}), ("sigs", []),
                  ("rest", {}), ("sch", {}), ("lifts", {}), ("evt", {}))

# The one account that may convene or adjourn the legislature; everyone else watches.
SOVEREIGN = os.environ.get("GAME_SOVEREIGN", identity.get("sovereign_user"))

ELEVATOR_FLOORS = 6


def ambient_snapshot(initial=False):
    """The cached ambient state as an amb_state message; `initial` marks a join catch-up."""
    msg = {"type": "amb_state"}
    if initial:
        msg["initial"] = True
    for key, empty in AMBIENT_FIELDS:
        msg[key] = state.ambient_state.get(key, empty)
    weather = state.ambient_state.get("weather", {})
    msg["weather"] = state.snow_cache.weather_for_join(weather) if initial else weather
    return msg


async def on_amb_state(client_id, websocket, data):
    """From the authority: replace (not merge, so despawns propagate) the ambient snapshot and relay it, minus rejected snow."""
    if client_id != state.npc_authority_client_id:
        return
    for key, empty in AMBIENT_FIELDS:
        state.ambient_state[key] = data.get(key, empty)
    weather = dict(data.get("weather", {}))
    if "snow" in weather and not state.snow_cache.accept(weather["snow"]):
        weather.pop("snow")
    state.ambient_state["weather"] = weather
    await state.relay(ambient_snapshot(), skip=client_id)


async def on_npc_say(client_id, websocket, data):
    """From the authority: a line a resident speaks, relayed so every player hears it."""
    if client_id == state.npc_authority_client_id:
        await state.relay(data, skip=client_id)


async def on_world_places(client_id, websocket, data):
    """From the authority: the city's places, for the mind and for plot geometry."""
    if client_id != state.npc_authority_client_id:
        return
    await state.world_mind.on_world_report(data)
    await plots.apply_reported_plots(data.get("places", []))


async def on_world_obs(client_id, websocket, data):
    """From the authority: what residents noticed this second, for the mind."""
    if client_id == state.npc_authority_client_id:
        await state.world_mind.on_observations(data)


async def on_mind_cmd(client_id, websocket, data):
    """A tools/run/mindctl.py command for the mind; unauthenticated, meant for loopback only."""
    async def reply(msg):
        await state.send_to(client_id, msg)
    data["_client"] = client_id   # a rehearsal ends when the client that began it leaves
    asyncio.create_task(state.world_mind.command(data, reply))


async def _to_authority(data):
    """Forward a message unchanged to the NPC authority, ignoring failures."""
    target = state.clients.get(state.npc_authority_client_id)
    if target is None:
        return
    try:
        await target["websocket"].send(json.dumps(data))
    except Exception:
        pass


async def on_res_plan(client_id, websocket, data):
    """Intents for a resident, forwarded to the authority. Any client may send one."""
    await _to_authority(data)


async def on_world_cmd(client_id, websocket, data):
    """A studio panel command (events, population), forwarded to the authority."""
    await _to_authority(data)


async def _open_computer(client_id, pc_id):
    who = state.clients.get(client_id, {}).get("username", f"Guest{client_id}")
    await state.send_to(client_id, await state.world_mind.computers.open_for_player(pc_id, who))


async def _close_computer(client_id, pc_id):
    who = state.clients.get(client_id, {}).get("username", f"Guest{client_id}")
    await state.world_mind.computers.close_for_player(pc_id, who)


async def on_pc_open(client_id, websocket, data):
    """A player sits at a computer: the mind opens a session and replies with its socket."""
    asyncio.create_task(_open_computer(client_id, str(data.get("id", ""))))


async def on_pc_close(client_id, websocket, data):
    asyncio.create_task(_close_computer(client_id, str(data.get("id", ""))))


async def on_npc_addr(client_id, websocket, data):
    """A player addressed (or let go of) a person; the server stamps who it was."""
    data["p"] = state.clients.get(client_id, {}).get("username") or data.get("p", "")
    await state.relay(data, skip=client_id)


async def on_elevator_req(client_id, websocket, data):
    """Relay a valid floor request with the server-known username; the authority checks range."""
    floor = data.get("floor")
    is_int = isinstance(floor, int) and not isinstance(floor, bool)
    if not (is_int and 0 <= floor < ELEVATOR_FLOORS):
        return
    await state.relay({"type": "elevator_req", "id": str(data.get("id", "")), "floor": floor,
                       "username": state.clients.get(client_id, {}).get("username", "")},
                      skip=client_id)


async def on_relay_to_others(client_id, websocket, data):
    await state.relay(data, skip=client_id)


async def _parliament_ack(websocket, ok, text):
    await websocket.send(json.dumps({"type": "parliament_ack", "ok": ok, "text": text}))


async def on_parliament_req(client_id, websocket, data):
    """Seating ops relay to the authority; "submit" and "adjourn" are the sovereign's alone."""
    op = str(data.get("op", ""))
    if op not in ("submit", "adjourn"):
        await state.relay(data, skip=client_id)
        return
    who = state.clients.get(client_id, {}).get("username") or ""
    if who != SOVEREIGN:
        try:
            await _parliament_ack(websocket, False,
                                  "only the sovereign may put a matter to the house")
        except Exception:
            pass
        return
    await state.world_mind.command({
        "cmd": "sitting",
        "op": "stop" if op == "adjourn" else "start",
        "matter": str(data.get("matter", "")),
        "house": str(data.get("house", "both")),
    }, lambda m: _parliament_ack(websocket, m.get("ok", False), m.get("text", "")))


async def on_handshake(client_id, websocket, data):
    """A connection declaring itself the world process takes the authority."""
    if data.get("role") == "world" and not state.is_world(state.clients[client_id]):
        state.clients[client_id]["role"] = "world"
        state.clients[client_id]["username"] = "[world]"
        await update_npc_authority()
