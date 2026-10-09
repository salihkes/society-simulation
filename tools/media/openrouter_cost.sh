#!/bin/sh
# What OpenRouter has cost — today, this month, and what is left.
#
# The channel runs on the local box by default and spends nothing.  It only
# reaches OpenRouter when something explicitly asks it to: news.py
# --openrouter, or NEWS_BACKEND=openrouter for the news desk.  This prints
# what that has actually cost, straight from OpenRouter, so the answer is
# never a guess.
#
#   tools/media/openrouter_cost.sh            what has been spent
#   tools/media/openrouter_cost.sh mark       remember today's figure
#   tools/media/openrouter_cost.sh since      spend since the last mark
#
# Needs OPENROUTER_API_KEY in the environment.
set -e
mark="${TMPDIR:-/tmp}/openrouter_mark"
[ -n "$OPENROUTER_API_KEY" ] || { echo "OPENROUTER_API_KEY is not set." >&2; exit 1; }

fetch() {
	curl -s --max-time 20 "https://openrouter.ai/api/v1/$1" \
		-H "Authorization: Bearer $OPENROUTER_API_KEY"
}

SHOW=$(cat <<'EOF'
import json, sys
key = json.loads(sys.stdin.readline())["data"]
credits = json.loads(sys.stdin.readline())["data"]
left = credits["total_credits"] - credits["total_usage"]
print(f'  today      ${key["usage_daily"]:.4f}')
print(f'  this week  ${key["usage_weekly"]:.4f}')
print(f'  this month ${key["usage_monthly"]:.4f}')
print(f'  lifetime   ${key["usage"]:.4f}   (this key)')
print(f'  remaining  ${left:.2f}   of ${credits["total_credits"]:.2f}')
EOF
)

key=$(fetch auth/key)
credits=$(fetch credits)

daily=$(printf '%s' "$key" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["usage_daily"])')

case "${1:-show}" in
	mark)
		printf '%s' "$daily" > "$mark"
		echo "Marked at \$$daily spent today."
		;;
	since)
		[ -f "$mark" ] || { echo "Nothing marked yet — run: $0 mark" >&2; exit 1; }
		before=$(cat "$mark")
		python3 -c "print(f'Since the mark: \${float('$daily') - float('$before'):.4f}')"
		;;
	*)
		printf '%s\n%s\n' "$key" "$credits" | python3 -c "$SHOW"
		;;
esac
