# Open LLM Stack — Architecture Spec

**Status:** binding. Every plan in `plans/` cites this file. If a plan and this file disagree, this file wins; fix the plan.
**Written:** 2026-09-12, from a planning session that verified every image tag, env var, and command below against the real registries and by booting throwaway copies of each service on this host. Executing agents have no internet: everything they need is in this file and the plans.

---

## 1. What this project is

A local-first, open-weights development stack. One `docker compose up` gives a developer:

| Layer | Service | Host port | Profile | Image (pinned, verified 2026-09-12) |
|---|---|---|---|---|
| API gateway | LiteLLM (+ its own Postgres) | **3000** | `litellm` | `ghcr.io/berriai/litellm:v1.89.7`, `postgres:17.11-alpine` |
| Chat | Open WebUI | **3001** | `openwebui` | `ghcr.io/open-webui/open-webui:v0.11.3` |
| Team collaboration | Buzz relay (+ Postgres, Redis, MinIO) | **3002** | `buzz` | `ghcr.io/block/buzz:sha-e17cdd9`, `postgres:17.11-alpine`, `redis:7.4.11-alpine`, `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`, `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z` |
| Version control | Gitea (SQLite) | **3003** | `gitea` | `docker.gitea.com/gitea:1.27.3` |
| Optional: Buzz agent | buzz-acp + buzz-agent (sprig) | none (host network) | `buzz-agent` | `ghcr.io/block/buzz-sprig:sha-e17cdd9` |
| Optional: CI runner | Gitea Actions runner "Laurie" (`gitea-runner`) | none (host network; docker.sock mounted) | `gitea-runner` | `docker.gitea.com/act_runner:3.4.2` (verified 2026-09-13); jobs run in `python:3.12-alpine` |
| Optional: agent team | `dinesh`, `gilfoyle`, `jared`, `erlich` (buzz-acp + buzz-agent, sprig; one volume each) | none (host network) | `team` | `ghcr.io/block/buzz-sprig:sha-e17cdd9` |
| Optional: goose runtime for Dinesh (plan 12) | same `dinesh` service, image `open-llm-stack/goose-agent:1.50.0` built locally by `make goose-image` | none (host network) | `team` + `TEAM_DINESH_RUNTIME=goose` | `debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171` + goose v1.50.0 (release tarball sha256 `8b5dfae07d16e352fbabe3122339a9270ea30e3b29246c81d6a227ed5f35e904`) + the sprig binaries (verified 2026-09-14) |
| Optional: Ollama | Ollama server | none | `ollama` | `ollama/ollama:0.34.0` |
| Optional: llama.cpp | llama.cpp server (CPU) | none | `llamacpp` | `ghcr.io/ggml-org/llama.cpp:server-b10920` (CUDA variant: `server-cuda-b10920`) |

The LLM backend is **bring your own** by default (`LLM_BASE_URL`), with the two optional backend profiles as an on-ramp.

Design principles, in priority order:

1. **Light.** One compose file, one bridge network, one `.env`, one `Makefile`. No service the README does not name. Exception (plan 12): one opt-in Dockerfile, `agents/goose/Dockerfile`, builds the goose runtime image; nothing else is built.
2. **Every layer optional and swappable.** Each layer is a Compose profile. Turning a layer off is removing its profile from `COMPOSE_PROFILES`; pointing at an external instance is setting that layer's URL variable. No cross-layer `depends_on` (see §4.3 for why).
3. **Preconfigured to work together out of the box.** `make init && make up` on a machine with Docker and an Ollama reaches a healthy stack with zero edits, on this host.
4. **Loopback only by default.** Every published port binds `BIND_HOST` (default `127.0.0.1`).
5. **Pin everything, verify before pinning.** Exact tags only, each verified with `docker manifest inspect` on 2026-09-12. Never `:latest`, never `:main`.
6. **A claim that something works means it was run.** Every plan ends with commands whose real output is shown.

---

## 2. Repository layout (target)

```
open-llm-stack/
├── README.md                    # operator docs (plan 07 writes the full version)
├── AGENTS.md / CLAUDE.md        # rules for coding agents (CLAUDE.md is `@AGENTS.md`)
├── docker-compose.yml           # all services, profile-gated
├── .env.example                 # every variable, documented; `make init` fills secrets
├── .gitignore
├── Makefile                     # init, up, down, ps, logs, test, reload, gitea-bootstrap, team-bootstrap, team-smoke, team-model
├── docs/spec.md                 # this file
├── plans/                       # implementation plans 01–08
├── proxy/
│   ├── config.yaml.example      # committed LiteLLM model registry sample
│   └── config.yaml              # gitignored, the live registry (`make init` copies it)
├── agents/                      # team personas: TEAM.md (norms) + dinesh/gilfoyle/jared/erlich.md + jared-heartbeat.md (plan 08)
│   └── ci-python.yaml           # the one Python CI workflow: bootstrap copies it into demo-calc, Dinesh into new repos
├── runner/config.yaml           # Gitea Actions runner config: label python, host network (plan 08)
├── scripts/
│   ├── init.sh                  # .env + secrets + proxy/config.yaml, idempotent
│   ├── check-ports.sh           # refuses `make up` when 3000–3003 are held by something else
│   ├── preflight.sh             # LLM_BASE_URL reachable from inside litellm?
│   ├── smoke-test.sh            # per-layer gates, skips layers whose profile is off
│   ├── bootstrap-gitea.sh       # admin user + API token, idempotent
│   ├── buzz-smoke.sh            # CLI round trip: mention the agent, expect a reply
│   ├── bootstrap-team.sh        # Gitea users + tokens for the agents, org TEAM_GITEA_ORG + team, runner token, fixture repo demo-calc, idempotent
│   ├── team-entrypoint.sh       # shared team-agent entrypoint: guards, git creds, prompt assembly, context caps from LiteLLM
│   └── team-smoke.sh            # job thread → Dinesh PR → green CI → Gilfoyle review
└── models/                      # gitignored; GGUF files for the llamacpp profile
```

---

## 3. Environment variables (`.env.example`)

`make init` copies `.env.example` to `.env` and fills every blank secret. It never overwrites a non-blank value, so re-running is safe. Format rule: a variable that `init.sh` fills is written as `VAR=` with its comment on the line **above** (a trailing `# comment` after `=` would become part of the value for Compose and defeats blank-detection).

```bash
# --- Which layers run. Remove a profile to disable that layer; set its *_URL to use an external one.
COMPOSE_PROFILES=litellm,openwebui,buzz,gitea
# Optional extras: ollama, llamacpp, buzz-agent, gitea-runner, team  (comma-append, e.g. ...,gitea,gitea-runner,team)

# --- Host interface for every published port. 0.0.0.0 exposes the stack to your LAN.
BIND_HOST=127.0.0.1

# --- LLM backend (bring your own). Must be reachable from INSIDE the litellm container.
#     host process on 0.0.0.0 -> http://host.docker.internal:<port> (default below, matches Ollama)
#     bundled profile         -> http://ollama:11434  or  http://llamacpp:8080
LLM_BASE_URL=http://host.docker.internal:11434
# Key for an OpenAI-compatible server that requires one (intranet vLLM, LM Studio with auth). Blank for Ollama and open servers;
# registry entries reference it as api_key: os.environ/LLM_API_KEY
LLM_API_KEY=

# --- LiteLLM (profile: litellm) --------------------------------------------------------------
LITELLM_PORT=3000
# make init: sk-<48 hex>
LITELLM_MASTER_KEY=
# make init: 32 hex
LITELLM_DB_PASSWORD=
# How OTHER CONTAINERS reach LiteLLM. Bundled: the service name. External: that gateway's URL.
LITELLM_URL=http://litellm:4000
# How HOST processes reach it (Buzz desktop app, the buzz-agent container, you). Keep the port in sync.
LITELLM_PUBLIC_URL=http://127.0.0.1:3000

# --- Open WebUI (profile: openwebui) --------------------------------------------------------
OPENWEBUI_PORT=3001
# make init: 32 hex
WEBUI_SECRET_KEY=
WEBUI_AUTH=false               # false = single-user, no login screen. true = normal signup/login.

# --- Buzz relay (profile: buzz) -------------------------------------------------------------
BUZZ_PORT=3002
# The relay creates ONE community keyed on exactly this host:port (§5.3). Every client — browser,
# desktop app, CLI, agent — must connect using this exact string or it gets HTTP 404.
BUZZ_PUBLIC_HOST=127.0.0.1:3002
# What clients and the buzz-agent profile connect to. Bundled: ws://${BUZZ_PUBLIC_HOST}. External: wss://...
BUZZ_RELAY_URL=ws://127.0.0.1:3002
# make init: `buzz-admin generate-key` secret (64 hex)
BUZZ_RELAY_PRIVATE_KEY=
# make init: 64 hex
BUZZ_GIT_HOOK_HMAC_SECRET=
# make init: 32 hex
BUZZ_DB_PASSWORD=
# make init: 32 hex
BUZZ_REDIS_PASSWORD=
# make init: 16 hex
BUZZ_S3_ACCESS_KEY=
# make init: 32 hex
BUZZ_S3_SECRET_KEY=
BUZZ_REQUIRE_RELAY_MEMBERSHIP=false   # open relay for local dev. true = closed; then set RELAY_OWNER_PUBKEY
BUZZ_REQUIRE_AUTH_TOKEN=false
# RELAY_OWNER_PUBKEY=          # 64 hex pubkey; required only when BUZZ_REQUIRE_RELAY_MEMBERSHIP=true
BUZZ_SERVE_GIT_WEB_GUI=true    # serves the relay's browser UI (repo browser + invite pages) at http://${BUZZ_PUBLIC_HOST}/

# --- Buzz agent (profile: buzz-agent) — an LLM agent living in the relay, answering @mentions via LiteLLM
# make init: `buzz-admin generate-key` secret
BUZZ_AGENT_PRIVATE_KEY=
# make init: matching public key (needed to add the agent to channels)
BUZZ_AGENT_PUBKEY=
BUZZ_AGENT_NAME=stack-agent
BUZZ_AGENT_MODEL=ornith-max    # a model_name from proxy/config.yaml. Verified 2026-09-12: ornith-max, laguna-max and
                               # qwen3.8-max publish their results; qwen3.6-max tends to end long turns in discarded text.
BUZZ_AGENT_MAX_CONTEXT_TOKENS=65536    # keep equal to that model's max_input_tokens in proxy/config.yaml (plan 14: 131072 window)
# Agent instructions appended to the harness base prompt. Verified 2026-09-12: without an explicit
# publish rule, local models answer in text the harness never posts (the reply shows only in the app's activity log).
BUZZ_AGENT_INSTRUCTIONS='Your text output is NOT delivered to anyone; humans only see messages you publish with the buzz CLI. For every request you MUST end by running: buzz messages send --channel <channel-uuid from the context block> --content "<your answer or a summary of what you did>". If you created or changed files, first run: buzz upload file --file <path> and include the returned URL in that message. Never end a turn without publishing.'

# --- Gitea (profile: gitea) -----------------------------------------------------------------
GITEA_PORT=3003
# Bundled: the loopback ROOT_URL (keep the port in sync). External: https://git.example.com -- and drop gitea AND gitea-runner
# from COMPOSE_PROFILES (the bundled runner must never register against a production instance).
GITEA_PUBLIC_URL=http://127.0.0.1:3003
# Bundled: created by make gitea-bootstrap. External: the account that owns GITEA_ADMIN_TOKEN (an admin there).
GITEA_ADMIN_USER=stackadmin
# make init: 24 hex (bundled only)
GITEA_ADMIN_PASSWORD=
# Bundled: written by make gitea-bootstrap. External: paste a token of GITEA_ADMIN_USER with scopes
#   write:admin,write:organization,write:repository,write:user  (agents never see it; delete/rotate it in Gitea at will)
GITEA_ADMIN_TOKEN=
# Root CA of a Gitea behind a private CA, mounted read-only into the team agents. Blank = system trust store.
# External example: /usr/local/share/ca-certificates/<forge-ca>.crt  (the same file your OS trust store got from the forge's docs)
GITEA_CA_FILE=

# --- Agent team (profile: team) — Dinesh (builder), Gilfoyle (reviewer), Jared (coordinator), Erlich (assistant)
# One model for the whole team; must be a model_name in proxy/config.yaml. Switch with `make team-model M=qwen3.8-max`.
# Measured 2026-09-13: ornith-max, qwen3.8-max and laguna-max publish multi-step results; qwen3.6-max does not.
# Gitea organization that owns every team repository; agents can create repositories in it (make team-bootstrap creates it)
TEAM_GITEA_ORG=piedpiper
# runs-on label for the CI workflows the team generates: python = the bundled gitea-runner profile; ci = the forge's runner
TEAM_CI_LABEL=python
# Your own (non-admin) Gitea login on the bundled instance: org owner, and the only user besides the admin who may merge
TEAM_HUMAN_USER=richard
# make init: 24 hex
TEAM_HUMAN_PASSWORD=
TEAM_MODEL=ornith-max
# Leave blank: each agent reads max_input_tokens/max_output_tokens for TEAM_MODEL from LiteLLM's registry at startup.
# Set only to force a smaller window than the registry declares.
TEAM_MAX_CONTEXT_TOKENS=
# Comma-separated 64-hex pubkeys of the humans the agents obey (Richard). Find yours in the Buzz app profile,
# or from a message you posted: `buzz messages get --channel <uuid>` shows `pubkey`. First entry is the agents' owner.
TEAM_ALLOWLIST=
TEAM_HEARTBEAT_SECONDS=0       # Jared's proactive triage tick (plan 08). 0 = off (default since plan 14: a tick is ~13 LLM calls at full prefill every interval and keeps the model in VRAM). 7200 when you want it.
TEAM_NARRATE=off               # plan 11 progress mirror: off | tools (state-changing shell commands) | both (+ model narration); milestones are persona posts and always on
TEAM_DINESH_RUNTIME=buzz-agent # plan 12: buzz-agent | goose; switch with make dinesh-runtime R=…, which also rewrites TEAM_DINESH_IMAGE
TEAM_DINESH_IMAGE=ghcr.io/block/buzz-sprig:sha-e17cdd9   # image behind the dinesh service (open-llm-stack/goose-agent:1.50.0 for goose)
# Keys: `make init` fills these (one identity per agent, plus a throwaway human for the smoke test)
TEAM_DINESH_PRIVATE_KEY=
TEAM_DINESH_PUBKEY=
TEAM_GILFOYLE_PRIVATE_KEY=
TEAM_GILFOYLE_PUBKEY=
TEAM_JARED_PRIVATE_KEY=
TEAM_JARED_PUBKEY=
TEAM_ERLICH_PRIVATE_KEY=
TEAM_ERLICH_PUBKEY=
TEAM_MONICA_PRIVATE_KEY=
TEAM_MONICA_PUBKEY=
TEAM_SMOKE_PRIVATE_KEY=
TEAM_SMOKE_PUBKEY=
# Gitea accounts for the agents (make team-bootstrap creates them and writes the tokens)
TEAM_GITEA_PASSWORD=
TEAM_DINESH_GITEA_TOKEN=
TEAM_GILFOYLE_GITEA_TOKEN=
TEAM_JARED_GITEA_TOKEN=        # plan 13: also the judge -- make score-sync / score-report use it (the admin token has no read:issue)
TEAM_MONICA_GITEA_TOKEN=
# --- Gitea Actions runner (profile: gitea-runner)
GITEA_RUNNER_TOKEN=            # make team-bootstrap: `gitea actions generate-runner-token`
GITEA_RUNNER_NAME=laurie

# --- Optional backends ----------------------------------------------------------------------
# LLAMACPP_MODEL_FILE=your-model.gguf   # file inside ./models/, llamacpp profile only
# LLAMACPP_CTX_SIZE=0                   # 0 = read from the model file
# Ollama tuning (bundled `ollama` profile). A host Ollama needs the same variables on its own container: README "GPU budget".
# OLLAMA_NUM_PARALLEL=3     # slots: Dinesh, Gilfoyle and Jared talk concurrently during a job; the rest queue
# OLLAMA_KEEP_ALIVE=5m      # unload 5 min after the last call; the registry's keep_alive does the same for calls through LiteLLM
# llama.cpp profile: LLAMACPP_CTX_SIZE = context_window x slots, and add -np <slots> --no-context-shift to its command (README)
```

Rules:
- Ports are variables so a clash is a one-line fix, but the documented defaults are 3000/3001/3002/3003 and every `*_PUBLIC_*` default embeds them. Change both together.
- A `*_URL` variable that points outside the stack is the **only** thing needed to swap a layer, plus removing that layer's profile so the bundled copy stops running.
- Secrets never appear in `docker-compose.yml`; they are `${VAR}` references.

---

## 4. Docker design

### 4.1 One network

```yaml
networks:
  default:
    name: open-llm-stack
```

Every service joins it. Containers address each other by service name (`litellm`, `gitea`, `buzz`, `buzz-db`...). Only `litellm` gets `extra_hosts: ["host.docker.internal:host-gateway"]`, for the bring-your-own backend case. No `internal: true` networks, no per-service networks.

### 4.2 Profiles

| Profile | Services |
|---|---|
| `litellm` | `litellm`, `litellm-db` |
| `openwebui` | `open-webui` |
| `buzz` | `buzz`, `buzz-db`, `buzz-redis`, `buzz-minio`, `buzz-minio-init` |
| `gitea` | `gitea` |
| `buzz-agent` | `buzz-agent` |
| `gitea-runner` | `gitea-runner` (bundled mode only: mounts the host docker socket; never registered against an external Gitea) |
| `team` | `dinesh`, `gilfoyle`, `jared`, `erlich` |
| `ollama` | `ollama` |
| `llamacpp` | `llamacpp` |

Compose reads `COMPOSE_PROFILES` from `.env` automatically; no `--profile` flags anywhere, including in the Makefile.

### 4.3 No `depends_on` across profiles — verified constraint

Tested 2026-09-12 with Compose v5.1.3: a service whose `depends_on` names a service in a profile that is not enabled makes the whole project invalid:

```
service "b" depends on undefined service "a": invalid compose project
```

Therefore `depends_on` is only used **inside** a layer (`litellm` → `litellm-db`; `buzz` → its db/redis/minio/minio-init). Open WebUI does not depend on `litellm`; it retries on its own. The agent does not depend on `buzz` or `litellm`.

### 4.4 Ports

Every `ports:` entry is `"${BIND_HOST}:${X_PORT}:<container port>"`. Container ports: LiteLLM 4000, Open WebUI 8080, Gitea 3000, Buzz `${BUZZ_PORT}` (the relay is told to bind the same number it is published on, see §5.3). Backends (`ollama`, `llamacpp`) publish nothing.

### 4.5 Healthchecks — which images ship what (verified)

| Image | Has `curl`? | Healthcheck to use |
|---|---|---|
| litellm v1.89.7 | no (python3 yes) | `python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')"` |
| open-webui v0.11.3 | yes | image ships its own `HEALTHCHECK` (curl + jq on `/health`); do not override |
| buzz sha-e17cdd9 | yes | `curl -fsS http://127.0.0.1:8080/_readiness` (health listener is a separate port, `BUZZ_HEALTH_PORT=8080`) |
| gitea 1.27.3 | yes | `curl -fsS http://127.0.0.1:3000/api/healthz` (returns `{"status":"pass",...}`) |
| postgres | n/a | `pg_isready -U <user> -d <db>` |
| redis | n/a | `redis-cli -a "$$REDIS_PASSWORD" ping \| grep -q PONG` |
| minio | yes | `curl -f http://127.0.0.1:9000/minio/health/live` |
| ollama 0.34.0 | no | none (no host port; preflight checks it via litellm) |

### 4.6 The buzz-agent runs on the host network

`buzz-agent` uses `network_mode: host`. Reason: the relay accepts a connection only when the HTTP `Host` header equals `BUZZ_PUBLIC_HOST` (§5.3). On the host network the agent connects to exactly the URLs a human uses (`BUZZ_RELAY_URL`, `LITELLM_PUBLIC_URL`), so it works identically against the bundled relay or an external one, and needs no `depends_on`. Verified live: an agent on the host network answered a mention in ~10 s. (An alternative that also verified live — `network_mode: "service:buzz"` — was rejected because it hard-couples the agent to the bundled relay.)

---

## 5. Per-layer facts (verified 2026-09-12)

### 5.1 LiteLLM `v1.89.7`

- Tag pattern on ghcr.io is now `vX.Y.Z` (and bare `X.Y.Z`); the older `main-vX.Y.Z` series stops at `main-v1.82.3`. The `-stable` series stops at `v1.83.14-stable`. `v1.89.7` is the newest release tag. PyPI `1.82.7`/`1.82.8` were the credential-stealing releases (BerriAI/litellm#24518); never pin those.
- Booted here with `postgres:17.11-alpine`, `--config /app/config.yaml --num_workers 1`, `DATABASE_URL`, `LITELLM_MASTER_KEY`, `LLM_BASE_URL=http://host.docker.internal:11434` + `extra_hosts`: healthy in ~40 s. `GET /v1/models` and `GET /v1/model/info` (custom `model_info` fields such as `execution_locus` pass through untouched). A chat completion to `ollama_chat/qwen3.6-max` returned `OK`.
- Benign startup warning: `prisma:warn Prisma doesn't know which engines to download for the Linux distro "wolfi"`.
- Health path: `/health/liveliness`. Master key: use `sk-` prefix (`sk-` + 48 hex).
- Registry rules carried over from the reference project: `ollama_chat/<tag>` for Ollama chat models (never `ollama/`), `ollama/<tag>` for embeddings, `openai/<name>` + `api_base` + dummy `api_key` for llama.cpp/vLLM; `drop_params: true`, `num_retries: 0`, `request_timeout: 900`; `max_input_tokens = physical_window − max_output_tokens − 8192`. Never register a closed-weight model or a router. Adding a model = edit `proxy/config.yaml` + `make reload`.

### 5.2 Open WebUI `v0.11.3`

- Env (from `backend/open_webui/env.py` and `config.py` at tag v0.11.3): `WEBUI_AUTH` (default `True`), `WEBUI_SECRET_KEY` (required when auth on), `ENABLE_OPENAI_API` (default `True`), `OPENAI_API_BASE_URL`, `OPENAI_API_KEY`, `ENABLE_OLLAMA_API` (default `True` — must be `"false"` or it probes a local Ollama directly), `ENABLE_SIGNUP` (forced false when `WEBUI_AUTH=false`), `ENABLE_PERSISTENT_CONFIG` (default `True`; set `"false"` so env values win on every restart instead of the first boot's values being frozen in the database — this is what makes a later change to `LITELLM_URL` take effect).
- Container listens on 8080. Ships its own HEALTHCHECK.
- Verified with `WEBUI_AUTH=false`: `GET /health` → `{"status":true}`; `GET /api/config` → `features.auth: false`; raw API calls without a token get `401 Not authenticated`; **the no-login token flow** is `POST /api/v1/auths/signin` with body `{"email":"","password":""}` → JSON with `token`; then `GET /api/models` with `Authorization: Bearer <token>` listed `qwen3.6-max` (plus the built-in `arena-model`); `POST /api/chat/completions` with the token returned `OK` through LiteLLM and Ollama.
- Data volume: `/app/backend/data`.

### 5.3 Buzz relay `ghcr.io/block/buzz:sha-e17cdd9`

Source: `github.com/block/buzz` (Apache-2.0). `sha-e17cdd9` = main commit 2026-09-11T18:07Z, the newest commit that has **both** a relay image and a `buzz-sprig` image published. Relay manifest digest `sha256:1101854b…c63a`; sprig `sha256:df3da2b7…1f5f`. NIP-11 reports `version 0.2.1`.

- One Rust binary `buzz-relay` (entrypoint) serving WebSocket + REST + optional web assets. Also in the image: `buzz-admin` (subcommands: `add-member`, `remove-member`, `list-members`, `generate-key`, `migrate`, `product-feedback`, `deletions`, `reconcile-channels`) and `buzz-pair-relay`. Image has `curl` and `bash`.
- Hard dependencies: Postgres, Redis (`--requirepass`), S3-compatible store (MinIO, `BUZZ_S3_ADDRESSING_STYLE=path`), a git data volume.
- **Multi-tenant host binding (the important gotcha).** On startup the relay derives a host from `RELAY_URL` (authority, **port included**, e.g. `127.0.0.1:3002`) and upserts a community row for it (log line: `Deployment community ensured host=... community=<uuid>`). Every WebSocket and REST request is bound to a community by its `Host` header; an unmapped host gets `404 relay: no community is configured for this host`. Consequences: (a) clients must use `BUZZ_PUBLIC_HOST` literally — `localhost:3002` and `127.0.0.1:3002` are two different communities; (b) a container on the compose network using `ws://buzz:3002` is rejected (verified); (c) the relay is told to bind `0.0.0.0:${BUZZ_PORT}` inside the container so its port number matches the published one. NIP-11 (`Accept: application/nostr+json`) is served for any host and stays fail-open.
- Health: `BUZZ_HEALTH_PORT=8080` serves `/_liveness` and `/_readiness` (200 when ready); `/_liveness` is also served on the main port. Metrics on `BUZZ_METRICS_PORT=9102`.
- Open-mode env, all verified booting: `BUZZ_BIND_ADDR`, `RELAY_URL`, `BUZZ_MEDIA_BASE_URL` (default `http://localhost:3000/media`), `BUZZ_CORS_ORIGINS` (comma list), `BUZZ_REQUIRE_AUTH_TOKEN=false` (default false; logs a WARN), `BUZZ_REQUIRE_RELAY_MEMBERSHIP=false` (default false), `BUZZ_AUTO_MIGRATE=true` (opt-in; without it run `buzz-admin migrate` first), `BUZZ_RELAY_PRIVATE_KEY` (64-hex secret; **required**, relay exits without it), `BUZZ_GIT_HOOK_HMAC_SECRET` (≥32 chars; random per boot if unset — pin it), `DATABASE_URL=postgres://…`, `REDIS_URL=redis://:<pw>@buzz-redis:6379`, `BUZZ_S3_ENDPOINT=http://buzz-minio:9000`, `BUZZ_S3_ACCESS_KEY/SECRET_KEY/BUCKET`, `BUZZ_GIT_REPO_PATH=/data/git`, `BUZZ_GIT_CONFORMANCE_PROBE=true`. `RELAY_OWNER_PUBKEY` is optional (only validated when set; required only with membership on). `RUST_LOG` optional.
- Browser UI: the image's `BUZZ_WEB_DIR=/srv/buzz/web` bundle is served **only** when `BUZZ_SERVE_GIT_WEB_GUI=true` (default false): `/` (with `Accept: text/html`), `/repos…`, `/assets/…`, and invite landing pages. It is the git/repo browser and invite flow, **not a chat client**. Chat clients are the Buzz desktop app (set `BUZZ_RELAY_URL` before launch or switch relay in-app) and `buzz` CLI. With the flag off, `/` returns the NIP-11 JSON to browsers.
- Key generation: `docker run --rm --entrypoint /usr/local/bin/buzz-admin <relay image> generate-key` prints `Public key:  <64 hex>` and `Secret key:  <64 hex>`.
- Verified boot on this host: db+redis+minio+minio-init healthy in ~16 s, relay `healthy` ~10 s later; `/_readiness` 200; NIP-11 `supported_nips [1,2,10,11,16,17,23,25,29,33,38,42,50,56]`.
- Reference: your existing `~/code/buzz/deploy/compose/compose.yml` (the upstream production bundle) is what §5.3 was derived from; this project inlines the same four services with project-specific names.

### 5.4 Buzz agent — `ghcr.io/block/buzz-sprig:sha-e17cdd9`

- Alpine + `bash`, `git`, `curl`; multicall `sprig` binary with links `buzz-acp`, `buzz-agent`, `buzz-dev-mcp`, `buzz`, `rg`, `tree`, `git-credential-nostr`, `git-sign-nostr`. Entrypoint `/usr/local/bin/sprig-entrypoint` (bash: scopes a git credential helper to `BUZZ_RELAY_URL`, then `exec buzz-acp "$@"`). **No Goose in the image** — the agent runtime is `buzz-agent`.
- `buzz-acp` (harness) env: `BUZZ_PRIVATE_KEY` (required; 64-hex secret from `generate-key` works), `BUZZ_RELAY_URL` (default `ws://localhost:3000`), `BUZZ_ACP_AGENT_COMMAND` (default `goose` → set `buzz-agent`), `BUZZ_ACP_AGENT_ARGS` (default `acp` → set empty; `buzz-agent` ignores non-`auth` args anyway), `BUZZ_ACP_MCP_COMMAND` (set `buzz-dev-mcp` so the agent has shell/file/buzz tools), `BUZZ_ACP_RESPOND_TO` (`owner-only` default → set `anyone` on an open relay, otherwise it never answers), `BUZZ_ACP_DISPLAY_NAME` (git author name for dev-mcp), `BUZZ_ACP_AGENT_OWNER`, `BUZZ_ACP_IDLE_TIMEOUT`, `BUZZ_ACP_SUBSCRIBE` (`mentions` default).
- `buzz-agent` (LLM loop) env for an OpenAI-compatible gateway: `BUZZ_AGENT_PROVIDER=openai`, `OPENAI_COMPAT_BASE_URL=<gateway>/v1`, `OPENAI_COMPAT_API_KEY=<key>` (required, non-empty), `OPENAI_COMPAT_MODEL=<model_name>`, `OPENAI_COMPAT_API=chat` (pin Chat Completions; `auto` picks Responses only for `*.openai.com`), `BUZZ_AGENT_MAX_CONTEXT_TOKENS` (default 200000), `BUZZ_AGENT_MAX_OUTPUT_TOKENS` (default 65536; set ≤ the model's `max_output_tokens`), `BUZZ_AGENT_LLM_TIMEOUT_SECS` (default 240).
- Display name: `buzz users set-profile --name <name>` (CLI, run once with the agent's key). `BUZZ_ACP_DISPLAY_NAME` alone does not publish a profile.
- Channels: the harness only sees channels the agent is a **member** of; a membership notification auto-subscribes it. Add it with `buzz channels add-member --channel <uuid> --pubkey <agent hex> --role bot`, or DM it.
- `buzz` CLI facts: JSON out; `BUZZ_RELAY_URL` accepts `ws://` (normalised to `http://`); verified subcommands and flags: `users set-profile --name/--about`, `channels create --name --type stream|forum --visibility open|private [--ttl <s>]` → `{"accepted":true,"channel_id":"<uuid>",...}`, `channels add-member --channel --pubkey --role`, `messages send --channel --content --mention <hex>` → `{"accepted":true,"event_id":...,"mention_pubkeys":[...]}`, `messages get --channel [--limit]` → JSON array of `{content, pubkey, kind, id, created_at, tags}`, `channels list`, `dms open --pubkey`.
- **Verified end to end (twice):** agent container (`network_mode: host`, and separately sharing the relay's netns) with the env above, `OPENAI_COMPAT_MODEL=qwen3.6-max` against Ollama; human key created channel, added agent as `bot`, sent `@stack-agent Reply with exactly the single word: PONG` with `--mention`; agent replied `PONG` after ~10 s (two LLM calls, one `buzz-dev-mcp__shell` tool call). A looser prompt (`What is 2+2?`) once produced no reply within 3 min — model nondeterminism, not infrastructure. The smoke test uses the strict PONG prompt and a 4-minute window.

### 5.5 Gitea `1.27.3`

- Newest tag on `docker.gitea.com/gitea` (1.27.x line). Image has `curl`, no built-in HEALTHCHECK.
- Env (Gitea's `GITEA__section__KEY` convention): `GITEA__security__INSTALL_LOCK=true`, `GITEA__database__DB_TYPE=sqlite3`, `GITEA__server__ROOT_URL=${GITEA_PUBLIC_URL}/`, `GITEA__server__HTTP_PORT=3000`. Data volume `/data`.
- Verified: healthy in ~10 s via `/api/healthz`; `docker compose exec -T -u git gitea gitea admin user create --username <u> --password <p> --email <u>@localhost --admin --must-change-password=false` → `New user '<u>' has been successfully created!`; re-run prints `Command error: CreateUser: user already exists [name: <u>]` (exit non-zero — the bootstrap script swallows exactly this message); `gitea admin user generate-access-token --username <u> --token-name <unique> --scopes write:repository,write:user --raw` → 40-char token (token names must be unique per call: use `$(date +%s%N)-$$`); `POST /api/v1/user/repos` with `Authorization: token <t>` created a private repo; `git -c http.extraHeader="Authorization: token <t>" clone http://127.0.0.1:<port>/<u>/<repo>.git` works; `GET /api/v1/version` → `{"version":"1.27.3"}`.

### 5.6 Optional backends

- `ollama/ollama:0.34.0` (newest on Docker Hub, 2026-09-09). Volume `/root/.ollama`. Reached as `http://ollama:11434`. Pull models with `docker compose exec ollama ollama pull <tag>`.
- `ghcr.io/ggml-org/llama.cpp:server-b10920` (newest `server-b*`; CUDA twin `server-cuda-b10920`, both multi-arch amd64/arm64). Command: `-m /models/<file> --host 0.0.0.0 --port 8080 -c <ctx>`; bind-mount `./models:/models:ro`.
- Preflight (from inside `litellm`): try `${LLM_BASE_URL}/v1/models` then `/api/tags`; on failure print the three reachability cases (container → attach by name; host process on 0.0.0.0 → `host.docker.internal`; host process on 127.0.0.1 only → cannot be reached via host-gateway, do NOT rebind to 0.0.0.0 without understanding LAN exposure).

### 5.7 This host (the validation machine)

- Docker Compose v5.1.3. An Ollama container named `ollama` (outside this project; `ollama/ollama:0.33.3`, env `OLLAMA_HOST=0.0.0.0:11434 OLLAMA_NUM_PARALLEL=3 OLLAMA_MAX_LOADED_MODELS=2 OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_KEEP_ALIVE=5m` since plan 14, volume `ollama`, `--gpus all`, `restart unless-stopped`) listens on `0.0.0.0:11434`, so `LLM_BASE_URL=http://host.docker.internal:11434` works. RTX 5090 32 GB, driver 580.126.18; power limit 600 W (min 400), `nvidia-persistenced` active. Models present (`ollama list`, 2026-09-12): `qwen3.6-max`, `ornith-max`, `laguna-max`, `qwen3.8-max`, `embed` (qwen3 0.6B embedding, num_ctx 512, 1024-dim), plus `ornith-1.5:35b`, `laguna-xs-2.1`, `qwen3.8:27b`, `qwen3.6:35b`, `qwen3-embedding:0.6b`. All chat models report an architectural context length of 262144.
- Ports 3000–3003 were held by the operator's `buzz-prod` and `open-llm-runner` compose projects; the operator stops those before execution. `scripts/check-ports.sh` guards this.
- Already pulled here: every image in §1 except `ghcr.io/ggml-org/llama.cpp:server-b10920` and `ollama/ollama:0.34.0`. `docker pull` works on this host.
- MinIO images must be pulled from **quay.io**; Docker Hub returned `denied` for anonymous manifest access to `minio/minio` and `minio/mc` on 2026-09-12.

### 5.8 Agent team + Gitea Actions (plan 08; verified 2026-09-13)

Profiles `gitea-runner` (service `gitea-runner`, "Laurie") and `team` (services `dinesh`, `gilfoyle`, `jared`, `erlich`). Variables: the `TEAM_*` and `GITEA_RUNNER_*` block in §3. Gates G11–G14 in §7.

**Runner.**
- `docker.gitea.com/act_runner:3.4.2` is the newest semver on Gitea's own registry (the `gitea/act_runner` repo on Docker Hub is stale; do not use it). Entrypoint `/sbin/tini -- run.sh`; binary `gitea-runner` v3.4.2. `run.sh` honours `CONFIG_FILE`, `GITEA_INSTANCE_URL`, `GITEA_RUNNER_REGISTRATION_TOKEN` (or `_FILE`), `GITEA_RUNNER_NAME`, `GITEA_RUNNER_LABELS`, `GITEA_RUNNER_EPHEMERAL`, `GITEA_RUNNER_ONCE`, `GITEA_MAX_REG_ATTEMPTS`. Registration state persists in `/data/.runner` (volume `gitea-runner-data`; the healthcheck is `test -s /data/.runner`). Config `runner/config.yaml`: one label `python:docker://python:3.12-alpine`, capacity 2, `container.network: host`, `/var/run/docker.sock` mounted (jobs are sibling containers: same trust boundary as the operator's docker).
- Job image `python:3.12-alpine` (Docker Hub) has no git; the workflow's first step is `apk add --no-cache git`.
- Gitea 1.27.3 has Actions **on by default** (`has_actions: true` on new repos; no `[actions]` config needed). Runner token: `docker compose exec -T -u git gitea gitea actions generate-runner-token` (40 chars). The admin API route for it needs `write:admin`, which `GITEA_ADMIN_TOKEN` lacks.
- Networking: runner and job containers share the host network, so `GITEA_INSTANCE_URL` and the job's clone URL are the loopback `ROOT_URL` (`http://127.0.0.1:3003`); the job clones `main` with `${{ github.token }}` (`http://x-access-token:${GITHUB_TOKEN}@127.0.0.1:3003/${GITHUB_REPOSITORY}.git`), then checks out the PR head or the pushed branch (gotcha 6).
- Commit status contexts: `ci / test (push)` on pushes, `ci / test (pull_request)` on PRs. Branch protection on `main` names the latter: `enable_status_check` + `status_check_contexts: ["ci / test (pull_request)"]`, `required_approvals: 1`, `block_on_rejected_reviews: true`, `enable_push: false` (direct push blocked).
- Gitea forbids self-approval (reviewer must differ from the PR author), so `dinesh`, `gilfoyle` and `jared` each get their own Gitea user (password `TEAM_GITEA_PASSWORD`) and token (scopes `write:repository,write:issue,read:user,write:organization`) and sit on the `agents` team of the organization `TEAM_GITEA_ORG` (next block), which owns the fixture repo `demo-calc`. `erlich` has no Gitea identity.
- Verified API shapes (swagger on the live instance): `POST /repos/{o}/{r}/pulls` `{title, head, base, body}`; `POST /repos/{o}/{r}/pulls/{n}/reviews` `{event: APPROVED|REQUEST_CHANGES|COMMENT, body, comments[]}` (enum as verified live, see gotcha 5); `POST /repos/{o}/{r}/pulls/{n}/reviews/{id}` `{event, body}` submits a pending draft; `GET /repos/{o}/{r}/pulls/{n}.diff` (unified diff); `POST /repos/{o}/{r}/branch_protections`; `GET /repos/{o}/{r}/commits/{ref}/status` (`state`: `pending|success|failure`); `PUT /repos/{o}/{r}/collaborators/{user}` `{permission}`; `GET /repos/{o}/{r}/actions/runs`.

**Organization (added 2026-09-13; every fact verified live).**
- Why: a non-admin cannot create a repository in another user's namespace (the first version put every repo under `GITEA_ADMIN_USER`, so Dinesh could not create one); creating in his own namespace needs the `write:user` token scope; push-to-create is off by default; `POST /api/v1/repos` does not exist (404). Repositories therefore live in one organization, `TEAM_GITEA_ORG` (default `piedpiper`, visibility `private`, owned by `GITEA_ADMIN_USER`). `GITEA_OWNER` in `docker-compose.yml` is the org, not the admin user; `agents/TEAM.md` says agents may create repos there and nowhere else.
- `POST /orgs/{org}/repos` needs the `write:organization` token scope. `GET /user/orgs` is a cheap scope probe: 200 with the scope, 403 `required scope` without. `scripts/bootstrap-team.sh` uses it to re-mint under-scoped tokens: `GITEA_ADMIN_TOKEN` → `write:repository,write:user,write:organization` (a fresh `scripts/bootstrap-gitea.sh` now mints the same), agent tokens → the four scopes above. Old tokens stay valid until deleted: `DELETE /users/{u}/tokens/{id}` with basic auth (the `gitea admin user` CLI in 1.27.3 has no delete-access-token subcommand that takes `--username`).
- One team `agents`: `permission: write`, `units` `repo.code`, `repo.issues`, `repo.pulls`, `repo.releases`, `repo.actions`, `can_create_org_repo: true`, `includes_all_repositories: true`; members `dinesh`, `gilfoyle`, `jared` (Gilfoyle is read-only by persona, not by permission). The API shows the team's `permission` as `none` while `units_map` carries the per-unit `write` values (1.27 reports per-unit access); effective permissions for a member on a repo: `push: true`, `admin: false`. A member with `write` may `POST /repos/{o}/{r}/branch_protections` on a repo he created (201); `admin` is not needed.
- `demo-calc` is created in the org, or an existing `${GITEA_ADMIN_USER}/demo-calc` from an older bootstrap is transferred with `POST /repos/{o}/{r}/transfer` `{"new_owner": "<org>"}`: the two open PRs and the branch protection survived the transfer; the old URL answers 301. The bootstrap is idempotent (run twice).
- `agents/ci-python.yaml` is the single source of the Python workflow: the bootstrap copies it into `demo-calc`; for a new project Dinesh creates the repo with `POST /orgs/$GITEA_OWNER/repos`, copies `/opt/team/agents/ci-python.yaml` (bind-mounted into his container) to `.gitea/workflows/ci.yaml` and adds `pyproject.toml` in the first commit, and once the PR is open protects `main` with the bootstrap's branch_protections JSON (`agents/dinesh.md` step 2). Measured: "create a repository named hello-py with a Python package, a pytest test, CI, and open a pull request" → `piedpiper/hello-py` created, first commit carried `.gitea/workflows/ci.yaml`, `pyproject.toml`, package and test, PR #1 open after ~50 s, `ci / test (pull_request)` `success`, branch protection on `main` set by Dinesh, Gilfoyle `APPROVED` ~40 s after the request.
- **Merge is enforced by Gitea, not by persona.** With team `write` plus his own approval satisfying the protection, Gilfoyle could have merged (he told a thread a PR was "approved and merged"; it was not, and he corrected himself, but Gitea would have allowed it). The branch protection therefore also sets `enable_merge_whitelist: true`, `merge_whitelist_usernames: ["<GITEA_ADMIN_USER>"]`: in `scripts/bootstrap-team.sh` for new repos, as a `PATCH` on an existing protection that lacks it when re-run, and in the JSON Dinesh applies to a repo he created. `docker-compose.yml` passes `GITEA_ADMIN: ${GITEA_ADMIN_USER:-stackadmin}` to the team env and the entrypoint inlines `$GITEA_ADMIN` into the prompt like `$GITEA_URL`; `agents/TEAM.md` states that only `$GITEA_ADMIN` can merge and that an agent must never claim to have merged. Applied live to `demo-calc` and `hello-py`.
- Links: `agents/TEAM.md` tells agents to post URLs exactly as the API's `html_url` returns them. Gitea here is plain `http`; Dinesh once typed `https://127.0.0.1:3003/…`, which a human cannot open (Gilfoyle was unaffected: his persona uses the literal API URL).
- **Your own login (added 2026-09-13).** `TEAM_HUMAN_USER` (default `richard`, password `TEAM_HUMAN_PASSWORD` from `make init`) is created by `make team-bootstrap` as a plain user, added to the org's `Owners` team, and listed with the admin in every merge whitelist (`merge_whitelist_usernames: [GITEA_ADMIN_USER, TEAM_HUMAN_USER]`, also in the protection Dinesh applies to repos he creates: `$GITEA_HUMAN` is inlined into his prompt). Verified: `GET /user` with basic auth → `is_admin: false`; the user lists the private org repos; squash-merged an approved, green PR via `POST …/pulls/{n}/merge`. Right after a branch-protection change Gitea answers that call `405 {"message":"Please try again later"}` while it re-checks the PR; retrying a few seconds later succeeds (seen twice). The bundled Gitea and any external one (for example an operator's production instance) are unrelated databases: accounts exist on one or the other, and the team layer supports only the bundled instance (its bootstrap uses the Gitea CLI through `docker compose exec`).
- Portability: `agents/ci-python.yaml` clones from `GITHUB_SERVER_URL` (= `ROOT_URL` = `GITEA_PUBLIC_URL`, verified on push and pull_request runs) instead of a literal loopback address, and the entrypoint writes the git credential line with the scheme of `GITEA_URL` rather than a hardcoded `http://`.

**Team agents.**
- Image is the sprig image of §5.4. Additional verified facts: `git 2.49.1`, `curl`, `bash`, `rg`, `tree`; **no `jq`, `python3` or `openssl`** (personas say so; scripts inside the container parse JSON with `sed`/`grep`/bash). Consequence: Dinesh cannot run a Python test suite locally; `agents/dinesh.md` has him push and read the PR's commit status (`GET …/commits/<sha>/status`) after CI runs. `git config --global credential.helper store` + `~/.git-credentials` works. User `agent` (uid 1000), `HOME=/home/agent` = the harness working dir (`REPOS/`, `WORK_LOGS/`, `OUTBOX/`); one named volume per agent (`team-<role>`).
- All four run `network_mode: host` for the reason in §4.6 and publish nothing. Shared entrypoint `scripts/team-entrypoint.sh`: runtime guards → wait for `/_liveness` → git identity + credential store + `~/.gitea.env` (roles with a token) → prompt file `/home/agent/.prompt.md` = `agents/TEAM.md` + `agents/<role>.md` with `$GITEA_URL`/`$GITEA_OWNER` substituted literally → context caps from LiteLLM → `buzz users set-profile --name` → `exec sprig-entrypoint`.
- buzz-acp flags used (all in `buzz-acp --help` of the pinned image): `BUZZ_ACP_SYSTEM_PROMPT_FILE`, `BUZZ_ACP_SESSION_POLICY=thread` (dinesh, gilfoyle) or `channel` (jared, erlich), `BUZZ_ACP_RESPOND_TO=allowlist` with `BUZZ_ACP_RESPOND_TO_ALLOWLIST=${TEAM_ALLOWLIST},${TEAM_SMOKE_PUBKEY},<the four TEAM_*_PUBKEY>` (teammates included: gotcha 4), `BUZZ_ACP_HEARTBEAT_INTERVAL` + `BUZZ_ACP_HEARTBEAT_PROMPT_FILE` (jared only), `BUZZ_ACP_AGENTS=1`, `BUZZ_ACP_DISPLAY_NAME`. buzz-agent: `BUZZ_AGENT_REQUIRE_REPLY=1` (present in the pinned binary; rerolls a turn that ends without a publish, at most twice; advisory, not a guarantee).
- `TEAM_ALLOWLIST` holds the operator's 64-hex pubkey (first entry = the agents' owner). Find it in the Buzz app profile, or from a message you posted: `buzz messages get --channel <uuid>` shows `pubkey`. On this host it is also the pubkey whose kind-0 profile carries the git user's name.
- **One-variable model switch.** At start the entrypoint reads `max_input_tokens`/`max_output_tokens` for `OPENAI_COMPAT_MODEL` (= `TEAM_MODEL`) from `GET /v1/model/info` and exports `BUZZ_AGENT_MAX_CONTEXT_TOKENS`/`BUZZ_AGENT_MAX_OUTPUT_TOKENS`, logging `model=<name> context=<in> output=<out>`. Verified: `ornith-max` → `237568/16384`, `qwen3.8-max` → `106496/16384`. A name not in the registry exits 1 (`model '<name>' is not in proxy/config.yaml`). `make team-model M=<name>` checks the name against `/v1/models` first, rewrites `TEAM_MODEL` in `.env`, and re-creates the four containers. `TEAM_MAX_CONTEXT_TOKENS` (blank by default) only forces a smaller input window.
- Model: `ornith-max` by default (§3 measurements). The host Ollama runs `OLLAMA_NUM_PARALLEL=3` since plan 14, but the qwen3.5 family gets one slot regardless (§5.15); agents + CI queue on it. Under the team smoke, `docker exec ollama ollama ps` stayed at `100% GPU` throughout (G13). A local model does not know its own name (Dinesh on `qwen3.8-max` called itself "Claude"): read `TEAM_MODEL` or the `model=` log line, never ask the agent.
- Measured 2026-09-13 (final clean run, `ornith-max`, Jared's heartbeat turn running concurrently on the same GPU slot): each agent `presence set to online` ~1 s after its relay wait; fixture CI on `main` `success` within ~1 min of the runner registering; mention → Dinesh PR opened in 70 s (10–20 s with the GPU idle); `ci / test (pull_request)` `success` ~25 s after push; Gilfoyle `APPROVED` ~30 s after the review request; whole `make team-smoke` 96 s. Erlich answered a "summarise this channel" mention in ~10 s. Jared with `TEAM_HEARTBEAT_SECONDS=60` logged `heartbeat_fired`, opened a heartbeat session, found the `triage` channel UUID, queried Gitea for open PRs/issues and, with nothing to report, posted nothing. After `make team-model M=qwen3.8-max` Dinesh answered a mention in ~20 s.

**Gotchas found during execution (both verified).**
1. Compose interpolates `${VAR:?}` for **every** service, even when its profile is off. A `:?` on a value filled later by `make team-bootstrap` (`GITEA_RUNNER_TOKEN`, `TEAM_*_GITEA_TOKEN`) or by the operator (`TEAM_ALLOWLIST`) would break every `docker compose` call before bootstrap can run. `docker-compose.yml` therefore uses `${VAR:-}` for those, and `scripts/team-entrypoint.sh` guards at runtime: a blank allowlist, or a missing Gitea token for any role but `erlich`, exits 1 with a message naming the fix. Keys from `make init` keep `:?run make init`.
2. In the sprig image, `grep -o … | head -1` under `set -o pipefail` dies with SIGPIPE (exit 141) when `head` closes the pipe first (timing dependent). The entrypoint parses the registry JSON with bash `[[ … =~ … ]]` instead of a pipeline.
3. buzz-acp starts `buzz-dev-mcp` (the shell tool) with a **scrubbed environment**: `HOME` and `PATH` only (read from `/proc/<pid>/environ` inside the `dinesh` container, 2026-09-13), and `buzz-acp --help` has no passthrough flag. The agents' shell therefore never sees `GITEA_URL`, `GITEA_OWNER` or `GITEA_TOKEN`. Fix: the entrypoint inlines the non-secret `GITEA_URL` and `GITEA_OWNER` into the assembled prompt (`sed` on `/home/agent/.prompt.md`) and, for roles with a token, writes `/home/agent/.gitea.env` (mode 600: `export GITEA_URL=… GITEA_OWNER=… GITEA_USER=… GITEA_TOKEN=…`). `agents/TEAM.md` states that the shell starts empty, and every API call in the personas is written `. ~/.gitea.env && curl …`. Erlich gets no env file. `git clone`/`push` were unaffected because the credential store is file-based. Rule for persona files: `$GITEA_URL`, `$GITEA_OWNER` and `$GITEA_ADMIN` may appear bare (substituted at container start); `$GITEA_TOKEN` only after sourcing `~/.gitea.env` in the same command.
4. With only humans on the allowlist, agent-to-agent mentions are silently dropped: Dinesh's `@Gilfoyle review please <url>`, Jared→Dinesh and Erlich→Dinesh never started a session (verified: Gilfoyle opened no session). `docker-compose.yml` therefore appends the four `TEAM_*_PUBKEY` values to `BUZZ_ACP_RESPOND_TO_ALLOWLIST`, so Dinesh requests the review himself once the PR is up; `scripts/team-smoke.sh` still sends its own review request after CI is green.
5. Gitea 1.27.3 review `event` enum is `APPROVED | REQUEST_CHANGES | COMMENT` (plus `PENDING`, `REQUEST_REVIEW`), **not** `APPROVE`. Any unknown value is accepted with 200 and stored as a `PENDING` draft only the reviewer can see (Gitea logs `Unsupported review webhook type`). A draft is submitted with `POST /repos/{o}/{r}/pulls/{n}/reviews/{id}` `{event, body}`; there is no `/submit` route (405). `agents/gilfoyle.md` writes the JSON to a file via a quoted heredoc and checks the returned `state`; `scripts/team-smoke.sh` accepts only a non-`PENDING` Gilfoyle review.
6. On `pull_request` events Gitea sets `GITHUB_REF_NAME` to the PR **index**, not a branch (`git clone --branch` failed with `Remote branch 1 not found`). The workflow `agents/ci-python.yaml` (copied into repos by `scripts/bootstrap-team.sh` and by Dinesh) clones `main`, then: if `${{ github.event.number }}` is set, `git fetch origin +refs/pull/<n>/head && git checkout FETCH_HEAD`; otherwise `git checkout "$GITHUB_REF_NAME"`.
7. Shell quoting: Dinesh and Gilfoyle both mangled command strings containing backticks or `--` (and self-corrected, costing turns). `agents/TEAM.md` tells them to write message bodies and JSON to files with a quoted heredoc and pass `--content "$(cat msg.txt)"` / `-d @file.json`.
8. `scripts/team-smoke.sh` records the highest PR number before posting the job and accepts only a Dinesh PR numbered above it; without that, a leftover open PR from an earlier run was matched.

**Out of scope (by design):** relay-hosted git / `buzz pr` (the desktop app cannot attach non-relay repos), NIP-OA owner attestation for server agents (no CLI mints it), mirrors. (Gitea org/teams were out of scope until 2026-09-13; see the Organization block above.)

---

### 5.10 External Gitea (plan 09; verified 2026-09-13)

The team works against **either** the bundled Gitea or one you already run, selected by `.env` alone. Verified read-only against an operator's own Gitea 1.27.3 behind Caddy with a private CA ("the forge"), and live on the bundled instance.

- **Mode switch.** Bundled: `GITEA_PUBLIC_URL=http://127.0.0.1:3003`, token from `make gitea-bootstrap`, `GITEA_CA_FILE` blank, `TEAM_CI_LABEL=python`, profiles `gitea,gitea-runner,team`. External: `https://…`, a pasted admin token (`write:admin,write:organization,write:repository,write:user`), `GITEA_CA_FILE` = the forge's root CA (blank for a public certificate), `TEAM_CI_LABEL` = that instance's runner label, profile `team` only. `make gitea-bootstrap` exits 0 with a hint when the `gitea` profile is off.
- **One API-only bootstrap.** `scripts/bootstrap-team.sh` never calls the Gitea CLI except for the bundled runner token: users via `POST /admin/users` (needs `write:admin`; `GET /admin/users?limit=1` is the scope probe, 403 without it), agent tokens minted by each agent **with its own password** through `POST /users/{u}/tokens` (basic auth; verified: no admin involved), org/team/fixture/protection as in §5.8. `make gitea-bootstrap` re-mints a bundled admin token that predates `write:admin` (probe → re-mint).
- **Private CA in the agents.** The sprig image runs as uid 1000 and cannot install a CA (`update-ca-certificates` needs root). `GITEA_CA_FILE` is bind-mounted read-only at `/opt/team/ca.crt` (`/dev/null` when blank, which renders as a 0-byte device file). When that file is non-empty the entrypoint exports `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`, `SSL_CERT_FILE` for the harness **and** writes `git config --global http.sslCAInfo` plus `~/.curlrc` (`cacert = …`), because the agent's shell tool runs with a scrubbed environment (§5.8) and only file-based settings under `HOME` reach it. Verified from a scrubbed shell inside `dinesh`: token call to `/api/v1/user` → own login, `git ls-remote` over HTTPS through the credential store. An empty value makes curl and git fail, hence no exports when the file is empty. Verified from the agent image: curl 200 and `git ls-remote` through TLS with those variables. Compose `${VAR:+x}` is deliberately not used for the same reason. Host-side scripts use the host's own trust store (install the forge's root CA there first).
- **CI on the forge.** Its runner label is whatever it registered (`ci` on the reference forge, one global runner, capacity 2, Debian job image with git/curl/jq/python3/pip/venv and no pytest, 2 CPU / 4 GB, no bind mounts). Jobs there reach Gitea through an internal hostname (`http://gitea:3000` via add-host), never the public HTTPS name, so `agents/ci-python.yaml` clones from `GITHUB_SERVER_URL` (= `ROOT_URL` in bundled mode, the internal URL in a forge job) and installs into a venv (Debian pip refuses system installs, PEP 668; verified on `python:3.12-alpine` too). `TEAM_CI_LABEL` is written into `runs-on` by the bootstrap (fixture repo) and by Dinesh (repos he creates; `$TEAM_CI_LABEL` is inlined into his prompt). `GET /admin/actions/runners` lists global runners with `status` and `labels`; the bootstrap warns when no online runner carries the label (org-level `GET /orgs/{org}/actions/runners` does not list global runners).
- **Workspaces outlive an instance switch.** Each agent volume keeps `REPOS/<repo>` clones. After switching instances, Dinesh based new work on the bundled clone of `demo-calc` and pushed it to the forge, so the PR branch carried the bundled workflow (`runs-on: python`) and its jobs queued forever on an instance that has only a `ci` runner (verified 2026-09-13). The entrypoint now removes every clone whose `origin` is not under `GITEA_URL` at start (`removing stale clone <name>` in the logs; bodies are disposable, finished work lives in PRs), and Dinesh's persona says to re-clone rather than push history from another host. Symptom to recognise: runs stuck in `queued` with `started_at` at the epoch while `GET /admin/actions/runners` shows the runner `online` and not `busy`.
- **Protection is re-applied by the bootstrap, not trusted to the model.** A new-project run on the forge produced a correct repo, label and green CI but no branch protection (Dinesh skipped the step he had performed in bundled mode). `make team-bootstrap` therefore protects every repo in the org (create or repair the merge whitelist), idempotently; re-run it after the agents create repositories.
- **Status contexts.** The combined commit status (`GET /repos/{o}/{r}/commits/{sha}/status` `.state`) becomes `failure` as soon as any context fails, including the push-event run, which is not what protection checks. The smoke and any automation must read the `ci / test (pull_request)` context itself. The Alpine job image installs git per job; a transient DNS error was observed during Docker network churn, so the template retries `apk add`.
- **Machine-user email.** The API validates email syntax: `dinesh@localhost` is rejected with `422 [Email]: Email` (the bundled CLI accepted it). The bootstrap uses `<user>@agents.invalid` (RFC 2606 reserved; no mail is ever sent).
- **Forge facts that matter to agents:** sign-in required for every API call (anonymous `/api/v1/version` → 403, so the smoke sends the token; `/api/healthz` stays anonymous), `[api] MAX_RESPONSE_ITEMS` default 50 (paginate), `DEFAULT_PRIVATE=private`, push-to-create off, registration off. On a `pull_request` event the runner executes the workflow file **from the PR branch**, before review: an agent can change CI in its own PR. The forge's job containment bounds that; record it in the forge's own decision log.
- **Never** register the bundled `gitea-runner` against an external instance (host docker socket, host network). `scripts/check-ports.sh` checks only the ports of enabled profiles, so a foreign 3003 listener does not block `make up` when the bundled Gitea is off.
- **Switching back:** keep `.env.bundled` / `.env.forge` copies (gitignored by `.env.*`); `make down`, copy over `.env`, `make up`, `make team-bootstrap`. Agent tokens are per instance and are blanked on a switch; the data volumes of the bundled Gitea are never touched.
- Execution results (G16/G17): see `plans/09-external-gitea.md` §7.

### 5.11 Repository factory and role teams (plan 10; verified 2026-09-13)

- **Why.** Gitea makes the creator of an org repository a collaborator with **admin** rights (verified: the creating agent could PATCH the protection on his own repo, 200, and not on others, 403). Governance that depends on the model performing persona steps was skipped once (§5.10). Both are closed by a factory command plus self-demotion, and by role teams.
- **Template repository.** `make team-bootstrap` creates `TEAM_GITEA_ORG/python-template` (private, `template: true`) from `agents/template/` plus `agents/ci-python.yaml` with `runs-on` = `TEAM_CI_LABEL`, protects its `main`, and re-syncs it when the files change (a protected `main` rejects direct pushes even from an admin: `remote: error: Not allowed to push to protected branch main`; the bootstrap drops the rule for the update and the reconcile loop restores it).
- **The factory** `agents/bin/new-repo <name>` (mounted read-only at `/opt/team/agents/bin/new-repo`, bash, no jq): validates the name, `POST /repos/{org}/python-template/generate` with `git_content`, `labels` and `protected_branch` (the rule is copied at birth, including `block_admin_merge_override`; no Actions run fires on generation, the first PR is the first check), checks the rule while still admin (reading a rule needs admin), then `DELETE /repos/{o}/{r}/collaborators/{self}` (204). Result verified inside `dinesh`: workflow present, rule complete, `collaborators: []`, `permissions {admin:false, push:true}`. Error paths: bad name → exit 2, existing name → exit 1, a non-builder → `generate failed: Given user is not allowed to create repository in organization` (exit 1).
- **Monica** (added 2026-09-13): a fifth agent, UI designer, on the `builders` team with Dinesh; service `monica`, volume `team-monica`, keys `TEAM_MONICA_*`, persona `agents/monica.md` (condensed from VoltAgent's `ui-designer`, plus the builder PR protocol). Bootstrapped and verified on the forge like the others.
- **Role teams** replace the single `agents` team (the bootstrap migrates: creates the three, moves members, deletes `agents`): `builders` (Dinesh) code/pulls/issues write, actions/releases read, `can_create_org_repo`; `reviewers` (Gilfoyle) code read, pulls and issues write; `coordinators` (Jared) issues and pulls write, code/actions read (pulls write since plan 13: Gitea checks labels on a PR against the pulls unit, `403 write permission is required` with read; his approvals stay unofficial because the approvals whitelist names only `gilfoyle` and `reviewers`, §5.14). The bootstrap PATCHes each team's `units_map` on every run, so unit changes reach an existing forge. Verified with each agent's token: Gilfoyle branch creation 403, review POST 200; Jared generate 422 (not allowed to create), branch 403, issue create/label/assign 201/200/201, protection PATCH 403; Dinesh generate 201. Nobody but humans is an org owner. `CreateTeamOption.units_map` sets per-unit access; `permission` must still be given (`read`).
- **Reconcile loop** (bootstrap, every org repo): create or repair the protection rule (required check, one approval, merge whitelist admin + human, `block_admin_merge_override`), and remove any agent left as collaborator. It is the backstop; after the factory it normally prints only `exists`.
- **Admin token scopes** stay `write:admin,write:organization,write:repository,write:user`: no `write:issue`, so issue probes must use an agent token.

### 5.12 Progress in the job thread (plan 11; verified 2026-09-13)

- **What a human sees by default (+2 messages per job, persona-driven).** Builders post `🚩 pushed <branch> (<n> files) — opening the PR, CI running` right after `git push` and `🚩 CI success|failure on <sha7>` after reading the commit status; deliverables start with a bold label (`**PR:**`, `**Review:**`, `**Question:**`) and are the only messages carrying `@mentions`; bodies go through `--content -` with a quoted heredoc (`agents/TEAM.md`). Conventions come from a UX and a UI review of the noise trade-off: narration off by default (it restates the next command; per-message unread badges), only state-changing commands are worth a post, one fixed glyph, no bold or mention on progress, drop the final narration chunk (it is the reply), everything in the thread. Deferred until measured: per-phase batching (`ran 4 commands (12s)`, ≤ 8 lines), an idle heartbeat once per long phase, `retry: … → …` lines after a failed command. Measure: messages per job thread (median, p95), "still going?" questions, whether humans reply after milestones or after command posts.
- **Mirror, opt-in (`TEAM_NARRATE=tools|both`, default `off`).** `scripts/team-narrate.sh` runs inside the agent container: the entrypoint creates a FIFO, starts the filter reading it in the background and execs the harness with stdout+stderr into it, so `buzz-acp` stays PID 1 (healthcheck `pgrep -f buzz-acp`) and `docker logs` is unchanged (the filter echoes every line). **Gotcha:** a dead reader blocks the harness on its next write, so the filter runs `set +e`, `trap '' PIPE`, never exits before EOF. Posts are thread replies signed by the agent's own key (the entrypoint has `BUZZ_PRIVATE_KEY`; the model's shell tool does not, §5.8 gotcha 3), `buzz messages send --channel <uuid> --reply-to <root> --content -`.
- **What the log offers.** `turn starting for channel <uuid> (thread:<root8>)` / `turn complete …` bracket a turn; `<root8>` = first 8 hex of the thread root event id (`crates/buzz-acp/src/scope.rs`), resolved to the full id with `buzz messages get --channel --limit 300` once per thread; channel-policy agents log `(conversation)` and are never mirrored. `INFO acp::stream: <text>` = an `agent_message_chunk`, **multi-line** (continuation lines carry no timestamp; chunks end with blank lines); the chunk is complete at the next timestamped line. `INFO acp::tool: tool_call: <title> (<kind>)` names the tool only; the command text is in the ACP frame, logged at debug on target `acp::wire` (`← {"…"sessionUpdate":"tool_call"…"rawInput":{"command":"…"}}`, JSON-escaped; the same command repeats in the following `session/request_permission` frame, which has no `sessionUpdate` key). The entrypoint raises `RUST_LOG` to `info,acp::wire=debug` only when the mirror is on; wire debug is ~10× the info volume (the whole prompt per turn, no secret), so the team anchor rotates logs (`json-file`, 20 MB × 3).
- **Filter rules.** `tools`: post a command only when it changes state (`git push|commit|merge|rebase|reset|checkout -b|switch -c`, `curl -X POST|PATCH|PUT|DELETE` or `-d @`, `new-repo`, `rm -rf`), never `buzz messages send`/`reactions add` (already the agent's post); fenced block, `$ ` prefix, wrapped on ` && `/` | ` with `\` continuation past 48 chars, hard cut at 300. `both`: also narration as `› <first 3 lines>`, but only a chunk that is followed by a tool call or another record inside the turn; the chunk still buffered at `turn complete` is discarded (in every captured turn it was the text then sent with `buzz messages send`, or prose the reply guard failed to get posted).
- **Execution findings (2026-09-13).** The sprig image's `sed` is BusyBox (no `-u`, no GNU multi-line commands): the filter strips ANSI and trims chunks in pure bash (`extglob`, `mapfile`). Gilfoyle's thread post lands ~5 s after his Gitea review and Dinesh may still be finishing after Gilfoyle answered, so `team-smoke.sh` waits (up to 3 min) for both `**PR:**` and `**Review:**` before judging, and reads both the job thread and the review-request thread (Gilfoyle replies to whichever asked). The channel members list carries no names, so builders hunted for Gilfoyle's pubkey and once posted a stray `probe @Gilfoyle`: `GILFOYLE_PUBKEY` is now inlined into the prompt like `GITEA_URL`. Model quirks seen and handled by persona wording, not by loosening gates: a `🚩 CI … pending` post (rule: poll until success/failure), `***Review:**` (rule: exact eleven characters via heredoc file), a PR body mangled by backticks inside `--content "…"` (rule: `--content - < pr.txt`). With `TEAM_NARRATE=tools` a smoke job added 3 command posts (branch, commit+push, PR curl) to the 4 persona posts. Milestones are model-dependent (present in 9 of 12 jobs on 2026-09-13; once without the flag; once narrated as posted while the send never reached the relay), so the team smoke reports them and gates only the deliverable labels (12/12). The builder personas carry the exact milestone command inline as a mandatory step. Persona edits take effect only after `docker compose up -d --force-recreate <agent>` (bind mount: a plain `up -d` keeps the container).
- **Observer pane, not used (for the record).** `BUZZ_ACP_RELAY_OBSERVER=true` + `BUZZ_ACP_AGENT_OWNER=<pubkey>` makes buzz-acp publish NIP-AO kind 24200 frames of the live turn to the owner; the relay authorizes them by `users.agent_owner_pubkey` (`is_agent_owner`), a column filled from a NIP-OA `auth` tag (a bootstrap could set it with the relay's own first-write-wins statement). Verified: with the row set, 66 frames received, 0 rejected, and the desktop subscribes to every frame addressed to the owner (`#p`), but it renders only agents it lists as its own, which come from **kind 30177 records signed by the owner's desktop key** (`list_relay_agents`: `kinds [30177], authors [viewer]`); the app creates those only for agents it spawned (backends `Local`, `Provider`). No CLI signs one and no Rust toolchain exists here, so server-side agents never appear. A Gitea-webhook feed (relay `POST /hooks/<workflow>` → workflow `send_message`) was also prototyped and dropped: it reports Gitea facts, not progress; relay templates reach top-level body keys only and reserve `trigger.text`, so only Gitea's `msteams` hook type (`summary`) would work, and Gitea blocks private webhook targets by default.

### 5.13 goose runtime (plan 12; verified 2026-09-14)

- **What.** `buzz-acp` speaks ACP to any runtime. `TEAM_DINESH_RUNTIME=goose` runs Dinesh on goose 1.50.0 from the locally built image (§1); `make dinesh-runtime R=goose|buzz-agent` rewrites `TEAM_DINESH_RUNTIME` + `TEAM_DINESH_IMAGE` and force-recreates the service. The entrypoint branches on `TEAM_RUNTIME`: goose gets `BUZZ_ACP_AGENT_COMMAND=goose`, `BUZZ_ACP_AGENT_ARGS=acp,--with-builtin,developer`, an empty `BUZZ_ACP_MCP_COMMAND` (goose's `developer` extension provides shell + file editing), `GOOSE_PROVIDER=openai`, `OPENAI_HOST=<LiteLLM without /v1>`, `OPENAI_API_KEY`, `GOOSE_MODEL=$TEAM_MODEL`, `GOOSE_MODE=auto`, `GOOSE_DISABLE_KEYRING=1`, `GOOSE_CONTEXT_LIMIT` = the registry's `max_input_tokens`, `GOOSE_MAX_TURNS=200`. Same persona file: the harness sets it with `_goose/unstable/session/system-prompt/set`.
- **Image.** goose is glibc-linked; the sprig binary is musl static-PIE and runs unchanged on Debian (`ldd` names the musl loader, but `buzz-acp --help` works in `debian:bookworm-slim`), so one Debian image holds goose and the harness/CLI with no Rust build. The Dockerfile pins the base digest and the goose release sha256; the build needs the release download and `apt-get` (the only step in this repository that needs the internet beyond `docker pull`). No `jq`/`python3` in this image either.
- **Verified behaviour.** Env-only provider config works (no `config.yaml`); goose writes config, sessions and `llm_request.N.jsonl` (with `usage.input_tokens`/`output_tokens` per call: the metrics source) under `$HOME` = the agent volume. Through the harness a mention got `PONG` in ~4 s; goose used its own `shell` tool (log title `tool_call: shell · <command>…`, command truncated), first call 8.2k input tokens (buzz-agent 7.5k). goose streams **token-sized** `acp::stream` records; the progress mirror joins consecutive narration records into one post (plan 11 filter, changed here). `agent initialized … name="goose" steering_supported=false` at init; the harness still knows `_goose/unstable/session/steer`.
- **Differences the operator must know.** goose's shell runs with the **container environment** (`GITEA_TOKEN`, `BUZZ_PRIVATE_KEY`, `OPENAI_API_KEY` visible to the model's commands); buzz-agent's `buzz-dev-mcp` shell is scrubbed. Same trust boundary as the container, but `~/.gitea.env` is no longer what hides the token. No reply guard on goose (`BUZZ_AGENT_REQUIRE_REPLY` is buzz-agent only).
- **Measured (plan 12 §7, 2026-09-14).** On the smoke job goose and buzz-agent cost the same (goose 231–328k input tokens per job vs buzz-agent 227k; turns 45–60 s both; 17–24 tool calls); goose made no shell-quoting mistakes in five jobs and had no silent turns without a reply guard; persona adherence equal. Default stays `buzz-agent`; goose is the verified alternative. One of six goose jobs ended its turn after writing the files (no commit, push or post): goose has no reply guard, so an abandoned turn is silent; keep that in mind before making it a default. Execution gotchas: `sed -i` on a bind-mounted script leaves the container on the old inode (recreate); the progress-mirror filter must not run global pattern substitution or `.*` regexes over wire frames (quadratic in bash; it pegged a CPU and delayed posts by a minute until rewritten with bounded prefix stripping and globs).
- **Runtime matrix.** `buzz-agent` (default; sprig; scrubbed shell; reply guard) · `goose` (this plan; own tools; open weights via LiteLLM) · `claude-agent-acp` (design only: Node 20 image + `npm install -g @agentclientprotocol/claude-agent-acp`, Anthropic API key or Claude Code subscription credentials persisted under `/home/agent`; closed weights, so never a default: a separate opt-in "grid" plan if wanted).

### 5.14 PR scoring (plan 13; verified 2026-09-14, judge moved from a sixth agent to Jared the same day)

- **What.** Every PR gets `complexity/1..5` and `confidence/low|medium|high` as exclusive-scope org labels, one `**Score:**` comment carrying the rubric as fenced JSON (`schema`, `pr`, `sha`, `complexity`, `confidence`, `rubric`, `judge`, `scored_at`), and one `**Score:**` line in the job thread. The judge is **Jared** (the coordinator: no new service, keys or user; Gitea user on the `coordinators` team: code read, pulls and issues write — labels on a PR need pulls write, comments need issues write (verified: `403 write permission is required` with pulls read); judge duty and rubric in `agents/jared.md`; channel session policy, so the score request carries the thread root id in its context block), asked by Gilfoyle after his verdict (`@Jared score <url>`, `$JARED_PUBKEY` inlined into prompts) and by the team smoke as a fallback. Delivery is members-only and the CLI refuses a body that names a non-member (`does not match a current channel member`), so the judge must be in the job channel: the smoke adds him, the README tells the operator to, and Gilfoyle adds him when the send fails (found 2026-09-14: two smoke runs ended without a score because Gilfoyle had added the judge in the first run only). Jared never builds or reviews, so the judge stays independent of the builder and the reviewer; the one known bias is that he scores `scope_match` on briefs he may have written (persona rule: the brief never colours the score). He scores only when CI is `success|failure` and a submitted review exists (`agents/bin/score-signals` exits 3 otherwise; the persona retries 6 × 30 s, then posts `**Score:** not scored — <reason>`).
- **Rubric.** Complexity = scope, novelty, risk, verification, ambiguity (each 0–2, sum 0–10 → 1–5: 0-1/2-3/4-5/6-7/8-10). Confidence = tests, ci, review, scope_match, hygiene (each 0–2; `ci=0` caps at low; sum ≥ 8 high, ≥ 5 medium, else low). Anchors in the persona. Effort (tokens, time, tool calls) is excluded by rule: it measures work, not correctness. `agents/bin/score-post` validates the flat JSON with bash (exit 2 on a missing or out-of-range dimension), computes, removes stale scope labels, labels, comments, posts the thread line.
- **Truth loop.** `make score-sync` (host, judge token) reads closed PRs with a confidence label and adds `outcome/merged-as-is` (merged and `head.sha` equals the scored sha), `outcome/merged-after-changes` (merged, sha differs), `outcome/closed`. `make score-report` prints complexity counts, the confidence × outcome table and the merged-as-is rate per bucket: the reliability table is the acceptance test of the confidence score. Routing on the scores is deliberately not built; when it is, the policy consumes `complexity/*` before a run and `confidence/*` after, in one script, never in personas.
- **Verified API facts.** `POST /orgs/{org}/labels` `{name,color,description,exclusive:true}` → 201; a `reviewers`-team token labels a PR by id or name (`POST …/issues/{n}/labels` → 200) and comments (201); `GET …/issues/{n}/labels|comments` needs `read:issue`, which `GITEA_ADMIN_TOKEN` lacks (`write:admin,write:organization,write:repository,write:user`), so the host scripts use `TEAM_JARED_GITEA_TOKEN`; `GET pulls/{n}/files` gives per-file `additions/deletions/status`, `…/commits` the commit list, `…/reviews` `state` + `commit_id` per review (a `head.sha` different from the last review's `commit_id` = pushed after review); `GET pulls?state=closed` carries `merged`, `merged_at`, `merge_commit_sha`.
- **Approvals must be official (found 2026-09-14).** Gitea counts an approval towards `required_approvals` only from a user with write access or on the rule's approvals whitelist, and the `reviewers` team has `repo.code: read` (§5.11), so since plan 10 Gilfoyle's approvals did not count and every merge needed a human approval too (`405 Does not have enough approvals`). The protection rule now carries `enable_approvals_whitelist: true`, `approvals_whitelist_username: ["gilfoyle"]`, `approvals_whitelist_teams: ["reviewers"]` (note the singular `_username` field for users); the bootstrap reconciles it on every org repo and the template. Official-ness is stamped when the review is submitted: existing approvals stay non-official, a fresh one is needed.
- **Principles.** Two independent axes; small ordinal scales with written anchors; raw dimensions stored next to the score; the judge is neither the builder nor the reviewer, with a fixed rubric and strict, script-validated output; CI red is a hard cap; agents never see the formula; never gate a merge on a score.

### 5.15 Context contract and GPU budget (plan 14; verified 2026-09-14)

- **The contract.** Every chat model in `proxy/config.yaml` declares `model_info.context_window` (the physical window per slot the backend is configured for), `max_output_tokens` (32768 for reasoning models: thinking counts as output) and `max_input_tokens = context_window − max_output_tokens − max(context_window/4, 8192)`. The 25% margin covers buzz-agent's token estimate (measured ≥ 23% under the backend's count) plus template and tool scaffolding. Ollama entries mirror the window as `litellm_params.num_ctx` and carry `keep_alive: "5m"`; both are forwarded per request (`OllamaChatConfig` in LiteLLM 1.89.7; verified: after `make reload` and one completion `/api/ps` shows `context_length 131072`, `expires_at` = now + 5 min, and the runner cmdline `-c 131072 -np 1`). `/v1/model/info` exposes custom `litellm_params` keys (`num_ctx`) and custom `model_info` keys (`context_window`), so the smoke checks the arithmetic and `num_ctx == context_window` from the gateway. For `openai/` entries (llama.cpp, vLLM, LM Studio) the window is a server flag (`-c window × slots -np slots --no-context-shift`; `--max-model-len --max-num-seqs`), declared here and probed.
- **Why (found 2026-09-14, before this plan).** 34 generations on `qwen3.8-max` ended `n_tokens = 131071, truncated = 1` while the agent's estimate stayed under its 106496 cap; 7 completions hit `max_output_tokens` 16384; 262144-token windows for a p95 prompt of 93 k (72% of 3794 calls under 32 k); `OLLAMA_KEEP_ALIVE=30m` refreshed by the heartbeat kept the model resident (80 W idle vs 45 W empty); nothing verified the declared window.
- **Verification is black-box through the gateway.** `scripts/context-probe.sh` (`make context-probe [M=…] [FULL=1]`) calibrates the tokenizer on a fixed line (two sizes give slope and offset exactly: 11 tokens per line, 18 fixed on the qwen3.5 family) and sends prompts at 50% and 100% of `max_input_tokens` and at `max_input + max_output − 128`; each must return HTTP 200 with `usage.prompt_tokens` within 16 of what was sent. Ollama past `num_ctx` truncates silently and reports fewer tokens (negative case, verified: `context_window = max_input_tokens = 131072` on `qwen3.8-max` → `50%` ok at 65534, `100%` FAIL `got 65538 length`: Ollama 0.33.3 cut the prompt to half the window at its own layer, no `truncated = 1` in the llama-server log); llama.cpp and vLLM reject with an error. Prompts go to `jq` by `--rawfile`, not `--arg`: a 100 k-token body is ~600 kB, past the kernel's per-argument limit.
- **Sizing (Ollama).** `scripts/model-fit.sh` (`make model-fit M=<tag> [OUT=32768] [MAX_WINDOW=131072]`) unloads everything, measures what the display server holds, loads the model at candidate windows through the backend and keeps the largest that stays fully on the GPU within `total − other − HEADROOM_MB` (2048), then prints the registry block. Windows are sized to real use (p95 + output budget), so the search is capped by `MAX_WINDOW`: at one slot the 262144 maximum "fits" too (ornith-max 23754 MiB) and only costs VRAM and prefill. Measured 2026-09-14 at 131072: ornith-max 22010, qwen3.6-max 21288, laguna-max 21114, qwen3.8-max 17043 MiB; laguna-max spills to the CPU at 196608 and 262144 (its MTP draft model).
- **Slots.** Ollama runs `-c num_ctx × OLLAMA_NUM_PARALLEL -np OLLAMA_NUM_PARALLEL` and, with the variable set, does not shrink an oversized window: it spills (`size_vram < size`). **Ollama 0.33.3 gives the qwen3.5 family one slot regardless**: `sched.go: model architecture does not currently support parallel requests architecture=qwen35moe` (and `qwen35`), so every model in the shipped registry runs `-np 1` whatever the variable says. `OLLAMA_NUM_PARALLEL=3` stays the documented value (harmless here, right for architectures that support it); the per-agent prompt-cache design of this plan (G31) is therefore not reachable on this backend for these models, and hybrid re-prefill stays architectural: any prompt that is not append-only to the slot's last checkpoint costs a full prefill.
- **Residency and idle.** `keep_alive: "5m"` per request plus `OLLAMA_KEEP_ALIVE=5m` on the container (backstop for direct callers). `TEAM_HEARTBEAT_SECONDS` defaults to 0: a tick is up to 12 shell commands, each a full-prefill call, and each refreshes `keep_alive`. Direct callers get the tag's own window (262144 on the `*-max` tags) and force a runner reload each way.
- **Real use.** `scripts/context-report.sh` (`make context-report [SINCE="7 days"]`) reads LiteLLM's spend log per model: calls, p50/p95/max prompt, max completion, `over_in` (prompts above `max_input_tokens`: compaction came late) and `at_out` (completions at `max_output_tokens`: truncated). The registry's windows are re-sized from it. The probe's third case (`max_input + max_output − 128`) is above `max_input_tokens` by design, so a window that includes a probe run shows `over_in ≥ 1` per model: read the report over the interval of the work you are judging (`SINCE="<n> seconds"`).
- **Smoke.** `test_litellm` fails on any chat model without `context_window`, on `max_input + max_output > context_window`, and on an Ollama entry whose `num_ctx ≠ context_window`; the chat round-trip covers `TEAM_MODEL` only by default (`SMOKE_CHAT_MODELS=all` for every model, one 25 GB model swap each).
- **Power.** 45 W empty (three displays pin the memory clock), ≈ 80 W with a model resident, 470–570 W in prefill; limit 600 W, minimum 400 W. A cap (`nvidia-smi -pl 450`, persisted by a systemd oneshot) is an opt-in host setting; `sudo` on the reference host needs a password, so the measurement (G34) is an operator step.
- **Backend-agnostic by construction.** Above the gateway nothing changes between backends: the registry fields, the probe, the report, the agents' caps. Switching the team backend is the server's window flags + `openai/<name>` entries with `context_window` + `make context-probe` + `make team-smoke`. Ollama stays the default because idle unload matters here; write the next plan when `context-report` shows `over_in > 0` under the new caps, or when per-model slots are needed (llama.cpp per model with `-np`, or vLLM).

## 6. Model registry sample (`proxy/config.yaml.example`)

Registers the operator's tuned `*-max` tags and `embed` (validated in the reference project on the same host), with the other locally present tags as commented entries. Numbers follow the context contract (§5.15): the window is declared per slot, mirrored to the backend (`num_ctx`), and proved through the gateway (`make context-probe`); sized by `make model-fit` on 2026-09-14.

| model_name | litellm model | mode | context_window | max_input_tokens | max_output_tokens | note |
|---|---|---|---|---|---|---|
| qwen3.6-max | ollama_chat/qwen3.6-max | chat | 131072 | 65536 | 32768 | `num_ctx: 131072`, `keep_alive: "5m"`; supports_vision; 21288 MiB |
| ornith-max | ollama_chat/ornith-max | chat | 131072 | 65536 | 32768 | same knobs; 22010 MiB |
| laguna-max | ollama_chat/laguna-max | chat | 131072 | 65536 | 32768 | same knobs; 21114 MiB (spills to CPU at 196608+: MTP draft model) |
| qwen3.8-max | ollama_chat/qwen3.8-max | chat | 131072 | 65536 | 32768 | same knobs; dense 27B, 17043 MiB |
| embed | ollama/embed | embedding | — | — | — | |

Every entry carries `execution_locus: local` and a `model_revision` string, so downstream tools keep the reference project's contract.

---

## 7. Validation gates (each plan names the ones it proves)

| Gate | Proves | How |
|---|---|---|
| G0 | Compose file valid for every profile combination | `docker compose config --quiet` with `COMPOSE_PROFILES` set to each profile alone and to all |
| G1 | Ports free / stack not colliding | `scripts/check-ports.sh` |
| G2 | Backend reachable from inside litellm | `scripts/preflight.sh` |
| G3 | LiteLLM registry + chat + embeddings + no closed-weight model | `scripts/smoke-test.sh` (litellm section) |
| G4 | Open WebUI healthy, no-login token flow lists LiteLLM models, chat round-trip | smoke-test (openwebui section) |
| G5 | Buzz relay ready, NIP-11 served, community host = `BUZZ_PUBLIC_HOST`, browser UI 200 | smoke-test (buzz section) |
| G6 | Gitea healthy, admin+token bootstrap idempotent, API repo create, clone | smoke-test (gitea section) + `bootstrap-gitea.sh` twice |
| G7 | Agent answers a mention through LiteLLM | `scripts/buzz-smoke.sh` |
| G8 | Nothing published beyond `BIND_HOST` | `docker compose ps --format '{{.Name}} {{.Ports}}'` shows only `127.0.0.1:` |
| G9 | External swap works | Open WebUI pointed at `LITELLM_URL=http://host.docker.internal:3000` with profile `litellm` still on (simulates an external gateway) still lists models |
| G10 | Optional backends | `COMPOSE_PROFILES=…,ollama` + `LLM_BASE_URL=http://ollama:11434` passes G2; same for llamacpp with a GGUF |
| G11 | Runner registered, fixture CI green on `main` | smoke-test (gitea-runner section): `registered` from `test -s /data/.runner`, then `GET …/demo-calc/actions/runs` → `run completed/success main` |
| G12 | Team job loop | `scripts/team-smoke.sh` (also `make test` with profile `team`): job thread → new PR by `dinesh` in `${TEAM_GITEA_ORG}/demo-calc` → `ci / test (pull_request)` = `success` → non-`PENDING` review by `gilfoyle` → `TEAM SMOKE PASS` (measured 96 s) |
| G13 | GPU stays on GPU under team load | during/after G12, `docker exec ollama ollama ps` shows the team model at `100% GPU` |
| G14 | One-variable model switch | `make team-model M=qwen3.8-max` → each agent logs `model=qwen3.8-max context=106496 output=16384` and answers a mention; `make team-model M=nope-model` prints `not registered` and `make` exits 2 (the recipe exits 1) |
| G15 | Bundled regression after the API-only rewrite | `make gitea-bootstrap` (re-mint), `make team-bootstrap` twice, full `make test` in bundled mode, new-project job with `runs-on` rewrite |
| G16 | External bootstrap idempotent, agents authenticate over TLS | `make team-bootstrap` twice against the forge; `docker compose exec dinesh` curl `$GITEA_URL/api/v1/user` → own login; `.git-credentials` carries `https://` |
| G17 | Team loop on the forge | `make team-smoke` → PR on `<org>/demo-calc` at the forge, `ci / test (pull_request)` success on its runner, Gilfoyle `APPROVED`, merge refused for agents |
| G18 | Factory inside `dinesh`, no LLM (both modes) | smoke `test_team_factory`: workflow present, rule complete, no collaborators, then deleted |
| G19 | LLM new-project request goes through the factory | ask Dinesh for a new project; before any bootstrap: `collaborators: []`, rule present with `block_admin_merge_override`, PR opened, CI green |
| G20 | Roles enforced by Gitea, not personas | per-token probes: reviewer branch 403 / review 200; coordinator generate 422 / branch 403 / label 200; builder generate 201 |
| G21 | Progress mirror filter, no LLM | smoke `test_team_narrate`: canned log through `team-narrate.sh` in `dinesh` → exactly 2 thread replies (narration, wrapped `git push`); fetch, buzz send, final chunk and conversation turn skipped |
| G22 | Thread conventions on a real job | team smoke: `**PR:**` from dinesh and `**Review:**` from gilfoyle gated; `🚩 pushed` / `🚩 CI …` milestones reported; with `TEAM_NARRATE=tools` also a `$ git push` reply gated |
| G23 | Dinesh runs the requested runtime | smoke `test_team_runtime`: PID 1 `buzz-acp`, `agent initialized … name="goose"`, `goose acp` process (or `buzz-agent`) |
| G24 | Team smoke on goose, measured | two consecutive `make team-smoke` passes with `TEAM_DINESH_RUNTIME=goose`; metrics table vs buzz-agent (time to PR, LLM calls, input tokens, tool calls, persona misses) in plan 12 §7 |
| G25 | Switch back | `make dinesh-runtime R=buzz-agent`, one smoke pass |
| G26 | Scoring path without an LLM | smoke `test_team_score`: bad rubric rejected (exit 2); canned rubric → `complexity/1` + `confidence/high` labels and a `**Score:**` comment on the newest demo-calc PR |
| G27 | Judge in the loop | team smoke: after the review, `**Score:**` line from jared in the job thread and both score labels on the PR within 3 min; two consecutive passes |
| G28 | Outcomes | `make score-sync` labels a closed smoke PR `outcome/closed` and a merged one `outcome/merged-as-is`; `make score-report` prints the reliability table |
| G29 | Context contract | smoke: every chat model has `context_window ≥ max_input_tokens + max_output_tokens` and Ollama entries `num_ctx == context_window`; on the reference host the runner runs the declared window fully on the GPU (`memory.used` ≤ 29 500 MiB through a team smoke) |
| G30 | No truncation | `make context-probe` passes for every registered chat model; two consecutive team smokes with zero `truncated = 1` in the backend log; `make context-report` `over_in 0`, `at_out 0` |
| G31 | Cache reuse | prefilled tokens per team smoke at least halved vs the baseline; `f_sim_best ≥ 0.9` on agent turns (not reachable on Ollama 0.33.3 for the qwen3.5 family: one slot, §5.15) |
| G32 | Idle | six minutes after a smoke: no model resident, power ≤ 50 W; no chat completion in LiteLLM's log for 30 min (heartbeat off) |
| G33 | Sizing and a probe that can fail | `make model-fit M=ornith-max` reproduces the registry's window; `qwen3.8-max` sized and recorded; the probe on `max_input_tokens = context_window` fails |
| G34 | Power cap (opt-in, measured once) | decode tok/s at 450 W within 10% of 600 W |
