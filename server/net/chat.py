"""Chat messages and the server's slash commands; unknown commands are left to the client."""

import json

from world import countryballs
from core import identity
from core.constants import DEFAULT_CHARACTER_TYPE
from net import state
from world.plots import describe_plot, get_user_plots, plot_center
from world.textures import (
    flag_exists, get_available_flags, send_flag_texture_data, send_texture_data, user_has_texture,
)
from accounts.users import load_user_data, save_user_character_type, save_user_data

TRANSFORM_TYPES = ["humanoid", "countryball", "custom"]
SCALE_MIN = 0.2
SCALE_MAX = 1.5

# Fixed /teleport destinations, in global metres.
TELEPORT_DESTINATIONS = identity.get("teleport_destinations")


async def _announce_transform(client_id, username, character_type, flag_code=None):
    msg = {
        "type": "character_transform",
        "player_id": client_id,
        "username": username,
        "character_type": character_type
    }
    if flag_code is not None:
        msg["flag_code"] = flag_code
    await state.broadcast(msg)


async def _cmd_transform(client_id, websocket, message):
    """/transform <humanoid|countryball|custom>"""
    if not message.startswith("/transform "):
        return False
    parts = message.split(" ")
    if len(parts) < 2:
        return False
    character_type = parts[1].lower()
    if character_type not in TRANSFORM_TYPES:
        await state.system_message(
            websocket, "Invalid character type. Use 'humanoid', 'countryball' or 'custom'")
        return True
    client = state.clients[client_id]
    client["character_type"] = character_type
    if client["authenticated"]:
        username = client["username"]
        save_user_character_type(username, character_type)
        if user_has_texture(username, character_type):
            client["texture"] = username
            await send_texture_data(username, character_type, state.clients.values())
            print(f"Sent {character_type} texture for {username} after transformation")
        else:
            client["texture"] = None
            print(f"No {character_type} texture found for {username} after transformation")
    await _announce_transform(client_id, client["username"], character_type)
    await state.system_message(websocket, f"Transformed to {character_type}")
    return True


def _save_countryball(username, countryball_type, flag_code):
    save_user_character_type(username, countryball_type)
    user_data = load_user_data(username)
    user_data["flag_code"] = flag_code
    save_user_data(username, user_data)


async def _cmd_countryball(client_id, websocket, message):
    """/countryball <flag> [subtype]; a flag like TUR_republic falls back to TUR without its own texture."""
    if not message.startswith("/countryball "):
        return False
    parts = message.split()
    if len(parts) < 2:
        return False
    flag_code = parts[1].strip()
    subtype_arg = parts[2].strip() if len(parts) >= 3 else ""
    countryball_type = countryballs.resolve_subtype(subtype_arg)
    if countryball_type is None:
        await state.system_message(
            websocket, f"Unknown countryball subtype '{subtype_arg}'. "
                       f"Available: {', '.join(countryballs.SUBTYPE_NAMES)}")
        return True
    if not flag_exists(flag_code):
        available_flags = get_available_flags()
        await state.system_message(
            websocket,
            f"Flag '{flag_code}' not found. Available: {', '.join(sorted(available_flags))}")
        return True
    client = state.clients[client_id]
    client["character_type"] = countryball_type
    client["flag_code"] = flag_code
    if not countryballs.supports_emotion(countryball_type, client.get("emotion", "neutral")):
        client["emotion"] = "neutral"
    if client["authenticated"]:
        _save_countryball(client["username"], countryball_type, flag_code)
    username = client["username"]
    success, actual_flag_code = await send_flag_texture_data(
        username, flag_code, state.clients.values(), countryball_type)
    if not success:
        await state.system_message(websocket, f"Error loading flag texture for '{flag_code}'")
        return True
    client["texture"] = username
    print(f"Sent flag texture {actual_flag_code} for {username} ({countryball_type})")
    fallback_msg = ""
    if actual_flag_code.lower() != flag_code.lower():
        fallback_msg = f" ('{flag_code}' not found, using '{actual_flag_code}')"
    await _announce_transform(client_id, username, countryball_type, actual_flag_code)
    await state.system_message(
        websocket, f"Transformed to countryball with {actual_flag_code} flag{fallback_msg}")
    return True


async def _cmd_emotion(client_id, websocket, message):
    """/<emotion> (/happy, /sad, ...): change the face of a character that has one."""
    emotion = message.strip().lower()[1:] if message.startswith("/") else ""
    if emotion not in countryballs.all_emotions():
        return False
    client = state.clients[client_id]
    character_type = client.get("character_type", DEFAULT_CHARACTER_TYPE)
    if not countryballs.emotions_for(character_type):
        await state.system_message(
            websocket, "Emotion commands only work for countryballs and the humanoid. "
                       "Use /transform humanoid or /transform countryball first.")
        return True
    if not countryballs.supports_emotion(character_type, emotion):
        supported = ', '.join(countryballs.emotions_for(character_type))
        await state.system_message(
            websocket, f"'{emotion}' is not available for {character_type}. Available: {supported}")
        return True
    client["emotion"] = emotion
    username = client["username"]
    print(f"Player {username} set emotion to: {emotion}")
    await state.broadcast({
        "type": "emotion_update",
        "player_id": client_id,
        "username": username,
        "emotion": emotion
    })
    await state.system_message(websocket, f"Emotion set to {emotion}")
    return True


async def _cmd_scale(client_id, websocket, message):
    """/scale <value>: resize the character, clamped to SCALE_MIN..SCALE_MAX."""
    if not message.startswith("/scale "):
        return False
    parts = message.split(" ")
    if len(parts) < 2:
        await state.system_message(websocket, f"Usage: /scale <value> ({SCALE_MIN} to {SCALE_MAX})")
        return True
    try:
        scale_value = max(SCALE_MIN, min(SCALE_MAX, float(parts[1])))
        state.clients[client_id]["character_scale"] = scale_value
        username = state.clients[client_id]["username"]
        print(f"Player {username} set scale to: {scale_value}")
        await state.broadcast({
            "type": "scale_update",
            "player_id": client_id,
            "username": username,
            "character_scale": scale_value
        })
        await state.system_message(websocket, f"Scale set to {scale_value}")
    except ValueError:
        await state.system_message(
            websocket, f"Invalid scale value. Use /scale <number> where number is between "
                       f"{SCALE_MIN} and {SCALE_MAX}")
    return True


def _plot_report(username):
    owned = get_user_plots(username, state.plots_config)
    if not owned:
        return ("You don't have a plot assigned. Draw a Plot_<id> in the world scene and "
                "give <id> your name in data/plots.json.")
    lines = [f"Your plots ({len(owned)}):"]
    for plot_id, _plot_data in owned:
        count = len(state.plot_objects.get(plot_id, {}))
        lines.append("  " + describe_plot(plot_id, state.plots_config, state.plot_geometry, count))
    unowned = ", ".join(pid for pid, p in sorted(state.plots_config.items()) if not p.get('owner'))
    lines.append("Teleport with /teleport <plot name>. Drawn plots without an owner: "
                 + (unowned or "none"))
    return "\n".join(lines)


async def _cmd_plot(client_id, websocket, message):
    """/plot or /myplot: describe the player's plots."""
    if not (message.startswith("/myplot") or message.startswith("/plot")):
        return False
    if not state.clients[client_id]["authenticated"]:
        await state.system_message(websocket, "You must be logged in to view your plot")
        return True
    await state.system_message(websocket, _plot_report(state.clients[client_id]["username"]))
    return True


def _teleport_choices():
    return ", ".join(list(TELEPORT_DESTINATIONS) + ["your plot name"])


def _teleport_target(client, destination):
    """(position, display name) for a fixed destination or one of the player's plots."""
    if destination in TELEPORT_DESTINATIONS:
        return TELEPORT_DESTINATIONS[destination], destination.capitalize()
    if not client["authenticated"]:
        return None, None
    for plot_id, plot_data in get_user_plots(client["username"], state.plots_config):
        if destination not in (plot_data.get("name", "").lower(), plot_id.lower()):
            continue
        center = plot_center(plot_id, state.plot_geometry)
        if center is None:
            continue
        return center, plot_data.get("name", plot_id)
    return None, None


async def _cmd_teleport(client_id, websocket, message):
    """/teleport <destination>: a fixed place, or a plot of the player's by name or id."""
    if not message.startswith("/teleport "):
        return False
    parts = message.split(" ", 1)
    if len(parts) < 2:
        await state.system_message(websocket, f"Usage: /teleport <{_teleport_choices()}>")
        return True
    client = state.clients[client_id]
    new_position, name = _teleport_target(client, parts[1].lower().strip())
    if not new_position:
        await state.system_message(
            websocket, f"Invalid destination. Use: /teleport <{_teleport_choices()}>")
        return True
    client["position"] = new_position
    await state.system_message(websocket, f"Teleported to {name}")
    await websocket.send(json.dumps({"type": "teleport", "position": new_position}))
    await state.broadcast({
        "type": "player_transform",
        "player_id": client_id,
        "position": new_position,
        "rotation": client["rotation"],
        "on_floor": True
    }, skip=client_id)
    return True


COMMANDS = (_cmd_transform, _cmd_countryball, _cmd_emotion, _cmd_scale, _cmd_plot, _cmd_teleport)


async def on_chat_message(client_id, websocket, data):
    message = data["message"]
    for command in COMMANDS:
        if await command(client_id, websocket, message):
            return
    if message.startswith("/"):
        return
    username = state.clients[client_id]["username"]
    print(f"[CHAT] <{username}> {message}")
    await state.broadcast({
        "type": "chat_message",
        "player_id": client_id,
        "username": username,
        "message": message,
        "to": str(data.get("to", "") or "")     # whom the speaker meant
    })
