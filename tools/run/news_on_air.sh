#!/bin/sh
# Put a bulletin on air and start the channel.
#
# A bulletin only plays when three things are true, and getting one wrong
# leaves you watching filler with no explanation:
#   1. it sits in tv/news/ with its .txt beside it (the headline, the
#      source and the detail lines are read from there, and only there);
#   2. it has a .package.json saying it is news and when it goes stale —
#      without one the channel gives it news_max_age_minutes from the file's
#      own timestamp, which is an hour, and an older file is simply skipped;
#   3. the schedule names a slot that has not passed yet.  News more than
#      news_late_seconds late is dropped: a bulletin is not worth joining
#      halfway.
# This script does all three, then starts the channel on that slot.
#
#   tools/run/news_on_air.sh [bulletin.mp4] [minutes from now]
#
# Drag a bulletin onto the terminal and press return, or run it bare to put
# the newest bulletin in tv/news/ on air two minutes from now.
set -e
here="$(cd "$(dirname "$0")/../.." && pwd)"
tv="$here/tv"
news="$tv/news"

clip="$1"
if [ -z "$clip" ]; then
	clip=$(ls -t "$news"/*.mp4 2>/dev/null | head -1)
	[ -n "$clip" ] || { echo "No bulletin in $news. Make one with production.py news." >&2; exit 1; }
	echo "Newest bulletin: $(basename "$clip")"
fi
[ -f "$clip" ] || { echo "No such bulletin: $clip" >&2; exit 1; }

# It must live in news/ — the headline graphics are loaded from the sibling
# .txt only for clips in a folder of that name.
parent=$(cd "$(dirname "$clip")" && pwd)
if [ "$parent" != "$news" ]; then
	echo "Copying into $news (graphics are only drawn for clips that live there) …"
	base="${clip%.*}"
	for ext in mp4 txt scenes.json brief.json; do
		[ -f "$base.$ext" ] && cp "$base.$ext" "$news/"
	done
	clip="$news/$(basename "$clip")"
fi

stem="${clip%.*}"
[ -f "$stem.txt" ] || echo "Warning: no $(basename "$stem").txt — it will air without headline graphics."

minutes="${2:-2}"
slot=$(date -v+"${minutes}"M "+%H:%M")
today=$(date "+%Y-%m-%d")
now=$(date "+%Y-%m-%dT%H:%M:%S%z")
stale=$(date -v+12H "+%Y-%m-%dT%H:%M:%S%z")

cat > "$stem.package.json" <<EOF
{
 "kind": "news",
 "presentation": "presenter",
 "repeatable": false,
 "state": "ready",
 "not_before": "$now",
 "expires_at": "$stale"
}
EOF

cat > "$tv/schedule.txt" <<EOF
# Schedule for $today — written by tools/run/news_on_air.sh
# The channel reloads this file while it runs; a slot already past is skipped.

$slot - news
EOF

echo "On air at $slot: $(basename "$clip")"
echo "Starting the channel — the bulletin begins at $slot."
cd "$tv"
exec .venv/bin/python main.py --design cnbce --resolution 1280x720
