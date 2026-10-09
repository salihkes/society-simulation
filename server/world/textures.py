#!/usr/bin/env python
"""Player textures and countryball flags: finding them, saving decals, sending them to clients."""

import base64
import io
import json
import os

from world import countryballs
from core.constants import FLAGS_DIR, USER_TEXTURE_DIR

try:
    from PIL import Image
    PIL_AVAILABLE = True
except ImportError:
    PIL_AVAILABLE = False
    print("Warning: Pillow not installed. TGA flag support will be disabled.")

FLAG_EXTENSIONS = ['.png', '.tga']

DEFAULT_COUNTRYBALL_TEXTURE = "countryball.png"
MAX_DECAL_BYTES = 5 * 1024 * 1024


def _absolute(directory):
    """`directory` itself when absolute, else resolved against this file's folder."""
    if os.path.isabs(directory):
        return directory
    return os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), directory))


def get_texture_dir():
    return _absolute(USER_TEXTURE_DIR)


def get_flags_dir():
    return _absolute(FLAGS_DIR)


def _flag_code_of(filename):
    """The flag code a flag file is named for, or None when it is not a flag file."""
    for ext in FLAG_EXTENSIONS:
        if filename.lower().endswith(ext):
            return filename[:-len(ext)]
    return None


def get_available_flags():
    """Every flag code with a texture (e.g. 'TUR', 'TUR_republic'), once each ignoring case."""
    flags_dir = get_flags_dir()
    if not os.path.exists(flags_dir):
        return []
    flags = []
    seen_codes = set()
    for filename in os.listdir(flags_dir):
        flag_code = _flag_code_of(filename)
        if flag_code is None or flag_code.lower() in seen_codes:
            continue
        flags.append(flag_code)
        seen_codes.add(flag_code.lower())
    return flags


def _find_flag_file(flags_dir, filenames, code):
    """(path, actual code) of the file for `code` (case ignored, PNG first), or None."""
    for ext in FLAG_EXTENSIONS:
        for filename in filenames:
            if filename.lower() == f"{code.lower()}{ext}":
                return os.path.join(flags_dir, filename), filename[:-len(ext)]
    return None


def get_flag_texture_path(flag_code):
    """(path, actual flag code), or (None, None); 'TUR_republic' without its own texture falls back to 'TUR'."""
    flags_dir = get_flags_dir()
    if not os.path.exists(flags_dir):
        return None, None
    filenames = os.listdir(flags_dir)
    found = _find_flag_file(flags_dir, filenames, flag_code)
    if found is None and '_' in flag_code:
        found = _find_flag_file(flags_dir, filenames, flag_code.split('_')[0])
    return found if found is not None else (None, None)


def flag_exists(flag_code):
    """True if the flag, or the base flag it falls back to, has a texture."""
    path, _ = get_flag_texture_path(flag_code)
    return path is not None


def convert_tga_to_png_bytes(tga_path):
    """A TGA image as RGBA PNG bytes, or None without Pillow or on failure."""
    if not PIL_AVAILABLE:
        print("Cannot convert TGA to PNG: Pillow not installed")
        return None
    try:
        with Image.open(tga_path) as img:
            if img.mode != 'RGBA':
                img = img.convert('RGBA')
            buffer = io.BytesIO()
            img.save(buffer, format='PNG')
            return buffer.getvalue()
    except Exception as e:
        print(f"Error converting TGA to PNG: {e}")
        return None


def _read_base64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode('utf-8')


async def send_flag_texture_data(username, flag_code, target_clients,
                                 character_type=countryballs.ONESIDE):
    """Send a flag wearer's flag (TGA as PNG) to `target_clients`; returns (sent, actual flag code or None)."""
    flag_path, actual_flag_code = get_flag_texture_path(flag_code)
    if not (flag_path and os.path.exists(flag_path)):
        return False, None
    if flag_path.lower().endswith('.tga'):
        png_data = convert_tga_to_png_bytes(flag_path)
        if png_data is None:
            print(f"Failed to convert TGA flag: {flag_path}")
            return False, None
        texture_data = base64.b64encode(png_data).decode('utf-8')
    else:
        texture_data = _read_base64(flag_path)
    for client in target_clients:
        await client["websocket"].send(json.dumps({
            "type": "texture_data",
            "texture_name": username,
            "character_type": character_type,
            "flag_code": actual_flag_code,
            "data": texture_data
        }))
    return True, actual_flag_code


def get_texture_filename(username, character_type):
    """<username>_countryball.png for countryballs, else <username>.png."""
    if character_type == "countryball":
        return f"{username}_countryball.png"
    return f"{username}.png"


def get_texture_path(username, character_type):
    """The player's texture file (for a countryball without one, the default), or None."""
    texture_dir = get_texture_dir()
    texture_path = os.path.join(texture_dir, get_texture_filename(username, character_type))
    if not os.path.exists(texture_path) and character_type == "countryball":
        fallback_path = os.path.join(texture_dir, DEFAULT_COUNTRYBALL_TEXTURE)
        if os.path.exists(fallback_path):
            return fallback_path
    if os.path.exists(texture_path):
        return texture_path
    return None


def user_has_texture(username, character_type):
    return get_texture_path(username, character_type) is not None


async def send_texture_data(username, character_type, target_clients):
    """Send the player's texture to each client in `target_clients`; False when there is none."""
    texture_path = get_texture_path(username, character_type)
    if texture_path is None:
        return False
    texture_data = _read_base64(texture_path)
    for client in target_clients:
        await client["websocket"].send(json.dumps({
            "type": "texture_data",
            "texture_name": username,
            "character_type": character_type,
            "data": texture_data
        }))
    return True


def save_decal_texture(username, character_type, base64_data):
    """Save a base64 image as the player's texture; returns (ok, message, path or None)."""
    try:
        if character_type not in ["humanoid", "countryball"]:
            return (False, f"Invalid character type: {character_type}. "
                           f"Must be 'humanoid' or 'countryball'", None)
        try:
            image_data = base64.b64decode(base64_data)
        except Exception as e:
            return False, f"Invalid base64 data: {str(e)}", None
        if len(image_data) > MAX_DECAL_BYTES:
            return False, "Image too large. Maximum size is 5MB", None
        texture_dir = get_texture_dir()
        os.makedirs(texture_dir, exist_ok=True)
        texture_path = os.path.join(texture_dir, get_texture_filename(username, character_type))
        with open(texture_path, "wb") as f:
            f.write(image_data)
        file_size_kb = len(image_data) / 1024
        print(f"Saved {character_type} decal for {username}: {texture_path} "
              f"({file_size_kb:.2f} KB)")
        return (True, f"Successfully uploaded {character_type} decal ({file_size_kb:.1f} KB)",
                texture_path)
    except Exception as e:
        error_msg = f"Error saving decal texture: {str(e)}"
        print(error_msg)
        return False, error_msg, None
