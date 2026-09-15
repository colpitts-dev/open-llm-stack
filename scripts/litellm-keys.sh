#!/usr/bin/env bash
# One LiteLLM team per agent team and one virtual key per client, by alias, into .env (plan 16). Members come from the
# roster; Open WebUI and the Buzz agent are the two non-team clients. Idempotent: a blank variable is minted; a set
# variable whose alias no longer exists in LiteLLM (fresh database) is re-minted. The team (team_alias = the org) puts
# user_api_key_team_alias on every spend row; plan 15's cost-report groups by the aliases. The master key stays for the operator.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
base="${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}"; auth="Authorization: Bearer ${LITELLM_MASTER_KEY}"
setenv() { grep -qE "^$1=" .env && sed -i "s|^$1=.*|$1=$2|" .env || echo "$1=$2" >> .env; }
team_alias="${TEAM_GITEA_ORG:-piedpiper}"
tid=$(curl -fsS -H "$auth" "$base/team/list" | jq -r --arg a "$team_alias" '.[] | select(.team_alias==$a) | .team_id' | head -1)   # host jq, no pipefail here
[ -n "$tid" ] || { tid=$(curl -fsS -X POST "$base/team/new" -H "$auth" -H 'Content-Type: application/json' -d "{\"team_alias\":\"$team_alias\"}" | jq -r .team_id); echo "litellm team $team_alias created ($tid)"; }
mint() {   # mint <alias> <ENV_VAR> [team_id]
  local alias=$1 var=$2 cur; cur=$(grep -E "^$var=" .env | cut -d= -f2- | sed 's/[[:space:]]*#.*//' || true)   # absent line = blank (set -e, pipefail)
  if [ -n "$cur" ] && [ "$(curl -fsS -H "$auth" "$base/key/list?key_alias=$alias&return_full_object=true" | jq -r '.total_count')" != 0 ]; then echo "$alias: key present"; return; fi
  local key; key=$(curl -fsS -X POST "$base/key/generate" -H "$auth" -H 'Content-Type: application/json' \
    -d "{\"key_alias\":\"$alias\"${3:+,\"team_id\":\"$3\"},\"metadata\":{\"client\":\"$alias\",\"minted_by\":\"litellm-keys.sh\"}}" | jq -r .key)
  setenv "$var" "$key" && echo "$alias: key minted into $var${3:+ (team $team_alias)}"
}
python3 scripts/team-roster.py members | while read -r name role display login prefix; do mint "$name" "${prefix}_LITELLM_KEY" "$tid"; done
mint buzz-agent BUZZ_AGENT_LITELLM_KEY
mint open-webui OPENWEBUI_LITELLM_KEY
echo "apply: docker compose up -d --force-recreate $(python3 scripts/team-roster.py members | cut -d' ' -f1 | paste -sd ' ') buzz-agent open-webui   (each client re-reads its key)"
