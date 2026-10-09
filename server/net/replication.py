"""Replicated things players own: grabbable objects, ships, combat events and monsters."""

import json

from net import state

DEFAULT_HULL_HP = 1000.0
DEFAULT_SHIELD_HP = 500.0
ZERO_VECTOR = {"x": 0, "y": 0, "z": 0}


async def on_object_grab(client_id, websocket, data):
    """Store a grabbed object's transform and announce it to everyone, sender included."""
    net_id = str(data.get("net_id"))
    xf = data.get("transform", {})
    state.objects[net_id] = {"transform": xf}
    await state.broadcast({
        "type": "object_spawn",
        "net_id": net_id,
        "transform": xf,
        "seq": data.get("seq", 0),
        "authority": client_id
    })


async def on_object_release(client_id, websocket, data):
    net_id = str(data.get("net_id"))
    xf = data.get("transform", {})
    vel = data.get("velocity", {"x": 0, "y": 0, "z": 0})
    state.objects[net_id] = {"transform": xf}
    await state.broadcast({
        "type": "object_update",
        "net_id": net_id,
        "node_path": data.get("node_path", None),
        "transform": xf,
        "velocity": vel,
        "seq": data.get("seq", 0),
        "authority": client_id
    })


async def on_object_update(client_id, websocket, data):
    """Store a held object's transform and send it to everyone else."""
    net_id = str(data.get("net_id"))
    xf = data.get("transform", {})
    state.objects[net_id] = {"transform": xf}
    await state.broadcast({
        "type": "object_update",
        "net_id": net_id,
        "node_path": data.get("node_path", None),
        "transform": xf,
        "seq": data.get("seq", 0),
        "authority": client_id
    }, skip=client_id)


async def on_ship_transform(client_id, websocket, data):
    """Store a ship's pose for late joiners (keeping its hit points) and relay it."""
    net_id = data.get("net_id", "")
    if net_id:
        previous = state.ships.get(net_id, {})
        state.ships[net_id] = {
            "origin": data.get("origin", {}),
            "basis_x": data.get("basis_x", {}),
            "basis_y": data.get("basis_y", {}),
            "basis_z": data.get("basis_z", {}),
            "velocity": data.get("velocity", {}),
            "ship_name": data.get("ship_name", ""),
            "hull_hp": previous.get("hull_hp", DEFAULT_HULL_HP),
            "shield_hp": previous.get("shield_hp", DEFAULT_SHIELD_HP)
        }
    await state.broadcast({
        "type": "ship_transform",
        "net_id": net_id,
        "ship_name": data.get("ship_name", ""),
        "origin": data.get("origin", {}),
        "basis_x": data.get("basis_x", {}),
        "basis_y": data.get("basis_y", {}),
        "basis_z": data.get("basis_z", {}),
        "velocity": data.get("velocity", {}),
        "player_id": client_id
    }, skip=client_id)


async def on_ship_board(client_id, websocket, data):
    state.clients[client_id]["on_ship"] = True
    state.clients[client_id]["ship_id"] = data.get("ship_id", "")
    await state.broadcast({
        "type": "ship_board",
        "player_id": client_id,
        "ship_id": data.get("ship_id", ""),
        "ship_name": data.get("ship_name", "")
    }, skip=client_id)


async def on_ship_depart(client_id, websocket, data):
    state.clients[client_id]["on_ship"] = False
    state.clients[client_id]["ship_id"] = ""
    await state.broadcast({
        "type": "ship_depart",
        "player_id": client_id,
        "ship_id": data.get("ship_id", "")
    }, skip=client_id)


async def on_combat_event(client_id, websocket, data):
    """Relay a combat message to everyone else, stamped with the sender."""
    msg = dict(data)
    msg["player_id"] = client_id
    await state.broadcast(msg, skip=client_id)


async def on_combat_ship_damage(client_id, websocket, data):
    net_id = data.get("net_id", "")
    if net_id and net_id in state.ships:
        state.ships[net_id]["hull_hp"] = data.get("hull_hp", 0)
        state.ships[net_id]["shield_hp"] = data.get("shield_hp", 0)
    await on_combat_event(client_id, websocket, data)


def _monster_record(monster_data, owner_id):
    return {
        "species": monster_data.get("species", "countryball"),
        "position": monster_data.get("position", dict(ZERO_VECTOR)),
        "rotation": monster_data.get("rotation", dict(ZERO_VECTOR)),
        "texture": monster_data.get("texture", ""),
        "owner_id": owner_id
    }


async def on_monster_spawn(client_id, websocket, data):
    monster_data = data.get("monster_data", {})
    net_id = monster_data.get("net_id")
    if not net_id:
        print("Warning: monster_spawn without net_id")
        return
    state.monsters[net_id] = _monster_record(monster_data, client_id)
    m = state.monsters[net_id]
    print(f"Monster spawned: {m['species']} (net_id: {net_id}, texture: '{m['texture']}') "
          f"by client {client_id}")
    await state.broadcast({"type": "monster_spawn", "monster_data": monster_data},
                          skip=client_id)


async def on_monster_update(client_id, websocket, data):
    """Move a monster (recording it if unknown) and relay the update."""
    monster_data = data.get("monster_data", {})
    net_id = monster_data.get("net_id")
    if not net_id:
        return
    if net_id in state.monsters:
        m = state.monsters[net_id]
        m["position"] = monster_data.get("position", m["position"])
        m["rotation"] = monster_data.get("rotation", m["rotation"])
    else:
        state.monsters[net_id] = _monster_record(monster_data, client_id)
    await state.broadcast({"type": "monster_update", "monster_data": monster_data},
                          skip=client_id)


async def on_monster_despawn(client_id, websocket, data):
    net_id = data.get("net_id")
    if not net_id:
        return
    if net_id in state.monsters:
        print(f"Monster despawned: {net_id}")
        del state.monsters[net_id]
    await state.broadcast({"type": "monster_despawn", "net_id": net_id}, skip=client_id)


async def despawn_monsters_of(client_id, username):
    owned = [net_id for net_id, m in state.monsters.items() if m["owner_id"] == client_id]
    for net_id in owned:
        print(f"Despawning monster {net_id} (owner {username} disconnected)")
        del state.monsters[net_id]
        payload = json.dumps({"type": "monster_despawn", "net_id": net_id})
        for cid, client in list(state.clients.items()):
            try:
                await client["websocket"].send(payload)
            except BaseException:     # runs during disconnect cleanup; nothing may stop it
                pass
