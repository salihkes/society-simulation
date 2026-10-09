"""The website: the JSON API under /api/ and, for local use, the pages in web/ui and the game in web/play."""

import asyncio
import os

from aiohttp import web

from accounts.auth import AuthManager
from core import identity
from core import paths
from core.constants import WEB_API_HOST, WEB_API_PORT
from web import accounts, community, decals, session
from web.reply import fail

REDIRECTS = {"/play": "/play/", "/home": "/", "/r": "/r/", "/game": "/play/"}


@web.middleware
async def api_errors(request, handler):
    """Errors under /api/ answer in the API's JSON shape instead of an HTML page."""
    try:
        return await handler(request)
    except web.HTTPException as e:
        if not request.path.startswith("/api/") or e.status < 400:
            raise
        return fail(e.status, e.reason)


async def identity_info(request):
    return web.json_response({
        "product_name": identity.get("product_name"),
        "community_home": identity.get("community_home")["name"],
        "enable_guest": accounts.env_flag("ENABLE_GUEST"),
    })


def _file_under(root, rel):
    """The file at `rel` inside `root`, or None when it is missing or outside."""
    root = os.path.realpath(root)
    full = os.path.realpath(os.path.join(root, rel.lstrip("/")))
    if not full.startswith(root + os.sep) or not os.path.isfile(full):
        return None
    return full


def _try_files(root, path):
    """The first of path, path.html and path/index.html that exists (the proxy's try_files)."""
    for rel in (path, path + ".html", path.rstrip("/") + "/index.html"):
        found = _file_under(root, rel)
        if found:
            return found
    return None


async def redirect(request):
    raise web.HTTPFound(REDIRECTS[request.path])


async def old_game(request):
    raise web.HTTPFound("/play/" + request.match_info["tail"])


async def play_as_guest(request):
    raise web.HTTPFound("/play/" if accounts.env_flag("ENABLE_GUEST") else "/login")


async def game_file(request):
    found = _try_files(paths.web("play"), request.match_info["tail"] or "index.html")
    if not found:
        raise web.HTTPNotFound()
    return web.FileResponse(found)


async def board_page(request):
    found = _file_under(paths.web("ui"), "r.html")
    if not found:
        raise web.HTTPNotFound()
    return web.FileResponse(found)


async def ui_file(request):
    found = _try_files(paths.web("ui"), request.path if request.path != "/" else "/index.html")
    if not found:
        raise web.HTTPNotFound()
    return web.FileResponse(found)


def _add_page_routes(app):
    r = app.router
    for path in REDIRECTS:
        r.add_get(path, redirect)
    r.add_get("/game/{tail:.*}", old_game)
    r.add_get("/play-as-guest", play_as_guest)
    r.add_get("/play/{tail:.*}", game_file)
    r.add_get("/r/{tail:.*}", board_page)
    r.add_get("/{tail:.*}", ui_file)


def build_app(auth=None, secret=None):
    """The aiohttp Application; `auth` is shared with the game server, `secret` signs sessions."""
    app = web.Application(middlewares=[api_errors, session.middleware],
                          client_max_size=decals.MAX_REQUEST_BYTES)
    app[accounts.AUTH] = auth or AuthManager()
    app[session.SECRET] = secret or session.load_secret()
    app.router.add_get("/api/identity", identity_info)
    accounts.add_routes(app)
    community.add_routes(app)
    decals.add_routes(app)
    _add_page_routes(app)
    return app


async def start_web_server(auth=None):
    """Serve the website on WEB_API_HOST:WEB_API_PORT until cancelled."""
    runner = web.AppRunner(build_app(auth), access_log=None)
    await runner.setup()
    try:
        await web.TCPSite(runner, WEB_API_HOST, WEB_API_PORT).start()
        print(f"[Web] API and pages on http://{WEB_API_HOST}:{WEB_API_PORT}/ "
              f"(pages from {paths.web()})")
        await asyncio.Future()
    finally:
        await runner.cleanup()
