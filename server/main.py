#!/usr/bin/env python
"""The game server's entry point; importing it loads state without starting (server_gui.py relies on that)."""

import os


def _load_env_file(path):
    if not os.path.exists(path):
        return
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if '=' not in line or line.startswith('#'):
                continue
            key, value = line.split('=', 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
                value = value[1:-1]     # KEY="value": the quotes are not the value
            os.environ.setdefault(key.strip(), value)


# Before any other import: core/paths.py and others read the environment at import time.
_load_env_file(os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env'))

import asyncio  # noqa: E402

from net import startup  # noqa: E402
from net.state import clients  # noqa: E402,F401  (the live client table, for server_gui)

startup.load_state()


async def main():
    await startup.serve()


if __name__ == "__main__":
    from core import log
    log.install()  # tee all output to data/logs/latest.log
    asyncio.run(main())
