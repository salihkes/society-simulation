#!/bin/bash
# Lint the code with the project's rules: gdlint (GDScript) and ruff (Python).
# Read-only; reports, never rewrites. Install the tools once with:
#   pip install "gdtoolkit==4.*" ruff
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
status=0
if command -v gdlint > /dev/null; then
	gdlint client/src client/tools client/tests || status=1
else
	echo "gdlint not installed: pip install \"gdtoolkit==4.*\""
fi
if command -v ruff > /dev/null; then
	ruff check server council tools tv || status=1
else
	echo "ruff not installed: pip install ruff"
fi
exit $status
