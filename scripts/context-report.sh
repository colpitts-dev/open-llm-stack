#!/usr/bin/env bash
# Real context use per model from LiteLLM's spend log against the registry caps (plan 14): the input to sizing,
# and the check that no call sat on a truncation edge. Any backend; needs the bundled litellm-db.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
SINCE=${SINCE:-7 days}
base="${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}"; auth="Authorization: Bearer ${LITELLM_MASTER_KEY}"
docker compose ps -q litellm-db 2>/dev/null | grep -q . || { echo "no litellm-db container (external gateway): nothing to report"; exit 0; }
echo "context use per model, last $SINCE   (over_in: prompts above max_input_tokens = compaction came late; at_out: completions at max_output_tokens = truncated)"
printf '%-14s %6s %8s %8s %8s %8s %7s %6s\n' model calls p50_in p95_in max_in max_out over_in at_out
curl -fsS -H "$auth" "$base/v1/model/info" \
  | jq -r '.data[] | select(.model_info.mode=="chat") | "\(.model_name) \(.litellm_params.model) \(.model_info.max_input_tokens) \(.model_info.max_output_tokens)"' \
  | while read -r name lm cap_in cap_out; do
      docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "select count(*), coalesce(percentile_cont(0.5) within group (order by prompt_tokens)::int,0), coalesce(percentile_cont(0.95) within group (order by prompt_tokens)::int,0), coalesce(max(prompt_tokens),0), coalesce(max(completion_tokens),0), count(*) filter (where prompt_tokens > $cap_in), count(*) filter (where completion_tokens >= $cap_out) from \"LiteLLM_SpendLogs\" where model='$lm' and \"startTime\" > now() - interval '$SINCE'" </dev/null \
        | { IFS='|' read -r calls p50 p95 maxin maxout over atout; printf '%-14s %6s %8s %8s %8s %8s %7s %6s\n' "$name" "$calls" "$p50" "$p95" "$maxin" "$maxout" "$over" "$atout"; }   # </dev/null: exec -T would eat the remaining model lines from the loop's stdin (execution finding)
    done
