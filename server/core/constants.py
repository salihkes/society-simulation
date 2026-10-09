#!/usr/bin/env python
"""Server-wide constants: file locations (through paths.py), ports, limits and keys."""

from core import identity, keys
from core import paths

# Character type of a new player: "humanoid", "countryball", "countryball_oneside" or "custom".
DEFAULT_CHARACTER_TYPE = "humanoid"

USER_TEXTURE_DIR = paths.assets("textures")
FLAGS_DIR = paths.assets("flags")           # country flags worn by countryballs
PLACES_DIR = paths.assets("places")

USER_DATA_DIR = paths.data("users")
PLOTS_DATA_DIR = paths.data("plots")

# Which plot id (a Plot_<id> polygon in the workspace scene) belongs to which account.
PLOTS_CONFIG_FILE = paths.data("plots.json")

# Last reported plot polygons, so placements validate before the world reconnects.
PLOT_GEOMETRY_FILE = paths.data("plot_geometry.json")

WORLD_ENVIRONMENT_FILE = paths.data("world_environment.json")
MAP_STATE_FILE = paths.data("map_state.json")

# Province map colours auto-assigned to players on first login.
MAP_COLOR_PALETTE = [
    "c0392b", "2980b9", "27ae60", "f39c12", "8e44ad",
    "1abc9c", "d35400", "2c3e50", "e74c3c", "3498db",
    "2ecc71", "e67e22", "9b59b6", "16a085", "f1c40f",
    "34495e",
]

# Optional {"username": {"color": "hex"}}: admin overrides of player colours.
MAP_PLAYERS_OVERRIDE_FILE = paths.data("map_players.json")

TREATY_TIMEOUT_SECONDS = 30

MAP_REQUIRE_ONLINE_TO_OCCUPY = True

# The public origin; its reverse proxy terminates TLS and forwards /mv, /voice, /cinema, /pck/ to the ports below.
EXTERNAL_DOMAIN = identity.get("external_domain")

# The client dials 3246 for voice beside a local server (network_controller.gd LOCAL_SERVICE_PORTS).
VOICE_CHAT_SERVER_PORT = 3246
VOICE_CHAT_SERVER_URL = f"wss://{EXTERNAL_DOMAIN}/voice"

MAIN_SERVER_PORT = 2053
MAIN_SERVER_HOST = "0.0.0.0"

PLACE_SERVER_START_PORT = 2086

MAX_MESSAGE_SIZE = 10_000_000   # bytes
MAX_QUEUE_SIZE = None           # no limit

# Signs the website's single sign-on tokens; the website uses the same value.
SSO_SECRET_KEY = keys.get("sso_secret_key")
SSO_TOKEN_EXPIRY_SECONDS = 60

# Every client message must carry this key (also built into the client).
CLIENT_KEY = identity.get("client_key")
SECURE_HANDSHAKE = True

# .pck packs in this directory are served; the manifest adds optional metadata.
PCK_PACKAGES_DIR = paths.assets("pck")
PCK_MANIFEST_FILE = paths.assets("pck_manifest.json")
# Not 8080, which a local model server often holds; serves loopback and LAN only.
PCK_HTTP_SERVER_PORT = 8099

# The website's JSON API (and its pages, for local use); the reverse proxy forwards /api/ here.
WEB_API_HOST = "127.0.0.1"
WEB_API_PORT = 8100
