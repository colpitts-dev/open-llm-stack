#!/usr/bin/env bash
# Per-layer smoke tests. A layer is tested only when its profile is in COMPOSE_PROFILES.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
BIND_HOST=${BIND_HOST:-127.0.0.1}
has_profile() { [[ ",${COMPOSE_PROFILES:-}," == *",$1,"* ]]; }
fail() { echo "FAIL: $*" >&2; exit 1; }

test_litellm() {
  local base="http://${BIND_HOST}:${LITELLM_PORT:-3000}" auth="Authorization: Bearer ${LITELLM_MASTER_KEY}"
  echo "--- litellm: registry"
  curl -fsS -H "$auth" "$base/v1/models" | jq -r '.data[].id' | sort
  curl -fsS -H "$auth" "$base/v1/model/info" \
    | jq -r '.data[] | "\(.model_name)\t\(.model_info.max_input_tokens)\t\(.model_info.execution_locus)"'
  echo "--- litellm: chat round-trip (every mode:chat model; reasoning models need a generous max_tokens)"
  for m in $(curl -fsS -H "$auth" "$base/v1/model/info" | jq -r '.data[] | select(.model_info.mode=="chat") | .model_name'); do
    printf '%s -> ' "$m"
    curl -fsS "$base/v1/chat/completions" -H "$auth" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":512}" \
      | jq -r 'if .error then "ERROR " + .error.message elif (.choices[0].message.content // "") != "" then .choices[0].message.content else "(empty content; reasoning_content chars: " + ((.choices[0].message.reasoning_content // "") | length | tostring) + ")" end'
  done
  echo "--- litellm: embeddings"
  if curl -fsS -H "$auth" "$base/v1/model/info" | jq -e '.data[] | select(.model_info.mode=="embedding")' >/dev/null; then
    local em; em=$(curl -fsS -H "$auth" "$base/v1/model/info" | jq -r '[.data[] | select(.model_info.mode=="embedding") | .model_name][0]')
    curl -fsS "$base/v1/embeddings" -H "$auth" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$em\",\"input\":\"test\"}" | jq '.data[0].embedding | length'
  else echo "(no embedding model registered -- skipped)"; fi
  echo "--- litellm: no closed-weight model or router registered"
  if curl -fsS -H "$auth" "$base/v1/models" | jq -r '.data[].id' | grep -iE 'claude|anthropic|gpt-|gemini|router'; then
    fail "closed-weight model or router in the registry"
  fi
  echo "ok"
}

# --- dispatcher (later plans add: openwebui, buzz, gitea) ---
has_profile litellm && test_litellm
echo "smoke test finished"
