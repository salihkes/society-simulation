#!/bin/bash
# THE COUNTRY: city.sh with the world process on the country map.
#
# Same server, same supervision, same flags as tools/run/city.sh. The only
# difference is the scene the world loads: workspace_country.tscn, which adds
# the terrain, the intercity roads and the other cities around the home one. The world
# keeps every city loaded (no distance streaming on the dedicated process).
#
#   tools/run/country.sh                     local, plain ws on 127.0.0.1:2053
#   tools/run/country.sh --ssl               production certs from .env
#   tools/run/country.sh --clean             scratch copy, no memories
#   tools/run/country.sh --once              do not restart either half
#
# The city stays the default: tools/run/city.sh is unchanged.

HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/city.sh" --scene "res://assets/scenes/workspace_country.tscn" "$@"
