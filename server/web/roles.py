"""Who may post, administer and invite on the website, from config/roles.yaml (re-read on every check)."""

import os
import sys

import yaml

from core import paths

ROLES_PATH = paths.config("roles.yaml")
EXAMPLE_PATH = paths.config("roles.example.yaml")
_noticed = False


def _roles_file():
    """roles.yaml, else the tracked example (with a notice, once), else None."""
    global _noticed
    if os.path.exists(ROLES_PATH):
        return ROLES_PATH
    if not os.path.exists(EXAMPLE_PATH):
        return None
    if not _noticed:
        print("using roles.example.yaml; copy it to roles.yaml and edit", file=sys.stderr)
        _noticed = True
    return EXAMPLE_PATH


def load_roles():
    """{"posters", "admins", "inviters"}; inviters is None when the key is absent (anyone may invite)."""
    path = _roles_file()
    if path is None:
        return {"posters": [], "admins": [], "inviters": None}
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    out = {}
    for key in ("posters", "admins", "inviters"):
        value = data.get(key)
        if isinstance(value, str):
            value = [value]
        out[key] = list(value or [])
    if data.get("inviters") is None:
        out["inviters"] = None
    return out


def can_post(username):
    return bool(username) and username in load_roles()["posters"]


def can_admin(username):
    return bool(username) and username in load_roles()["admins"]


def can_invite(username):
    if not username:
        return False
    inviters = load_roles()["inviters"]
    return inviters is None or username in inviters
