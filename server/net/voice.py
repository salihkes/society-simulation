"""Voice chat server: relays audio chunks between clients in the same room."""

import asyncio
import json
import time
from collections import defaultdict

import websockets


def _now_ms():
    return int(time.time() * 1000)


class VoiceChatServer:
    def __init__(self, port=3246):
        self.port = port
        self.clients = {}               # websocket -> {"username", "room", "user_type"}
        self.rooms = defaultdict(set)   # room_id -> set of websockets
        self.ping_interval = 3          # seconds
        self.ping_tasks = {}            # websocket -> ping task

    async def _ping_loop(self, websocket):
        """Ping a client every ping_interval seconds until it leaves or a send fails."""
        try:
            while websocket in self.clients:
                await asyncio.sleep(self.ping_interval)
                if websocket not in self.clients:
                    continue
                try:
                    await websocket.send(json.dumps({"type": "ping"}))
                except websockets.exceptions.ConnectionClosed:
                    break
                except Exception as e:
                    print(f"Error sending ping: {e}")
                    break
        except asyncio.CancelledError:
            pass

    async def start_ping_task(self, websocket):
        task = asyncio.create_task(self._ping_loop(websocket))
        self.ping_tasks[websocket] = task
        return task

    async def register_client(self, websocket, client_info):
        self.clients[websocket] = client_info
        room_id = client_info.get('room', 'default')
        self.rooms[room_id].add(websocket)
        await self.start_ping_task(websocket)
        print(f"Voice client registered: {client_info['username']} in room '{room_id}' "
              f"({len(self.clients)} total)")
        await self.broadcast_to_room(room_id, {
            "type": "user_joined",
            "username": client_info['username'],
            "timestamp": _now_ms()
        }, exclude=websocket)

    async def unregister_client(self, websocket):
        if websocket not in self.clients:
            return
        client_info = self.clients[websocket]
        room_id = client_info.get('room', 'default')
        if websocket in self.ping_tasks:
            self.ping_tasks[websocket].cancel()
            del self.ping_tasks[websocket]
        self.rooms[room_id].discard(websocket)
        del self.clients[websocket]
        print(f"Voice client unregistered: {client_info['username']} from room '{room_id}' "
              f"({len(self.clients)} remaining)")
        await self.broadcast_to_room(room_id, {
            "type": "user_left",
            "username": client_info['username'],
            "timestamp": _now_ms()
        })

    async def broadcast_to_room(self, room_id, message, exclude=None):
        """Send to every client in a room; clients whose send fails are unregistered."""
        if room_id not in self.rooms:
            return
        room_clients = self.rooms[room_id].copy()
        if exclude:
            room_clients.discard(exclude)
        if not room_clients:
            return
        message_json = json.dumps(message)
        disconnected = set()
        for client_ws in room_clients:
            try:
                await client_ws.send(message_json)
            except websockets.exceptions.ConnectionClosed:
                disconnected.add(client_ws)
            except Exception as e:
                print(f"Error sending to voice client: {e}")
                disconnected.add(client_ws)
        for ws in disconnected:
            await self.unregister_client(ws)

    async def handle_audio_chunk(self, websocket, data):
        """Stamp a chunk with its sender and send it to the whole room, sender included."""
        if websocket not in self.clients:
            return
        client_info = self.clients[websocket]
        room_id = client_info.get('room', 'default')
        await self.broadcast_to_room(room_id, {
            "type": "audio_chunk",
            "username": client_info['username'],
            "audio_data": data['audio_data'],
            "timestamp_ms": data.get('timestamp_ms', _now_ms()),
            "chunk_info": data.get('chunk_info', {})
        })

    async def _handle_message(self, websocket, message):
        try:
            data = json.loads(message)
            kind = data.get('type')
            if kind == 'audio_chunk':
                await self.handle_audio_chunk(websocket, data)
            elif kind == 'ping':
                await websocket.send(json.dumps({"type": "pong"}))
            elif kind != 'pong':
                print(f"Unknown voice message type: {kind}")
        except json.JSONDecodeError:
            print("Received invalid JSON from voice client")
        except Exception as e:
            print(f"Error handling voice message: {e}")

    async def handle_client(self, websocket):
        client_info = None
        try:
            registration = json.loads(await websocket.recv())
            if registration.get('type') != 'register':
                await websocket.send(json.dumps({"type": "error",
                                                 "message": "First message must be registration"}))
                return
            client_info = {
                'username': registration.get('username', 'Anonymous'),
                'room': registration.get('room', 'default'),
                'user_type': registration.get('user_type', 'player')  # 'player' or 'streamer'
            }
            await self.register_client(websocket, client_info)
            await websocket.send(json.dumps({
                "type": "registered",
                "username": client_info['username'],
                "room": client_info['room']
            }))
            async for message in websocket:
                await self._handle_message(websocket, message)
        except websockets.exceptions.ConnectionClosed:
            pass
        except Exception as e:
            print(f"Error in voice client handler: {e}")
        finally:
            if client_info:
                await self.unregister_client(websocket)

    async def start_server(self, ssl_context=None):
        protocol = "wss" if ssl_context else "ws"
        print(f"Starting Voice Chat Server on port {self.port}")
        async with websockets.serve(self.handle_client, "0.0.0.0", self.port, ssl=ssl_context):
            print(f"Voice Chat Server listening on {protocol}://0.0.0.0:{self.port}")
            await asyncio.Future()
