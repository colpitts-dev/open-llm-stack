#!/usr/bin/env bash
# Size a model for this GPU on an OLLAMA backend (plan 14). Loads it at candidate windows on the LIVE backend, keeps
# the largest window that stays fully on the GPU within the budget, and prints the proxy/config.yaml block.
# The backend's OLLAMA_NUM_PARALLEL is already folded into what it reports (it loads -c num_ctx x parallel), so the
# measurement is exact for the server as configured. Re-run after changing slots, the KV cache type, the model, or
# the GPU. Other backends: set the server's window flags, declare context_window, run `make context-probe`.
# Usage: make model-fit M=<ollama tag> [OUT=32768] [HEADROOM_MB=2048] [MAX_WINDOW=131072]
# MAX_WINDOW caps the search: a window is sized to real prompts (p95 of `make context-report` + the output budget), never
# to the architectural maximum, which only costs VRAM and prefill (execution finding: at one slot 262144 "fits" too).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
M=${M:-${1:-}}; [ -n "$M" ] || { echo "usage: make model-fit M=<ollama tag>  [OUT=<max_output_tokens>] [HEADROOM_MB=<free VRAM to keep>] [MAX_WINDOW=<largest window to try>]"; exit 1; }
OUT=${OUT:-32768}
HEADROOM_MB=${HEADROOM_MB:-2048}             # kept free for compute-buffer growth under load and the embedding model
MAX_WINDOW=${MAX_WINDOW:-131072}
CANDIDATES=${CANDIDATES:-$(for c in 262144 196608 131072 98304 65536 49152 32768 16384; do [ "$c" -le "$MAX_WINDOW" ] && printf '%s ' "$c"; done)}
GPU_INDEX=${GPU_INDEX:-0}

# Backend calls run inside litellm (python3, no curl there) so LLM_BASE_URL resolves as the stack sees it;
# without a litellm container (external gateway) they go to OLLAMA_URL from the host.
api() {   # api <path> [json body]
  if docker compose ps -q litellm 2>/dev/null | grep -q .; then
    docker compose exec -T litellm python3 -c '
import sys, urllib.request
base, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(base + path, data=body.encode() if body else None, headers={"Content-Type": "application/json"})
sys.stdout.write(urllib.request.urlopen(req, timeout=900).read().decode())' "$LLM_BASE_URL" "$1" "${2:-}"
  else
    curl -fsS "${OLLAMA_URL:-http://127.0.0.1:11434}$1" ${2:+-d "$2"}
  fi
}
api /api/tags >/dev/null 2>&1 || { echo "$LLM_BASE_URL is not an Ollama backend (no /api/tags): set the window on your server, declare context_window, run make context-probe"; exit 1; }
unload_all() { for m in $(api /api/ps | jq -r '.models[].name'); do api /api/generate "{\"model\":\"$m\",\"keep_alive\":0}" >/dev/null; done; sleep 3; }

api /api/show "{\"model\":\"$M\"}" | jq -e .details >/dev/null || { echo "$M is not a model on $LLM_BASE_URL"; exit 1; }
arch=$(api /api/show "{\"model\":\"$M\"}" | jq -r '.details.family + " " + .details.parameter_size + " " + .details.quantization_level')

if command -v nvidia-smi >/dev/null; then
  total=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=memory.total --format=csv,noheader,nounits | tr -d ' ')
  unload_all
  other=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' ')   # display server etc.
else
  [ -n "${VRAM_MB:-}" ] || { echo "no nvidia-smi: set VRAM_MB=<total> and OTHER_MB=<used by the display server>"; exit 1; }
  total=$VRAM_MB; other=${OTHER_MB:-0}; unload_all
fi
budget=$(( total - other - HEADROOM_MB ))
echo "model $M ($arch); GPU $total MiB, other $other MiB, headroom $HEADROOM_MB MiB -> budget for the runner: $budget MiB; windows tried: $CANDIDATES"
printf '%-8s %-10s %-10s %s\n' window size_MiB vram_MiB verdict

pick=""; pick_vram=""
for ctx in $CANDIDATES; do
  api /api/generate "{\"model\":\"$M\",\"prompt\":\"\",\"options\":{\"num_ctx\":$ctx},\"keep_alive\":\"1m\",\"stream\":false}" >/dev/null 2>&1 || { printf '%-8s %-10s %-10s %s\n' "$ctx" - - "load failed"; continue; }
  read -r size vram <<<"$(api /api/ps | jq -r --arg m "$M" '.models[] | select(.name==$m or .name==($m+":latest")) | "\(.size/1048576|floor) \(.size_vram/1048576|floor)"')"
  [ -n "${size:-}" ] || { printf '%-8s %-10s %-10s %s\n' "$ctx" - - "not loaded"; continue; }
  if [ "$vram" -lt "$size" ]; then verdict="spills to CPU"
  elif [ "$vram" -gt "$budget" ]; then verdict="over budget"
  else verdict="fits"; fi
  printf '%-8s %-10s %-10s %s\n' "$ctx" "$size" "$vram" "$verdict"
  if [ "$verdict" = fits ]; then pick=$ctx; pick_vram=$vram; break; fi
done
unload_all
[ -n "$pick" ] || { echo "no candidate fits: fewer slots (OLLAMA_NUM_PARALLEL), a smaller quantisation, or a smaller model"; exit 2; }

margin=$(( pick / 4 )); [ "$margin" -lt 8192 ] && margin=8192
in=$(( pick - OUT - margin ))
[ "$in" -ge 16384 ] || echo "WARNING: max_input_tokens $in is small: lower OUT, or give the model fewer slots"
name=${M%:latest}
cat <<EOT

# paste into proxy/config.yaml, then: make reload && make context-probe M=$name && make test
  - model_name: $name
    litellm_params:
      model: ollama_chat/$M
      api_base: os.environ/LLM_BASE_URL
      num_ctx: $pick                 # = context_window; make model-fit $(date +%F): $pick_vram MiB on the GPU with OLLAMA_NUM_PARALLEL as set
      keep_alive: "5m"
    model_info:
      mode: chat
      context_window: $pick
      max_input_tokens: $in         # $pick - $OUT - $margin
      max_output_tokens: $OUT
      model_revision: "ollama:$name:$(date +%F)"
      execution_locus: local
EOT
