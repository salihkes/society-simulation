#!/bin/bash
# THE TWO MODELS MEMORY NEEDS that the chat pool does not serve.
#
# The city's llama-servers hold chat models. Recall wants two other kinds:
# an embedding model, so a memory can be found by what it means rather than
# only by the words in it, and a reranker, so that of the dozen candidates
# the lanes turn up, the one that actually answers the question comes first.
# Nothing else serves them.
#
# They are small, they run on the Mac beside everything else, and they are
# never asked to chat — llm.json gives them rank 0 in every chat tier, so the
# pool only reaches for them by name.
#
#   tools/run/memmodels.sh           start both, in the background
#   tools/run/memmodels.sh stop      stop them
#   tools/run/memmodels.sh status    are they up?

EMBED_MODEL="$HOME/Documents/models/embeddings/Qwen3-Embedding-4B-Q8_0.gguf"
RERANK_MODEL="$HOME/Documents/models/reranker/Qwen3-Reranker-4B.Q8_0.gguf"
EMBED_PORT=8086
RERANK_PORT=8087
LLAMA="${LLAMA_SERVER:-/opt/homebrew/bin/llama-server}"
LOGS="${TMPDIR:-/tmp}/game-memmodels"

up() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

case "${1:-start}" in
status)
  up $EMBED_PORT  && echo "embeddings  :$EMBED_PORT  up" || echo "embeddings  :$EMBED_PORT  down"
  up $RERANK_PORT && echo "reranker    :$RERANK_PORT  up" || echo "reranker    :$RERANK_PORT  down"
  exit 0 ;;
stop)
  pkill -f "llama-server.*Qwen3-Embedding" && echo "embeddings stopped"
  pkill -f "llama-server.*Qwen3-Reranker"  && echo "reranker stopped"
  exit 0 ;;
start) ;;
*) echo "[memmodels] try: start | stop | status" >&2; exit 2 ;;
esac

[ -x "$LLAMA" ] || { echo "[memmodels] no llama-server at $LLAMA (set LLAMA_SERVER=…)" >&2; exit 1; }
mkdir -p "$LOGS"

if up $EMBED_PORT; then
  echo "[memmodels] embeddings already up on $EMBED_PORT"
elif [ -f "$EMBED_MODEL" ]; then
  echo "[memmodels] embeddings → :$EMBED_PORT  ($(basename "$EMBED_MODEL"))"
  nohup "$LLAMA" --model "$EMBED_MODEL" --embedding --port $EMBED_PORT \
        --ctx-size 8192 --batch-size 4096 --ubatch-size 4096 --alias Qwen3-Embedding-4B \
        > "$LOGS/embed.log" 2>&1 &
else
  echo "[memmodels] no embedding model at $EMBED_MODEL" >&2
fi

if up $RERANK_PORT; then
  echo "[memmodels] reranker already up on $RERANK_PORT"
elif [ -f "$RERANK_MODEL" ]; then
  echo "[memmodels] reranker   → :$RERANK_PORT  ($(basename "$RERANK_MODEL"))"
  nohup "$LLAMA" --model "$RERANK_MODEL" --reranking --port $RERANK_PORT \
        --ctx-size 8192 --batch-size 4096 --ubatch-size 4096 --alias Qwen3-Reranker-4B \
        > "$LOGS/rerank.log" 2>&1 &
else
  echo "[memmodels] no reranker at $RERANK_MODEL" >&2
fi

printf "[memmodels] loading"
for _ in $(seq 90); do
  up $EMBED_PORT && up $RERANK_PORT && break
  printf "."; sleep 1
done
echo
"$0" status
echo "[memmodels] logs in $LOGS"
