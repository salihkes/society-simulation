"""Who this deployment is: names, domain, keys and home places, from config/identity.json."""

import json
import os
import sys

from core import paths


def _load(name):
    path = paths.config(name)
    if not os.path.exists(path):
        example = name.replace(".json", ".example.json")
        print(f"using {example}; copy it to {name} and edit", file=sys.stderr)
        path = paths.config(example)
    with open(path, encoding="utf-8") as f:
        return json.load(f)


_IDENTITY = _load("identity.json")


def get(key):
    """A value from identity.json; a missing key is an error, not a guess."""
    return _IDENTITY[key]
