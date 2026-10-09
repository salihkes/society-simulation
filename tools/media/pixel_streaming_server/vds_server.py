import argparse
import asyncio
import json
import logging
import os
import uuid

from aiohttp import web
from aiortc import RTCPeerConnection, RTCSessionDescription
from aiortc.contrib.media import MediaRelay

ROOT = os.path.dirname(__file__)

# Global State
relay = None
publisher_pc = None
publisher_dc = None # Data channel to the local streamer (for input forwarding)
pcs = set()

# Auth Configuration
AUTH_KEY = os.environ.get("GAME_STREAM_KEY", "change-me")

async def index(request):
    content = open(os.path.join(ROOT, "templates/index.html"), "r").read()
    return web.Response(content_type="text/html", text=content)

async def javascript(request):
    content = open(os.path.join(ROOT, "static/client.js"), "r").read()
    return web.Response(content_type="application/javascript", text=content)

# --- CLIENT / VIEWER ROUTE ---
async def offer_viewer(request):
    # Web Client connects here to watch the stream
    global relay, publisher_dc
    
    if relay is None:
        return web.Response(status=503, text="Stream not active")

    params = await request.json()
    offer = RTCSessionDescription(sdp=params["sdp"], type=params["type"])

    pc = RTCPeerConnection()
    pcs.add(pc)

    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        print("Viewer connection state is %s" % pc.connectionState)
        if pc.connectionState == "failed":
            await pc.close()
            pcs.discard(pc)

    # Handle Input from Viewer
    @pc.on("datachannel")
    def on_datachannel(channel):
        @channel.on("message")
        def on_message(message):
            # Forward input to the Publisher (Local Streamer)
            if publisher_dc and publisher_dc.readyState == "open":
                try:
                    publisher_dc.send(message)
                except Exception as e:
                    print(f"Failed to relay input: {e}")

    # Subscribe to the relay (video track)
    # The relay provides a track that copies the publisher's frames
    video_track = relay.subscribe(publisher_pc.getTransceivers()[0].receiver.track)
    pc.addTrack(video_track)

    await pc.setRemoteDescription(offer)
    answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)

    return web.Response(
        content_type="application/json",
        text=json.dumps(
            {"sdp": pc.localDescription.sdp, "type": pc.localDescription.type}
        ),
    )

# --- PUBLISHER / LOCAL STREAMER ROUTE ---
async def publish(request):
    # Local PC connects here to send the stream
    global relay, publisher_pc, publisher_dc

    # Simple Auth
    auth_header = request.headers.get("X-Auth-Key")
    if auth_header != AUTH_KEY:
        return web.Response(status=401, text="Unauthorized")

    params = await request.json()
    offer = RTCSessionDescription(sdp=params["sdp"], type=params["type"])

    pc = RTCPeerConnection()
    publisher_pc = pc
    pcs.add(pc)

    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        print("Publisher connection state is %s" % pc.connectionState)
        if pc.connectionState == "failed" or pc.connectionState == "closed":
            await pc.close()
            pcs.discard(pc)
            # Reset global state if publisher dies
            global relay, publisher_dc
            if pc == publisher_pc:
                relay = None
                publisher_dc = None
                print("Publisher disconnected, stream stopped.")

    @pc.on("track")
    def on_track(track):
        global relay
        if track.kind == "video":
            print("Publisher started video stream")
            relay = MediaRelay() # Create a new relay for this track
            # We don't need to do anything else, the relay tracks are created on subscription

    @pc.on("datachannel")
    def on_datachannel(channel):
        global publisher_dc
        print("Publisher established input channel")
        publisher_dc = channel

    await pc.setRemoteDescription(offer)
    answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)

    return web.Response(
        content_type="application/json",
        text=json.dumps(
            {"sdp": pc.localDescription.sdp, "type": pc.localDescription.type}
        ),
    )

async def on_shutdown(app):
    coros = [pc.close() for pc in pcs]
    await asyncio.gather(*coros)
    pcs.clear()

if __name__ == "__main__":
    app = web.Application()
    app.on_shutdown.append(on_shutdown)
    
    # Viewer routes
    app.router.add_get("/", index)
    app.router.add_get("/client.js", javascript)
    app.router.add_post("/offer", offer_viewer) # Standard client connects here
    
    # Publisher route
    app.router.add_post("/publish", publish)
    
    print(f"VDS Middleware started on port 80. Auth Key: {AUTH_KEY}")
    web.run_app(app, access_log=None, port=80)

