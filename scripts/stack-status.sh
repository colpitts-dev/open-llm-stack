#!/usr/bin/env bash
# One JSON with what the console shows (plan 17): services, gateway, backend, the last meter row per energy domain (plan 15),
# last 24 h of tokens and energy cost, open PRs by agents, cap alerts. Terminal-first; calls no vendor tool (power comes from
# stack_energy, so it is the same on any host the meter supports); never calls LiteLLM's /health (it test-calls every model).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
base="${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}"; auth="Authorization: Bearer ${LITELLM_MASTER_KEY}"
psql() { docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "$1" 2>/dev/null || true; }
services=$(docker compose ps --format json 2>/dev/null | jq -s 'map({service: .Service, state: .State, health: (.Health // "")})')
gateway=$(curl -fsS -m 3 -H "$auth" "$base/health/readiness" 2>/dev/null | jq -c '{status, db}' || echo '{"status":"unreachable"}')
power=$(psql "select coalesce(json_agg(json_build_object('host', host, 'domain', domain, 'scope', scope, 'watts', watts_avg, 'mem_mib', mem_mib, 'util', util, 'exact', exact, 'at', ts) order by host, scope, domain), '[]')
  from (select distinct on (host, domain) * from stack_energy where ts > now() - interval '2 minutes' order by host, domain, ts desc) q")   # empty = meter not running
spend=$(psql "select json_build_object('calls', count(*), 'prompt_tokens', coalesce(sum(prompt_tokens),0), 'completion_tokens', coalesce(sum(completion_tokens),0), 'litellm_spend', round(coalesce(sum(spend),0)::numeric,4)) from \"LiteLLM_SpendLogs\" where \"startTime\" > now() - interval '24 hours'")
energy='null'; if [ -n "${POWER_COST_PER_KWH:-}" ]; then scope="${POWER_SCOPE:-gpu}"
  energy=$(psql "with s as (select scope, sum(joules) j, count(distinct ts) n from stack_energy where ts > now() - interval '24 hours' group by scope),
    m as (select coalesce((select j from s where scope = '$scope'), 0) j, coalesce((select n from s where scope = '$scope'), 0) n),
    o as (select avg(h.j - g.j) w from (select ts, sum(joules) j from stack_energy where scope = 'host' and ts > now() - interval '24 hours' group by ts) h
              join (select ts, sum(joules) j from stack_energy where scope = '$scope' and ts > now() - interval '24 hours' group by ts) g using (ts)),
    h as (select m.j + m.n * case when '$scope' = 'host' then 0 else coalesce(o.w, ${POWER_HOST_OVERHEAD:-0}) end j,
                 case when '$scope' <> 'host' and o.w is not null then 'measured' else 'estimated' end src from m, o)
    select json_build_object('scope', '$scope', 'measured_kwh', round((m.j / 3600000.0)::numeric, 3), 'host_kwh', round((h.j / 3600000.0)::numeric, 3), 'host_kwh_is', h.src,
      'cost', round((h.j / 3600000.0 * ${POWER_COST_PER_KWH} / 100.0)::numeric, 4), 'tariff_cents', ${POWER_COST_PER_KWH}, 'last_sample', (select max(ts) from stack_energy)) from m, h"); fi
alerts=$(curl -fsS -m 3 -H "$auth" "$base/v1/model/info" 2>/dev/null | jq -r '.data[] | select(.model_info.mode=="chat") | "\(.model_name) \(.litellm_params.model) \(.model_info.max_input_tokens) \(.model_info.max_output_tokens)"' \
  | while read -r name lm cap_in cap_out; do
      psql "select json_build_object('model','$name','over_in', count(*) filter (where prompt_tokens > $cap_in), 'at_out', count(*) filter (where completion_tokens >= $cap_out)) from \"LiteLLM_SpendLogs\" where model='$lm' and \"startTime\" > now() - interval '7 days'"
    done | jq -s 'map(select(.over_in > 0 or .at_out > 0))')
# judge/coordinator token: teams are data since plan 16, so ask the roster rather than hardcode a member name
judge_token=""
coord=$(python3 scripts/team-roster.py role coordinator 2>/dev/null | awk 'NR==1' || true)
if [ -n "$coord" ]; then
  row=$(python3 scripts/team-roster.py members 2>/dev/null | awk -v n="$coord" '$1==n')
  prefix=$(awk '{print $5}' <<<"$row")
  if [ -n "$prefix" ]; then var="${prefix}_GITEA_TOKEN"; judge_token="${!var:-}"; fi
fi
: "${judge_token:=${TEAM_JARED_GITEA_TOKEN:-}}"
prs='[]'; if [ -n "$judge_token" ] && [ -n "${GITEA_PUBLIC_URL:-}" ]; then
  B="${GITEA_PUBLIC_URL%/}/api/v1"; org="${TEAM_GITEA_ORG:-piedpiper}"
  prs=$(curl -fsS -m 5 -H "Authorization: token $judge_token" "$B/orgs/$org/repos?limit=50" 2>/dev/null | jq -r '.[].name' \
    | while read -r repo; do curl -fsS -m 5 -H "Authorization: token $judge_token" "$B/repos/$org/$repo/pulls?state=open&limit=20" 2>/dev/null \
        | jq -c --arg r "$repo" '.[] | {repo: $r, number, title, by: .user.login, labels: [.labels[].name], url: .html_url, opened: .created_at}'; done | jq -s '.'); fi
jq -n --argjson services "${services:-[]}" --argjson gateway "$gateway" --argjson power "${power:-[]}" --argjson spend "${spend:-null}" \
      --argjson energy "${energy:-null}" --argjson alerts "${alerts:-[]}" --argjson prs "${prs:-[]}" \
      '{generated: (now|todate), bind_host: env.BIND_HOST, backend: env.LLM_BASE_URL, services: $services, gateway: $gateway, power: $power,
        last_24h: $spend, energy_24h: $energy, alerts: $alerts, open_prs: $prs}'
