# Plan 17 — The console: a host-side window onto the stack's files and scripts, port 3004

**Spec:** `docs/spec.md` (this plan adds §5.19 and gates G50–G54, plus G39 for `make stack-status`, moved here from plan 15 on 2026-09-14 because the console owns its data contract). **Rules:** `AGENTS.md`. **Knowledge:** plan 11 §5.12 (milestone lines in agent logs), plan 13 §5.14 (scores, judge token), plan 14 §5.15 (`context-probe`, `context-report`, `model-fit`), plan 15 (`stack-status` JSON, `cost-report`, virtual keys), plan 16 (`teams/<team>/team.toml`, `team-status`, `member-add`, `team-new`, `agents/roles/`, `teams/<team>/personas/`).
**Sequence:** 17. Requires plans 15 and 16 executed. Adds one directory (`console/`: one Python file, one CSS file, one JS file), one make target, one host port (**3004**, loopback), a console Buzz identity minted by `make init`, a `console` section in the smoke test. No new service, image, build, network, container or Python package: the console is a host process like `init.sh` and `bootstrap-*.sh`.
**Execute with:** `/execute plans/17-console.md`
**No internet at execution.** Nothing is downloaded: no htmx, no fonts, no CDN. Every mechanism below was verified on the reference host on 2026-09-14 (Python 3.12.3, Docker Compose v5.1.3).

---

## 1. Overview

**Intent.** Make the stack visible and operable without the terminal, for a technical lead who understands what it does but should not have to read `docker-compose.yml`, mint keys by hand or tune context windows from log lines. The console is not a second control plane: it is a window onto the same files and the same scripts the terminal uses, and it teaches the terminal by showing every command it runs.

**Principles, each a named best practice.**

1. **Files and scripts are the truth.** The console edits `.env`, `teams/*/team.toml`, `proxy/config.yaml` and personas, and runs make targets. Nothing exists only in the console. (Cockpit's ideals: use the same system APIs and commands as the command line, store no opinion of the server's state, let the operator jump between terminal and UI at will. Portainer over Compose and Dokploy follow the same shape: thin over primitives.)
2. **Show the command.** Every action displays the exact argv it will run, streams the output as it happens, and appends `ts, actor, command, exit, duration` to `console/audit.log`. A click on "Add member" shows `make member-add T=piedpiper N=bertram R=builder` and its output.
3. **Read-only by default, diff before write.** Every write shows a unified diff of the file it changes and the recreate it triggers, and applies only on confirmation. Destructive actions (`down`, key rotation, `member-rm`, model unload) need the action's name typed back.
4. **Host-side, because setup must work before the stack exists.** A containerised console cannot run `make init && make up` for the stack it lives in. `make console` runs `python3 console/app.py` on the host.
5. **Loopback, and an admin UI on loopback is still an attack surface.** Bind `BIND_HOST:3004`; reject any request whose `Host` is not the console's own; reject state-changing requests without the per-process token, with a foreign `Origin`, or with `Sec-Fetch-Site: cross-site`. This is the documented defence against CSRF and DNS rebinding for local web UIs (see §3). Authentication is one function, `actor_of(request)`, returning `operator` on loopback today; a later plan replaces it with Gitea OIDC behind TLS at a reverse proxy without touching the routes.
6. **One privileged operation at a time.** A queue with a single worker: the make targets are not concurrent-safe, and the audit log stays a sequence.
7. **Secrets never render.** Any `.env` value whose key matches `KEY|TOKEN|SECRET|PASSWORD|PRIVATE` shows as `••••` plus its last four characters; the editor writes back only keys the operator changed.
8. **Zero build, zero dependency.** Python standard library (`http.server`, `tomllib`, `difflib`, `subprocess`, `secrets`, `hmac`), one hand-written CSS file (the tokens of the stamped mock), one small vanilla JavaScript file for streaming and confirmations. No htmx (it cannot be vendored without internet), no Node, no pip.
9. **Backend-agnostic like the stack.** Health and models come from LiteLLM and `stack-status`; power tiles from the meter's last rows (`stack_energy`, plan 15), never from a vendor tool; Ollama-only controls (`model-fit`) appear only when the backend answers `/api/tags`. The console never calls LiteLLM `/health` (it test-calls every model): `/health/readiness` only.

**Screens** (baseline: the stamped "Stack Console" mock; same layout, tokens, pills, the fixed "last command" drawer, the numbered setup checklist).

| Screen | Job | Reads | Writes / runs |
|---|---|---|---|
| Setup | get it running on this machine | `check-ports.sh`, `preflight.sh`, presence and health of `.env`, tokens, containers | `.env` form (profiles as toggles, `BIND_HOST`, `LLM_BASE_URL`, `LLM_API_KEY`, forge), `make init`, `make up`, `make gitea-bootstrap`, `make team-bootstrap`, `make test` |
| Overview | is it healthy, what is it doing, what did it burn | `make stack-status` JSON (services, gateway, the last meter row per energy domain, 24 h tokens, 24 h kWh measured + host + cost, cap alerts, open PRs), the `== TOTAL`, per-model and per-client lines of `make cost-report SINCE="24 hours"` (energy panel: calls / idle bar, per model and per client rows), team members from `team.toml` | `make cost-report` |
| Models | what the team can use, is it tuned | registry from `/v1/model/info`, `context-report`, backend type | `make context-probe`, `make model-fit M=` (Ollama only), `make reload`, `make team-model M=` |
| Teams | who is on the team, doing what | `team.toml`, `make team-status`, personas | `make member-add`, `make member-rm` (destructive), persona editor (diff + force-recreate one container), `make team-model` |
| Jobs | ask the team, see what shipped and how good | Gitea PRs with labels (judge token), `make score-report` | post a job thread as the console identity, `make score-sync` |
| Runs & logs | why is Dinesh quiet | `docker compose logs --since` per agent with the milestone filter, smoke history from the audit log | `make team-smoke`, `docker compose restart <agent>` |
| Audit | who changed what | `console/audit.log` | none |

**Architecture.**

```
console/
  app.py            # stdlib HTTP server (threading), routes, screens, runner queue, audit, file editor, security checks, auth hook
  static/console.css
  static/console.js # run an action and stream its output; show a diff and confirm; typed confirmation for destructive actions
  audit.log         # append-only, created on first action; gitignored
make console        # python3 console/app.py  (BIND_HOST:CONSOLE_PORT, default 127.0.0.1:3004)
```

Data flows: screens call the same scripts the terminal does (`make stack-status`, `team-status`, `score-report`, `context-report`) with a 10 s in-process cache for the status JSON; actions are an allowlist of named commands mapped to argv (never a shell string built from input); writes go through one function that reads the file, computes the diff, waits for confirmation and writes atomically (`tmp` + `os.replace`); streaming uses chunked `text/event-stream` with the job's lines replayed on reconnect.

**Phases** (tasks below are ordered so execution can stop at a phase boundary with green gates): 0 the status JSON (plan 15, done); 1 Setup + Overview + Models (G50–G52); 2 Teams (G53); 3 Jobs + Runs + Audit (G54). Phase 4 (intranet: container image, Gitea OIDC, TLS) is a later plan.

**Security notes for the record.** The console holds the master key, the admin token and runs `make`: the most privileged process in the stack. Loopback by default and never auto-exposed; `Host` allowlist; per-process token on every state-changing request, delivered in the page and echoed in a header; `Origin`/`Sec-Fetch-Site` checks; one worker; typed confirmation for destructive actions; secrets masked; append-only audit shown in the UI; no arbitrary shell, only named actions with validated parameters.

**Success criteria.** G50 — `make console` binds only `BIND_HOST:3004`; every screen answers 200 with real data in under 2 s; the smoke's new `console` section checks each screen, a foreign-`Host` request (400), a POST without the token (403). G51 — `make context-report` run from the UI streams its output, lands in `console/audit.log` with exit code and duration, and its captured output equals the terminal's byte for byte. G52 — a `.env` edit from Setup shows a diff, applies only after confirmation, and `make up` from the wizard reaches healthy. G53 — `member-add` from the UI runs the same command as the terminal and the new member answers a mention; a persona edit shows its diff and force-recreates only that container. G54 — a job posted from the console produces a PR whose scores show in Jobs; `make down` and `member-rm` are refused without the typed confirmation and run with it.

**Out of scope.** Intranet deployment (container image, OIDC, TLS: phase 4), multi-deployment views, editing `docker-compose.yml`, a chat surface (Buzz and Open WebUI), metrics storage beyond the stack's tables, running two actions at once.

## 2. Relevant files

| Path | Action |
|---|---|
| `scripts/stack-status.sh` | new: the status JSON the Overview and Setup screens read (`make stack-status`; moved here from plan 15) |
| `console/app.py` | new: the console |
| `console/static/console.css`, `console/static/console.js` | new: tokens and layout from the mock; streaming, diff, confirmations |
| `Makefile` | `console` |
| `.env.example` | `CONSOLE_PORT`, `CONSOLE_PRIVATE_KEY`, `CONSOLE_PUBKEY` |
| `scripts/init.sh` | mint the console keypair |
| `docker-compose.yml` / plan 16 renderer | console pubkey in the agents' allowlist (`humans`) |
| `scripts/smoke-test.sh` | `test_console` |
| `.gitignore` | `console/audit.log` |
| `README.md` "Console", `docs/spec.md` §3, §5.19, §7, `AGENTS.md` | docs |

## 3. Dependencies and verified facts (reference host, 2026-09-14)

- **Host Python.** `python3 --version` → 3.12.3; `import http.server, tomllib, json, subprocess, html, urllib.parse, threading, secrets, hmac, difflib, string` all succeed.
- **Streaming from the standard library works.** A scratch `http.server.ThreadingHTTPServer` on `127.0.0.1:3004` spawned `bash -c 'for i in 1 2 3; do echo line $i; sleep 0.3; done'` and wrote each line as a chunk (`Transfer-Encoding: chunked`, hand-framed `len\r\n…\r\n`, `0\r\n\r\n` at the end) both as `text/plain` and as `text/event-stream` (`data: line 1\n\n`, final `event: done\ndata: 0\n\n`); `curl -N` printed the lines as they arrived (0.9 s total for three lines 0.3 s apart), then the server was stopped and `ss -ltn` shows nothing on 3004. `BaseHTTPRequestHandler` does not check `Host`: a request with `Host: evil.example` got 200 from the scratch server, which is why the console checks it itself.
- **Port 3004 is free** (`ss -ltn | grep -c ':3004 '` → 0). `scripts/check-ports.sh` lists only the ports of Compose profiles and treats a port as "ours" when a container of the project publishes it; the console is a host process, so adding 3004 there would report it BUSY whenever the console runs. Decision: the console checks its own port at start and prints the holder (`ss -Htlnp`) on `EADDRINUSE`; `check-ports.sh` is unchanged.
- **Buzz CLI for job threads**, from `scripts/team-smoke.sh:11–20`: `bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_SMOKE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@"; }`, `bz users set-profile --name Richard-smoke`, `bz channels create --name "job-$(date +%s)" --type stream --visibility open --ttl 7200 | jq -r .channel_id`, `bz channels add-member --channel "$ch" --pubkey "$TEAM_DINESH_PUBKEY" --role bot` (builder, reviewer and the judge: delivery is members-only), `bz messages send --channel "$ch" --mention "$TEAM_DINESH_PUBKEY" --content "@Dinesh …"`, `bz messages get --channel "$ch" --limit 20`, `bz messages thread --channel "$ch" --event "$root"`. The smoke identity is minted by `scripts/init.sh:37–41` (`for who in DINESH GILFOYLE JARED ERLICH MONICA SMOKE` → `TEAM_${who}_PRIVATE_KEY/PUBKEY` from `buzz-admin generate-key`, `Secret key:` / `Public key:` lines). The console identity follows the `BUZZ_AGENT_*` block shape (`init.sh:31–34`): `CONSOLE_PRIVATE_KEY` / `CONSOLE_PUBKEY`. Agents obey only pubkeys in their allowlist (`BUZZ_ACP_RESPOND_TO_ALLOWLIST`, spec §5.8): the console pubkey must be in `humans` of `team.toml` (plan 16) so the renderer puts it there; **verify at execution** that a mention from the console identity gets a reply (G54).
- **`make stack-status` is Task 0 of this plan** (moved from plan 15). Its sources were verified 2026-09-14: `docker compose ps --format json` gives one object per line with `Service`, `State`, `Health`; LiteLLM `GET /health/readiness` → `{"status":"healthy","db":"connected"}` without calling any model (`/health` test-calls every registered model and would load them: never in status); the last meter row per domain is `select distinct on (host, domain) * from stack_energy where ts > now() - interval '2 minutes' order by host, domain, ts desc` (ran on a scratch table; the `json_agg` wrapper: **verify at execution**); Gitea PRs with the judge token (plan 13); `context-report` logic (plan 14) for cap alerts. The Overview is written against this JSON shape: `{generated, bind_host, backend, services[{service,state,health}], gateway{status,db}, power[{host,domain,scope,watts,mem_mib,util,exact,at}] (the last meter row per energy domain within two minutes; empty when the meter is not running; no vendor tool behind it), last_24h{calls,prompt_tokens,completion_tokens,litellm_spend}, energy_24h{scope,measured_kwh,host_kwh,host_kwh_is,cost,tariff_cents,last_sample}|null (plan 15 as revised 2026-09-14: kWh first, the measured figure and the host figure never blended, `host_kwh_is` says `measured` or `estimated`), alerts[{model,over_in,at_out}], open_prs[{repo,number,title,by,labels,url,opened}]}`. If plan 15 changes a field, the console's one mapping function (`status_view`) changes with it.
- **Mock tokens.** The stamped mock defines the whole palette on bare `:root`, redefines only the tokens under `@media (prefers-color-scheme: dark)` guarded as `:root:not([data-theme="light"])`, and again under `:root[data-theme="dark"]`; components use the tokens only. `console.css` below carries them verbatim.
- **Log filters.** `scripts/smoke-test.sh:163` reads an agent with `docker compose logs --since 24h --no-log-prefix dinesh | sed 's/\x1b\[[0-9;]*m//g'` (ANSI stripped); the milestone and deliverable lines an agent posts start with `🚩 pushed`, `🚩 CI`, `**PR:**`, `**Review:**`, `**Score:**`, `**Question:**` (plan 11, `agents/TEAM.md`); `scripts/team-narrate.sh` reads `acp::wire` tool-call frames (`$ …` commands) and `acp::stream` narration (`› …`). The Runs screen filter keeps lines matching `turn starting|turn complete|🚩|\*\*(PR|Review|Score|Question):\*\*|acp::tool.*tool_call_update|^\s*\$ ` after stripping ANSI.
- **Score report shape** (`scripts/score-report.sh`): rows `{repo,n,state,merged,cx,cf,out}` from `GET /repos/{org}/{repo}/pulls?state=all&limit=50` with the judge token; the console reuses the same request for the Jobs table and calls the script for the reliability text.
- **The plan's `app.py` ran on a scratch copy** (2026-09-14, port 3004, real `.env`): all seven screens 200 (0.5 ms to 0.43 s, Jobs slowest: Gitea calls), `Host: evil.example` → 400, POST without the token → 403, `down` without the typed confirmation → 409, a queued `check-ports` streamed four lines as `data:` events and ended with `event: done {"exit": 0, "seconds": 0.1}`, a missing script ended the job with exit 127 instead of killing the worker (fixed during the test: `OSError` around `Popen`), both actions landed in `console/audit.log` with actor, command, exit and duration; `/api/diff` for `kind: env` produced a unified diff. That diff showed a token in its context lines, so `.env` diffs are now rendered over masked text (`mask_env_text`) while the signature and the apply use the real content.
- **Research (network available today).** Cockpit's ideals: use the same system APIs and commands as the command line, keep no private opinion of the server's state, the same permissions as SSH, terminal and UI interchangeable ([Cockpit's Ideals](https://cockpit-project.org/ideals), [Development principles](https://github.com/cockpit-project/cockpit/wiki/DevelopmentPrinciples)). Server-sent events for streamed output: `text/event-stream`, `data:` lines, blank-line delimiters, `EventSource` reconnects by itself ([MDN: Using server-sent events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events), [web.dev: Stream updates with server-sent events](https://web.dev/articles/eventsource-basics)). Local admin UIs need `Host`/`Origin`/`Sec-Fetch-Site` checks even without authentication: reject state-changing requests whose `Origin` is present and not the loopback origin, or whose `Sec-Fetch-Site` is `cross-site`; strict `Host` filtering is the boundary against DNS rebinding ([FPVThePlanet issue #79: local-mode API has no Host/Origin check](https://github.com/lionrayonnant/FPVThePlanet/issues/79), [hero-passport issue #38: Host/CSRF security boundary](https://github.com/runtime-human/hero-passport/issues/38), [amd/gaia issue #3365: agent UI backend drivable from any web page](https://github.com/amd/gaia/issues/3365), [HackTricks: CSRF](https://hacktricks.wiki/en/pentesting-web/csrf-cross-site-request-forgery.html)).

## 4. Tasks (ordered by phase)

### Task 0 (phase 1) — `scripts/stack-status.sh` and `make stack-status`

```bash
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
prs='[]'; if [ -n "${TEAM_JARED_GITEA_TOKEN:-}" ] && [ -n "${GITEA_PUBLIC_URL:-}" ]; then
  B="${GITEA_PUBLIC_URL%/}/api/v1"; org="${TEAM_GITEA_ORG:-piedpiper}"
  prs=$(curl -fsS -m 5 -H "Authorization: token $TEAM_JARED_GITEA_TOKEN" "$B/orgs/$org/repos?limit=50" 2>/dev/null | jq -r '.[].name' \
    | while read -r repo; do curl -fsS -m 5 -H "Authorization: token $TEAM_JARED_GITEA_TOKEN" "$B/repos/$org/$repo/pulls?state=open&limit=20" 2>/dev/null \
        | jq -c --arg r "$repo" '.[] | {repo: $r, number, title, by: .user.login, labels: [.labels[].name], url: .html_url, opened: .created_at}'; done | jq -s '.'); fi
jq -n --argjson services "${services:-[]}" --argjson gateway "$gateway" --argjson power "${power:-[]}" --argjson spend "${spend:-null}" \
      --argjson energy "${energy:-null}" --argjson alerts "${alerts:-[]}" --argjson prs "${prs:-[]}" \
      '{generated: (now|todate), bind_host: env.BIND_HOST, backend: env.LLM_BASE_URL, services: $services, gateway: $gateway, power: $power,
        last_24h: $spend, energy_24h: $energy, alerts: $alerts, open_prs: $prs}'
```

`Makefile`: `stack-status:    ## one JSON: services, gateway, backend, power per domain, 24 h tokens and energy cost, open PRs, cap alerts (plan 17)` → `./scripts/stack-status.sh`. After plan 16 the judge token is `$(python3 scripts/team-roster.py role coordinator …)`'s prefix; until then `TEAM_JARED_GITEA_TOKEN`. Gate G39 (§7): valid JSON with every field above in under 3 s, no vendor tool, nothing loaded.

### Task 1 (phase 1) — `console/app.py`

```python
#!/usr/bin/env python3
"""open-llm-stack console (plan 17): a host-side window onto the stack's files and scripts.
Standard library only. Files and scripts are the truth: every screen reads them, every action runs a make target or a
script, shows the exact command, streams its output and appends to console/audit.log. Read-only until you act; writes
show a diff first; destructive actions need their name typed back. Binds BIND_HOST:CONSOLE_PORT (127.0.0.1:3004)."""
import difflib, hmac, html, http.server, json, os, re, secrets, shlex, socket, subprocess, sys, threading, time, tomllib, urllib.request
from collections import deque
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
STATIC = os.path.join(ROOT, "console", "static")
AUDIT = os.path.join(ROOT, "console", "audit.log")
SECRET_RE = re.compile(r"KEY|TOKEN|SECRET|PASSWORD|PRIVATE", re.I)

# ---------------------------------------------------------------- configuration and helpers
def read_env():
    env = {}
    if os.path.exists(".env"):
        for line in open(".env"):
            s = line.strip()
            if s and not s.startswith("#") and "=" in s:
                k, v = s.split("=", 1); env[k] = v.split(" #", 1)[0].strip()
    return env

def mask(k, v):
    return v if not v or not SECRET_RE.search(k) else "••••" + v[-4:]

def sh(argv, timeout=60):
    """run a command, return (rc, text). Used for reads; actions go through the runner so they stream and are audited."""
    try:
        p = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except Exception as ex:  # noqa: BLE001
        return 1, str(ex)

def esc(s): return html.escape(str(s if s is not None else ""), quote=True)

def strip_ansi(s): return re.sub(r"\x1b\[[0-9;]*m", "", s)

_cache = {}
def cached(key, ttl, fn):
    now = time.time(); hit = _cache.get(key)
    if hit and now - hit[0] < ttl: return hit[1]
    val = fn(); _cache[key] = (now, val); return val

def stack_status():
    def load():
        rc, out = sh(["make", "-s", "stack-status"], timeout=20)
        try: return json.loads(out[out.index("{"):])
        except Exception: return {"error": out.strip()[-400:]}
    return cached("status", 10, load)

def gateway_json(path, env):
    try:
        req = urllib.request.Request(f"{env.get('LITELLM_PUBLIC_URL', 'http://127.0.0.1:3000')}{path}",
                                     headers={"Authorization": f"Bearer {env.get('LITELLM_MASTER_KEY', '')}"})
        return json.loads(urllib.request.urlopen(req, timeout=3).read())
    except Exception: return None

def gitea_json(path, env, token_var="TEAM_JARED_GITEA_TOKEN"):
    base = env.get("GITEA_PUBLIC_URL", "http://127.0.0.1:3003").rstrip("/") + "/api/v1"
    try:
        req = urllib.request.Request(base + path, headers={"Authorization": f"token {env.get(token_var, '')}"})
        return json.loads(urllib.request.urlopen(req, timeout=5).read())
    except Exception: return None

def backend_is_ollama(env):
    url = env.get("LLM_BASE_URL", "").replace("host.docker.internal", "127.0.0.1")
    def probe():
        try: return urllib.request.urlopen(url + "/api/tags", timeout=2).status == 200
        except Exception: return False
    return cached("ollama", 60, probe) if url.startswith("http://127.0.0.1") else False

def team_file():
    for t in sorted(os.listdir("teams")) if os.path.isdir("teams") else []:
        p = os.path.join("teams", t, "team.toml")
        if not t.startswith("_") and os.path.exists(p):
            with open(p, "rb") as f: return t, tomllib.load(f), p
    return None, {}, None

# ---------------------------------------------------------------- actions: an allowlist of named commands, never a shell string built from input
NAME = re.compile(r"^[a-z][a-z0-9._-]{0,63}$")
ROLE = re.compile(r"^(builder|reviewer|coordinator|assistant)$")
SERVICE = re.compile(r"^[a-z][a-z0-9-]{0,40}$")
UUID = re.compile(r"^[0-9a-f-]{36}$"); HEX64 = re.compile(r"^[0-9a-f]{64}$")   # a Buzz channel id and an event id (plan 16.5 approve-job)
def p(params, key, rx=NAME):
    v = params.get(key, "")
    if not rx.match(v): raise ValueError(f"bad {key}: {v!r}")
    return v

ACTIONS = {   # name -> (argv builder, destructive?)
    "init": (lambda q: ["make", "init"], False),
    "up": (lambda q: ["make", "up"], False),
    "down": (lambda q: ["make", "down"], True),
    "test": (lambda q: ["make", "test"], False),
    "reload": (lambda q: ["make", "reload"], False),
    "gitea-bootstrap": (lambda q: ["make", "gitea-bootstrap"], False),
    "team-bootstrap": (lambda q: ["make", "team-bootstrap"], False),
    "check-ports": (lambda q: ["./scripts/check-ports.sh"], False),
    "preflight": (lambda q: ["./scripts/preflight.sh"], False),
    "stack-status": (lambda q: ["make", "-s", "stack-status"], False),
    "context-report": (lambda q: ["make", "context-report"], False),
    "context-probe": (lambda q: ["make", "context-probe"] + ([f"M={p(q, 'M')}"] if q.get("M") else []), False),
    "model-fit": (lambda q: ["make", "model-fit", f"M={p(q, 'M')}"], False),
    "cost-report": (lambda q: ["make", "cost-report"], False),
    "team-model": (lambda q: ["make", "team-model", f"M={p(q, 'M')}"], False),
    "team-status": (lambda q: ["make", "team-status"], False),
    "team-smoke": (lambda q: ["make", "team-smoke"], False),
    "member-add": (lambda q: ["make", "member-add", f"T={p(q, 'T')}", f"N={p(q, 'N')}", f"R={p(q, 'R', ROLE)}"], False),
    "member-rm": (lambda q: ["make", "member-rm", f"T={p(q, 'T')}", f"N={p(q, 'N')}"], True),
    "score-sync": (lambda q: ["make", "score-sync"], False),
    "score-report": (lambda q: ["make", "score-report"], False),
    "restart": (lambda q: ["docker", "compose", "restart", p(q, "S", SERVICE)], False),
    "recreate": (lambda q: ["docker", "compose", "up", "-d", "--force-recreate", p(q, "S", SERVICE)], False),
    "unload-model": (lambda q: ["bash", "-c", "curl -s localhost:11434/api/generate -d '{\"model\":\"" + p(q, "M") + "\",\"keep_alive\":0}'"], True),
    "post-job": (lambda q: ["./console/post-job.sh", p(q, "T"), q.get("text", "")[:2000]], False),
    "approve-job": (lambda q: ["./console/approve-job.sh", p(q, "C", UUID), p(q, "R", HEX64), q.get("note", "")[:200]], False),   # plan 16.5 checkpoint: the human says `approved`
}

# ---------------------------------------------------------------- runner: one job at a time, streamed, audited
class Job:
    def __init__(self, name, argv, actor):
        self.id = secrets.token_hex(6); self.name = name; self.argv = argv; self.actor = actor
        self.lines = deque(); self.done = threading.Event(); self.rc = None; self.started = None; self.ended = None
        self.cond = threading.Condition()
    def cmd(self): return " ".join(shlex.quote(a) for a in self.argv)

class Runner:
    def __init__(self):
        self.queue = deque(); self.jobs = {}; self.current = None; self.lock = threading.Lock()
        threading.Thread(target=self.loop, daemon=True).start()
    def submit(self, job):
        with self.lock: self.jobs[job.id] = job; self.queue.append(job)
        return job
    def loop(self):
        while True:
            with self.lock: job = self.queue.popleft() if self.queue else None
            if job is None: time.sleep(0.2); continue
            self.current = job; job.started = time.time()
            try:
                proc = subprocess.Popen(job.argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
                for line in proc.stdout:
                    with job.cond: job.lines.append(strip_ansi(line.rstrip("\n"))); job.cond.notify_all()
                job.rc = proc.wait()
            except OSError as ex:   # a missing script or binary must end the job, never the worker
                with job.cond: job.lines.append(f"cannot run: {ex}"); job.cond.notify_all()
                job.rc = 127
            job.ended = time.time(); self.current = None
            with open(AUDIT, "a") as f:
                f.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(job.started)), "actor": job.actor, "action": job.name,
                                    "cmd": job.cmd(), "exit": job.rc, "seconds": round(job.ended - job.started, 1), "job": job.id}) + "\n")
            with job.cond: job.done.set(); job.cond.notify_all()
RUNNER = Runner()

# ---------------------------------------------------------------- writes: read, diff, confirm, replace atomically
EDITABLE = {"env": ".env", "registry": "proxy/config.yaml"}
def editable_path(kind, name=None):
    if kind in EDITABLE: return EDITABLE[kind]
    team, _, path = team_file()
    if kind == "team" and path: return path
    if kind == "persona" and team and name and NAME.match(name): return os.path.join("teams", team, "personas", f"{name}.md")
    raise ValueError("not editable")

def mask_env_text(text):
    """secrets never render, not even as diff context: KEY=value lines with a secret-looking key are masked for display."""
    return "".join((f"{m.group(1)}={mask(m.group(1), m.group(2))}\n" if (m := re.match(r"^([A-Z0-9_]+)=(.*)$", line.rstrip("\n"))) else line) for line in text.splitlines(True))

def diff_for(path, new):
    old = open(path).read() if os.path.exists(path) else ""
    if path == ".env": old, new = mask_env_text(old), mask_env_text(new)   # display only; apply uses the real content behind the signature
    return "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True), f"a/{path}", f"b/{path}"))

def env_merge(form):
    """the .env editor posts only the keys it changed; masked values never come back, so unchanged secrets are untouched."""
    lines = open(".env").read().splitlines(True) if os.path.exists(".env") else []
    seen = set()
    for i, line in enumerate(lines):
        m = re.match(r"^([A-Z0-9_]+)=(.*)$", line)
        if m and m.group(1) in form:
            seen.add(m.group(1)); lines[i] = f"{m.group(1)}={form[m.group(1)]}\n"
    for k, v in form.items():
        if k not in seen and re.match(r"^[A-Z0-9_]+$", k): lines.append(f"{k}={v}\n")
    return "".join(lines)

def write_atomic(path, content):
    tmp = path + ".console.tmp"
    with open(tmp, "w") as f: f.write(content)
    os.replace(tmp, path)

# ---------------------------------------------------------------- security: Host allowlist, per-process token, Origin / Sec-Fetch-Site, auth hook
TOKEN = secrets.token_urlsafe(24)
def actor_of(handler):
    """authentication hook. Today: loopback = the operator. A later plan replaces this with Gitea OIDC behind TLS."""
    return "operator"

def host_ok(handler, allowed):
    return handler.headers.get("Host", "").lower() in allowed

def mutation_ok(handler, allowed_origins):
    if handler.headers.get("X-Console-Token", "") != TOKEN: return False
    origin = handler.headers.get("Origin"); site = handler.headers.get("Sec-Fetch-Site", "")
    if origin and origin.lower() not in allowed_origins: return False
    if site and site not in ("same-origin", "none"): return False
    return True

# ---------------------------------------------------------------- html
NAV = [("overview", "Overview"), ("jobs", "Jobs"), ("teams", "Teams"), ("models", "Models"), ("runs", "Runs & logs"), ("setup", "Setup"), ("audit", "Audit")]
def page(active, title, body, env, last):
    nav = "".join(f'<a href="/{k}"{" aria-current=page" if k == active else ""}>{esc(v)}</a>' + ('<div class="sep"></div>' if k == "runs" else "") for k, v in NAV)
    lastrow = (f'<span>Last action</span><span class="cmd">$ {esc(last["cmd"])}</span><span class="{"exit" if last["exit"] == 0 else "fail"}">exit {last["exit"]} · {last["seconds"]} s</span>'
               if last else '<span>No action yet. Everything on screen is read-only until you act.</span>')
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)} · Stack Console</title><meta name="console-token" content="{TOKEN}"><link rel="stylesheet" href="/static/console.css"></head><body>
<header><div><h1>Stack Console</h1><div class="host">open-llm-stack · {esc(socket.gethostname())} · BIND_HOST {esc(env.get("BIND_HOST", "127.0.0.1"))} · backend {esc(env.get("LLM_BASE_URL", "?"))}</div></div>
<div class="mono host">console/app.py · read-only until you act</div></header>
<div class="shell"><nav aria-label="Console sections">{nav}</nav><main>{body}</main></div>
<div class="drawer"><div class="row" id="drawer">{lastrow}</div><pre id="stream" hidden></pre></div>
<script src="/static/console.js"></script></body></html>"""

def pill(text, kind="neutral"): return f'<span class="pill {kind}">{esc(text)}</span>'
def dot(kind): return f'<span class="dot {kind}"></span>'
def btn(action, label, params=None, kind="", destructive=False):
    q = esc(json.dumps(params or {}))
    return f'<button class="btn {kind}" data-action="{esc(action)}" data-params=\'{q}\'{" data-destructive=1" if destructive else ""}>{esc(label)}</button>'
def table(headers, rows, numeric=()):
    th = "".join(f'<th class="{"n" if i in numeric else ""}">{esc(h)}</th>' for i, h in enumerate(headers))
    tr = "".join("<tr>" + "".join(f'<td class="{"n" if i in numeric else ""}">{c}</td>' for i, c in enumerate(r)) + "</tr>" for r in rows)
    return f'<div class="tablewrap"><table><thead><tr>{th}</tr></thead><tbody>{tr or "<tr><td colspan=99 class=note>nothing yet</td></tr>"}</tbody></table></div>'
def panel(title, inner, right=""): return f'<div class="panel"><h3>{esc(title)}<span class="right">{right}</span></h3>{inner}</div>'
def last_action():
    try:
        with open(AUDIT) as f: lines = f.read().splitlines()
        return json.loads(lines[-1]) if lines else None
    except Exception: return None

# ---------------------------------------------------------------- screens
def screen_overview(env):
    st = stack_status(); team, tf, _ = team_file()
    if "error" in st: return f'<h2>Overview</h2><p class="sub">stack-status failed:</p><pre>{esc(st["error"])}</pre>'
    svc = st.get("services", []); up = sum(1 for s in svc if s.get("state") == "running"); en = st.get("energy_24h") or {}; scope = en.get("scope", "gpu"); pw = st.get("power") or []; attributed = [p for p in pw if p.get("scope") == scope]; hostp = [p for p in pw if p.get("scope") == "host"]; l24 = st.get("last_24h") or {}
    tiles = f"""<div class="tiles">
<div class="tile"><div class="l">Stack</div><div class="v">{dot("good" if up == len(svc) else "warn")}{up} / {len(svc)} up</div><div class="d">{esc(", ".join(s["service"] for s in svc if s.get("state") != "running") or "all services running")}</div></div>
<div class="tile energy"><div class="l">Energy · 24 h</div><div class="v">{esc(en.get("measured_kwh", "—"))}<small>kWh</small></div><div class="d">{("measured at " + str(en.get("scope")) + " · whole machine " + str(en.get("host_kwh")) + " kWh (" + str(en.get("host_kwh_is")) + ") · $" + str(en.get("cost")) + " at " + str(en.get("tariff_cents")) + " cents/kWh") if en else "no tariff in .env: energy accounting off"}</div></div>
<div class="tile"><div class="l">Power now</div><div class="v">{esc(round(sum(p.get("watts") or 0 for p in attributed)) if attributed else "—")} W</div><div class="d">{esc(", ".join(p["domain"] + (" · " + str(p["mem_mib"]) + " MiB" if p.get("mem_mib") is not None else "") for p in attributed) or "meter not running")}{(" · host " + str(round(sum(p.get("watts") or 0 for p in hostp))) + " W") if hostp else ""}</div></div>
<div class="tile"><div class="l">Last 24 h</div><div class="v">{esc(l24.get("calls", 0))} calls</div><div class="d">{esc(l24.get("prompt_tokens", 0))} prompt · {esc(l24.get("completion_tokens", 0))} completion · ${esc(l24.get("litellm_spend", 0))} at the gateway's rates</div></div>
<div class="tile"><div class="l">Open PRs by agents</div><div class="v">{len(st.get("open_prs", []))}</div><div class="d">{esc(", ".join("#" + str(x["number"]) for x in st.get("open_prs", [])[:6]))}</div></div></div>"""
    alerts = "".join(f'<li>{pill("cap", "warn")}<span><b>{esc(a["model"])}</b>: {a["over_in"]} prompts over max_input_tokens, {a["at_out"]} completions at max_output_tokens (7 d)</span></li>' for a in st.get("alerts", []))
    alerts = f'<ul class="list">{alerts or "<li><span class=note>nothing needs attention</span></li>"}</ul>'
    members = [(esc(m["name"].title()), esc(m["role"]), f'<span class="mono">{esc(m.get("runtime", "buzz-agent"))}</span>',
                dot("good" if any(s["service"] == m["name"] and s.get("state") == "running" for s in svc) else "crit") + ("up" if any(s["service"] == m["name"] and s.get("state") == "running" for s in svc) else "down"))
               for m in tf.get("members", [])]
    prs = [(f'<span class="mono">{x["number"]}</span>', f'<a href="{esc(x["url"])}">{esc(x["title"])}</a>', esc(x["by"]),
            " ".join(pill(l.split("/", 1)[1], "good" if l.endswith("high") else "neutral") for l in x.get("labels", []) if l.startswith(("complexity/", "confidence/"))), esc(x["opened"][:16]))
           for x in st.get("open_prs", [])]
    return (f'<h2>Overview</h2><p class="sub">Is it healthy, what is it doing, what does it cost. Generated {esc(st.get("generated", ""))}.</p>{tiles}'
            f'<div class="grid2">{panel("Needs attention", alerts, btn("context-report", "make context-report"))}'
            f'{panel(f"Team {team or "(none)"}", table(["Agent", "Role", "Runtime", "State"], members), pill(tf.get("model", ""), "neutral"))}</div>'
            f'{panel("Open pull requests by agents", table(["#", "Title", "By", "Score", "Opened"], prs), btn("score-sync", "make score-sync"))}')

def screen_models(env):
    info = gateway_json("/v1/model/info", env) or {"data": []}; ollama = backend_is_ollama(env)
    rows = []
    for m in info["data"]:
        mi = m.get("model_info", {}); lp = m.get("litellm_params", {})
        rows.append((f'<span class="mono">{esc(m["model_name"])}</span>', f'<span class="mono">{esc(lp.get("model", "").split("/")[0])}</span>', esc(mi.get("context_window", "—")),
                     esc(mi.get("max_input_tokens", "—")), esc(mi.get("max_output_tokens", "—")),
                     btn("context-probe", "probe", {"M": m["model_name"]}) + (btn("model-fit", "fit", {"M": lp.get("model", "").split("/", 1)[-1]}) if ollama and lp.get("model", "").startswith("ollama_chat/") else "")
                     + btn("team-model", "use for team", {"M": m["model_name"]})))
    rc, rep = sh(["make", "-s", "context-report"], timeout=30)
    return (f'<h2>Models</h2><p class="sub">The registry is the contract; declared windows are proved through the gateway.</p>'
            f'{panel("Registry · proxy/config.yaml", table(["Model", "Backend", "Window", "Input cap", "Output cap", ""], rows, numeric=(2, 3, 4)), btn("context-probe", "make context-probe") + btn("reload", "make reload"))}'
            f'<div class="grid2">{panel("Backend", f"<dl class=kv><dt>Endpoint</dt><dd class=mono>{esc(env.get("LLM_BASE_URL", ""))}</dd><dt>Type</dt><dd>{"Ollama (answers /api/tags)" if ollama else "OpenAI-compatible"}</dd></dl>")}'
            f'{panel("Real use vs caps (7 d)", f"<pre>{esc(rep.strip())}</pre>", btn("context-report", "refresh"))}</div>'
            f'{panel("Edit the registry", editor("registry", "proxy/config.yaml"))}')

def editor(kind, path, name=None):
    content = open(path).read() if os.path.exists(path) else ""
    return (f'<form class="mock" data-write="{esc(kind)}" data-name="{esc(name or "")}"><textarea id="ed-{esc(kind)}-{esc(name or "x")}" name="content" rows="14" class="mono">{esc(content)}</textarea>'
            f'<div><button class="btn" type="submit">Show diff</button> <span class="example">nothing is written until you confirm the diff</span></div></form>')

def screen_setup(env):
    st = stack_status(); have_env = os.path.exists(".env"); svc = st.get("services", []) if isinstance(st, dict) else []
    steps = [("Prerequisites: Docker, Compose, ports 3000–3003 free", "check-ports", bool(svc)),
             ("Backend reachable from inside the gateway", "preflight", bool(svc)),
             ("Configuration: layers, bind host, backend, forge", None, have_env),
             ("Secrets minted, registry copied", "init", have_env and bool(env.get("LITELLM_MASTER_KEY"))),
             ("Stack up and healthy", "up", bool(svc) and all(s.get("health") in ("healthy", "") for s in svc)),
             ("Forge admin and token", "gitea-bootstrap", bool(env.get("GITEA_ADMIN_TOKEN"))),
             ("Team accounts, tokens, fixture repository", "team-bootstrap", bool(env.get("TEAM_DINESH_GITEA_TOKEN"))),
             ("Every gate green", "test", False)]
    first_open = next((i for i, s in enumerate(steps) if not s[2]), len(steps))
    items = "".join(f'<li><span class="n {"done" if done else ("now" if i == first_open else "")}">{i + 1}</span><span>{esc(label)}</span>'
                    f'<span>{btn(action, "make " + action if action not in ("check-ports", "preflight") else action, kind="primary" if i == first_open else "") if action else ""}</span></li>'
                    for i, (label, action, done) in enumerate(steps))
    keys = ["COMPOSE_PROFILES", "BIND_HOST", "LLM_BASE_URL", "LLM_API_KEY", "LITELLM_PUBLIC_URL", "GITEA_PUBLIC_URL", "GITEA_ADMIN_USER", "TEAM_GITEA_ORG", "TEAM_MODEL", "POWER_COST_PER_KWH", "POWER_PROBES", "POWER_SCOPE", "POWER_HOST_OVERHEAD"]
    fields = "".join(f'<label>{esc(k)}<input id="env-{esc(k)}" name="{esc(k)}" value="{esc(mask(k, env.get(k, "")))}" data-masked="{1 if SECRET_RE.search(k) else 0}"></label>' for k in keys)
    form = f'<form class="mock" data-write="env"><input type="hidden" name="content" value="">{fields}<div><button class="btn primary" type="submit">Show diff of .env</button> <span class="example">masked values are never sent back; leave them as they are</span></div></form>'
    return f'<h2>Setup</h2><p class="sub">Get it running on this machine. Each step shows the command it runs.</p>{panel("Steps", f"<ol class=steps>{items}</ol>")}{panel("Configuration", form)}'

def screen_teams(env):
    team, tf, path = team_file()
    if not team: return '<h2>Teams</h2><p class="sub">No teams/<team>/team.toml yet (plan 16). Run make team-new from the terminal.</p>'
    rc, status = sh(["make", "-s", "team-status", f"T={team}"], timeout=30)
    members = [(esc(m["name"].title()), esc(m["role"]), f'<span class="mono">{esc(m["name"])}</span>', f'<span class="mono">{esc(m.get("runtime", "buzz-agent"))}</span>',
                btn("recreate", "restart", {"S": m["name"]}) + f' <a class="btn" href="/teams?persona={esc(m["name"])}">persona</a> ' + btn("member-rm", "remove", {"T": team, "N": m["name"]}, destructive=True))
               for m in tf.get("members", [])]
    add = (f'<form class="mock" data-run="member-add"><input type="hidden" name="T" value="{esc(team)}"><label>Name <input id="m-name" name="N" value=""></label>'
           f'<label>Role <select id="m-role" name="R"><option>builder</option><option>reviewer</option><option>coordinator</option><option>assistant</option></select></label>'
           f'<div><button class="btn primary" type="submit">Add member</button> <span class="example">runs make member-add T={esc(team)} N=&lt;name&gt; R=&lt;role&gt;: keys, render, forge user, container; then write the persona</span></div></form>')
    kv = f'<dl class="kv"><dt>Organisation</dt><dd class="mono">{esc(tf.get("org", ""))}</dd><dt>Model</dt><dd class="mono">{esc(tf.get("model", ""))}</dd><dt>CI label</dt><dd class="mono">{esc(tf.get("ci_label", ""))}</dd><dt>Humans</dt><dd class="mono">{esc(", ".join(h[:8] + "…" for h in tf.get("humans", [])))}</dd></dl>'
    return (f'<h2>Teams</h2><p class="sub">One team per deployment. Members are a few lines in <code>{esc(path)}</code> plus a persona.</p>'
            f'<div class="grid2">{panel(team, kv, btn("team-status", "make team-status"))}{panel("Add member", add)}</div>'
            f'{panel("Members", table(["Member", "Role", "Login", "Runtime", ""], members))}{panel("team-status", f"<pre>{esc(status.strip())}</pre>")}'
            f'{panel("team.toml", editor("team", path))}')

def screen_persona(env, name):
    team, tf, _ = team_file()
    if not team or not NAME.match(name): return "<h2>Persona</h2><p class=sub>unknown member</p>"
    path = editable_path("persona", name)
    return (f'<h2>Persona · {esc(name.title())}</h2><p class="sub">Applying writes <code>{esc(path)}</code> and force-recreates <code>{esc(name)}</code> only.</p>'
            f'{panel(path, editor("persona", path, name))}')

def screen_jobs(env):
    team, tf, _ = team_file(); org = tf.get("org") or env.get("TEAM_GITEA_ORG", "piedpiper")
    repos = gitea_json(f"/orgs/{org}/repos?limit=50", env) or []
    rows = []
    for r in repos:
        for pr in gitea_json(f"/repos/{org}/{r['name']}/pulls?state=all&limit=10", env) or []:
            labels = [l["name"] for l in pr.get("labels", [])]
            score = " ".join(pill(l.split("/", 1)[1], "good" if l.endswith("high") else ("warn" if l.endswith("medium") else ("crit" if l.endswith("low") else "neutral"))) for l in labels if l.startswith(("complexity/", "confidence/"))) or pill("not scored")
            out = next((l.split("/", 1)[1] for l in labels if l.startswith("outcome/")), "open" if pr["state"] == "open" else "unsynced")
            rows.append((f'<span class="mono">{r["name"]}#{pr["number"]}</span>', f'<a href="{esc(pr["html_url"])}">{esc(pr["title"])}</a>', esc(pr["user"]["login"]), score,
                         pill(out, "good" if out == "merged-as-is" else ("neutral" if out == "open" else "warn")), esc(pr["created_at"][:16])))
    rows.sort(key=lambda x: x[5], reverse=True)
    rc, rep = sh(["make", "-s", "score-report"], timeout=30)
    ask = (f'<form class="mock" data-run="post-job"><input type="hidden" name="T" value="{esc(team or "")}"><label>Ask <textarea id="job-text" name="text" rows="4"></textarea></label>'
           f'<div><button class="btn primary" type="submit">Post job thread</button> <span class="example">posts as the console identity into a new private job channel with the builder, the reviewer, the coordinator and the humans as members; the builder answers with a plan</span></div></form>'
           f'<form class="mock" data-run="approve-job"><label>Channel <input name="C" placeholder="job channel uuid (from the post-job output)"></label><label>Thread root <input name="R" placeholder="thread root event id"></label><label>Note <input name="note" placeholder="optional"></label>'
           f'<div><button class="btn" type="submit">Approve plan</button> <span class="example">replies `approved` as the console identity (plan 16.5); nothing is built before this</span></div></form>')
    return (f'<h2>Jobs</h2><p class="sub">Ask the team, then see what shipped and how good it was.</p><div class="grid2">{panel("New job and approval", ask)}{panel("Reliability", f"<pre>{esc(rep.strip())}</pre>", btn("score-report", "make score-report") + btn("score-sync", "make score-sync"))}</div>'
            f'{panel("Pull requests", table(["PR", "Title", "By", "Score", "Outcome", "Opened"], rows[:40]))}')

FILTER = re.compile(r"turn starting|turn complete|🚩|\*\*(PR|Review|Score|Question):\*\*|tool_call_update|^\s*\$ ")
def screen_runs(env):
    team, tf, _ = team_file(); names = [m["name"] for m in tf.get("members", [])] or ["dinesh", "gilfoyle", "jared", "erlich", "monica"]
    panels = ""
    for n in names:
        rc, log = sh(["docker", "compose", "logs", "--since", "2h", "--no-log-prefix", n], timeout=20)
        lines = [l for l in strip_ansi(log).splitlines() if FILTER.search(l)][-25:]
        panels += panel(f"{n} · last 2 h", f'<pre>{esc(chr(10).join(lines) or "quiet")}</pre>', btn("restart", "restart", {"S": n}))
    smokes = [(esc(a["ts"][:16]), pill("PASS" if a["exit"] == 0 else "FAIL", "good" if a["exit"] == 0 else "crit"), f'{a["seconds"]} s') for a in read_audit() if a.get("action") == "team-smoke"][-8:]
    return (f'<h2>Runs &amp; logs</h2><p class="sub">Why is an agent quiet. Milestones and deliverables filtered from the logs.</p>'
            f'{panel("Team smoke", table(["When", "Result", "Duration"], smokes), btn("team-smoke", "make team-smoke", kind="primary"))}{panels}')

def read_audit():
    try:
        with open(AUDIT) as f: return [json.loads(l) for l in f if l.strip()]
    except FileNotFoundError: return []

def screen_audit(env):
    rows = [(esc(a["ts"]), esc(a["actor"]), f'<span class="mono">{esc(a["cmd"])}</span>', pill(f'exit {a["exit"]}', "good" if a["exit"] == 0 else "crit"), f'{a["seconds"]} s') for a in reversed(read_audit()[-200:])]
    return f'<h2>Audit</h2><p class="sub">Every action the console ran, with its command and exit code. Append-only: <code>console/audit.log</code>.</p>{panel("Actions", table(["When (UTC)", "Actor", "Command", "Exit", "Took"], rows))}'

SCREENS = {"overview": ("Overview", screen_overview), "models": ("Models", screen_models), "setup": ("Setup", screen_setup),
           "teams": ("Teams", screen_teams), "jobs": ("Jobs", screen_jobs), "runs": ("Runs & logs", screen_runs), "audit": ("Audit", screen_audit)}

# ---------------------------------------------------------------- http
class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "StackConsole/1"
    def log_message(self, fmt, *args): pass
    def send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Frame-Options", "DENY"); self.send_header("Referrer-Policy", "no-referrer"); self.end_headers(); self.wfile.write(data)
    def chunk(self, data):
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n"); self.wfile.flush()
    def do_GET(self):
        if not host_ok(self, self.server.hosts): return self.send(400, "bad Host", "text/plain")
        env = read_env(); u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/": self.send_response(302); self.send_header("Location", "/overview"); self.end_headers(); return
        if u.path.startswith("/static/"):
            f = os.path.join(STATIC, os.path.basename(u.path))
            if not os.path.exists(f): return self.send(404, "not found", "text/plain")
            return self.send(200, open(f, "rb").read(), "text/css" if f.endswith(".css") else "application/javascript")
        if u.path.startswith("/api/jobs/") and u.path.endswith("/stream"):
            job = RUNNER.jobs.get(u.path.split("/")[3])
            if not job: return self.send(404, "no such job", "text/plain")
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            self.chunk(f"event: cmd\ndata: {json.dumps(job.cmd())}\n\n".encode()); i = 0
            while True:
                with job.cond:
                    while i >= len(job.lines) and not job.done.is_set(): job.cond.wait(1)
                    lines = list(job.lines)[i:]; i = len(job.lines); done = job.done.is_set()
                for l in lines: self.chunk(f"data: {json.dumps(l)}\n\n".encode())
                if done and i >= len(job.lines):
                    self.chunk(f"event: done\ndata: {json.dumps({'exit': job.rc, 'seconds': round(job.ended - job.started, 1)})}\n\n".encode()); break
            self.wfile.write(b"0\r\n\r\n"); return
        if u.path == "/api/status": return self.send(200, json.dumps(stack_status()), "application/json")
        if u.path == "/teams" and q.get("persona"): return self.send(200, page("teams", "Persona", screen_persona(env, q["persona"]), env, last_action()))
        key = u.path.strip("/")
        if key in SCREENS:
            title, fn = SCREENS[key]
            try: body = fn(env)
            except Exception as ex:  # noqa: BLE001
                body = f"<h2>{esc(title)}</h2><pre>{esc(repr(ex))}</pre>"
            return self.send(200, page(key, title, body, env, last_action()))
        self.send(404, "not found", "text/plain")
    def do_POST(self):
        if not host_ok(self, self.server.hosts): return self.send(400, "bad Host", "text/plain")
        if not mutation_ok(self, self.server.origins): return self.send(403, "missing or bad token / origin", "text/plain")
        actor = actor_of(self); n = int(self.headers.get("Content-Length", "0") or 0)
        try: body = json.loads(self.rfile.read(n) or b"{}")
        except Exception: return self.send(400, "bad json", "text/plain")
        u = urlparse(self.path)
        try:
            if u.path == "/api/run":
                name = body.get("action", ""); spec = ACTIONS.get(name)
                if not spec: return self.send(404, "unknown action", "text/plain")
                argv, destructive = spec[0](body.get("params", {})), spec[1]
                if destructive and body.get("confirm") != name: return self.send(409, f"type {name} to confirm", "text/plain")
                job = RUNNER.submit(Job(name, argv, actor)); return self.send(200, json.dumps({"job": job.id, "cmd": job.cmd(), "queued": len(RUNNER.queue)}), "application/json")
            if u.path == "/api/diff":
                path = editable_path(body.get("kind", ""), body.get("name")); new = env_merge(body.get("form", {})) if body.get("kind") == "env" else body.get("content", "")
                d = diff_for(path, new); sig = hmac.new(TOKEN.encode(), (path + new).encode(), "sha256").hexdigest()
                return self.send(200, json.dumps({"path": path, "diff": d, "sig": sig, "empty": not d, "content": new}), "application/json")
            if u.path == "/api/apply":
                path = editable_path(body.get("kind", ""), body.get("name")); new = body.get("content", "")
                if not hmac.compare_digest(body.get("sig", ""), hmac.new(TOKEN.encode(), (path + new).encode(), "sha256").hexdigest()): return self.send(409, "diff changed; show it again", "text/plain")
                write_atomic(path, new)
                with open(AUDIT, "a") as f: f.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "actor": actor, "action": "write", "cmd": f"write {path}", "exit": 0, "seconds": 0}) + "\n")
                follow = {"registry": "reload", "persona": "recreate", "team": None, "env": None}.get(body.get("kind"))
                job = RUNNER.submit(Job(follow, ACTIONS[follow][0]({"S": body.get("name", "")}), actor)) if follow else None
                return self.send(200, json.dumps({"written": path, "job": job.id if job else None, "cmd": job.cmd() if job else None}), "application/json")
        except ValueError as ex: return self.send(400, str(ex), "text/plain")
        self.send(404, "not found", "text/plain")

def main():
    env = read_env(); host = env.get("BIND_HOST", "127.0.0.1"); port = int(env.get("CONSOLE_PORT") or 3004)
    hosts = {f"{host}:{port}", f"127.0.0.1:{port}", f"localhost:{port}"}; origins = {f"http://{h}" for h in hosts}
    try: srv = http.server.ThreadingHTTPServer((host, port), Handler)
    except OSError as ex:
        rc, who = sh(["bash", "-c", f"ss -Htlnp | grep -E '[:.]{port} ' | head -1"]); print(f"cannot bind {host}:{port}: {ex}\n{who.strip()}"); sys.exit(1)
    srv.hosts, srv.origins = hosts, origins; srv.daemon_threads = True
    print(f"console on http://{host}:{port}  (token in the page; audit: console/audit.log)")
    try: srv.serve_forever()
    except KeyboardInterrupt: pass

if __name__ == "__main__": main()
```

Notes on the file: `ACTIONS` is the only way to run anything; parameters pass through `p()` with a regex per kind; `post-job` delegates to `console/post-job.sh` (Task 5) so the Buzz commands stay in one bash file next to the smoke's. `TOKEN` is generated per process and embedded in every page as a `<meta>`; `console.js` echoes it in `X-Console-Token`. The audit line for a write records `write <path>`; the follow-up (`make reload` for the registry, `docker compose up -d --force-recreate <member>` for a persona) is a normal job with its own line.

### Task 2 (phase 1) — `console/static/console.css`

The tokens and rules of the stamped mock, verbatim, with two additions (`.fail` for a non-zero exit in the drawer, `#stream` for the streamed output). Copy from the mock's `<style>` block: `:root` tokens, the two dark blocks, `body`, `.mono`, `header`, `.shell`, `nav` (rules apply to `nav a` instead of `nav button`: same selectors with `a` and `aria-current`), `section`/`h2`/`.sub`, `.tiles`/`.tile`, `.panel`, `.tablewrap`/`table`, `.pill`, `.dot`, `.btn`, `.list`, `pre`, `.drawer`, `.grid2`, `.kv`, `form.mock`, `.diff`, `.steps`, `.note`, `.example`, the two media queries. Append:

```css
.drawer .fail { color: var(--crit); font-weight: 600; }
#stream { max-height: 40vh; overflow: auto; margin-top: 8px; }
.drawer { max-height: 55vh; overflow: hidden; }
nav a { text-decoration: none; }
```

### Task 3 (phase 1) — `console/static/console.js`

```javascript
// Stack Console (plan 17): run a named action and stream its output; show a diff and apply on confirmation;
// destructive actions need their name typed back. Vanilla JS, no library: nothing is downloaded at execution.
(function () {
  const token = document.querySelector('meta[name="console-token"]').content;
  const drawer = document.getElementById('drawer'), out = document.getElementById('stream');
  const post = (path, body) => fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Console-Token': token }, body: JSON.stringify(body) });
  function follow(job, cmd) {
    out.hidden = false; out.textContent = ''; drawer.innerHTML = `<span>Running</span><span class="cmd">$ ${esc(cmd)}</span>`;
    const es = new EventSource(`/api/jobs/${job}/stream`);
    es.onmessage = (e) => { out.textContent += JSON.parse(e.data) + '\n'; out.scrollTop = out.scrollHeight; };
    es.addEventListener('done', (e) => { const d = JSON.parse(e.data); es.close();
      drawer.innerHTML = `<span>Last action</span><span class="cmd">$ ${esc(cmd)}</span><span class="${d.exit === 0 ? 'exit' : 'fail'}">exit ${d.exit} · ${d.seconds} s</span><button class="btn" onclick="location.reload()">Refresh screen</button>`; });
  }
  async function run(action, params, destructive) {
    let confirm;
    if (destructive) { confirm = prompt(`This is destructive. Type ${action} to confirm.`); if (confirm !== action) return; }
    const r = await post('/api/run', { action, params, confirm });
    if (!r.ok) { alert(await r.text()); return; }
    const j = await r.json(); follow(j.job, j.cmd);
  }
  document.querySelectorAll('button[data-action]').forEach((b) => b.addEventListener('click', () => run(b.dataset.action, JSON.parse(b.dataset.params || '{}'), !!b.dataset.destructive)));
  document.querySelectorAll('form[data-run]').forEach((f) => f.addEventListener('submit', (e) => { e.preventDefault();
    const params = Object.fromEntries(new FormData(f).entries()); run(f.dataset.run, params, false); }));
  document.querySelectorAll('form[data-write]').forEach((f) => f.addEventListener('submit', async (e) => { e.preventDefault();
    const kind = f.dataset.write, name = f.dataset.name || undefined; let body;
    if (kind === 'env') { const form = {}; f.querySelectorAll('input[name]').forEach((i) => { if (i.name !== 'content' && !(i.dataset.masked === '1' && i.value.startsWith('••••'))) form[i.name] = i.value; }); body = { kind, form }; }
    else body = { kind, name, content: f.querySelector('textarea[name="content"]').value };
    const r = await post('/api/diff', body); if (!r.ok) { alert(await r.text()); return; }
    const d = await r.json(); if (d.empty) { alert('No change.'); return; }
    out.hidden = false; out.textContent = d.diff; drawer.innerHTML = `<span>Diff of ${esc(d.path)}</span><button class="btn primary" id="apply">Apply</button><button class="btn" onclick="location.reload()">Discard</button>`;
    document.getElementById('apply').onclick = async () => {
      const content = kind === 'env' ? null : body.content; const a = await post('/api/apply', { kind, name, content: content ?? d.content ?? '', sig: d.sig });
      if (!a.ok) { alert(await a.text()); return; } const j = await a.json();
      if (j.job) follow(j.job, j.cmd); else { drawer.innerHTML = `<span>Written ${esc(j.written)}</span><button class="btn" onclick="location.reload()">Refresh screen</button>`; }
    };
  }));
  function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
})();
```

`/api/diff` returns `content` (the merged file for `kind: env`) alongside `diff` and `sig`, so apply sends back exactly what was diffed. **Verify at execution** that masked values never reach `/api/diff` (the JS skips inputs still starting with `••••`).

### Task 4 (phase 1) — wiring: Makefile, `.env.example`, `init.sh`, `.gitignore`, smoke

`Makefile`:

```make
console:         ## the console on BIND_HOST:CONSOLE_PORT (127.0.0.1:3004): a window onto the same files and scripts (plan 17)
	python3 console/app.py
```

`.env.example`, after `BIND_HOST`:

```
# --- Console (plan 17): host process, `make console`; loopback only. Its Buzz identity posts job threads and must be in the team's humans.
CONSOLE_PORT=3004
CONSOLE_PRIVATE_KEY=
CONSOLE_PUBKEY=
```

`scripts/init.sh`, after the `BUZZ_AGENT_*` block (`:31–34`), same shape:

```bash
if blank CONSOLE_PRIVATE_KEY; then
  out=$(gen_key)
  set_if_blank CONSOLE_PRIVATE_KEY "$(awk '/Secret key:/{print $3}' <<<"$out")"
  set_if_blank CONSOLE_PUBKEY "$(awk '/Public key:/{print $3}' <<<"$out")"
fi
```

`.gitignore`: `console/audit.log`. Allowlist: `CONSOLE_PUBKEY` joins the team's `humans` in `teams/<team>/team.toml` (plan 16 renders `humans` into `BUZZ_ACP_RESPOND_TO_ALLOWLIST`); until plan 16 lands on a host, `${CONSOLE_PUBKEY:-}` is appended to the allowlist line in `docker-compose.yml` `&team-env`. **Verify at execution** which of the two applies.

`scripts/smoke-test.sh`, new section, dispatched when `CONSOLE_PORT` is set and the console answers (the console is a host process, not a profile):

```bash
test_console() {   # G50: every screen 200 in < 2 s, foreign Host rejected, POST without the token rejected (plan 17)
  local base="http://${BIND_HOST}:${CONSOLE_PORT:-3004}"
  echo "--- console: screens"
  curl -fsS -m 3 -o /dev/null "$base/overview" 2>/dev/null || { echo "(console not running: make console; skipped)"; return 0; }
  for s in overview models setup teams jobs runs audit; do
    local t; t=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' "$base/$s"); echo "$s -> $t"
    [[ $t == 200* ]] || fail "console screen $s not 200"; awk -v x="${t#* }" 'BEGIN{exit !(x < 2.0)}' || fail "console screen $s slower than 2 s"
  done
  [ "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "$base/overview")" = 400 ] && echo "foreign Host rejected" || fail "foreign Host accepted"
  [ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"action":"stack-status"}' "$base/api/run")" = 403 ] && echo "POST without token rejected" || fail "POST without token accepted"
}
…
[ -n "${CONSOLE_PORT:-}" ] && test_console
```

### Task 5 (phase 3) — `console/post-job.sh`

```bash
#!/usr/bin/env bash
# Post a job thread as the console identity (plan 17): a new job channel with the team's builder, reviewer and coordinator
# as bot members, then the ask, mentioning the builder. Same commands as scripts/team-smoke.sh. Usage: post-job.sh <team> <text>
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
team=$1; text=$2; SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9; URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
: "${CONSOLE_PRIVATE_KEY:?run make init}"
bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$CONSOLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@"; }
member() { python3 -c 'import sys,tomllib; t=tomllib.load(open(sys.argv[1],"rb")); print(next(m["name"] for m in t["members"] if m["role"]==sys.argv[2]))' "teams/$team/team.toml" "$1"; }
pub() { local v="TEAM_$(echo "$1" | tr a-z A-Z)_PUBKEY"; echo "${!v}"; }
b=$(member builder); r=$(member reviewer); c=$(member coordinator)
bz users set-profile --name Console >/dev/null
ch=$(bz channels create --name "job-$(date +%s)" --type stream --visibility private --ttl 86400 | jq -r .channel_id)   # private: the adversary and the gatekeeper stay out (plan 16.5)
for who in "$b" "$r" "$c"; do bz channels add-member --channel "$ch" --pubkey "$(pub "$who")" --role bot >/dev/null; done
for h in $(tr ',' ' ' <<<"${TEAM_ALLOWLIST:-}"); do bz channels add-member --channel "$ch" --pubkey "$h" --role member >/dev/null; done   # the humans who may reply `approved`
bz messages send --channel "$ch" --mention "$(pub "$b")" --content "@${b^} $text" >/dev/null
root=$(bz messages get --channel "$ch" --limit 5 | jq -r --arg b "${b^}" '[.[] | select(.content|startswith("@" + $b + " "))][0].id')
echo "posted to channel $ch (thread root $root), mentioning ${b^}; the builder answers with **Plan:** and waits for a human `approved` (Buzz app, or console/approve-job.sh $ch $root)"
```

`console/approve-job.sh` (the human checkpoint of plan 16.5 from the console identity; the Jobs screen's Approve button runs it):

```bash
#!/usr/bin/env bash
# Approve a builder's **Plan:** as the console identity (plan 16.5 checkpoint). Usage: approve-job.sh <channel-uuid> <thread-root-id> [note]
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
ch=${1:?channel}; root=${2:?thread root}; note=${3:-}
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9; URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
: "${CONSOLE_PRIVATE_KEY:?run make init}"
docker run --rm --network host -e BUZZ_PRIVATE_KEY="$CONSOLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" messages send --channel "$ch" --reply-to "$root" --content "approved${note:+: $note}" >/dev/null
echo "approved in $ch/$root"
```

Plan 16 (executed) names member keys `TEAM_<NAME>_PUBKEY` with dashes as underscores, whatever the team; `pub()` above is right. Plan 16.5 (executed before this plan) makes the builder wait for a human `approved` reply in the thread and keeps job channels private, hence `--visibility private`, the human members and `approve-job.sh`.

### Task 6 — docs

- `docs/spec.md`: §3 (`CONSOLE_PORT`, `CONSOLE_*` keys); new §5.19 "The console (plan 17)": the nine principles, the screens table, the security model (Host allowlist, per-process token, Origin/Sec-Fetch-Site, one worker, typed confirmation, masking, audit), the auth hook contract (`actor_of`), the `/health` rule, the action allowlist rule; §7 gates G50–G54.
- `README.md`: "Console" after "The agent team": `make console`, the URL, what each screen does, the drawer, the audit log, the rule that the console never does anything the terminal cannot, the systemd user unit (mirror of the meter's), and that exposing it beyond loopback waits for a later plan.
- `AGENTS.md`: status line + one non-negotiable: "The console (`console/app.py`, port 3004, host process) only runs named actions from its allowlist that map to make targets and scripts, shows every command, streams and audits it, diffs before every write, never calls LiteLLM `/health`, and binds loopback with Host/token/Origin checks (spec §5.17). Never add a control path that bypasses the make targets."

## 5. Considerations

- **One process, one operator.** `ThreadingHTTPServer` and a single worker suit one lead at a terminal-less desk. Two people clicking at once queue; the drawer says `queued`. Phase 4 keeps the queue and adds identity.
- **The token is per process.** Restarting the console invalidates open pages; they reload and get the new token. Cookies are not used, so there is nothing for a foreign page to ride on.
- **Writes are whole-file replacements** guarded by an HMAC of the exact content shown in the diff; a change between "show diff" and "apply" is refused. The `.env` editor merges only posted keys and never receives masked values.
- **Screens shell out** to the same scripts the terminal runs (`stack-status`, `team-status`, `context-report`, `score-report`) with small timeouts and a 10 s cache for the status JSON; a slow script shows as a slow screen, which G50 bounds at 2 s and which points at the script, not the console.
- **Backend-agnostic by construction:** only `model-fit` is Ollama-gated, by the same `/api/tags` probe plan 14 used.
- **Intranet (phase 4)** replaces `actor_of`, adds TLS at a reverse proxy, widens the `Host` allowlist to the proxy's name, and containerises with the same `console/` mounted; nothing in the routes changes.

## 6. Testing strategy

Phase 1 first: start the console, G50 through the smoke section, G51 with `make context-report` from the UI against the terminal (`diff <(make -s context-report) <(sed -n '/^data:/p' …)` using the audit job's captured lines), G52 with a harmless `.env` change (`POWER_HOST_OVERHEAD=100`), its diff, apply, revert, and `make up` from Setup on the running stack. Phase 2 after plan 16: G53 with a member on the fixture team. Phase 3: G54 with a job from the Jobs screen and the two destructive refusals. Numbers and outputs into §8.

## 7. Validation commands

```bash
# G39 status (moved from plan 15): no vendor tool, nothing loaded
P0=$(nvidia-smi --query-gpu=power.draw.average --format=csv,noheader,nounits); time make stack-status | jq -e '.services, .gateway.status, .power, .last_24h.calls, .energy_24h, .alerts, .open_prs' >/dev/null && echo "status ok"   # under 3 s
grep -c nvidia-smi scripts/stack-status.sh   # 0
curl -s localhost:11434/api/ps | jq '.models|length'; nvidia-smi --query-gpu=power.draw.average --format=csv,noheader,nounits   # unchanged: nothing loaded by status
make console &                              # prints: console on http://127.0.0.1:3004
# G50
ss -ltnp | grep ':3004 '                    # 127.0.0.1:3004 only
make test 2>&1 | sed -n '/--- console/,/POST without token/p'
# G51: run from the UI (Models -> make context-report), then:
tail -1 console/audit.log | jq .            # action context-report, exit 0, seconds
# capture the streamed lines the same way the browser did, and compare with the terminal
TOKEN=$(curl -s http://127.0.0.1:3004/overview | grep -o 'console-token" content="[^"]*' | cut -d'"' -f3)
JOB=$(curl -s -X POST -H "X-Console-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"action":"context-report"}' http://127.0.0.1:3004/api/run | jq -r .job)
curl -sN http://127.0.0.1:3004/api/jobs/$JOB/stream | sed -n 's/^data: //p' | jq -r . | grep -v '^{' > /tmp/ui.txt; make -s context-report > /tmp/term.txt; diff /tmp/ui.txt /tmp/term.txt && echo "byte for byte"
# G52: Setup -> change POWER_HOST_OVERHEAD -> Show diff -> Apply (UI), or the same through the API the button calls:
D=$(curl -s -X POST -H "X-Console-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"kind":"env","form":{"POWER_HOST_OVERHEAD":"41"}}' http://127.0.0.1:3004/api/diff); jq -r '.diff' <<<"$D" | head -5
curl -s -X POST -H "X-Console-Token: $TOKEN" -H 'Content-Type: application/json' -d "$(jq -c '{kind:"env",content:.content,sig:.sig}' <<<"$D")" http://127.0.0.1:3004/api/apply | jq -c .   # {"written":".env",...}
# then
grep '^POWER_HOST_OVERHEAD=' .env; tail -1 console/audit.log            # write .env
# Setup -> make up: stream ends with exit 0; docker compose ps shows healthy
# G53 (after plan 16): Teams -> Add member bertram/builder; then in Buzz mention @Bertram in a job thread; a reply within 3 min
# Teams -> persona -> edit -> Show diff -> Apply: audit shows write teams/<team>/personas/bertram.md then docker compose up -d --force-recreate bertram
# G54: Jobs -> Post job thread (or console/post-job.sh piedpiper "<ask>"); the builder posts **Plan:**; console/approve-job.sh <channel> <root>; a PR by the builder appears in Jobs within 10 min and, once the pipeline of plan 16.5 has run, its complexity/ and confidence/ labels
curl -s -X POST -H "X-Console-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"action":"down"}' http://127.0.0.1:3004/api/run -w '\n%{http_code}\n'    # 409 type down to confirm
```

## 8. Execution report

(to be written at execution: the smoke's console section, the audit lines for G51–G54, the diff shown for G52, the member and the job for G53–G54, any deviation with its reason)
