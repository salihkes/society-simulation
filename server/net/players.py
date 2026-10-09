"""Player appearance and movement: the player list, textures, transforms, decals, monsters."""

import base64
import json

from world import countryballs
from core.constants import DEFAULT_CHARACTER_TYPE
from net import state
from world.outfits import parse_outfit
from world.textures import (
    get_flag_texture_path, get_texture_filename, get_texture_path, save_decal_texture,
    send_texture_data,
)
from accounts.users import get_user_monsters, save_user_character_type

DECAL_CHARACTER_TYPES = ["humanoid", "countryball"]


def player_list(exclude_id, default_type):
    """Every player but `exclude_id` (and never the world process), as player_list entries."""
    players = []
    for cid, client in list(state.clients.items()):
        if cid == exclude_id or state.is_world(client):
            continue
        entry = {
            "id": cid,
            "username": client["username"],
            "position": client["position"],
            "rotation": client["rotation"],
            "texture": client["texture"],
            "accessories": client.get("accessories", []),
            "character_type": client.get("character_type", default_type),
            "emotion": client.get("emotion", "neutral"),
            "character_scale": client.get("character_scale", 1.0)
        }
        if countryballs.wears_flag(client.get("character_type")):
            entry["flag_code"] = client.get("flag_code", "")
        players.append(entry)
    return players


def _read_base64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode('utf-8')


def _appearance_of(username):
    """(character_type, flag_code) of the connected player with this name, else the defaults."""
    for cid, client in list(state.clients.items()):
        if client["username"] != username:
            continue
        character_type = client.get("character_type", DEFAULT_CHARACTER_TYPE)
        flag_code = None
        if countryballs.wears_flag(character_type):
            flag_code = client.get("flag_code", "")
        return character_type, flag_code
    return DEFAULT_CHARACTER_TYPE, None


async def _send_flag_texture(websocket, texture_name, character_type, flag_code):
    flag_path, actual_flag_code = get_flag_texture_path(flag_code)
    if not flag_path:
        await state.system_message(websocket, f"Flag texture '{flag_code}' not found")
        print(f"Flag texture not found for {texture_name}, flag_code: {flag_code}")
        return
    await websocket.send(json.dumps({
        "type": "texture_data",
        "texture_name": texture_name,
        "character_type": character_type,
        "flag_code": actual_flag_code,
        "data": _read_base64(flag_path)
    }))
    print(f"Sent flag texture {actual_flag_code} for {texture_name}")


async def _send_user_texture(websocket, texture_name, character_type):
    texture_path = get_texture_path(texture_name, character_type)
    if not texture_path:
        texture_filename = get_texture_filename(texture_name, character_type)
        await state.system_message(websocket, f"Texture {texture_filename} not found")
        print(f"Texture not found for {texture_name}")
        return
    await websocket.send(json.dumps({
        "type": "texture_data",
        "texture_name": texture_name,
        "character_type": character_type,
        "data": _read_base64(texture_path)
    }))
    print(f"Sent {character_type} texture for {texture_name}")


async def on_get_texture(client_id, websocket, data):
    """Send the texture a player is shown with: their flag, or their own/default texture."""
    texture_name = data["texture_name"]
    character_type, flag_code = _appearance_of(texture_name)
    if countryballs.wears_flag(character_type) and flag_code:
        await _send_flag_texture(websocket, texture_name, character_type, flag_code)
    else:
        await _send_user_texture(websocket, texture_name, character_type)


async def on_transform_update(client_id, websocket, data):
    client = state.clients[client_id]
    client["position"] = data["position"]
    client["rotation"] = data["rotation"]
    model_rotation_y = data.get("model_rotation_y", None)
    on_floor = data.get("on_floor", True)
    on_ship = data.get("on_ship", False)
    ship_id = data.get("ship_id", "")
    move_speed = data.get("speed", None)
    is_running = data.get("running", None)
    floor_pose = data.get("pose", None)     # a floor pose the body holds (seiza, agura)
    outfit = parse_outfit(data.get("outfit"))
    if outfit is not None:
        client["outfit"] = outfit
    message = {
        "type": "player_transform",
        "player_id": client_id,
        "position": data["position"],
        "rotation": data["rotation"],
        "on_floor": on_floor
    }
    if model_rotation_y is not None:
        message["model_rotation_y"] = model_rotation_y
    if move_speed is not None:
        message["speed"] = move_speed
        message["running"] = bool(is_running)
    if floor_pose:
        message["pose"] = floor_pose
    if outfit is not None:
        message["outfit"] = outfit
    if on_ship:
        message["on_ship"] = True
        message["ship_id"] = ship_id
    await state.broadcast(message, skip=client_id)


async def on_get_players(client_id, websocket, data):
    await websocket.send(json.dumps({
        "type": "player_list",
        "players": player_list(client_id, "countryball")
    }))


async def on_upload_decal(client_id, websocket, data):
    if not state.clients[client_id]["authenticated"]:
        await state.system_message(websocket, "You must be logged in to upload decals")
        return
    username = state.clients[client_id]["username"]
    character_type = data.get("character_type", DEFAULT_CHARACTER_TYPE)
    base64_data = data.get("data", "")
    if not base64_data:
        await state.system_message(websocket, "No image data provided")
        return
    if character_type not in DECAL_CHARACTER_TYPES:
        await state.system_message(websocket,
                                   "Invalid character type. Must be 'humanoid' or 'countryball'")
        return
    success, message, _file_path = save_decal_texture(username, character_type, base64_data)
    if not success:
        await state.system_message(websocket, f"Failed to upload decal: {message}")
        return
    if state.clients[client_id].get("character_type") != character_type:
        state.clients[client_id]["character_type"] = character_type
        save_user_character_type(username, character_type)
    state.clients[client_id]["texture"] = username
    await send_texture_data(username, character_type, state.clients.values())
    # Always true after the assignment above, so the transform is always broadcast.
    if state.clients[client_id].get("character_type") == character_type:
        await state.broadcast({
            "type": "character_transform",
            "player_id": client_id,
            "username": username,
            "character_type": character_type
        })
    await state.system_message(websocket, message)


async def on_get_player_monsters(client_id, websocket, data):
    """Send a logged-in player's saved monsters; guests get an empty list."""
    username = state.clients[client_id]["username"]
    authenticated = state.clients[client_id]["authenticated"]
    if not authenticated or username.startswith("Guest"):
        await websocket.send(json.dumps({"type": "player_monsters_list", "monsters": []}))
        print(f"Sent empty monster list to guest: {username}")
        return
    user_monsters = get_user_monsters(username)
    for monster in user_monsters:
        if monster.get("species") == "countryball":
            monster["texture"] = f"{username}_countryball"
            print(f"Set countryball texture to: {username}_countryball")
    await websocket.send(json.dumps({"type": "player_monsters_list", "monsters": user_monsters}))
    print(f"Sent {len(user_monsters)} monster(s) to {username}")
