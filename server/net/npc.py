"""NPCs: who simulates them, their replicated state, and talking to them."""

import asyncio
import json
import os
import time
from datetime import datetime

from services import assistant
from net import state
from net.weather import get_world_environment

# Block guests from talking to NPCs when true.
NPC_CHAT_REQUIRE_AUTH = os.environ.get("NPC_CHAT_REQUIRE_AUTH", "false").lower() == "true"

NEARBY_RADIUS = 100     # players this close count as near an NPC (world state)
HEARING_RADIUS = 150    # clients this close receive an NPC's reply

# Fixed list handed to the brain; not read from the plots config.
LANDMARKS = ["Market", "Town Center", "Park", "BuildingA"]


def _distance_sq(position, center):
    dx = position.get("x", 0) - center.get("x", 0)
    dz = position.get("z", 0) - center.get("z", 0)
    return dx * dx + dz * dz


def _current_weather():
    """The weather the world simulates in the home region, else the configured type."""
    try:
        from mind import regions
        regional = (state.ambient_state.get("weather") or {}).get("regional") or {}
        live = regional.get("states") or {}
        weather = str((live.get(regions.home()) or {}).get("type") or "")
        if not weather:
            w = get_world_environment().get("weather", {})
            weather = w.get("type", "clear") if isinstance(w, dict) else str(w)
        return weather
    except Exception:
        return "unknown"


def _schedule_text(npc_id):
    """An NPC's schedule as one readable line, or "" when it has none."""
    if npc_id not in state.npc_schedules:
        return ""
    parts = [f"At {e.get('hour', '?')}h go to {e.get('waypoint', '?')} ({e.get('action', 'idle')})"
             for e in state.npc_schedules[npc_id]]
    return "; ".join(parts)


def gather_world_state(npc_id: str, client_id: int) -> dict:
    """Live server facts handed to the NPC brain with each turn."""
    now = datetime.now()
    online = [c["username"] for c in state.clients.values() if not state.is_world(c)]
    npc_pos = state.npc_transforms.get(npc_id, {})
    nearby = []
    npc_location = ""
    if npc_pos:
        center = {"x": npc_pos.get("x", 0), "z": npc_pos.get("z", 0)}
        nearby = [c["username"] for c in list(state.clients.values())
                  if _distance_sq(c.get("position", {}), center) < NEARBY_RADIUS ** 2]
        npc_location = f"x={npc_pos.get('x', 0):.0f}, z={npc_pos.get('z', 0):.0f}"
    return {
        "time": now.strftime("%H:%M, %A"),
        "weather": _current_weather(),
        "online_players": online,
        "player_count": len(state.clients),
        "nearby_players": nearby,
        "npc_location": npc_location,
        "npc_schedule": _schedule_text(npc_id),
        "landmarks": LANDMARKS,
    }


async def _voice_turn(client_id: int, npc_id: str, username: str, audio_b64: str):
    """Send a voice turn to the Assistant (it does speech-to-text) and relay the reply."""
    world_state = gather_world_state(npc_id, client_id)
    result = await assistant.voice_chat(npc_id, username, audio_b64, world_state)
    await broadcast_npc_response(client_id, npc_id, username, result)


async def _text_turn(client_id: int, npc_id: str, username: str, message: str):
    print(f"[NpcChat] {username} -> {npc_id}: {message}")
    asyncio.ensure_future(ensure_npc_schedule(npc_id))
    world_state = gather_world_state(npc_id, client_id)
    result = await assistant.chat(npc_id, username, message, world_state)
    await broadcast_npc_response(client_id, npc_id, username, result)


async def ensure_npc_schedule(npc_id: str):
    """Fetch an NPC's schedule from the Assistant once per run and broadcast it; a failure retries next turn."""
    if not npc_id or npc_id in state.npc_schedules_fetched:
        return
    state.npc_schedules_fetched.add(npc_id)
    sched = await assistant.fetch_schedule(npc_id)
    if not sched:
        state.npc_schedules_fetched.discard(npc_id)
        return
    state.npc_schedules[npc_id] = sched
    await state.relay({"type": "npc_schedule", "npc_id": npc_id, "schedule": sched})


async def broadcast_npc_response(client_id: int, npc_id: str, username: str, result: dict | None):
    """Send an Assistant reply ({"text", "audio", "error"?}) near the NPC; None tells only the asker."""
    if result is None:
        if client_id in state.clients:
            await state.clients[client_id]["websocket"].send(json.dumps({
                "type": "npc_chat_response",
                "npc_id": npc_id,
                "message": "(NPC brain unavailable)",
                "error": True,
            }))
        return
    response_text = result.get("text", "")
    response_audio = result.get("audio")
    print(f"[NpcChat] {npc_id} -> {username}: {response_text}")
    msg_data = {
        "type": "npc_chat_response",
        "npc_id": npc_id,
        "message": response_text,
        "from_username": username,
    }
    if result.get("error"):
        msg_data["error"] = True
    if response_audio:
        msg_data["audio"] = response_audio
    msg = json.dumps(msg_data)
    npc_pos = state.npc_transforms.get(npc_id, {})
    for cid, client in list(state.clients.items()):
        try:
            if npc_pos and _distance_sq(client.get("position", {}), npc_pos) > HEARING_RADIUS ** 2:
                continue
            await client["websocket"].send(msg)
        except Exception:
            pass


async def update_npc_authority():
    """Elect the NPC authority (the world process, else the lowest client id) and broadcast a change."""
    if not state.clients:
        state.npc_authority_client_id = -1
        return
    worlds = [cid for cid, c in state.clients.items() if c.get("role") == "world"]
    new_authority = min(worlds) if worlds else min(state.clients.keys())
    if new_authority == state.npc_authority_client_id:
        return
    state.npc_authority_client_id = new_authority
    print(f"[NPC] Authority transferred to client {state.npc_authority_client_id}")
    asyncio.create_task(state.world_mind.on_world_reset())
    await state.relay({"type": "npc_authority",
                       "authority_client_id": state.npc_authority_client_id})


async def on_npc_transform(client_id, websocket, data):
    """From the authority: store NPC transforms for late joiners and relay them."""
    if client_id != state.npc_authority_client_id:
        return
    transforms = data.get("transforms", {})
    state.npc_transforms.update(transforms)
    await state.relay({"type": "npc_transform", "transforms": transforms}, skip=client_id)


async def on_npc_action_event(client_id, websocket, data):
    """From the authority: track NPC audio for late joiners and relay the event."""
    if client_id != state.npc_authority_client_id:
        return
    event = data.get("event", "")
    npc_id = data.get("npc_id", "")
    event_data = data.get("data", {})
    if event == "audio_play" and npc_id:
        state.npc_audio_playback[npc_id] = {
            "path": event_data.get("path", ""),
            "started_at": time.time(),
            "duration": event_data.get("duration", 0)
        }
    elif event == "audio_stop" and npc_id:
        state.npc_audio_playback.pop(npc_id, None)
    await state.relay({
        "type": "npc_action_event",
        "npc_id": npc_id,
        "event": event,
        "data": event_data
    }, skip=client_id)


async def on_npc_schedule(client_id, websocket, data):
    """Store a client-sent NPC schedule and relay it to the others."""
    npc_id = data.get("npc_id", "")
    sched = data.get("schedule", [])
    if not npc_id:
        return
    state.npc_schedules[npc_id] = sched
    await state.relay({"type": "npc_schedule", "npc_id": npc_id, "schedule": sched},
                      skip=client_id)


async def on_npc_voice_chat(client_id, websocket, data):
    """Start a voice turn with an NPC in the background."""
    npc_id = data.get("npc_id", "")
    audio_b64 = data.get("audio", "")
    username = state.clients[client_id]["username"]
    if npc_id and audio_b64:
        asyncio.ensure_future(_voice_turn(client_id, npc_id, username, audio_b64))


async def on_npc_chat(client_id, websocket, data):
    """Start a text turn with an NPC in the background (guests refused when required)."""
    npc_id = data.get("npc_id", "")
    message = data.get("message", "").strip()
    username = state.clients[client_id]["username"]
    if NPC_CHAT_REQUIRE_AUTH and not state.clients[client_id].get("authenticated", False):
        await websocket.send(json.dumps({
            "type": "npc_chat_response",
            "npc_id": npc_id,
            "message": "You must be logged in to talk to NPCs.",
            "error": True
        }))
    elif npc_id and message:
        asyncio.ensure_future(_text_turn(client_id, npc_id, username, message))


async def on_npc_dialog(client_id, websocket, data):
    """Answer a click on an NPC with the canned greeting; real talk goes through the mind."""
    target = str(data.get("target", ""))
    if not target:
        return
    try:
        await websocket.send(json.dumps({"type": "npc_say", "id": target, "line": "greet_q"}))
    except Exception:
        pass
