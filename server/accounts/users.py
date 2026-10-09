#!/usr/bin/env python
"""Per-player saved data in data/users/<username>.json: look, monsters and map colour."""

import json
import os

from core.constants import (
    DEFAULT_CHARACTER_TYPE, MAP_COLOR_PALETTE, MAP_PLAYERS_OVERRIDE_FILE, USER_DATA_DIR,
)


def get_user_data_path(username):
    return os.path.join(USER_DATA_DIR, f"{username}.json")


def load_user_data(username):
    """The player's saved data, or {} when there is none or it cannot be read."""
    user_data_path = get_user_data_path(username)
    if not os.path.exists(user_data_path):
        return {}
    try:
        with open(user_data_path, "r") as f:
            return json.load(f)
    except Exception as e:
        print(f"Error reading user data for {username}: {e}")
        return {}


def save_user_data(username, user_data):
    """Write the player's saved data; False on failure."""
    user_data_path = get_user_data_path(username)
    try:
        with open(user_data_path, "w") as f:
            json.dump(user_data, f, indent=2)
        return True
    except Exception as e:
        print(f"Error saving user data for {username}: {e}")
        return False


def get_user_accessories(username):
    return load_user_data(username).get("equipped_accessories", [])


def get_user_character_type(username):
    """The player's saved character type, DEFAULT_CHARACTER_TYPE when unset."""
    return load_user_data(username).get("character_type", DEFAULT_CHARACTER_TYPE)


def save_user_character_type(username, character_type):
    user_data = load_user_data(username)
    user_data["character_type"] = character_type
    return save_user_data(username, user_data)


def get_user_monsters(username):
    """The player's monsters: [{"species", "texture"}, ...]."""
    return load_user_data(username).get("monsters", [])


def _load_admin_overrides():
    """The optional admin file of player map colours: {username: {"color": hex}}."""
    if not os.path.exists(MAP_PLAYERS_OVERRIDE_FILE):
        return {}
    try:
        with open(MAP_PLAYERS_OVERRIDE_FILE, "r") as f:
            return json.load(f)
    except Exception as e:
        print(f"Error reading map players override: {e}")
        return {}


def _read_map_color(path):
    """The map_color saved in one user file, lower-cased; None when absent or unreadable."""
    try:
        with open(path, "r") as f:
            color = json.load(f).get("map_color")
        return color.lower() if color else None
    except Exception:
        return None


def _collect_used_colors():
    used = set()
    if not os.path.exists(USER_DATA_DIR):
        return used
    for filename in os.listdir(USER_DATA_DIR):
        if not filename.endswith(".json"):
            continue
        color = _read_map_color(os.path.join(USER_DATA_DIR, filename))
        if color:
            used.add(color)
    return used


def _override_owner(username, color):
    """Save an admin-set colour (and an owner id if missing) for the player; returns both."""
    user_data = load_user_data(username)
    owner_id = user_data.get("map_owner_id")
    if user_data.get("map_color", "").lower() != color or not owner_id:
        owner_id = owner_id or f"owner_{username}"
        user_data["map_owner_id"] = owner_id
        user_data["map_color"] = color
        save_user_data(username, user_data)
    return {"owner_id": owner_id, "color": color}


def get_user_map_owner(username):
    """{"owner_id", "color"} or None; an admin override colour wins and is saved."""
    overrides = _load_admin_overrides()
    if username in overrides:
        color = overrides[username].get("color", "").lower()
        if color:
            return _override_owner(username, color)
    user_data = load_user_data(username)
    owner_id = user_data.get("map_owner_id")
    color = user_data.get("map_color")
    if owner_id and color:
        return {"owner_id": owner_id, "color": color}
    return None


def assign_user_map_owner(username):
    """Give the player the first unused palette colour and save it; past the palette, a per-run name hash."""
    used = _collect_used_colors()
    color = next((c for c in MAP_COLOR_PALETTE if c.lower() not in used), None)
    if not color:
        color = f"{hash(username) & 0xFFFFFF:06x}"
    owner_id = f"owner_{username}"
    user_data = load_user_data(username)
    user_data["map_owner_id"] = owner_id
    user_data["map_color"] = color
    save_user_data(username, user_data)
    print(f"[Map] Auto-assigned colour {color} to {username} (owner_id={owner_id})")
    return {"owner_id": owner_id, "color": color}
