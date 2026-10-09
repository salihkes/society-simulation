#!/bin/sh
# Put the channel on air, with everything running on OpenRouter.
#
#   tools/run/channel.sh            on air, all models in the cloud
#   tools/run/channel.sh --local    on air, the boxes at home instead
#
# The channel writes its own bulletins while it broadcasts: it queues the
# upcoming news slots, produces them, and airs them.  Watch at
# http://localhost:5002/ once it says HLS.
#
# Why the models are pinned here and not in config.toml: the key does not
# belong in a tracked file, and an unpinned cloud model is expensive.  The
# aggregator's own default is anthropic/claude-sonnet-5, and every ReAct step
# of every story would go to it — two to three orders of magnitude more than
# the model named below for the same bulletin.  Never leave it unset.
#
# The embedding model is NOT free to change.  news.db holds 2560-dimension
# vectors from Qwen3-Embedding-4B and the on-air log is compared against
# them; the 8B returns 4096 and would not improve the numbers, it would make
# them incomparable.  qwen3-embedding-4b is the cloud sibling of the local
# GGUF, and a vector from one matches a vector from the other.
set -e
here="$(cd "$(dirname "$0")/../.." && pwd)"
tv="$here/tv"

# tv/.env, which nothing else reads.  Flask prints a tip about
# python-dotenv and then ignores the file, and even if it did not, Flask is
# one process out of four: the bulletin writer, the production worker and the
# desk's pipeline are all separate and would each see an empty environment.
# Exporting here puts the keys in front of everything the channel starts.
# Keys already in the environment win, so a one-off `RUNPOD_API_KEY=… ` on the
# command line still overrides the file.
if [ -f "$tv/.env" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$(printf '\r')}"
		case "$line" in ''|'#'*) continue ;; esac
		key="${line%%=*}"
		value="${line#*=}"
		# Only NAME=value lines; anything else in the file is left alone.
		case "$key" in
			*[!A-Za-z0-9_]*|'') continue ;;
		esac
		# Strip one layer of matching quotes, as a .env file usually carries.
		case "$value" in
			\'*\') value="${value#\'}"; value="${value%\'}" ;;
			\"*\") value="${value#\"}"; value="${value%\"}" ;;
		esac
		eval "existing=\${$key-}"
		[ -n "$existing" ] || export "$key=$value"
	done < "$tv/.env"
fi

if [ "$1" = "--local" ]; then
	shift
	echo "On air with the local boxes."
else
	[ -n "$OPENROUTER_API_KEY" ] || {
		echo "OPENROUTER_API_KEY is not set.  Use --local to stay at home." >&2
		exit 1
	}

	# A ceiling, checked before going on air.  The channel produces
	# unattended; without this a stuck loop spends all night.
	CEILING="${CHANNEL_DAILY_CEILING:-2.00}"
	spent=$(curl -s --max-time 20 https://openrouter.ai/api/v1/auth/key \
		-H "Authorization: Bearer $OPENROUTER_API_KEY" |
		python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["usage_daily"])' 2>/dev/null || echo 0)
	over=$(python3 -c "print(1 if float('$spent') >= float('$CEILING') else 0)")
	if [ "$over" = "1" ]; then
		echo "Already spent \$$spent today, ceiling is \$$CEILING." >&2
		echo "Raise CHANNEL_DAILY_CEILING or use --local." >&2
		exit 1
	fi
	echo "OpenRouter: \$$spent spent today, ceiling \$$CEILING."

	# The bulletin, the scene director and the day's schedule.
	export LLM_URL="https://openrouter.ai/api/v1"
	export LLM_MODEL="google/gemma-4-26b-a4b-it"
	export LLM_API_KEY="$OPENROUTER_API_KEY"

	# Embeddings for stories the outlets send without one.
	export EMBED_URL="https://openrouter.ai/api"
	export EMBED_MODEL="qwen/qwen3-embedding-4b"
	export EMBED_API_KEY="$OPENROUTER_API_KEY"

	# The news desk's own pipeline, when it refreshes its stories.
	export NEWS_BACKEND="openrouter"
	export NEWS_OPENROUTER_MODEL="google/gemma-4-26b-a4b-it"
	export NEWS_OPENROUTER_EMBED_MODEL="qwen/qwen3-embedding-4b"
	export NEWS_OPENROUTER_RERANK_MODEL="qwen/qwen3-reranker-8b"
fi

cd "$tv"
exec .venv/bin/python main.py "$@"
