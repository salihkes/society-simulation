"""One game connection; without SECURE_HANDSHAKE a client joins at once and is dropped if no key arrives in time."""

import asyncio
import json
import random
import time

import websockets

from world import countryballs
from core.constants import CLIENT_KEY, DEFAULT_CHARACTER_TYPE, SECURE_HANDSHAKE, VOICE_CHAT_SERVER_URL
from net import (accounts, chat, npc, places, players, plots, replication, state, world,
                 world_map)
from net.npc import update_npc_authority
from net.weather import get_world_environment
from net.world import ambient_snapshot
from services.pck import get_manifest_for_client
from world.plots import get_plot_info_for_client
from world.textures import send_flag_texture_data, send_texture_data

KEY_TIMEOUT_SECONDS = 15

HANDLERS = {
    "register": accounts.on_register,
    "login": accounts.on_login,
    "token_login": accounts.on_token_login,
    "get_texture": players.on_get_texture,
    "transform_update": players.on_transform_update,
    "chat_message": chat.on_chat_message,
    "get_players": players.on_get_players,
    "join_place": places.on_join_place,
    "list_places": places.on_list_places,
    "upload_place": places.on_upload_place,
    "upload_decal": players.on_upload_decal,
    "place_plot_object": plots.on_place_plot_object,
    "remove_plot_object": plots.on_remove_plot_object,
    "update_plot_object": plots.on_update_plot_object,
    "object_grab": replication.on_object_grab,
    "object_release": replication.on_object_release,
    "object_update": replication.on_object_update,
    "ship_transform": replication.on_ship_transform,
    "ship_board": replication.on_ship_board,
    "ship_depart": replication.on_ship_depart,
    "combat_bolt": replication.on_combat_event,
    "combat_weapon": replication.on_combat_event,
    "combat_saber_xf": replication.on_combat_event,
    "combat_health": replication.on_combat_event,
    "combat_ship_damage": replication.on_combat_ship_damage,
    "monster_spawn": replication.on_monster_spawn,
    "monster_update": replication.on_monster_update,
    "monster_despawn": replication.on_monster_despawn,
    "npc_transform": npc.on_npc_transform,
    "amb_state": world.on_amb_state,
    "npc_say": world.on_npc_say,
    "world_places": world.on_world_places,
    "world_obs": world.on_world_obs,
    "mind_cmd": world.on_mind_cmd,
    "res_plan": world.on_res_plan,
    "world_cmd": world.on_world_cmd,
    "pc_open": world.on_pc_open,
    "pc_close": world.on_pc_close,
    "npc_addr": world.on_npc_addr,
    "elevator_req": world.on_elevator_req,
    "school_req": world.on_relay_to_others,
    "parliament_req": world.on_parliament_req,
    "rest_req": world.on_relay_to_others,
    "handshake": world.on_handshake,
    "npc_dialog": npc.on_npc_dialog,
    # Player cars: owners re-announce vehicle_spawn every 2 s, so no cache is kept.
    "vehicle_spawn": world.on_relay_to_others,
    "vehicle_transform": world.on_relay_to_others,
    "vehicle_enter": world.on_relay_to_others,
    "vehicle_exit": world.on_relay_to_others,
    "vehicle_despawn": world.on_relay_to_others,
    "npc_action_event": npc.on_npc_action_event,
    "npc_schedule": npc.on_npc_schedule,
    "npc_voice_chat": npc.on_npc_voice_chat,
    "npc_chat": npc.on_npc_chat,
    "map_full_update": world_map.on_map_full_update,
    "map_request_state": world_map.on_map_request_state,
    "treaty_propose": world_map.on_treaty_propose,
    "treaty_respond": world_map.on_treaty_respond,
    "get_player_monsters": players.on_get_player_monsters,
}


def _new_client(client_id, websocket, role):
    """A fresh, unauthenticated client record at a random spawn point."""
    return {
        "websocket": websocket,
        "username": "[world]" if role == "world" else f"Guest{client_id}",
        "role": role,
        "authenticated": False,
        "position": {"x": random.uniform(-5, 5), "y": 10, "z": random.uniform(-5, 5)},
        "rotation": {"x": 0, "y": 0, "z": 0},
        "texture": None,
        "character_type": DEFAULT_CHARACTER_TYPE,
        "character_scale": 1.0,
        "key_validated": True,  # admission happens only once the key is accepted
        "on_ship": False,
        "ship_id": "",
    }


async def _send_player_textures(client_id):
    """Send the newcomer every other player's texture (their flag for flag wearers)."""
    newcomer = [state.clients[client_id]]
    for existing_id, existing in list(state.clients.items()):
        if existing_id == client_id or not existing.get("texture"):
            continue
        username = existing["username"]
        character_type = existing.get("character_type", "countryball")
        if not countryballs.wears_flag(character_type):
            await send_texture_data(username, character_type, newcomer)
            continue
        flag_code = existing.get("flag_code", "")
        if flag_code:
            await send_flag_texture_data(username, flag_code, newcomer, character_type)


async def _send_replicated(websocket):
    for net_id, obj in state.objects.items():
        await websocket.send(json.dumps({
            "type": "object_spawn",
            "net_id": net_id,
            "transform": obj.get("transform", {})
        }))
    for net_id, m in state.monsters.items():
        await websocket.send(json.dumps({
            "type": "monster_spawn",
            "monster_data": {
                "net_id": net_id,
                "species": m.get("species", "countryball"),
                "position": m.get("position", {"x": 0, "y": 0, "z": 0}),
                "rotation": m.get("rotation", {"x": 0, "y": 0, "z": 0}),
                "texture": m.get("texture", "")
            }
        }))
    for net_id, ship in state.ships.items():
        await websocket.send(json.dumps({
            "type": "ship_state",
            "net_id": net_id,
            "origin": ship.get("origin", {}),
            "basis_x": ship.get("basis_x", {}),
            "basis_y": ship.get("basis_y", {}),
            "basis_z": ship.get("basis_z", {}),
            "velocity": ship.get("velocity", {}),
            "ship_name": ship.get("ship_name", ""),
            "hull_hp": ship.get("hull_hp", replication.DEFAULT_HULL_HP),
            "shield_hp": ship.get("shield_hp", replication.DEFAULT_SHIELD_HP)
        }))


async def _send_plots(websocket):
    await websocket.send(json.dumps({
        "type": "plots_info",
        "plots": get_plot_info_for_client(state.plots_config)
    }))
    for plot_id, objects in state.plot_objects.items():
        for net_id, obj in objects.items():
            await websocket.send(json.dumps({
                "type": "plot_object_spawn",
                "plot_id": plot_id,
                "net_id": net_id,
                "transform": obj.get("transform", {}),
                "object_type": obj.get("object_type", "unknown")
            }))


async def _send_environment(websocket):
    weather_data = get_world_environment().get("weather", {"type": "clear"})
    await websocket.send(json.dumps({"type": "weather_update", "initial": True,
                                     "weather": weather_data}))
    await websocket.send(json.dumps({"type": "pck_manifest",
                                     "manifest": get_manifest_for_client(use_ssl=True)}))
    await websocket.send(json.dumps({"type": "map_state", "state": state.map_state}))


async def _announce_join(client_id, role):
    """Tell everyone else a player joined; the world process is not announced."""
    me = state.clients[client_id]
    for existing_id, existing in list(state.clients.items()):
        if existing_id == client_id or role == "world":
            continue
        await existing["websocket"].send(json.dumps({
            "type": "player_joined",
            "player_id": client_id,
            "username": me["username"],
            "position": me["position"],
            "rotation": me["rotation"],
            "texture": me["texture"],
            "accessories": me.get("accessories", []),
            "character_type": me["character_type"],
            "character_scale": me.get("character_scale", 1.0)
        }))


async def _send_npc_state(websocket):
    """Send NPC positions, schedules and playing audio; positions first, before AI runs."""
    if state.npc_transforms:
        await websocket.send(json.dumps({"type": "npc_initial_state",
                                         "transforms": state.npc_transforms}))
    for npc_id, sched in state.npc_schedules.items():
        await websocket.send(json.dumps({"type": "npc_schedule", "npc_id": npc_id,
                                         "schedule": sched}))
    for npc_id, playback in state.npc_audio_playback.items():
        elapsed = time.time() - playback["started_at"]
        duration = playback.get("duration", 0)
        if elapsed < duration:
            await websocket.send(json.dumps({
                "type": "npc_audio_sync",
                "npc_id": npc_id,
                "path": playback["path"],
                "offset": elapsed,
                "duration": duration
            }))


def _has_ambient():
    a = state.ambient_state
    return bool(a.get("peds") or a.get("cars") or a.get("trams") or a.get("res")
                or a.get("lifts") or a.get("weather"))


async def admit_client(client_id, websocket, role=""):
    """Add a client, send it the whole game state and announce it; role "world" is never announced and always NPC authority."""
    state.clients[client_id] = _new_client(client_id, websocket, role)
    me = state.clients[client_id]
    await websocket.send(json.dumps({
        "type": "connected",
        "client_id": client_id,
        "username": me["username"],
        "authenticated": False,
        "character_type": me["character_type"],
        "voice_chat_server": VOICE_CHAT_SERVER_URL
    }))
    await websocket.send(json.dumps({
        "type": "player_list",
        "players": players.player_list(client_id, DEFAULT_CHARACTER_TYPE)
    }))
    await _send_player_textures(client_id)
    await _send_replicated(websocket)
    await _send_plots(websocket)
    await _send_environment(websocket)
    print(f"[+] {me['username']} joined  ({len(state.clients)} online)")
    await _announce_join(client_id, role)
    print(f"[Admit] Client {client_id} admitted as {me['username']}")
    await _send_npc_state(websocket)
    await update_npc_authority()
    # Sent even when unchanged; otherwise the client assumes authority itself.
    if state.npc_authority_client_id >= 0:
        await websocket.send(json.dumps({"type": "npc_authority",
                                         "authority_client_id": state.npc_authority_client_id}))
    try:
        await websocket.send(json.dumps(state.world_mind.clock.message()))
    except Exception:
        pass
    if _has_ambient():
        await websocket.send(json.dumps(ambient_snapshot(initial=True)))


async def _await_client_key(client_id, websocket):
    """The first message once it carries the client key; None on close, a wrong key (closed) or timeout."""
    print(f"[Security] Connection from limbo client (pending ID {client_id}), "
          f"waiting for client key...")
    admitted = False

    async def kick():
        await asyncio.sleep(KEY_TIMEOUT_SECONDS)
        if not admitted:
            print(f"[Security] Limbo client {client_id} sent no valid key within "
                  f"{KEY_TIMEOUT_SECONDS}s, disconnecting")
            await websocket.close(4002, "Timeout")

    kick_task = asyncio.ensure_future(kick())
    try:
        async for raw_message in websocket:
            try:
                data = json.loads(raw_message)
            except json.JSONDecodeError:
                continue
            if data.get("ck") != CLIENT_KEY:
                print(f"[Security] Invalid/missing client key from limbo client {client_id}, "
                      f"disconnecting")
                await websocket.close(4001, "Invalid client")
                return None
            admitted = True
            kick_task.cancel()
            return data
    except websockets.exceptions.ConnectionClosed:
        pass
    if not kick_task.done():
        kick_task.cancel()
    return None


async def _kick_unvalidated(client_id, websocket):
    """Close a client that has sent no valid client key after KEY_TIMEOUT_SECONDS."""
    await asyncio.sleep(KEY_TIMEOUT_SECONDS)
    if client_id in state.clients and not state.clients[client_id].get("key_validated"):
        print(f"[Security] Client {client_id} sent no valid client key within "
              f"{KEY_TIMEOUT_SECONDS}s, disconnecting")
        await websocket.close(4002, "Timeout")


async def _messages(websocket, queued):
    """The already-read messages first, then each message parsed off the socket."""
    for data in queued:
        yield data
    async for raw in websocket:
        yield json.loads(raw)


async def _key_ok(client_id, websocket, kick_task, data):
    """Check the client key every message carries; close the connection when it is wrong."""
    if data.get("ck") != CLIENT_KEY:
        print(f"[Security] Invalid/missing client key from client {client_id}, disconnecting")
        await websocket.close(4001, "Invalid client")
        return False
    if not state.clients[client_id].get("key_validated"):
        state.clients[client_id]["key_validated"] = True
        if kick_task and not kick_task.done():
            kick_task.cancel()
    return True


async def _serve(client_id, websocket, kick_task, queued):
    async for data in _messages(websocket, queued):
        if not await _key_ok(client_id, websocket, kick_task, data):
            return
        kind = data["type"]
        handler = HANDLERS.get(kind) if isinstance(kind, str) else None
        if handler is not None:
            await handler(client_id, websocket, data)


async def _announce_leave(client_id, username):
    for cid, client in list(state.clients.items()):
        await client["websocket"].send(json.dumps({"type": "player_left", "player_id": client_id}))
        await client["websocket"].send(json.dumps({
            "type": "system_message",
            "message": f"{username} has left the server"
        }))


async def _drop_client(client_id):
    """Forget a departed client, its monsters and its authority, and tell everyone."""
    if client_id not in state.clients:
        return
    username = state.clients[client_id]["username"]
    was_world = state.is_world(state.clients[client_id])
    del state.clients[client_id]
    print(f"[-] {username} left  ({len(state.clients)} online)")
    if was_world:
        print("[World] The world process disconnected — city paused until it returns")
    # A studio rehearsal ends when the client that began it leaves.
    asyncio.create_task(state.world_mind.rehearsal.client_left(client_id))
    await replication.despawn_monsters_of(client_id, username)
    if not was_world:
        await _announce_leave(client_id, username)
    await world_map.broadcast_map_online_owners()
    if client_id == state.npc_authority_client_id:
        await update_npc_authority()


async def handle_client(websocket):
    client_id = state.next_id
    state.next_id += 1
    kick_task = None
    if SECURE_HANDSHAKE:
        first = await _await_client_key(client_id, websocket)
        if first is None:
            return
        await admit_client(client_id, websocket, str(first.get("role", "")))
        queued = [first]
    else:
        await admit_client(client_id, websocket)
        kick_task = asyncio.ensure_future(_kick_unvalidated(client_id, websocket))
        queued = []
    try:
        await _serve(client_id, websocket, kick_task, queued)
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        if kick_task and not kick_task.done():
            kick_task.cancel()
        await _drop_client(client_id)
