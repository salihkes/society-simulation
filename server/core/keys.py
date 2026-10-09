"""Secrets kept in config/secrets.json (gitignored), generated on first use."""

import json
import os
import secrets

from core import paths


def get(name, path=None):
    """The secret `name`; a random one is created and stored when it is missing."""
    path = path or paths.config("secrets.json")
    stored = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            stored = json.load(f)
    if stored.get(name):
        return stored[name]
    stored[name] = secrets.token_hex(32)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(stored, f, indent=2)
    print(f"[Keys] new {name} written to {path}")
    return stored[name]
