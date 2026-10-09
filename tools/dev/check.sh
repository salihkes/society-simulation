#!/bin/bash
# Full check before a commit: client compile, typed module boundaries, protocol
# contract, client tests against the recorded baseline, server tests. Exit 0
# only if everything holds.
#
#   tools/dev/check.sh            everything (~3 minutes)
#   tools/dev/check.sh --server   server tests only
#   tools/dev/check.sh --client   client only
#
# GODOT and PYTHON override the engine and the server venv.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/env.sh"
DEV="$ROOT/tools/dev"
CLIENT="$ROOT/client"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
PYTHON="${PYTHON:-$GAME_VENV_PY}"
command -v "$PYTHON" >/dev/null 2>&1 || PYTHON=python3
OUT="${CHECK_OUT:-${TMPDIR:-/tmp}/game-check}"
JOBS="${JOBS:-10}"
status=0

# Tests that need a GPU, or that crashed before the refactor and only hang.
SKIP="test_rain_render.gd test_snow_render.gd test_regional_water_render.gd test_quest_rendering.gd test_weather_sync.gd"
# Tests that crashed on a script error before the refactor (see client_baseline.txt).
KNOWN_CRASHES="test_building_nav.gd test_clock_jump.gd test_residence.gd"

fail() { echo "FAIL: $*"; status=1; }

# The classes the modules hold each other through. Godot only warns when a member
# is missing on a typed value; client_typed makes that an error for these types.
TYPED="AmbientManager|AmbientTraffic|AmbientPlaces|AmbientEngagement|AmbientReplication"
TYPED="$TYPED|AmbientSchool|SchoolMatch|SchoolAssembly|SchoolBoard|BuildingNav|NavCache"
TYPED="$TYPED|AmbientPedestrian|PedestrianAnimation|UnifiedCharacter|CharacterPlanet|CharacterShip"
TYPED="$TYPED|SpatialShell|ShellBrowser|ShellReader|VRPanel|VRVideoPlayer"
TYPED="$TYPED|NetChat|NetSession|NetWorkspace|NetObjects|NetPlayers|res://src/net/network_controller.gd"

client_compile() {
	local line
	line=$("$GODOT" --headless --path "$CLIENT" --script res://tools/check_scripts.gd 2>&1 |
		grep -E '^FAIL|^check_scripts')
	echo "$line"
	echo "$line" | grep -q ' 0 failed' || fail "client scripts do not all compile"
}

client_typed() {
	local lines
	[ -e "$CLIENT/override.cfg" ] && { fail "client/override.cfg exists: typed check not run"; return; }
	printf '[debug]\ngdscript/warnings/unsafe_method_access=2\ngdscript/warnings/unsafe_property_access=2\n' \
		> "$CLIENT/override.cfg"
	trap 'rm -f "$CLIENT/override.cfg"' EXIT
	lines=$("$GODOT" --headless --path "$CLIENT" --script res://tools/check_scripts.gd 2>&1 |
		grep -A1 -E "not present on the inferred type \"($TYPED)\"" | grep -oE 'Parse Error: .*|res://[^)]*')
	rm -f "$CLIENT/override.cfg"
	trap - EXIT
	if [ -n "$lines" ]; then
		echo "$lines"
		fail "a member missing on a typed module reference"
	else
		echo "typed modules: every member access resolves"
	fi
}

client_protocol() {
	local line
	line=$("$GODOT" --headless --path "$CLIENT" --script res://tests/test_protocol.gd 2>&1 |
		grep PROTOCOL)
	echo "$line"
	echo "$line" | grep -q ', 0 failures' || fail "protocol contract"
}

run_one() {
	local rel="$1" n nice_lvl=10 start=$SECONDS
	n=$(basename "$rel")
	# The nav test samples for ~160 s against a 240 s limit: give it the CPU.
	[ "$n" = "test_building_nav.gd" ] && nice_lvl=0
	nice -n $nice_lvl timeout 300 "$GODOT" --headless --path "$CLIENT" \
		--script "res://tests/$rel" > "$OUT/$n.log" 2>&1
	echo "$? $n $((SECONDS - start))s" >> "$OUT/summary.txt"
}

# Baseline lines ("test_x.gd: ...") of tests present here. World tests live in
# tests/world/ (gitignored), so a fresh clone has none.
existing_tests() {
	local line
	while IFS= read -r line; do
		{ [ -f "$CLIENT/tests/${line%%: *}" ] || [ -f "$CLIENT/tests/world/${line%%: *}" ]; } && printf '%s\n' "$line"
	done
}

client_tests() {
	rm -rf "$OUT"; mkdir -p "$OUT"; : > "$OUT/summary.txt"
	local t n started=0
	for t in "$CLIENT/tests/test_building_nav.gd" "$CLIENT"/tests/test_*.gd "$CLIENT"/tests/world/test_*.gd; do
		[ -f "$t" ] || continue
		n=$(basename "$t")
		if [ "$n" = "test_building_nav.gd" ]; then
			[ $started = 1 ] && continue
			started=1
		fi
		case "$n" in *_stub.gd) continue ;; esac
		case " $SKIP " in *" $n "*) continue ;; esac
		grep -qE 'connect_to_url|WebSocketPeer|ws://|wss://' "$t" && continue
		run_one "${t#"$CLIENT/tests/"}" &
		while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 0.5; done
	done
	wait
	local f crashed=""
	for f in "$OUT"/test_*.gd.log; do
		n=$(basename "$f" .log)
		grep -E '^(FAIL|.*FAILURES?|.*failures|.*: FAIL)' "$f" | sed "s|^|$n: |" | cut -c1-200
	done | grep -v 'test_protocol.gd: PROTOCOL: ' | sort > "$OUT/fail_lines.txt"
	for f in "$OUT"/test_*.gd.log; do
		n=$(basename "$f" .log)
		grep -q "SCRIPT ERROR" "$f" && grep -qE "res://tests/(world/)?$n" "$f" && crashed="$crashed $n"
	done
	local not_run
	not_run=$(echo "$SKIP" | tr ' ' '\n' | sed 's/\.gd$//' | paste -sd'|' -)
	local baseline="$DEV/client_baseline.txt"
	[ -f "$baseline" ] || baseline=/dev/null
	if diff <(grep -vE "^($not_run)\.gd:" "$baseline" | existing_tests | sort) "$OUT/fail_lines.txt"; then
		echo "client tests: failure lines as baseline"
	else
		fail "client tests: failure lines differ from baseline (above)"
	fi
	local known
	known=$(echo $KNOWN_CRASHES | tr ' ' '\n' | sed 's/$/: /' | existing_tests | sed 's/: $//' | sort | xargs)
	if [ "$(echo $crashed | tr ' ' '\n' | sort -u | xargs)" = "$known" ]; then
		echo "client tests: crashes as baseline"
	else
		fail "client tests: crashed set is [$(echo $crashed | xargs)], expected [$known]"
	fi
}

server_tests() {
	local t r ok=0 n=0
	cd "$ROOT/server" || return
	for t in tests/test_*.py; do
		n=$((n + 1))
		r=$(timeout 300 "$PYTHON" -m unittest "tests.$(basename "$t" .py)" 2>&1 | grep -E '^(OK|FAILED)')
		if [ "${r%% *}" = "OK" ]; then ok=$((ok + 1)); else fail "server $t: $r"; fi
	done
	echo "server tests: $ok / $n OK"
	cd "$ROOT" || return
}

case "$1" in
	--server) server_tests ;;
	--client) client_compile; client_typed; client_protocol; client_tests ;;
	*) client_compile; client_typed; client_protocol; client_tests; server_tests ;;
esac
[ $status = 0 ] && echo "CHECK: OK" || echo "CHECK: FAILED"
exit $status
