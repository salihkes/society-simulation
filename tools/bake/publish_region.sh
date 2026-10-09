#!/bin/bash
# Publish the country map (terrain tiles, road chunks) for the web build.
# Drag into a terminal after any regionforge bake. See tools/bake/publish_region.py.
exec python3 "$(cd "$(dirname "$0")" && pwd)/publish_region.py" "$@"
