"""JSON replies and request bodies shared by the API modules: {"success": bool, "message"?, ...}."""

import json

from aiohttp import web


def ok(**fields):
    return web.json_response(dict(success=True, **fields))


def fail(status, message):
    return web.json_response({"success": False, "message": message}, status=status)


async def body(request):
    """The JSON object a POST carries; {} for anything else, so a cross-site form post carries nothing."""
    if request.content_type != "application/json":
        return {}
    try:
        data = await request.json()
    except (json.JSONDecodeError, UnicodeDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def text(data, key):
    value = data.get(key)
    return value.strip() if isinstance(value, str) else ""
