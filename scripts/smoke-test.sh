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

test_openwebui() {
  local base="http://${BIND_HOST}:${OPENWEBUI_PORT:-3001}"
  echo "--- open-webui: health"
  curl -fsS "$base/health" | jq -e '.status == true' >/dev/null && echo "healthy"
  curl -fsS "$base/api/config" | jq -r '"version \(.version)  auth=\(.features.auth)"'
  local token
  if [ "${WEBUI_AUTH:-false}" = "false" ]; then
    # No-login mode still requires a bearer token for the API; an empty sign-in returns the admin session.
    token=$(curl -fsS -X POST "$base/api/v1/auths/signin" -H 'Content-Type: application/json' -d '{"email":"","password":""}' | jq -r .token)
  else
    echo "(WEBUI_AUTH=true: set OPENWEBUI_TOKEN in the environment to run the API checks)"; token="${OPENWEBUI_TOKEN:-}"
  fi
  [ -n "$token" ] || { echo "(no token -- skipping model/chat checks)"; return 0; }
  echo "--- open-webui: models via LiteLLM"
  curl -fsS -H "Authorization: Bearer $token" "$base/api/models" | jq -r '.data[].id' | grep -v '^arena-model$' | sort
  local m; m=$(curl -fsS -H "Authorization: Bearer $token" "$base/api/models" | jq -r '[.data[].id | select(. != "arena-model")][0]')
  [ -n "$m" ] && [ "$m" != "null" ] || fail "open-webui sees no models from LiteLLM (check LITELLM_URL / LITELLM_MASTER_KEY)"
  echo "--- open-webui: chat round-trip via $m"
  curl -fsS -m 300 -H "Authorization: Bearer $token" "$base/api/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":512}" \
    | jq -r '.choices[0].message.content // ("ERROR: " + (.detail // .error // "unknown" | tostring))'
}

test_buzz() {
  local host="${BUZZ_PUBLIC_HOST:-127.0.0.1:${BUZZ_PORT:-3002}}"
  echo "--- buzz: readiness (health listener inside the container)"
  docker compose exec -T buzz curl -fsS -o /dev/null -w 'readiness %{http_code}\n' http://127.0.0.1:8080/_readiness
  curl -fsS -o /dev/null -w "liveness on ${host}: %{http_code}\n" "http://${host}/_liveness"
  echo "--- buzz: NIP-11"
  curl -fsS -H 'Accept: application/nostr+json' "http://${host}/" | jq -r '"\(.name) \(.version) nips=\(.supported_nips|length) self=\(.self[0:16])..."'
  echo "--- buzz: community host == BUZZ_PUBLIC_HOST"
  local seeded; seeded=$(docker compose logs --no-log-prefix buzz 2>/dev/null | grep -o '"Deployment community ensured","host":"[^"]*"' | tail -1 | sed 's/.*"host":"//;s/"$//')
  [ "$seeded" = "$host" ] && echo "community host: $seeded" || fail "relay seeded community for '$seeded' but BUZZ_PUBLIC_HOST is '$host' -- clients will get 404"
  if [ "${BUZZ_SERVE_GIT_WEB_GUI:-true}" = "true" ]; then
    echo "--- buzz: browser UI"
    curl -fsS -H 'Accept: text/html' "http://${host}/" | grep -q '<title>Buzz</title>' && echo "web UI served at http://${host}/"
  fi
  echo "--- buzz: real client (buzz CLI from the sprig image, agent identity)"
  docker run --rm --network host -e BUZZ_PRIVATE_KEY="${BUZZ_AGENT_PRIVATE_KEY}" -e BUZZ_RELAY_URL="${BUZZ_RELAY_URL:-ws://${host}}" \
    --entrypoint buzz ghcr.io/block/buzz-sprig:sha-e17cdd9 channels list | jq -r 'if type=="array" then "channels visible: \(length)" else . end'
}

test_gitea() {
  # Bundled or external: GITEA_PUBLIC_URL is what the host and the agents use; the loopback fallback is the bundled default.
  local base="${GITEA_PUBLIC_URL:-http://${BIND_HOST}:${GITEA_PORT:-3003}}" org="${TEAM_GITEA_ORG:-piedpiper}"
  echo "--- gitea: health + version"
  curl -fsS "$base/api/healthz" | jq -r '"healthz: \(.status)"'
  [ -n "${GITEA_ADMIN_TOKEN:-}" ] || { echo "(GITEA_ADMIN_TOKEN blank -- run make gitea-bootstrap for the API checks)"; return 0; }
  local auth="Authorization: token ${GITEA_ADMIN_TOKEN}"
  curl -fsS -H "$auth" "$base/api/v1/version" | jq -r '"version \(.version)"'   # an external instance may require sign-in even for /version
  echo "--- gitea: token works"
  curl -fsS -H "$auth" "$base/api/v1/user" | jq -r '"user \(.login) admin=\(.is_admin)"'
  echo "--- gitea: create + clone + delete a private repo in org $org"
  local repo="smoke-$(date +%s)" out code
  # The probe lives in the team org, never in a human's namespace. The org exists only after make team-bootstrap.
  out=$(curl -sS -w '\n%{http_code}' -H "$auth" -H 'Content-Type: application/json' -d "{\"name\":\"$repo\",\"private\":true,\"auto_init\":true}" \
    "$base/api/v1/orgs/$org/repos"); code=$(tail -1 <<<"$out")
  if [ "$code" = 404 ]; then echo "(org $org missing -- run make team-bootstrap; skipping repo probe)"; return 0; fi
  [ "$code" = 201 ] || fail "repo create in org $org returned HTTP $code: $(head -1 <<<"$out")"
  head -1 <<<"$out" | jq -r '"created \(.full_name) private=\(.private) clone=\(.clone_url)"'
  local tmp; tmp=$(mktemp -d)
  git -c http.extraHeader="$auth" clone -q "$base/$org/${repo}.git" "$tmp/repo" && echo "cloned ($(ls "$tmp/repo" | tr '\n' ' '))"
  rm -rf "$tmp"
  curl -fsS -X DELETE -H "$auth" "$base/api/v1/repos/$org/${repo}" && echo "deleted $repo"
}

test_gitea_runner() {
  local base="${GITEA_PUBLIC_URL:-http://${BIND_HOST}:${GITEA_PORT:-3003}}/api/v1" auth="Authorization: token ${GITEA_ADMIN_TOKEN}"
  echo "--- gitea-runner: registered + last CI run on demo-calc"
  docker compose exec -T gitea-runner sh -c 'test -s /data/.runner && echo registered'
  curl -fsS -H "$auth" "$base/repos/${TEAM_GITEA_ORG:-piedpiper}/demo-calc/actions/runs" | jq -r '.workflow_runs[0] | "run \(.status)/\(.conclusion // "-") \(.head_branch)"'
}

test_team_factory() {
  local base="${GITEA_PUBLIC_URL:-http://${BIND_HOST}:${GITEA_PORT:-3003}}/api/v1" auth="Authorization: token ${GITEA_ADMIN_TOKEN}" org="${TEAM_GITEA_ORG:-piedpiper}"
  local name="factory-$(date +%s | tail -c 6)"
  echo "--- team: repository factory (new-repo inside dinesh, no LLM)"
  docker compose exec -T dinesh /opt/team/agents/bin/new-repo "$name" | head -1
  curl -fsS -o /dev/null -H "$auth" "$base/repos/$org/$name/contents/.gitea/workflows/ci.yaml" && echo "workflow present"
  curl -fsS -H "$auth" "$base/repos/$org/$name/branch_protections/main" | jq -r '"protection: contexts=\(.status_check_contexts|join(",")) approvals=\(.required_approvals) merge=\(.merge_whitelist_usernames|join(",")) admin_override_blocked=\(.block_admin_merge_override)"'
  local collab; collab=$(curl -fsS -H "$auth" "$base/repos/$org/$name/collaborators" | jq -r 'length')
  [ "$collab" = 0 ] && echo "collaborators: none (creator demoted)" || fail "factory left $collab collaborator(s) on $name"
  curl -fsS -o /dev/null -X DELETE -H "$auth" "$base/repos/$org/$name" && echo "deleted $name"
}

test_team_narrate() {   # G21: canned harness log through team-narrate.sh inside dinesh -> expected replies in a throwaway thread
  local relay="${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}" sprig=ghcr.io/block/buzz-sprig:sha-e17cdd9
  echo "--- team: progress mirror (canned log through team-narrate.sh in dinesh, no LLM)"
  bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_SMOKE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$relay" --entrypoint buzz "$sprig" "$@"; }
  local ch root root8 n
  ch=$(bz channels create --name "narrate-$(date +%s)" --type stream --visibility open --ttl 3600 | jq -r .channel_id)
  bz channels add-member --channel "$ch" --pubkey "$TEAM_DINESH_PUBKEY" --role bot >/dev/null
  root=$(bz messages send --channel "$ch" --content "job root (mirror probe)" | jq -r .event_id); root8="${root:0:8}"
  docker compose exec -T -e TEAM_NARRATE=both dinesh bash /opt/team/team-narrate.sh >/dev/null <<EOF
2026-01-01T00:00:00.000000Z  INFO pool::prompt: turn starting for channel $ch (thread:$root8)
2026-01-01T00:00:01.000000Z  INFO acp::stream: Picked up: probe narration line.


2026-01-01T00:00:02.000000Z DEBUG acp::wire: ← {"jsonrpc":"2.0","method":"session/update","params":{"update":{"kind":"other","rawInput":{"command":"git fetch origin && git checkout main"},"sessionUpdate":"tool_call","status":"pending","title":"buzz-dev-mcp__shell"}}}
2026-01-01T00:00:03.000000Z DEBUG acp::wire: ← {"jsonrpc":"2.0","method":"session/update","params":{"update":{"kind":"other","rawInput":{"command":"git add -A && git commit -m \\"feat: probe\\" && git push -u origin agent/probe"},"sessionUpdate":"tool_call","status":"pending","title":"buzz-dev-mcp__shell"}}}
2026-01-01T00:00:04.000000Z DEBUG acp::wire: ← {"jsonrpc":"2.0","method":"session/update","params":{"update":{"kind":"other","rawInput":{"command":"buzz messages send --channel $ch --content \\"visible already\\""},"sessionUpdate":"tool_call","status":"pending","title":"buzz-dev-mcp__shell"}}}
2026-01-01T00:00:05.000000Z  INFO acp::stream: @Richard-smoke this is the final answer and must NOT be mirrored
2026-01-01T00:00:06.000000Z  INFO pool::prompt: turn complete for channel $ch (thread:$root8): end_turn
2026-01-01T00:00:07.000000Z  INFO pool::prompt: turn starting for channel $ch (conversation)
2026-01-01T00:00:08.000000Z  INFO acp::stream: must not be posted (conversation scope)
2026-01-01T00:00:09.000000Z  INFO pool::prompt: turn complete for channel $ch (conversation): end_turn
EOF
  sleep 3
  bz messages thread --channel "$ch" --event "$root" | jq -r --arg d "$TEAM_DINESH_PUBKEY" '.[] | select(.pubkey==$d) | "mirror: \(.content|gsub("\n";" | "))"'
  n=$(bz messages thread --channel "$ch" --event "$root" | jq -r --arg d "$TEAM_DINESH_PUBKEY" '[.[] | select(.pubkey==$d)] | length')
  [ "$n" = 2 ] && echo "mirror: 2 replies (narration + wrapped git push); skipped fetch, buzz send, final chunk, conversation turn" || fail "expected 2 mirror replies from dinesh, got $n"
}

test_team_runtime() {   # G23: dinesh runs the runtime .env asks for (plan 12)
  echo "--- team: dinesh runtime = ${TEAM_DINESH_RUNTIME:-buzz-agent}"
  docker compose exec -T dinesh sh -c 'tr "\0" " " </proc/1/cmdline | cut -c1-40; echo'
  docker compose logs --since 24h --no-log-prefix dinesh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'agent initialized agent=0 name="[a-z-]+"' | tail -1
  case "${TEAM_DINESH_RUNTIME:-buzz-agent}" in
    goose) docker compose exec -T dinesh sh -c 'goose --version && pgrep -f "goose acp" >/dev/null && echo "goose acp running"' || fail "goose runtime requested but not running" ;;
    *) docker compose exec -T dinesh sh -c 'pgrep -f buzz-agent >/dev/null && echo "buzz-agent running"' || fail "buzz-agent not running" ;;
  esac
}

test_team_score() {   # G26: script-only scoring path inside jared on the newest demo-calc PR; invalid rubric rejected (plan 13)
  local base="${GITEA_PUBLIC_URL%/}/api/v1" auth="Authorization: token ${GITEA_ADMIN_TOKEN}" judge="Authorization: token ${TEAM_JARED_GITEA_TOKEN}" org="${TEAM_GITEA_ORG:-piedpiper}"
  echo "--- team: PR scoring (score-post with a canned rubric inside jared, no LLM)"
  local n; n=$(curl -fsS -H "$auth" "$base/repos/$org/demo-calc/pulls?state=all&limit=1" | jq -r '.[0].number'); [ -n "$n" ] && [ "$n" != null ] || fail "no PR in demo-calc"
  if docker compose exec -T jared bash -c 'printf "{\"scope\":0,\"novelty\":3}" > /tmp/bad.json; /opt/team/agents/bin/score-post demo-calc '"$n"' /tmp/bad.json' >/dev/null 2>&1; then fail "score-post accepted a bad rubric"; else echo "bad rubric rejected"; fi
  docker compose exec -T jared bash -c 'cat > /tmp/r.json <<EOF
{"scope":0,"novelty":0,"risk":0,"verification":0,"ambiguity":0,"tests":2,"ci":2,"review":2,"scope_match":2,"hygiene":2,"summary":"smoke: canned rubric","evidence":{"scope":"one function"}}
EOF
/opt/team/agents/bin/score-post demo-calc '"$n"' /tmp/r.json'
  curl -fsS -H "$judge" "$base/repos/$org/demo-calc/issues/$n/labels" | jq -r 'map(.name)|join(",")' | grep 'complexity/1' | grep -q 'confidence/high' && echo "labels: complexity/1, confidence/high on demo-calc#$n" || fail "labels missing on demo-calc#$n"
  curl -fsS -H "$judge" "$base/repos/$org/demo-calc/issues/$n/comments" | jq -e '[.[] | select(.body|startswith("**Score:**"))] | length > 0' >/dev/null && echo "score comment present" || fail "no score comment"
}

# --- dispatcher: one section per profile in COMPOSE_PROFILES ---
has_profile litellm && test_litellm
has_profile openwebui && test_openwebui
has_profile buzz && test_buzz
{ has_profile gitea || [ -n "${GITEA_ADMIN_TOKEN:-}" ]; } && test_gitea   # external Gitea: no profile, but a token
has_profile buzz-agent && ./scripts/buzz-smoke.sh
has_profile gitea-runner && test_gitea_runner
has_profile team && ./scripts/team-smoke.sh
has_profile team && test_team_factory
has_profile team && test_team_narrate
has_profile team && test_team_runtime
has_profile team && test_team_score
echo "smoke test finished"
