"""Browser sessions: a JSON payload in a cookie, signed with HMAC-SHA256 under a secret from config/secrets.json."""

import base64
import hashlib
import hmac
import json
import time

from aiohttp import web

from core import keys

COOKIE_NAME = "session"
MAX_AGE_SECONDS = 30 * 24 * 60 * 60
SECRET_KEY = "session_secret"
SECRET = web.AppKey("session_secret", bytes)
SESSION = web.RequestKey("session", dict)
COOKIE_FLAGS = {"path": "/", "httponly": True, "secure": True, "samesite": "Lax"}


def load_secret(path=None):
    """The session secret from config/secrets.json, created there on first use."""
    return keys.get(SECRET_KEY, path).encode()


def _sign(secret, body):
    return hmac.new(secret, body.encode(), hashlib.sha256).hexdigest()


def encode(secret, payload):
    data = dict(payload, iat=int(time.time()))
    body = base64.urlsafe_b64encode(json.dumps(data).encode()).decode()
    return f"{body}.{_sign(secret, body)}"


def decode(secret, value):
    """The payload of a well signed, unexpired cookie value; {} for anything else."""
    body, _, sig = (value or "").partition(".")
    if not sig or not hmac.compare_digest(sig, _sign(secret, body)):
        return {}
    try:
        data = json.loads(base64.urlsafe_b64decode(body.encode()))
    except ValueError:
        return {}
    if not isinstance(data, dict) or time.time() - data.pop("iat", 0) > MAX_AGE_SECONDS:
        return {}
    return data


@web.middleware
async def middleware(request, handler):
    """Load request[SESSION]; write the cookie back only when the handler changed it."""
    secret = request.app[SECRET]
    loaded = decode(secret, request.cookies.get(COOKIE_NAME))
    request[SESSION] = dict(loaded)
    response = await handler(request)
    current = request[SESSION]
    if current == loaded:
        return response
    if current:
        response.set_cookie(COOKIE_NAME, encode(secret, current), **COOKIE_FLAGS)
    else:
        response.del_cookie(COOKIE_NAME, **COOKIE_FLAGS)
    return response


def user(request):
    return request[SESSION].get("user")
