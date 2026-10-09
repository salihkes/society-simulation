"""Places: private scenes, each served by its own services/place.py process (unused by the game itself)."""

import asyncio
import json
import os
import subprocess

from core.constants import EXTERNAL_DOMAIN, PLACE_SERVER_START_PORT, PLACES_DIR
from net import state

place_servers = {}      # place_name -> {"port", "process", "url", "place_name"}
next_place_port = PLACE_SERVER_START_PORT


def get_place_scene_path(place_name):
    return os.path.join(PLACES_DIR, f"{place_name}.tscn")


def place_scene_exists(place_name):
    return os.path.exists(get_place_scene_path(place_name))


def read_place_scene(place_name):
    path = get_place_scene_path(place_name)
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    return None


async def spawn_place_server(place_name):
    """Start a services/place.py process for a place on the next free port; None on failure."""
    global next_place_port
    if place_name in place_servers:
        print(f"Place server '{place_name}' already running")
        return place_servers[place_name]
    if not place_scene_exists(place_name):
        print(f"Place scene '{place_name}' not found")
        return None
    port = next_place_port
    next_place_port += 1
    try:
        process = subprocess.Popen(
            ["python", "-m", "services.place", place_name, str(port)],
            cwd=os.getcwd(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        await asyncio.sleep(1)  # give it a moment to bind
        server_info = {
            "port": port,
            "process": process,
            "url": f"wss://{EXTERNAL_DOMAIN}:{port}",
            "place_name": place_name
        }
        place_servers[place_name] = server_info
        print(f"Spawned place server '{place_name}' on port {port}")
        return server_info
    except Exception as e:
        print(f"Error spawning place server: {e}")
        return None


async def get_or_spawn_place_server(place_name):
    if place_name in place_servers:
        return place_servers[place_name]
    return await spawn_place_server(place_name)


def cleanup_place_servers():
    """Terminate every spawned place server (registered with atexit)."""
    print("\nShutting down all place servers...")
    for place_name, server_info in place_servers.items():
        try:
            process = server_info["process"]
            print(f"  Terminating place server: {place_name} (port {server_info['port']})")
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
        except Exception as e:
            print(f"  Error terminating place server {place_name}: {e}")
    print("All place servers stopped.")


async def on_join_place(client_id, websocket, data):
    place_name = data.get("place_name", "")
    if not place_name:
        await state.system_message(websocket, "Invalid place name")
        return
    if not place_scene_exists(place_name):
        await state.system_message(websocket, f"Place '{place_name}' does not exist")
        return
    server_info = await get_or_spawn_place_server(place_name)
    if not server_info:
        await state.system_message(websocket, f"Failed to start place server for '{place_name}'")
        return
    scene_data = read_place_scene(place_name)
    if not scene_data:
        await state.system_message(websocket, f"Failed to load scene data for '{place_name}'")
        return
    await websocket.send(json.dumps({
        "type": "place_info",
        "place_name": place_name,
        "server_url": server_info["url"],
        "scene_data": scene_data
    }))
    print(f"Client {client_id} joining place '{place_name}' at {server_info['url']}")


async def on_list_places(client_id, websocket, data):
    places = []
    if os.path.exists(PLACES_DIR):
        for filename in os.listdir(PLACES_DIR):
            if filename.endswith(".tscn"):
                places.append(filename[:-len(".tscn")])
    await websocket.send(json.dumps({"type": "places_list", "places": places}))


async def on_upload_place(client_id, websocket, data):
    """Save a logged-in player's scene as the place named after them."""
    if not state.clients[client_id]["authenticated"]:
        await state.system_message(websocket, "You must be logged in to upload places")
        return
    username = state.clients[client_id]["username"]
    scene_data = data.get("scene_data", "")
    if not scene_data:
        await state.system_message(websocket, "No scene data provided")
        return
    place_path = os.path.join(PLACES_DIR, f"{username}.tscn")
    try:
        with open(place_path, "w", encoding="utf-8") as f:
            f.write(scene_data)
        scene_size_kb = len(scene_data) / 1024
        print(f"User {username} uploaded their place: {place_path} ({scene_size_kb:.2f} KB)")
        await state.system_message(
            websocket,
            f"Successfully uploaded your place ({scene_size_kb:.1f} KB)! "
            f"Others can join with /join {username}")
    except Exception as e:
        print(f"Error saving place for {username}: {e}")
        await state.system_message(websocket, "Failed to upload place")
