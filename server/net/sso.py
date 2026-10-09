"""Single-use sign-on tokens: base64("username:timestamp:signature"), signed HMAC-SHA256 with SSO_SECRET_KEY."""

import base64
import hashlib
import hmac
import time

from core.constants import SSO_SECRET_KEY, SSO_TOKEN_EXPIRY_SECONDS

USED_TOKENS_LIMIT = 1000

used_tokens = set()


def _signature(username, timestamp):
    message = f"{username}:{timestamp}"
    return hmac.new(SSO_SECRET_KEY.encode(), message.encode(), hashlib.sha256).hexdigest()


def issue_sso_token(username):
    """A fresh token for `username`, valid for SSO_TOKEN_EXPIRY_SECONDS."""
    timestamp = str(int(time.time()))
    raw = f"{username}:{timestamp}:{_signature(username, timestamp)}"
    return base64.b64encode(raw.encode()).decode()


def validate_sso_token(token):
    """Return the token's username if it is well formed, signed, fresh and unused; else None."""
    try:
        parts = base64.b64decode(token).decode().split(':')
        if len(parts) != 3:
            print("[SSO] Invalid token format")
            return None
        username, timestamp_str, provided_signature = parts
        if token in used_tokens:
            print(f"[SSO] Token already used for {username}")
            return None
        expected = _signature(username, timestamp_str)
        if not hmac.compare_digest(provided_signature, expected):
            print("[SSO] Invalid signature for token")
            return None
        if int(time.time()) - int(timestamp_str) > SSO_TOKEN_EXPIRY_SECONDS:
            print(f"[SSO] Token expired for {username}")
            return None
        used_tokens.add(token)
        # Bounds memory; a token still inside its expiry could be replayed after this.
        if len(used_tokens) > USED_TOKENS_LIMIT:
            used_tokens.clear()
        print(f"[SSO] Token validated for {username}")
        return username
    except Exception as e:
        print(f"[SSO] Token validation error: {e}")
        return None
