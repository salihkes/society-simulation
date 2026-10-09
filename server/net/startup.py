"""Server startup: load the persistent state, then run every service together."""

import asyncio
import atexit
import os
import ssl

import websockets

import mind as mind_pkg
from core import paths
from accounts.auth import AuthManager
from core.constants import (
    EXTERNAL_DOMAIN, MAIN_SERVER_HOST, MAIN_SERVER_PORT, MAX_MESSAGE_SIZE, MAX_QUEUE_SIZE,
    PCK_HTTP_SERVER_PORT, PLACE_SERVER_START_PORT, PLACES_DIR, PLOTS_DATA_DIR,
    USER_DATA_DIR, USER_TEXTURE_DIR, VOICE_CHAT_SERVER_PORT, WEB_API_HOST, WEB_API_PORT,
    WORLD_ENVIRONMENT_FILE,
)
from net import places, plots, state, world_map
from net.connection import handle_client
from net.voice import VoiceChatServer
from net.weather import weather_monitor
from services.pck import start_pck_server
from web.app import start_web_server


def load_state():
    state.auth_manager = AuthManager()
    # The world folder is data/world, an external one, or a scratch copy (paths.open_world).
    state.world_mind = mind_pkg.Mind(paths.open_world(), state.send_all, state.send_world,
                                     environment_file=WORLD_ENVIRONMENT_FILE)
    for d in (USER_TEXTURE_DIR, USER_DATA_DIR, PLACES_DIR, PLOTS_DATA_DIR):
        os.makedirs(d, exist_ok=True)
    plots.load()
    world_map.load()
    atexit.register(places.cleanup_place_servers)


def _load_cwd_env():
    """Apply KEY=value lines from ./.env for unset variables; comments and quotes are not handled."""
    env_file = os.path.join(os.getcwd(), '.env')
    if not os.path.exists(env_file):
        return
    with open(env_file, 'r') as ef:
        for line in ef:
            if '=' in line:
                k, v = line.strip().split('=', 1)
                os.environ.setdefault(k, v)


def _ssl_context():
    """A TLS context from SSL_CERT_PATH and SSL_KEY_PATH, or None for plain ws."""
    cert_path = os.environ.get('SSL_CERT_PATH', None)
    key_path = os.environ.get('SSL_KEY_PATH', None)
    if not (cert_path and key_path and os.path.exists(cert_path)):
        print("SSL disabled (no certificates found). "
              "Set SSL_CERT_PATH and SSL_KEY_PATH environment variables.")
        return None
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert_path, key_path)
    print(f"SSL enabled with certificate: {cert_path}")
    return context


async def serve():
    paths.ensure_runtime_dirs()
    _load_cwd_env()
    ssl_context = _ssl_context()
    protocol = "wss" if ssl_context else "ws"
    game_server = websockets.serve(
        handle_client,
        MAIN_SERVER_HOST,
        MAIN_SERVER_PORT,
        max_size=MAX_MESSAGE_SIZE,
        max_queue=MAX_QUEUE_SIZE,
        ssl=ssl_context
    )
    voice_server = VoiceChatServer(VOICE_CHAT_SERVER_PORT).start_server(ssl_context)
    weather_task = weather_monitor()
    treaty_task = world_map.treaty_cleanup()
    mind_task = state.world_mind.run()
    # Public readers fetch packs through the domain's /pck/ path, not this server.
    pck_task = start_pck_server(ssl_context)
    web_task = start_web_server(state.auth_manager)
    print("Starting unified server with:")
    print(f"- Game Server (Lobby) on {protocol}://{MAIN_SERVER_HOST}:{MAIN_SERVER_PORT}")
    print(f"- Voice Chat Server on {protocol}://{MAIN_SERVER_HOST}:{VOICE_CHAT_SERVER_PORT}")
    print(f"- PCK files: public via https://{EXTERNAL_DOMAIN}/pck/ ; "
          f"local dev via http://<host>:{PCK_HTTP_SERVER_PORT}/pck/")
    print(f"- Website (API and pages) on http://{WEB_API_HOST}:{WEB_API_PORT}/")
    print(f"- Weather Monitor (checks {WORLD_ENVIRONMENT_FILE} every 5s)")
    print("- Treaty Cleanup (checks expired treaties every 5s)")
    print(f"- Place Servers will spawn dynamically on ports {PLACE_SERVER_START_PORT}+")
    await asyncio.gather(
        game_server,
        voice_server,
        weather_task,
        treaty_task,
        mind_task,
        pck_task,
        web_task
    )
