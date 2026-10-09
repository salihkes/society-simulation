#!/usr/bin/env python
"""A place server: one private scene with its own players; usage: python -m services.place <place_name> <port>."""

import asyncio
import base64
import json
import random
import sys

import websockets

from core.constants import (
    CLIENT_KEY, DEFAULT_CHARACTER_TYPE, MAX_MESSAGE_SIZE, MAX_QUEUE_SIZE, SECURE_HANDSHAKE,
)
from world.outfits import parse_outfit
from world.textures import (
    get_texture_filename, get_texture_path, send_texture_data, user_has_texture,
)
from accounts.users import save_user_character_type

KEY_TIMEOUT_SECONDS = 15
DEFAULT_PORT = 8766
TRANSFORM_TYPES = ["humanoid", "countryball", "custom"]

clients = {}
objects = {}


def _read_base64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode('utf-8')


class PlaceServer:
    def __init__(self, place_name, port):
        self.place_name = place_name
        self.port = port
        self.clients = clients
        self.next_id = 1
        self.objects = objects
        self.handlers = {
            "set_identity": self._on_set_identity,
            "transform_update": self._on_transform_update,
            "login": self._on_auth_attempt,
            "register": self._on_auth_attempt,
            "chat_message": self._on_chat_message,
            "get_texture": self._on_get_texture,
            "get_players": self._on_get_players,
            "object_grab": self._on_object_grab,
            "object_release": self._on_object_release,
            "object_update": self._on_object_update,
        }

    async def _send_others(self, client_id, msg):
        """Send to every client but `client_id`; a failed send raises."""
        payload = json.dumps(msg)
        for cid, client in self.clients.items():
            if cid != client_id:
                await client["websocket"].send(payload)

    async def _send_everyone(self, msg):
        """Send to every client; a failed send raises."""
        payload = json.dumps(msg)
        for cid, client in self.clients.items():
            await client["websocket"].send(payload)

    def _player_list(self, client_id):
        """Every player but `client_id`, as player_list entries."""
        return [{
            "id": existing_id,
            "username": existing["username"],
            "position": existing["position"],
            "rotation": existing["rotation"],
            "texture": existing["texture"],
            "accessories": existing.get("accessories", []),
            "character_type": existing.get("character_type", DEFAULT_CHARACTER_TYPE)
        } for existing_id, existing in self.clients.items() if existing_id != client_id]

    async def _send_existing_players(self, client_id, websocket):
        """Send the newcomer each other player's texture and accessories."""
        for existing_id, existing in self.clients.items():
            if existing_id == client_id:
                continue
            texture = existing.get("texture")
            character_type = existing.get("character_type", DEFAULT_CHARACTER_TYPE)
            texture_path = get_texture_path(texture, character_type) if texture else None
            if texture_path:
                await websocket.send(json.dumps({
                    "type": "texture_data",
                    "texture_name": texture,
                    "character_type": character_type,
                    "data": _read_base64(texture_path)
                }))
            await websocket.send(json.dumps({
                "type": "accessories_data",
                "player_id": existing_id,
                "username": existing.get("username"),
                "accessories": existing.get("accessories", [])
            }))

    async def _admit_client(self, client_id, websocket):
        self.clients[client_id] = {
            "websocket": websocket,
            "username": f"Guest{client_id}",
            "authenticated": False,
            "position": {"x": random.uniform(-5, 5), "y": 10, "z": random.uniform(-5, 5)},
            "rotation": {"x": 0, "y": 0, "z": 0},
            "texture": None,
            "character_type": DEFAULT_CHARACTER_TYPE,
            "key_validated": True,
        }
        me = self.clients[client_id]
        await websocket.send(json.dumps({
            "type": "connected",
            "client_id": client_id,
            "username": me["username"],
            "authenticated": False,
            "character_type": me["character_type"],
            "place_name": self.place_name
        }))
        await websocket.send(json.dumps({"type": "player_list",
                                         "players": self._player_list(client_id)}))
        await self._send_existing_players(client_id, websocket)
        for net_id, obj in self.objects.items():
            await websocket.send(json.dumps({
                "type": "object_spawn",
                "net_id": net_id,
                "transform": obj.get("transform", {})
            }))
        for existing_id, existing in self.clients.items():
            if existing_id == client_id:
                continue
            await existing["websocket"].send(json.dumps({
                "type": "player_joined",
                "player_id": client_id,
                "username": me["username"],
                "position": me["position"],
                "rotation": me["rotation"],
                "texture": me["texture"],
                "accessories": me.get("accessories", []),
                "character_type": me["character_type"]
            }))
        print(f"[Admit] Place client {client_id} admitted as {me['username']}")

    async def _on_set_identity(self, client_id, websocket, data):
        """Take the identity the player had on the main server and show it to everyone."""
        username = data.get("username", f"Guest{client_id}")
        texture = data.get("texture", None)
        character_type = data.get("character_type", DEFAULT_CHARACTER_TYPE)
        accessories = data.get("accessories", [])
        me = self.clients[client_id]
        me["username"] = username
        me["texture"] = texture
        me["character_type"] = character_type
        me["accessories"] = accessories
        me["authenticated"] = True
        print(f"Client {client_id} identity set: {username} ({character_type})")
        await self._send_others(client_id, {
            "type": "player_identity_update",
            "player_id": client_id,
            "username": username,
            "texture": texture,
            "character_type": character_type,
            "accessories": accessories
        })
        if texture and await send_texture_data(texture, character_type, self.clients.values()):
            print(f"Broadcasted texture for {username}")
        await self._send_everyone({
            "type": "accessories_data",
            "player_id": client_id,
            "username": username,
            "accessories": accessories
        })
        print(f"Broadcasted accessories for {username}: {accessories}")
        await self._send_everyone({
            "type": "character_transform",
            "player_id": client_id,
            "username": username,
            "character_type": character_type
        })
        print(f"Broadcasted character type for {username}: {character_type}")
        await websocket.send(json.dumps({
            "type": "system_message",
            "message": f"Identity set: {username} ({character_type})"
        }))

    async def _on_transform_update(self, client_id, websocket, data):
        self.clients[client_id]["position"] = data["position"]
        self.clients[client_id]["rotation"] = data["rotation"]
        model_rotation_y = data.get("model_rotation_y", None)
        on_floor = data.get("on_floor", True)
        move_speed = data.get("speed", None)
        is_running = data.get("running", None)
        floor_pose = data.get("pose", None)
        outfit = parse_outfit(data.get("outfit"))
        if outfit is not None:
            self.clients[client_id]["outfit"] = outfit
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
        await self._send_others(client_id, message)

    async def _on_auth_attempt(self, client_id, websocket, data):
        """Refuse login and register here, with a reply that unblocks the client's UI."""
        await websocket.send(json.dumps({
            "type": "system_message",
            "message": "You cannot login/register in a place. "
                       "Please return to the lobby to authenticate."
        }))
        response_type = "login_response" if data["type"] == "login" else "register_response"
        await websocket.send(json.dumps({
            "type": response_type,
            "success": False,
            "message": "Authentication not available in places. Return to lobby."
        }))

    async def _transform(self, client_id, websocket, character_type):
        """Change a player's character type, with their texture for it when they have one."""
        me = self.clients[client_id]
        me["character_type"] = character_type
        username = me["username"]
        if me.get("authenticated", False):
            save_user_character_type(username, character_type)
            if user_has_texture(username, character_type):
                me["texture"] = username
                await send_texture_data(username, character_type, self.clients.values())
                print(f"Sent {character_type} texture for {username} after transformation")
            else:
                me["texture"] = None
                print(f"No {character_type} texture found for {username} after transformation")
        await self._send_everyone({
            "type": "character_transform",
            "player_id": client_id,
            "username": username,
            "character_type": character_type
        })
        await websocket.send(json.dumps({
            "type": "system_message",
            "message": f"Transformed to {character_type}"
        }))

    async def _on_chat_message(self, client_id, websocket, data):
        """Handle /transform; drop other commands (the client runs them); broadcast the rest."""
        message = data["message"]
        if message.startswith("/transform "):
            character_type = message.split(" ")[1].lower()
            if character_type in TRANSFORM_TYPES:
                await self._transform(client_id, websocket, character_type)
            else:
                await websocket.send(json.dumps({
                    "type": "system_message",
                    "message": "Invalid character type. Use 'humanoid', 'countryball' or 'custom'"
                }))
            return
        if message.startswith("/"):
            return
        await self._send_everyone({
            "type": "chat_message",
            "player_id": client_id,
            "username": self.clients[client_id]["username"],
            "message": message
        })

    async def _on_get_texture(self, client_id, websocket, data):
        texture_name = data.get("texture_name", "")
        if not texture_name:
            return
        character_type = DEFAULT_CHARACTER_TYPE
        for cid, client_data in self.clients.items():
            if client_data["username"] == texture_name:
                character_type = client_data.get("character_type", DEFAULT_CHARACTER_TYPE)
                break
        texture_path = get_texture_path(texture_name, character_type)
        if not texture_path:
            print(f"Texture not found: {get_texture_filename(texture_name, character_type)}")
            return
        await websocket.send(json.dumps({
            "type": "texture_data",
            "texture_name": texture_name,
            "character_type": character_type,
            "data": _read_base64(texture_path)
        }))
        print(f"Sent texture for {texture_name}")

    async def _on_get_players(self, client_id, websocket, data):
        await websocket.send(json.dumps({"type": "player_list",
                                         "players": self._player_list(client_id)}))

    async def _on_object_grab(self, client_id, websocket, data):
        net_id = str(data.get("net_id"))
        xf = data.get("transform", {})
        self.objects[net_id] = {"transform": xf}
        await self._send_everyone({
            "type": "object_spawn",
            "net_id": net_id,
            "transform": xf,
            "seq": data.get("seq", 0),
            "authority": client_id
        })

    async def _on_object_release(self, client_id, websocket, data):
        net_id = str(data.get("net_id"))
        xf = data.get("transform", {})
        vel = data.get("velocity", {"x": 0, "y": 0, "z": 0})
        self.objects[net_id] = {"transform": xf}
        await self._send_everyone({
            "type": "object_update",
            "net_id": net_id,
            "node_path": data.get("node_path", None),
            "transform": xf,
            "velocity": vel,
            "seq": data.get("seq", 0),
            "authority": client_id
        })

    async def _on_object_update(self, client_id, websocket, data):
        net_id = str(data.get("net_id"))
        xf = data.get("transform", {})
        self.objects[net_id] = {"transform": xf}
        await self._send_others(client_id, {
            "type": "object_update",
            "net_id": net_id,
            "node_path": data.get("node_path", None),
            "transform": xf,
            "seq": data.get("seq", 0),
            "authority": client_id
        })

    async def _await_client_key(self, client_id, websocket):
        """Hold a new connection until a message carries the client key; None if it never does."""
        print(f"[Security] Place connection from limbo client (pending ID {client_id}), "
              f"waiting for key...")
        admitted = False

        async def kick():
            await asyncio.sleep(KEY_TIMEOUT_SECONDS)
            if not admitted:
                print(f"[Security] Place limbo client {client_id} sent no valid key within "
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
                    print(f"[Security] Invalid/missing client key from place limbo client "
                          f"{client_id}, disconnecting")
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

    async def _kick_unvalidated(self, client_id, websocket):
        await asyncio.sleep(KEY_TIMEOUT_SECONDS)
        if client_id in self.clients and not self.clients[client_id].get("key_validated"):
            print(f"[Security] Place client {client_id} sent no valid client key within "
                  f"{KEY_TIMEOUT_SECONDS}s, disconnecting")
            await websocket.close(4002, "Timeout")

    async def _key_ok(self, client_id, websocket, kick_task, data):
        """Check the client key every message carries; close the connection when it is wrong."""
        if data.get("ck") != CLIENT_KEY:
            print(f"[Security] Invalid/missing client key from place client {client_id}, "
                  f"disconnecting")
            await websocket.close(4001, "Invalid client")
            return False
        if not self.clients[client_id].get("key_validated"):
            self.clients[client_id]["key_validated"] = True
            if kick_task and not kick_task.done():
                kick_task.cancel()
        return True

    async def _serve(self, client_id, websocket, kick_task, queued):
        async for data in _messages(websocket, queued):
            if not await self._key_ok(client_id, websocket, kick_task, data):
                return
            kind = data["type"]
            handler = self.handlers.get(kind) if isinstance(kind, str) else None
            if handler is not None:
                await handler(client_id, websocket, data)

    async def _drop_client(self, client_id):
        if client_id not in self.clients:
            return
        username = self.clients[client_id]["username"]
        del self.clients[client_id]
        for cid, client in self.clients.items():
            await client["websocket"].send(json.dumps({"type": "player_left",
                                                       "player_id": client_id}))
            await client["websocket"].send(json.dumps({
                "type": "system_message",
                "message": f"{username} has left the place"
            }))

    async def handle_client(self, websocket):
        client_id = self.next_id
        self.next_id += 1
        kick_task = None
        if SECURE_HANDSHAKE:
            first = await self._await_client_key(client_id, websocket)
            if first is None:
                return
            await self._admit_client(client_id, websocket)
            queued = [first]
        else:
            await self._admit_client(client_id, websocket)
            kick_task = asyncio.ensure_future(self._kick_unvalidated(client_id, websocket))
            queued = []
        try:
            await self._serve(client_id, websocket, kick_task, queued)
        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            if kick_task and not kick_task.done():
                kick_task.cancel()
            await self._drop_client(client_id)

    async def start_server(self):
        print(f"Starting Place Server '{self.place_name}' on port {self.port}")
        async with websockets.serve(
            self.handle_client,
            "0.0.0.0",
            self.port,
            max_size=MAX_MESSAGE_SIZE,
            max_queue=MAX_QUEUE_SIZE
        ):
            print(f"Place Server '{self.place_name}' listening on ws://0.0.0.0:{self.port}")
            await asyncio.Future()


async def _messages(websocket, queued):
    """The already-read messages first, then each message parsed off the socket."""
    for data in queued:
        yield data
    async for raw in websocket:
        yield json.loads(raw)


async def main():
    place_name = sys.argv[1] if len(sys.argv) > 1 else "default"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_PORT
    await PlaceServer(place_name, port).start_server()


if __name__ == "__main__":
    asyncio.run(main())
