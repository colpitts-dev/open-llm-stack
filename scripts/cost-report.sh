#!/usr/bin/env bash
# What the local models cost to run (plan 15): metered energy of one scope (POWER_SCOPE) x your tariff (cents/kWh, printed as dollars), then per model,
# per client, per domain. Per call: joules of the seconds a call ran, pro rata, split equally among concurrent calls
# (stack_call_energy, incremental). Idle = everything the scope burned outside calls (includes the ~1% of call-boundary
# seconds). Host = the whole machine: measured when a host-scope probe runs, else scope + POWER_HOST_OVERHEAD x seconds.
# Usage: make cost-report [SINCE="7 days"]
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
SINCE=${SINCE:-7 days}
[ -n "${POWER_COST_PER_KWH:-}" ] || { echo "POWER_COST_PER_KWH is blank: energy accounting off"; exit 0; }
docker compose ps -q litellm-db 2>/dev/null | grep -q . || { echo "no litellm-db container: nothing to report"; exit 0; }
docker compose exec -T litellm-db psql -U litellm -d litellm -v ON_ERROR_STOP=1 -q \
  -v since="$SINCE" -v rate="$POWER_COST_PER_KWH" -v scope="${POWER_SCOPE:-gpu}" -v overhead_w="${POWER_HOST_OVERHEAD:-0}" <<'EOF'
\set win 'now() - :''since''::interval'
\set kwh '(1.0 / 3600000.0)'
-- joules -> dollars: the tariff is cents per kWh. No trailing comments on \set lines: psql appends them to the value
\set usd '(:kwh * :rate / 100.0)'
-- one row per second for the attributed scope (every domain of that scope summed: LiteLLM does not know which card served a call)
-- and one for the host scope when a PSU or plug probe runs; scopes are never summed together
create temp view energy_s as select ts, sum(joules) as joules from stack_energy where scope = :'scope' group by ts;
create temp view host_s as select ts, sum(joules) as joules from stack_energy where scope = 'host' group by ts;
-- 1. attribute new calls: joules of overlapping seconds, pro rata by overlap, divided by the calls sharing each second
with calls as (
  select request_id, model, "startTime" s, "endTime" e from "LiteLLM_SpendLogs"
  where "endTime" > :win and "endTime" >= (select min(ts) from stack_energy) and request_id not in (select request_id from stack_call_energy)
), ov as (
  select c.request_id, c.model, x.ts, x.joules,
         greatest(0, extract(epoch from (least(c.e, x.ts + interval '1 second') - greatest(c.s, x.ts)))) as frac
  from calls c join energy_s x on x.ts < c.e and x.ts + interval '1 second' > c.s
), conc as (
  select x.ts, sum(greatest(0, extract(epoch from (least(l."endTime", x.ts + interval '1 second') - greatest(l."startTime", x.ts))))) as busy
  from energy_s x join "LiteLLM_SpendLogs" l on x.ts < l."endTime" and x.ts + interval '1 second' > l."startTime"
  where x.ts > :win - interval '1 hour' group by x.ts
)
insert into stack_call_energy (request_id, model, joules, seconds, shared)
select o.request_id, o.model, sum(o.joules * o.frac / greatest(1, c.busy)), sum(o.frac), avg(c.busy)
from ov o join conc c on c.ts = o.ts group by o.request_id, o.model;
-- 2. the window's numbers: scope total, overhead (measured host - scope when host rows exist, else POWER_HOST_OVERHEAD), host total, calls
select coalesce(sum(joules), 0) as scope_j, count(*) as scope_s from energy_s where ts > :win \gset
select case when :'scope' = 'host' then 0 else coalesce((select avg(h.joules - x.joules) from host_s h join energy_s x using (ts) where h.ts > :win), :overhead_w) end as ovh_w \gset
select case when :'scope' <> 'host' and exists (select 1 from host_s where ts > :win) then 'measured' else 'estimated' end as host_src \gset
-- host = scope + seconds x overhead in both cases (with full host-row coverage this equals the host rows' sum; with partial coverage it stays consistent)
select :scope_j + :scope_s * :ovh_w as host_j \gset
create temp view attributed as select e.request_id, e.joules, e.seconds, e.shared, l.model, l.prompt_tokens, l.completion_tokens,
       coalesce(nullif(l.metadata->>'user_api_key_alias', ''), 'master key') as client
  from stack_call_energy e join "LiteLLM_SpendLogs" l using (request_id) where l."endTime" > :win;
select coalesce(sum(joules), 0) as calls_j from attributed \gset
-- a group of calls at the host: its joules plus its share of seconds x overhead
\set host_cost '((sum(joules) + sum(seconds / greatest(1, shared)) * :ovh_w) * :usd)'
\echo energy, last :since   (scope :scope, tariff :rate cents per kWh, cost in dollars, host figure :host_src, overhead :ovh_w W)
\echo
\echo == TOTAL: measured = the scope counters; host = the whole machine; cost = host x tariff; idle = measured - calls
select round((:scope_j * :kwh)::numeric, 3) as measured_kwh, round((:host_j * :kwh)::numeric, 3) as host_kwh, :'host_src' as host_kwh_is,
       round((:host_j * :usd)::numeric, 4) as cost, round((:calls_j * :kwh)::numeric, 3) as calls_kwh,
       round(((:scope_j - :calls_j) * :kwh)::numeric, 3) as idle_kwh, round((:scope_j / greatest(1, :scope_s))::numeric, 0) as avg_w, :scope_s as seconds;
\echo
\echo -- per model (calls only; wh_per_1k_tok is the sizing number)
select model, count(*) as calls, sum(prompt_tokens) as prompt_tok, sum(completion_tokens) as completion_tok,
       round((sum(joules) * :kwh)::numeric, 3) as calls_kwh, round(:host_cost::numeric, 4) as cost,
       round((sum(joules) / 3600.0 * 1000 / greatest(1, sum(prompt_tokens) + sum(completion_tokens)))::numeric, 3) as wh_per_1k_tok
from attributed group by model order by calls_kwh desc;
\echo
\echo -- per client (LiteLLM key alias: one row per member, buzz-agent, open-webui once make litellm-keys ran; else master key)
select client, count(*) as calls, round((sum(joules) * :kwh)::numeric, 3) as calls_kwh, round(:host_cost::numeric, 4) as cost
from attributed group by client order by calls_kwh desc;
\echo
\echo -- per domain (every probe row; scope :scope is attributed, host rows give the measured overhead)
select host, domain, scope, count(*) as rows, round((sum(joules) * :kwh)::numeric, 3) as kwh, round(avg(watts_avg)::numeric, 1) as avg_w, bool_and(exact) as exact
from stack_energy where ts > :win group by host, domain, scope order by host, scope, domain;
delete from stack_energy where ts < now() - interval '90 days';
EOF
