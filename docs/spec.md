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
| Optional: Ollama | Ollama server | none | `ollama` | `ollama/ollama:0.34.0` |
| Optional: llama.cpp | llama.cpp server (CPU) | none | `llamacpp` | `ghcr.io/ggml-org/llama.cpp:server-b10920` (CUDA variant: `server-cuda-b10920`) |

The LLM backend is **bring your own** by default (`LLM_BASE_URL`), with the two optional backend profiles as an on-ramp.

Design principles, in priority order:

1. **Light.** One compose file, one bridge network, one `.env`, one `Makefile`. No service the README does not name.
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
├── Makefile                     # init, up, down, ps, logs, test, reload, gitea-bootstrap
├── docs/spec.md                 # this file
├── plans/                       # implementation plans 01–07
├── proxy/
│   ├── config.yaml.example      # committed LiteLLM model registry sample
│   └── config.yaml              # gitignored, the live registry (`make init` copies it)
├── scripts/
│   ├── init.sh                  # .env + secrets + proxy/config.yaml, idempotent
│   ├── check-ports.sh           # refuses `make up` when 3000–3003 are held by something else
│   ├── preflight.sh             # LLM_BASE_URL reachable from inside litellm?
│   ├── smoke-test.sh            # per-layer gates, skips layers whose profile is off
│   ├── bootstrap-gitea.sh       # admin user + API token, idempotent
│   └── buzz-smoke.sh            # CLI round trip: mention the agent, expect a reply
└── models/                      # gitignored; GGUF files for the llamacpp profile
```

---

## 3. Environment variables (`.env.example`)

`make init` copies `.env.example` to `.env` and fills every blank secret. It never overwrites a non-blank value, so re-running is safe. Format rule: a variable that `init.sh` fills is written as `VAR=` with its comment on the line **above** (a trailing `# comment` after `=` would become part of the value for Compose and defeats blank-detection).

```bash
# --- Which layers run. Remove a profile to disable that layer; set its *_URL to use an external one.
COMPOSE_PROFILES=litellm,openwebui,buzz,gitea
# Optional extras: ollama, llamacpp, buzz-agent  (comma-append, e.g. ...,gitea,buzz-agent)

# --- Host interface for every published port. 0.0.0.0 exposes the stack to your LAN.
BIND_HOST=127.0.0.1

# --- LLM backend (bring your own). Must be reachable from INSIDE the litellm container.
#     host process on 0.0.0.0 -> http://host.docker.internal:<port> (default below, matches Ollama)
#     bundled profile         -> http://ollama:11434  or  http://llamacpp:8080
LLM_BASE_URL=http://host.docker.internal:11434

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
BUZZ_AGENT_MAX_CONTEXT_TOKENS=237568   # keep equal to that model's max_input_tokens in proxy/config.yaml
# Agent instructions appended to the harness base prompt. Verified 2026-09-12: without an explicit
# publish rule, local models answer in text the harness never posts (the reply shows only in the app's activity log).
BUZZ_AGENT_INSTRUCTIONS='Your text output is NOT delivered to anyone; humans only see messages you publish with the buzz CLI. For every request you MUST end by running: buzz messages send --channel <channel-uuid from the context block> --content "<your answer or a summary of what you did>". If you created or changed files, first run: buzz upload file --file <path> and include the returned URL in that message. Never end a turn without publishing.'

# --- Gitea (profile: gitea) -----------------------------------------------------------------
GITEA_PORT=3003
GITEA_PUBLIC_URL=http://127.0.0.1:3003   # ROOT_URL: what clone URLs and links show. Keep the port in sync.
GITEA_ADMIN_USER=stackadmin
# make init: 24 hex
GITEA_ADMIN_PASSWORD=
# written by `make gitea-bootstrap`
GITEA_ADMIN_TOKEN=

# --- Optional backends ----------------------------------------------------------------------
# LLAMACPP_MODEL_FILE=your-model.gguf   # file inside ./models/, llamacpp profile only
# LLAMACPP_CTX_SIZE=0                   # 0 = read from the model file
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

- Docker Compose v5.1.3. An Ollama container named `ollama` (outside this project) listens on `0.0.0.0:11434`, so `LLM_BASE_URL=http://host.docker.internal:11434` works. Models present (`ollama list`, 2026-09-12): `qwen3.6-max`, `ornith-max`, `laguna-max`, `qwen3.8-max`, `embed` (qwen3 0.6B embedding, num_ctx 512, 1024-dim), plus `ornith-1.5:35b`, `laguna-xs-2.1`, `qwen3.8:27b`, `qwen3.6:35b`, `qwen3-embedding:0.6b`. All chat models report an architectural context length of 262144.
- Ports 3000–3003 were held by the operator's `buzz-prod` and `open-llm-runner` compose projects; the operator stops those before execution. `scripts/check-ports.sh` guards this.
- Already pulled here: every image in §1 except `ghcr.io/ggml-org/llama.cpp:server-b10920` and `ollama/ollama:0.34.0`. `docker pull` works on this host.
- MinIO images must be pulled from **quay.io**; Docker Hub returned `denied` for anonymous manifest access to `minio/minio` and `minio/mc` on 2026-09-12.

---

## 6. Model registry sample (`proxy/config.yaml.example`)

Registers the operator's tuned `*-max` tags and `embed` (validated in the reference project on the same host), with the other locally present tags as commented entries. Numbers follow the reserve formula; the physical window is an operator declaration, never queried.

| model_name | litellm model | mode | max_input_tokens | max_output_tokens | note |
|---|---|---|---|---|---|
| qwen3.6-max | ollama_chat/qwen3.6-max | chat | 237568 | 16384 | 262144 window; supports_vision |
| ornith-max | ollama_chat/ornith-max | chat | 237568 | 16384 | |
| laguna-max | ollama_chat/laguna-max | chat | 237568 | 16384 | |
| qwen3.8-max | ollama_chat/qwen3.8-max | chat | 106496 | 16384 | window capped at 131072 by the operator |
| embed | ollama/embed | embedding | — | — | |

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
