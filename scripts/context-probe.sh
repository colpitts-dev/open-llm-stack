#!/usr/bin/env bash
# Black-box verification of the context contract through the gateway (plan 14), for ANY backend LiteLLM fronts.
# For each registered chat model: send prompts of 50% and 100% of max_input_tokens, and one of
# max_input_tokens + max_output_tokens - 128 (the window must hold both); each must come back whole:
# HTTP 200 and usage.prompt_tokens within 16 of what was sent. A backend that truncates silently (Ollama past
# num_ctx) returns fewer tokens; one that rejects (llama.cpp, vLLM) returns an error. Either fails the probe.
# FULL=1 also generates max_output_tokens once per model (slow: ~2 min per 32k tokens at 236 tok/s).
# Usage: make context-probe [M=<model_name>] [FULL=1]        Exit 1 on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
base="${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}"; auth="Authorization: Bearer ${LITELLM_MASTER_KEY}"
info=$(curl -fsS -H "$auth" "$base/v1/model/info")
models=${M:-$(jq -r '.data[] | select(.model_info.mode=="chat") | .model_name' <<<"$info")}
LINE="alpha beta gamma delta epsilon zeta eta theta iota kappa"   # a fixed line tokenizes the same on every repeat: tokens = c + k * repeats
body() { yes "$LINE" | head -n "$1" | tr '\n' ' '; }   # --rawfile, not --arg: a 100k-token prompt is ~600 kB, past the kernel's per-argument limit (execution finding)
ask() {   # ask <model> <repeats> <max_tokens> -> "<prompt_tokens> <finish_reason>" or "ERROR <message>"
  jq -cn --arg m "$1" --rawfile p <(body "$2") --argjson t "$3" \
     '{model:$m, messages:[{role:"user",content:("Reply with the single word ok.\n\n"+$p)}], max_tokens:$t, temperature:0}' \
  | curl -sS "$base/v1/chat/completions" -H "$auth" -H 'Content-Type: application/json' -d @- \
  | jq -r 'if .error then "ERROR " + (.error.message|tostring|.[0:160]) else "\(.usage.prompt_tokens) \(.choices[0].finish_reason)" end'
}
rc=0
for m in $models; do
  read -r win cap_in cap_out <<<"$(jq -r --arg m "$m" '.data[] | select(.model_name==$m) | "\(.model_info.context_window // 0) \(.model_info.max_input_tokens) \(.model_info.max_output_tokens)"' <<<"$info")"
  [ "${win:-0}" -gt 0 ] || { echo "$m: no context_window in model_info"; rc=1; continue; }
  # calibrate this model's tokenizer on the line: two sizes give the exact slope k and offset c
  read -r t1 _ <<<"$(ask "$m" 200 4)"; read -r t2 _ <<<"$(ask "$m" 400 4)"
  [[ $t1 =~ ^[0-9]+$ && $t2 =~ ^[0-9]+$ ]] || { echo "$m: calibration failed: $t1 / $t2"; rc=1; continue; }
  k=$(( (t2 - t1) )); c=$(( t1 * 2 - t2 ))      # k = tokens per 200 repeats, c = fixed overhead (system/template/instruction)
  echo "$m: context_window=$win max_input=$cap_in max_output=$cap_out; $((k/200)) tokens per line, $c fixed"
  for label in "50% of max_input:$(( cap_in / 2 ))" "100% of max_input:$cap_in" "max_input + max_output - 128:$(( cap_in + cap_out - 128 ))"; do
    target=${label##*:}; name=${label%%:*}
    reps=$(( (target - c) * 200 / k )); sent=$(( c + reps * k / 200 ))
    read -r got fin <<<"$(ask "$m" "$reps" 4)"
    if [[ $got =~ ^[0-9]+$ ]] && [ "$got" -ge $(( sent - 16 )) ]; then
      echo "  ok   $name: sent ~$sent tokens, backend counted $got"
    else
      echo "  FAIL $name: sent ~$sent tokens, got '$got $fin' (silent truncation or rejection: lower max_input_tokens or raise context_window)"; rc=1
    fi
  done
  if [ "${FULL:-0}" = 1 ]; then
    out=$(jq -cn --arg m "$m" --argjson t "$cap_out" '{model:$m, messages:[{role:"user",content:"Write a very long essay about the history of roads. Do not stop before 40000 words."}], max_tokens:$t}' \
      | curl -sS "$base/v1/chat/completions" -H "$auth" -H 'Content-Type: application/json' -d @- \
      | jq -r 'if .error then "ERROR " + (.error.message|tostring) else "\(.usage.completion_tokens) \(.choices[0].finish_reason)" end')
    echo "  output budget: completion_tokens / finish_reason = $out   (length at $cap_out = the cap held end to end)"
  fi
done
[ $rc = 0 ] && echo "context probe: every registered window holds" || echo "context probe: FAILED" >&2
exit $rc
