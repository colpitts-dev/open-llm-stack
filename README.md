# Open LLM Stack

A local-first, open-weights development stack in one `docker compose up`. Four batteries, preconfigured to work together: an OpenAI-compatible API gateway (LiteLLM), a chat UI (Open WebUI), team collaboration with LLM agents in the room (Buzz relay), and version control (Gitea). Every battery is a Compose profile you can switch off or point at an external instance. The model itself is bring your own: any OpenAI-compatible backend you already run (Ollama, llama.cpp, vLLM, LM Studio), or the optional bundled Ollama / llama.cpp profiles. Everything binds loopback by default, every image tag is pinned, and every command in this file was run on the reference host on 2026-09-12 (the agent team section: 2026-09-13).

Batteries included:

| Battery | What it gives you | Port |
|---|---|---|
| LiteLLM | one OpenAI-compatible endpoint + a hand-maintained model registry (`proxy/config.yaml`) | 3000 |
| Open WebUI | chat with every registered model, no login by default | 3001 |
| Buzz relay | team chat, channels, DMs, a bundled LLM agent that answers @mentions through LiteLLM | 3002 |
| Gitea | git hosting with a web UI, SQLite, admin + API token bootstrapped for you | 3003 |

## Quick start

Prerequisites:

- Docker Engine with Compose v2 (validated on Compose v5.1.3).
- On the host: `openssl`, `curl`, `jq`, `git`, `ss` (iproute2). The scripts use nothing else.
- An OpenAI-compatible LLM backend reachable **from inside Docker**. The default `.env` assumes Ollama on this machine listening on `0.0.0.0:11434`. Any other setup: read "Bring your own LLM backend" first, or add the `ollama` profile and let the stack run one.
- Ports 3000–3003 free (`make up` refuses to start otherwise; the port numbers are `.env` variables).

```bash
make init     # .env + generated secrets + proxy/config.yaml (idempotent; runs the relay image once to mint Nostr keys)
make up       # check ports, docker compose up -d --wait, then preflight the LLM backend from inside litellm
make test     # smoke-test every layer in COMPOSE_PROFILES
```

Then, once, `make gitea-bootstrap` (admin user + API token, written to `.env`). Expect the first `make up` on a fresh machine to take one to two minutes (LiteLLM is healthy ~45 s after start; Open WebUI ~90 s on first boot while it runs migrations). `make test` takes 35–60 s because it does one chat round-trip per registered chat model.

| Service | URL | Credentials |
|---|---|---|
| LiteLLM (OpenAI-compatible API) | http://127.0.0.1:3000/v1 | `Authorization: Bearer $LITELLM_MASTER_KEY` |
| Open WebUI | http://127.0.0.1:3001 | none (`WEBUI_AUTH=false`) |
| Buzz relay | ws://127.0.0.1:3002 (desktop app, CLI, agent); http://127.0.0.1:3002/ (repo browser + invites) | none (open relay) |
| Gitea | http://127.0.0.1:3003 | `GITEA_ADMIN_USER` / `GITEA_ADMIN_PASSWORD`; API: `GITEA_ADMIN_TOKEN` |

Every credential lives in `.env` (gitignored): `LITELLM_MASTER_KEY`, `GITEA_ADMIN_PASSWORD`, `GITEA_ADMIN_TOKEN` (after bootstrap), the Buzz relay key and the agent keypair. `make init` never overwrites a non-blank value, so re-running it is safe.

**Use `127.0.0.1` in the browser and in every client, not `localhost`.** The Buzz relay binds its community to the exact string in `BUZZ_PUBLIC_HOST` (`127.0.0.1:3002`) and answers 404 to any other host name, and browsers keep separate cookies, storage and service workers per origin, so `localhost:3001` and `127.0.0.1:3001` are not the same site.

First call through the gateway:

```bash
set -a; . ./.env; set +a
curl -sS http://127.0.0.1:3000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-max","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":512}' \
  | jq -r '.choices[0].message.content'
```

## What runs

| Layer | Service | Host port | Profile | Image (pinned, verified 2026-09-12) |
|---|---|---|---|---|
| API gateway | LiteLLM (+ its own Postgres) | **3000** | `litellm` | `ghcr.io/berriai/litellm:v1.89.7`, `postgres:17.11-alpine` |
| Chat | Open WebUI | **3001** | `openwebui` | `ghcr.io/open-webui/open-webui:v0.11.3` |
| Team collaboration | Buzz relay (+ Postgres, Redis, MinIO) | **3002** | `buzz` | `ghcr.io/block/buzz:sha-e17cdd9`, `postgres:17.11-alpine`, `redis:7.4.11-alpine`, `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`, `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z` |
| Version control | Gitea (SQLite) | **3003** | `gitea` | `docker.gitea.com/gitea:1.27.3` |
| Optional: Buzz agent | buzz-acp + buzz-agent (sprig) | none (host network) | `buzz-agent` | `ghcr.io/block/buzz-sprig:sha-e17cdd9` |
| Optional: CI runner | Gitea Actions runner "Laurie" | none (host network) | `gitea-runner` | `docker.gitea.com/act_runner:3.4.2` (verified 2026-09-13); jobs run in `python:3.12-alpine` |
| Optional: agent team | Dinesh, Gilfoyle, Jared, Erlich (sprig, one container each) | none (host network) | `team` | `ghcr.io/block/buzz-sprig:sha-e17cdd9` |
| Optional: Ollama | Ollama server | none | `ollama` | `ollama/ollama:0.34.0` |
| Optional: llama.cpp | llama.cpp server (CPU) | none | `llamacpp` | `ghcr.io/ggml-org/llama.cpp:server-b10920` (CUDA variant: `server-cuda-b10920`) |

Compose service names, for `make logs S=<service>` and `docker compose exec`: `litellm`, `litellm-db`, `open-webui`, `buzz`, `buzz-db`, `buzz-redis`, `buzz-minio`, `buzz-minio-init` (one-shot bucket creator, exits 0), `gitea`, `buzz-agent`, `gitea-runner`, `dinesh`, `gilfoyle`, `jared`, `erlich`, `ollama`, `llamacpp`. All of them share one bridge network named `open-llm-stack`, except the agents and the runner, which use the host network (see "The agent team"). Only `litellm` and `open-webui` carry `extra_hosts: host.docker.internal:host-gateway`. Only published ports bind the host, and every one of them binds `BIND_HOST` (default `127.0.0.1`); the backends, the runner and the agents publish nothing.

## Turning layers on/off and pointing at external services

`COMPOSE_PROFILES` in `.env` is the only switch. Compose reads it automatically; no `--profile` flags anywhere.

```bash
COMPOSE_PROFILES=litellm,openwebui,buzz,gitea          # the default four
COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,buzz-agent,ollama   # plus the bundled agent and Ollama
COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,gitea-runner,team   # plus the CI runner and the agent team (see below)
```

Turning a layer off is removing its profile. Pointing a layer at an external instance is removing its profile **and** setting that layer's `*_URL` variable. Run `make down` **before** you edit `COMPOSE_PROFILES`: once a profile is gone from `.env`, Compose no longer manages that layer's containers, so a later `make down` leaves them running as orphans (see Troubleshooting).

| Layer | Turn off | Use an external one |
|---|---|---|
| LiteLLM | drop `litellm` | `LITELLM_URL` (what containers use: Open WebUI) + `LITELLM_PUBLIC_URL` (what host processes use: desktop app, `buzz-agent`, you) + `LITELLM_MASTER_KEY` = that gateway's key |
| Open WebUI | drop `openwebui` | nothing else reads its variables; just drop the profile |
| Buzz relay | drop `buzz` | `BUZZ_RELAY_URL=wss://...`; only the `buzz-agent` profile reads it, humans point their app at the same URL |
| Gitea | drop `gitea` | nothing in the stack depends on it; use your GitHub/Gitea directly |
| CI runner, agent team | drop `gitea-runner`, `team` | they read `GITEA_PUBLIC_URL`, `BUZZ_RELAY_URL`, `LITELLM_PUBLIC_URL` (host network, like `buzz-agent`); only verified against the bundled instances |
| LLM backend | (bring-your-own is the default) | `LLM_BASE_URL`, see the next section |

One example per layer:

```bash
# External gateway (some other OpenAI-compatible proxy). A gateway on this machine is reachable from
# containers as host.docker.internal:<port> only if it is bound to 0.0.0.0 or the docker0 address
# (a 127.0.0.1-only bind cannot be reached; same rule as reachability case 3 below).
COMPOSE_PROFILES=openwebui,buzz,gitea
LITELLM_URL=http://host.docker.internal:4000
LITELLM_PUBLIC_URL=http://127.0.0.1:4000
LITELLM_MASTER_KEY=sk-...that-gateway's-key...

# External relay: the bundled agent (and your desktop app) talk to it instead
COMPOSE_PROFILES=litellm,openwebui,gitea,buzz-agent
BUZZ_RELAY_URL=wss://relay.example.com

# External Gitea or GitHub: just drop the profile
COMPOSE_PROFILES=litellm,openwebui,buzz

# No Open WebUI: just drop the profile
COMPOSE_PROFILES=litellm,buzz,gitea
```

Then `make up`. Open WebUI picks up a changed `LITELLM_URL` on restart because `ENABLE_PERSISTENT_CONFIG=false` keeps env authoritative. If you edit `docker-compose.yml`, keep this rule: `depends_on` never crosses a profile boundary, because Compose rejects the whole project (`depends on undefined service ... invalid compose project`) as soon as the target profile is off.

Ports and public URLs travel together: `LITELLM_PORT`/`LITELLM_PUBLIC_URL`, `OPENWEBUI_PORT`, `BUZZ_PORT`/`BUZZ_PUBLIC_HOST`/`BUZZ_RELAY_URL`, `GITEA_PORT`/`GITEA_PUBLIC_URL`. Change both halves. Every variable is documented inline in `.env.example`; `docs/spec.md` §3 is the authoritative list.

## Bring your own LLM backend

`LLM_BASE_URL` in `.env` must be reachable **from inside the litellm container**, which is not the same thing as reachable from your shell. `make up` runs `scripts/preflight.sh`, which tries `${LLM_BASE_URL}/v1/models` then `/api/tags` from inside the container and, on failure, prints which case you are in:

1. **Backend is a container.** Attach it to the `open-llm-stack` network (`docker network connect open-llm-stack <container>`) and use `http://<container>:<port>`. Or use a bundled profile below.
2. **Host process bound to `0.0.0.0`** (Ollama in Docker with a published port, LM Studio with "serve on network"). Use `http://host.docker.internal:<port>`. Already wired: `litellm` has `extra_hosts: host.docker.internal:host-gateway`. This is the default (`http://host.docker.internal:11434`).
3. **Host process bound to `127.0.0.1` only.** `host.docker.internal` resolves to the Docker bridge gateway, never to loopback, so it cannot be reached. Bind the backend to the `docker0` address (`ip addr show docker0`) or use case 1. Do not rebind an unauthenticated inference server to `0.0.0.0` on a LAN you do not trust; put LiteLLM (master-key auth) in front and keep the backend off every interface but loopback or a Docker network.

After changing `LLM_BASE_URL`, `docker compose up -d litellm` (re-renders the container's env), then `./scripts/preflight.sh`.

### Or let the stack run one

```bash
# Ollama: models pulled on demand into the ollama-data volume, no host port
COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,ollama
LLM_BASE_URL=http://ollama:11434
make up && docker compose exec ollama ollama pull qwen3:0.6b     # any tag; then register it in proxy/config.yaml + make reload

# llama.cpp: you supply a GGUF in ./models/ (create the directory; it is gitignored), no host port
COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,llamacpp
LLM_BASE_URL=http://llamacpp:8080
LLAMACPP_MODEL_FILE=your-model.gguf     # filename inside ./models/
LLAMACPP_CTX_SIZE=0                     # 0 = the model file's own context; set it to cap the window (this is the physical window below)
make up
```

Both were run on the reference host: preflight `OK backend reachable at http://ollama:11434/v1/models` and a completion through LiteLLM from the bundled Ollama (CPU) in 3.6 s; `llamacpp` healthy with a 1.2 MB toy GGUF and answering in 0.14 s. Pulling the two images took ~6 min. For an NVIDIA GPU, uncomment the `deploy:` block on `ollama` in `docker-compose.yml` (needs `nvidia-container-toolkit`), or switch `llamacpp` to the `server-cuda-b10920` tag.

### Registering models

`proxy/config.yaml` is the only model registry; nothing discovers models. `make init` copies it from `proxy/config.yaml.example`, which registers the reference host's tags as a worked sample. Edit it to match what your backend actually serves, then `make reload` (restarts `litellm`, healthy again in ~30 s). Every client (Open WebUI, the Buzz agent, your code) sees the `model_name` you choose; backends can change behind it without any client noticing.

Prefixes:

| Backend | `litellm_params.model` | Notes |
|---|---|---|
| Ollama chat model | `ollama_chat/<tag>` | never plain `ollama/` for chat: it skips the chat template and degrades tool calling |
| Ollama embedding model | `ollama/<tag>` | `mode: embedding` |
| llama.cpp, vLLM, LM Studio, any OpenAI-compatible server | `openai/<name>` + `api_base: http://.../v1` + `api_key: sk-unused` | the client library requires *a* key; the server ignores it |

Keep `execution_locus: local` and a `model_revision` string on every entry (downstream tools rely on them), and keep `litellm_settings` as shipped (`drop_params: true`, `num_retries: 0`, `request_timeout: 900`). Never register a closed-weight model or a pass-through router; `make test` fails if one appears.

`max_input_tokens` is a declaration to clients, not something the backend enforces: exceed the backend's real window (`num_ctx` in Ollama, `-c` in llama.cpp) and the backend silently drops the oldest tokens. Always declare below the physical window:

```
max_input_tokens = physical_window − max_output_tokens − 8192   (template and tool scaffolding)
```

| Physical window | `max_output_tokens` | `max_input_tokens` |
|---|---|---|
| 262144 | 16384 | 237568 |
| 131072 | 16384 | 106496 |
| 128000 | 16384 | 103424 |
| 32768 | 4096 | 20480 |

The physical window is an operator declaration; the stack never queries the backend for it. If the bundled Buzz agent uses a model, keep `BUZZ_AGENT_MAX_CONTEXT_TOKENS` in `.env` equal to that model's `max_input_tokens`. The team agents need no such variable: they read both caps for `TEAM_MODEL` from LiteLLM's registry when they start.

## Open WebUI (port 3001)

Open http://127.0.0.1:3001. With the default `WEBUI_AUTH=false` there is no login; every model in `proxy/config.yaml` is in the picker because Open WebUI talks only to LiteLLM (`LITELLM_URL`, with `LITELLM_MASTER_KEY`); its direct-Ollama probe is disabled (`ENABLE_OLLAMA_API=false`). Set `WEBUI_AUTH=true` in `.env` and `docker compose up -d open-webui` to get normal signup/login (the first account becomes admin).

Connection settings come from `.env` on every boot (`ENABLE_PERSISTENT_CONFIG=false`), so changes made to them in the admin UI do not survive a restart; edit `.env` instead. No-login mode still requires a bearer token for raw API calls; an empty sign-in returns the admin session:

```bash
token=$(curl -sS -X POST http://127.0.0.1:3001/api/v1/auths/signin -H 'Content-Type: application/json' -d '{"email":"","password":""}' | jq -r .token)
curl -sS -H "Authorization: Bearer $token" http://127.0.0.1:3001/api/models | jq -r '.data[].id'
```

Data (chats, settings, uploaded files) lives in the `open-webui-data` volume. Benign startup log lines: `CORS_ALLOW_ORIGIN IS SET TO '*'`, `USER_AGENT environment variable not set`, an SQLAlchemy `SAWarning` about `_alembic_tmp_tag`, a `grpcio` `FutureWarning`, and a `huggingface_hub` unauthenticated-requests notice.

## Buzz relay (port 3002)

The relay is up at `ws://127.0.0.1:3002` (open mode: anyone with the URL can join; fine on a laptop, see below for closed mode). Chat clients:

- **Buzz desktop app** (packaged builds: https://github.com/block/buzz/releases): launch with `BUZZ_RELAY_URL=ws://127.0.0.1:3002` in its environment, or use "Add community" inside the app with that URL.
- **`buzz` CLI** without installing anything: `docker run --rm --network host -e BUZZ_PRIVATE_KEY=<64-hex secret> -e BUZZ_RELAY_URL=ws://127.0.0.1:3002 --entrypoint buzz ghcr.io/block/buzz-sprig:sha-e17cdd9 channels list`. Mint a key with `docker compose exec buzz buzz-admin generate-key` (prints `Public key:` and `Secret key:`).
- Browser: http://127.0.0.1:3002/ serves the repo browser and invite pages (`BUZZ_SERVE_GIT_WEB_GUI=true`). It is not a chat client.

**Use exactly `127.0.0.1:3002`.** The relay is multi-tenant by host: on startup it creates one community keyed on `BUZZ_PUBLIC_HOST` (log line `Deployment community ensured host=127.0.0.1:3002`) and answers `404 relay: no community is configured for this host` to any other `Host` header, so `localhost:3002` is a different, non-existent community, and a container on the compose network using `ws://buzz:3002` is rejected too. That is why the bundled agent runs on the host network. To expose the relay on your LAN set `BIND_HOST=0.0.0.0`, `BUZZ_PUBLIC_HOST=<your-ip>:3002` and `BUZZ_RELAY_URL=ws://<your-ip>:3002`, then `docker compose up -d buzz`; every client must then use that IP literally.

Closed relay (members only): set `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true` and `RELAY_OWNER_PUBKEY=<your 64-hex pubkey>` in `.env`, `docker compose up -d buzz`, then add members with `docker compose exec buzz buzz-admin add-member --pubkey <hex-or-npub>` (include `BUZZ_AGENT_PUBKEY` if you run the bundled agent). `BUZZ_REQUIRE_AUTH_TOKEN=false` (default) logs one `WARN ... REST API requests bypass token auth` per boot; that is the documented open-mode notice, not an error.

External relay: remove `buzz` from `COMPOSE_PROFILES` and set `BUZZ_RELAY_URL=wss://your-relay.example`; only the optional `buzz-agent` profile reads it.

Data lives in the `buzz-db-data`, `buzz-redis-data`, `buzz-minio-data` and `buzz-git-data` volumes. Back up `.env` too: `BUZZ_RELAY_PRIVATE_KEY` is the relay's identity and `BUZZ_GIT_HOOK_HMAC_SECRET` must stay stable across restarts.

## Buzz + LLMs through LiteLLM

Every Buzz agent talks to a model through an OpenAI-compatible endpoint. LiteLLM is that endpoint. The relay itself never calls a model; agents do.

**Bundled agent (profile `buzz-agent`).** Add `buzz-agent` to `COMPOSE_PROFILES` and `make up`. An agent named `BUZZ_AGENT_NAME` (default `stack-agent`; its keypair is `BUZZ_AGENT_PRIVATE_KEY`/`BUZZ_AGENT_PUBKEY` in `.env`) connects to `BUZZ_RELAY_URL`, sets its profile name, and answers any @mention using `BUZZ_AGENT_MODEL` through `LITELLM_PUBLIC_URL` with the master key. It runs on the host network (`network_mode: host`), so it uses the same URLs a human does and works unchanged against an external relay or gateway. It has `buzz-dev-mcp` tools (shell, files, buzz) and answers anyone (`BUZZ_ACP_RESPOND_TO=anyone`, right for an open relay).

The agent only sees channels it is a **member** of. Add it, then mention it:

- Desktop app: open the channel's members, add by pubkey (`BUZZ_AGENT_PUBKEY` from `.env`) with the **bot** role, then type `@stack-agent ...`.
- CLI: `buzz channels add-member --channel <uuid> --pubkey $BUZZ_AGENT_PUBKEY --role bot`, then `buzz messages send --channel <uuid> --content "@stack-agent ..." --mention $BUZZ_AGENT_PUBKEY`.
- Or DM it.

Prove it with `./scripts/buzz-smoke.sh` (also run by `make test` when the profile is on): a throwaway human identity creates a channel, adds the agent, sends `@stack-agent Reply with exactly the single word: PONG`, and waits up to 240 s. Measured: `agent replied after ~10s: PONG` (two or three LLM calls, one tool call). A miss is possible with a reasoning model (one out of four runs on the reference host: the model ended its turn with empty content); re-run once before calling it a failure.

**Your own agents (Buzz desktop app, or `buzz-acp` anywhere on this machine).** Give them this environment, from `.env`. These are agent settings, not `.env` variables:

```bash
BUZZ_AGENT_PROVIDER=openai
OPENAI_COMPAT_BASE_URL=http://127.0.0.1:3000/v1      # LITELLM_PUBLIC_URL + /v1
OPENAI_COMPAT_API_KEY=<LITELLM_MASTER_KEY>
OPENAI_COMPAT_MODEL=qwen3.6-max                       # any model_name from proxy/config.yaml
OPENAI_COMPAT_API=chat                                # pin Chat Completions; "auto" picks Responses only for *.openai.com
BUZZ_AGENT_MAX_CONTEXT_TOKENS=237568                  # that model's max_input_tokens
BUZZ_AGENT_MAX_OUTPUT_TOKENS=16384                    # that model's max_output_tokens
```

In the desktop app these go in the agent's (or the global) configuration: provider `openai`, model `<model_name>`, and the `OPENAI_COMPAT_*` values as env vars. Do not set `BUZZ_RELAY_URL` as an agent env var; the app injects it for the community the agent runs in. Any runtime other than `buzz-agent` (for example Goose) has its own OpenAI-compatible provider settings; point them at the same base URL and key.

Swap the model for every agent at once by editing `proxy/config.yaml`: names stay stable, backends change.

## Gitea (port 3003)

http://127.0.0.1:3003, SQLite, HTTP only (no SSH port is published), install already locked. Create the admin account and an API token once:

```bash
make gitea-bootstrap        # uses GITEA_ADMIN_USER / GITEA_ADMIN_PASSWORD from .env, writes GITEA_ADMIN_TOKEN
```

Idempotent: a second run prints `already exists` and `already set`. `./scripts/bootstrap-gitea.sh --rotate` mints a new token (old tokens stay valid until deleted in Gitea under Settings, Applications). Log in with those credentials, or use the token:

```bash
set -a; . ./.env; set +a
curl -sS -H "Authorization: token $GITEA_ADMIN_TOKEN" http://127.0.0.1:3003/api/v1/user | jq .login
git -c http.extraHeader="Authorization: token $GITEA_ADMIN_TOKEN" clone http://127.0.0.1:3003/$GITEA_ADMIN_USER/<repo>.git
```

Push over HTTP the same way, or with the user's password. `make test` creates, clones and deletes a private repo through the API (`healthz: pass`, `version 1.27.3`, `cloned (README.md )`). Self-registration is on (`GITEA__service__DISABLE_REGISTRATION: "false"` in `docker-compose.yml`); fine on loopback, see Security notes before exposing it.

External Gitea/GitHub: remove `gitea` from `COMPOSE_PROFILES`; nothing else in this stack depends on it. `GITEA_PUBLIC_URL` only controls the bundled instance's `ROOT_URL` (what its clone URLs and links show), so change it together with `GITEA_PORT` or `BIND_HOST`. Data lives in the `gitea-data` volume.

## The agent team

Profiles `team` and `gitea-runner` turn the single bundled agent into a small development team that delivers **validated pull requests in Gitea**. Each agent is its own container from the sprig image (same harness as `buzz-agent`, host network, own volume at `/home/agent`, persona in `agents/<name>.md` on top of the shared `agents/TEAM.md`), talks to one model through LiteLLM, and obeys the pubkeys in `TEAM_ALLOWLIST` plus its teammates (agent-to-agent mentions such as Dinesh asking Gilfoyle for a review are otherwise dropped). Validated end to end on the reference host on 2026-09-13; the verified facts are in `docs/spec.md` §5.8.

| Agent | Role | Answers in | What it does |
|---|---|---|---|
| **Dinesh** | builder | threads | clones from Gitea (or, for a new project, creates the repository in the team org with CI and branch protection), branches `agent/<slug>`, pushes and lets CI run the tests (the image has no Python), opens the PR through the API, posts the URL, @mentions you and asks Gilfoyle for a review; reads the PR's commit status and fixes on the same branch |
| **Gilfoyle** | reviewer | threads | read-only: fetches the PR diff, posts a review in Gitea (approve / request changes / comment) and in the thread. Never edits, never opens PRs |
| **Jared** | coordinator | channels; heartbeat every `TEAM_HEARTBEAT_SECONDS` (1800) | triages Gitea issues, hands ready work to Dinesh, posts status in a channel named `triage`; never builds or reviews |
| **Erlich** | assistant | channels | Q&A, summaries, drafting in `#general`; has no Gitea access and points build requests at Dinesh |
| **Laurie** | CI | Gitea Actions | `gitea-runner`: runs the repo's workflow on every push and PR; `main` is protected by her `ci / test (pull_request)` check plus one approval |

Dinesh, Gilfoyle and Jared each have their own Gitea user and token (Gitea forbids approving your own PR, so one shared account would not work). Every team repository lives in one Gitea organization, `TEAM_GITEA_ORG` (default `piedpiper`; private, owned by `GITEA_ADMIN_USER`), and the three of them sit on its `agents` team: write on every repo in it, and allowed to create new ones there and nowhere else. The org exists because a non-admin cannot create a repository in another user's namespace, so repos under the admin user would leave Dinesh unable to start a project. All four agents share `TEAM_MODEL` (default `ornith-max`).

**Prerequisites:** the default four layers up (`make init && make up`) and `make gitea-bootstrap` done. **Setup, once, in this order** (the runner registers on its first boot and needs `GITEA_RUNNER_TOKEN` then, so bootstrap must finish before the `gitea-runner` profile is enabled):

```bash
# 1. Put your own 64-hex pubkey in TEAM_ALLOWLIST in .env (first entry = the agents' owner). It is in the
#    Buzz app profile, or on any message you posted: `buzz messages get --channel <uuid>` shows `pubkey`.
#    TEAM_GITEA_ORG (default piedpiper) names the organization the repos live in; change it before the first bootstrap or leave it.
make init             # fills TEAM_*_PRIVATE_KEY / _PUBKEY for the four agents + a throwaway smoke identity, and TEAM_GITEA_PASSWORD
make team-bootstrap   # Gitea users dinesh/gilfoyle/jared + tokens, org TEAM_GITEA_ORG + team `agents`, runner token, fixture repo <org>/demo-calc with CI + branch protection (idempotent)
make team-bootstrap   # ... and YOUR login: TEAM_HUMAN_USER (default richard) with TEAM_HUMAN_PASSWORD from .env, org owner, may merge
# 2. Only now: append gitea-runner,team to COMPOSE_PROFILES in .env (make down first if the stack is running)
make up               # runner registers in ~20 s (healthcheck: /data/.runner exists); agents log `presence set to online`
make test             # adds a gitea-runner section (registered + last CI run on demo-calc) and runs make team-smoke
```

`make team-bootstrap` needs `GITEA_ADMIN_TOKEN` (from `make gitea-bootstrap`) and writes `TEAM_{DINESH,GILFOYLE,JARED}_GITEA_TOKEN` and `GITEA_RUNNER_TOKEN` into `.env`; a second run prints only `exists` lines. If you ran an older bootstrap (repos under `GITEA_ADMIN_USER`, tokens without the `write:organization` scope), re-running it migrates and prints what it changed: it re-mints `GITEA_ADMIN_TOKEN` and the agent tokens with `write:organization` (old tokens stay valid until you delete them in Gitea under Settings, Applications), creates the org and team, and transfers `demo-calc` into the org (open PRs and the branch protection survive; the old URL redirects with 301). Within about a minute of the runner registering, `demo-calc` shows a green `ci` run on `main`.

**Giving Dinesh a job.** In the Buzz app, create a project channel, add Dinesh and Gilfoyle as members by pubkey (`TEAM_DINESH_PUBKEY`, `TEAM_GILFOYLE_PUBKEY` in `.env`, role bot), then start a thread mentioning Dinesh with the request and the repository name:

```
@Dinesh in the repository demo-calc, add a function subtract(a, b) that returns a - b, with a test, and open a pull request.
```

Expect, in that thread: `picked up: <plan>`, then the PR URL with what changed and the CI state (Dinesh reads the PR's commit status; CI is where the tests run), then Dinesh's own `@Gilfoyle review please <url>`, then Gilfoyle's verdict, which lands as a Gitea review (`APPROVED`, `REQUEST_CHANGES` or `COMMENT`) and in the thread. You can also ask Gilfoyle yourself with the same sentence. When the `ci / test (pull_request)` check is green and the review is an approval, log in at http://127.0.0.1:3003 as `TEAM_HUMAN_USER` (password `TEAM_HUMAN_PASSWORD` in `.env`; the admin `GITEA_ADMIN_USER` works too) and merge in Gitea as `GITEA_ADMIN_USER`. Merging stays with a human, and Gitea enforces it: the branch protection blocks direct pushes to `main` and whitelists only `GITEA_ADMIN_USER` for merges, because the agents' team write permission plus Gilfoyle's own approval would otherwise let an agent merge (Gilfoyle once told a thread a PR was "approved and merged"; it was not, but Gitea would have allowed it). Re-running `make team-bootstrap` adds the merge whitelist to a protection created by an older bootstrap. If CI fails or Gilfoyle requests changes, Dinesh fixes on the same branch and reports in the same thread; nudge him there if he does not.

A request for a new project works the same way: `@Dinesh create a repository named wordcount with a function count_words(text) and a test, and open a pull request.` Dinesh creates `wordcount` in the org through the API (a member of the `agents` team may create repos there, and only there), puts the CI workflow (`agents/ci-python.yaml`, mounted into his container) and a `pyproject.toml` in his first commit so Laurie can run the tests, opens the PR, and then protects `main` with the same rule the bootstrap uses (CI check plus one approval, no direct push, merge only by `GITEA_ADMIN_USER`). Measured on the reference host: `@Dinesh create a repository named hello-py with a Python package, a pytest test, CI, and open a pull request` gave `piedpiper/hello-py` with the workflow, `pyproject.toml`, package and test in the first commit, PR #1 open after ~50 s, CI green, branch protection set by Dinesh, and Gilfoyle's `APPROVED` ~40 s after the review request.

Jared and Erlich live in channels rather than threads: add Jared to a channel named `triage` (he posts status there on his heartbeat; set `TEAM_HEARTBEAT_SECONDS=0` to disable it, `docker compose up -d jared` after changing it) and Erlich to `#general`.

Prove the loop with `make team-smoke` (also run by `make test` when the profile is on): the throwaway smoke identity creates a job channel, adds Dinesh and Gilfoyle, asks for a `subtract_<n>` function in `demo-calc`, waits for a new PR by `dinesh` (numbered above any earlier one; up to 15 min), for its `ci / test (pull_request)` status to be `success` (up to 10 min), then asks Gilfoyle for a review and waits for a submitted (non-pending) one (up to 10 min). It ends with `TEAM SMOKE PASS: PR #<n>, CI success, review <state>`. Measured on the reference host with `ornith-max`, Jared's heartbeat running on the same GPU slot: PR opened 70 s after the mention (10–20 s with the GPU idle), CI green ~25 s after the push, `APPROVED` review ~30 s after the request, 96 s in total. Merge that PR in Gitea yourself. If it fails at "no PR", read `docker compose logs dinesh`; a single silent turn can be re-driven by mentioning Dinesh once more in the same thread.

**Switching the model.** `TEAM_MODEL` is the only knob: each agent reads `max_input_tokens`/`max_output_tokens` for it from LiteLLM's registry at start (logged as `model=<name> context=<in> output=<out>`), so there is no context variable to keep in sync.

```bash
make team-model M=qwen3.8-max    # checks the name against /v1/models, rewrites TEAM_MODEL, recreates the four agents
docker compose logs --since 2m dinesh | grep model=    # model=qwen3.8-max context=106496 output=16384
make team-model M=nope-model     # prints "not registered in proxy/config.yaml"; make exits 2
```

Measured 2026-09-13: `ornith-max`, `qwen3.8-max` and `laguna-max` publish multi-step results; `qwen3.6-max` does not, so it is a poor choice for the team. On `qwen3.8-max` Dinesh answered a mention in ~20 s. The four agents plus CI share one GPU slot on the host Ollama (`OLLAMA_NUM_PARALLEL=1`) by queueing; throughout the smoke run `docker exec ollama ollama ps` showed `100% GPU`.

**Using your own Gitea.** The same scripts drive an instance you already run (on the LAN behind a private CA, or on the internet with a public certificate). Switch with `.env` only, after `make down`:

```bash
COMPOSE_PROFILES=litellm,openwebui,buzz,buzz-agent,team      # no gitea, no gitea-runner: the bundled runner must never register against your instance
GITEA_PUBLIC_URL=https://git.example.com
GITEA_ADMIN_USER=<your admin login>                          # owner of the token below
GITEA_ADMIN_TOKEN=<token with write:admin,write:organization,write:repository,write:user>   # Settings -> Applications on your Gitea
GITEA_CA_FILE=/usr/local/share/ca-certificates/<your-ca>.crt # private CA only; blank for a public certificate
TEAM_CI_LABEL=ci                                             # the runs-on label your runner registered
TEAM_HUMAN_USER=<your login>                                 # existing account: becomes org owner and may merge
TEAM_DINESH_GITEA_TOKEN= TEAM_GILFOYLE_GITEA_TOKEN= TEAM_JARED_GITEA_TOKEN=   # blank: tokens are per instance, the bootstrap mints new ones
```

Then `make up && make team-bootstrap` (twice is fine; it prints what it created). Re-running `make team-bootstrap` is the backstop: it protects every repo in the org and strips any agent that is still a repo admin. Prerequisites: this host trusts your instance's certificate (for a private CA, install its root in the OS store; `GITEA_CA_FILE` is what the agent containers get), and your runner's job image has `git`, `python3` and `venv` (the generated workflow installs into a venv because Debian images refuse system pip installs). What lands on your instance: three machine users (`dinesh`, `gilfoyle`, `jared`), a private org `TEAM_GITEA_ORG` with an `agents` team (write, may create repos), the fixture `demo-calc` with its workflow, and branch protection on `main` (required check, one approval, merge restricted to the admin and you). The admin token stays on this host in `.env`; delete it on your Gitea when you no longer need to re-run the bootstrap. To revoke the agents, delete their three tokens there. Inside a CI job your Gitea is reached through your runner's internal URL, which the workflow gets from the runner, so nothing in the template names your host. Keep a copy of each mode's env (`.env.bundled`, `.env.forge`; gitignored) to switch back and forth.

One thing to record in your instance's own decision log: on a pull_request event the runner executes the workflow file from the PR branch before anyone reviews it, so an agent can change CI in its own PR. Your runner's isolation is what bounds that.

**New repositories.** Agents never create repositories by hand. Dinesh runs `/opt/team/agents/bin/new-repo <name>`, which generates the repo from the org's `python-template` (private, CI workflow, protected `main` with the merge whitelist and admin-override blocked) and then removes his own admin rights, so every repo an agent creates is born governed and the agent keeps only the team's write access. The template is built by `make team-bootstrap` from `agents/template/` and `agents/ci-python.yaml`; edit those and re-run the bootstrap to change what new repos look like. Roles are enforced by Gitea teams, not by personas: `builders` (Dinesh) may push and create repos, `reviewers` (Gilfoyle) may only review and comment, `coordinators` (Jared) may only triage issues. `make test` proves the factory without an LLM (`test_team_factory`).

**Limits, honestly.**

- The reply guard (`BUZZ_AGENT_REQUIRE_REPLY=1`, at most two rerolls) is advisory: a turn can still end in text nobody sees. Re-mention once before calling it a failure.
- The agents' shell tool starts with an empty environment (`HOME` and `PATH` only; the harness scrubs it and has no passthrough flag). Git clone/push still work because credentials are in the file-based store, and the entrypoint writes `~/.gitea.env` for the roles with a token; the personas source it per API call (`. ~/.gitea.env && curl …`). If you edit a persona in `agents/`, you may write `$GITEA_URL`, `$GITEA_OWNER` and `$GITEA_ADMIN` bare (substituted into the prompt at container start), but `$GITEA_TOKEN` only after `. ~/.gitea.env` in the same command. Erlich has no env file.
- Agents can misreport. Gilfoyle once announced a merge that had not happened, and Dinesh once posted an `https://` link to the plain-http Gitea. The team norms now say never claim a merge (Gitea's merge whitelist makes one impossible for an agent anyway) and post links exactly as the API's `html_url` returns them; check the PR page in Gitea rather than trusting the thread.
- One model for the whole team; there is no per-agent model. A local model does not know its own name (on `qwen3.8-max` Dinesh said it was "Claude"): read `TEAM_MODEL` or the `model=` log line, never ask the agent.
- Shell quoting trips the models: backticks or `--` inside a command string got mangled (then self-corrected, costing turns). The team norms tell them to write message bodies and JSON to files with a quoted heredoc; keep that rule if you edit `agents/TEAM.md`.
- Busy channels where several agents talk to each other are unreliable with local 35B-class models (see the `buzz-agent` note in Troubleshooting): keep task channels to one agent plus you, and put jobs in threads.
- No NIP-OA owner attestation for these server-side agents; no CLI mints it. The allowlist is the access control.
- Gitea repositories cannot be attached as Projects in the Buzz desktop app (it only attaches relay-hosted repos), so the PR link is the hand-off, not an in-app view.
- The bundled Gitea is its own database: your account there is the one `make team-bootstrap` creates, and an account on some other Gitea you run does not exist here (nor do the agents there). Pointing the team at an external Gitea is not supported: the bootstrap drives the Gitea CLI through `docker compose exec`, the runner would need that instance's trust and CA, and the agents would be creating orgs and repos on it.
- Never point the bundled `gitea-runner` at an external Gitea: it mounts the host docker socket and runs on the host network. External mode drops that profile and uses your instance's own runner.
- The runner mounts `/var/run/docker.sock`: CI jobs are sibling containers with the same trust boundary as your own `docker` command. Only run workflows you would run by hand.

## Security notes

- **Loopback only by default.** Every published port binds `BIND_HOST=127.0.0.1`; the backends, the health/metrics listeners and the databases publish nothing. `BIND_HOST=0.0.0.0` exposes all four services to your LAN at once: LiteLLM (master-key auth, so an authenticated model API), Open WebUI (with `WEBUI_AUTH=false` anyone on the network gets the admin chat session: switch to `WEBUI_AUTH=true` first), the Buzz relay (open mode: anyone joins), and Gitea (self-registration on). When you do it, also set `BUZZ_PUBLIC_HOST`, `BUZZ_RELAY_URL`, `LITELLM_PUBLIC_URL` and `GITEA_PUBLIC_URL` to the LAN address.
- **The relay is open.** Anyone who can reach the URL can join, create channels and mention the agent, which then runs `buzz-dev-mcp` shell and file tools inside its container on the host network. Closed mode is one line plus the owner key: `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true` and `RELAY_OWNER_PUBKEY=<64 hex>`, then `docker compose up -d buzz` and `buzz-admin add-member` per person. The team agents answer only the pubkeys in `TEAM_ALLOWLIST` (plus the smoke identity), but they hold Gitea write tokens, so keep that list short.
- **The CI runner mounts `/var/run/docker.sock`** and starts job containers on the host network. A workflow in any repository the runner serves can do what your own `docker` can. Keep `gitea-runner` off unless you run the team, and keep Gitea on loopback while it is on.
- **LiteLLM supply chain.** PyPI releases `1.82.7` and `1.82.8` shipped credential-stealing malware (BerriAI/litellm#24518). This stack runs the official container image pinned to `ghcr.io/berriai/litellm:v1.89.7`; its dependencies are baked at image build time, not pulled from PyPI at start. Never move to `:latest` or `:main`; change the pin only after verifying the new tag.
- **Open WebUI no-login mode** (`WEBUI_AUTH=false`) is for a single trusted machine. Anyone who can reach port 3001 is the admin.
- **Secrets** are only in `.env` (gitignored) and referenced from `docker-compose.yml` as `${VAR}`. `make init` generates them; nothing is hand-pasted. `GITEA_ADMIN_TOKEN` has `write:repository,write:user,write:organization` scope (`write:organization` for the team org; `make team-bootstrap` re-mints an older token that lacks it).
- The bundled Ollama/llama.cpp have no auth of their own, which is why they get no published port. Reach them through LiteLLM.

## Troubleshooting

- **`404 relay: no community is configured for this host`** (browser, desktop app, CLI, or the agent's connect loop). You connected with a host string that is not `BUZZ_PUBLIC_HOST`. Use it literally: `127.0.0.1:3002`, not `localhost:3002`, not the LAN IP unless you changed the variable. `make test` checks that the seeded community matches (`community host: 127.0.0.1:3002`).
- **`port 3000: BUSY -- ...` from `make up`.** `scripts/check-ports.sh` found a process that is not this stack on a port in `LITELLM_PORT`/`OPENWEBUI_PORT`/`BUZZ_PORT`/`GITEA_PORT`; the line shows the `ss` output for it. Stop it, or change the port (and its `*_PUBLIC_*` twin) in `.env`. `in use by this stack (ok)` is normal when the stack is already running.
- **The browser shows an old Open WebUI on port 3000.** That is a cached progressive-web-app service worker from a previous install that served Open WebUI on 3000; port 3000 is LiteLLM here. Clear site data for that origin in the browser, or open `127.0.0.1` instead of `localhost` (different origin, no stale worker). Open WebUI is on 3001.
- **`FAIL ... unreachable from inside the litellm container` from preflight.** Read the three cases it prints: (1) backend is a container: attach it to the `open-llm-stack` network or use the bundled profile; (2) host process on `0.0.0.0`: `http://host.docker.internal:<port>`; (3) host process on `127.0.0.1` only: cannot be reached through `host.docker.internal`, bind it to the `docker0` address or use case 1. After editing `LLM_BASE_URL`: `docker compose up -d litellm && ./scripts/preflight.sh`.
- **`make up` fails with a `required variable ... run make init` interpolation error.** A required secret is blank in `.env` (the compose file uses `${VAR:?run make init}` for every secret). Run `make init`; it fills only blank values.
- **Open WebUI shows no models.** It only lists what LiteLLM serves. Check `curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://127.0.0.1:3000/v1/models` first; then `LITELLM_URL` (must be reachable from inside the container: `http://litellm:4000` for the bundled gateway) and `LITELLM_MASTER_KEY` in `.env`; then `docker compose up -d open-webui` to re-render its env (`ENABLE_PERSISTENT_CONFIG` is already `false`, so env wins on every boot). `make test` reports `open-webui sees no models from LiteLLM` for this case.
- **The agent is silent.** It answers only in channels it is a member of and only to messages that mention it (`@stack-agent` in the app, `--mention $BUZZ_AGENT_PUBKEY` from the CLI). Add it to the channel with the bot role. With no channels it logs `WARN ... no channel subscriptions resolved — agent will sit idle`, which is expected. **The reply shows in the app's activity log but never in the channel:** the harness only publishes what the model posts with `buzz messages send`; plain text is discarded. The bundled agent carries `BUZZ_AGENT_INSTRUCTIONS` (in `.env`) for exactly this, verified to turn silent turns into replies. For agents you create in the Buzz app, the sentence has to go into the **persona's** instructions (the definition), not the agent instance: a linked agent takes its prompt from its persona and ignores the instance field. Model choice matters too: measured 2026-09-12, `ornith-max`, `laguna-max` and `qwen3.8-max` publish the result of a multi-step task, while `qwen3.6-max` keeps ending in discarded text even with the rule, so the bundled agent defaults to `ornith-max`. The relay's file store (Blossom) only accepts media, so agents cannot upload `.html` or archives; they paste code inline or push to Gitea. Known limit (2026-09-13): in a channel where several agents chat with each other, even `ornith-max` sometimes ends a turn in text or posts to a remembered channel instead of the one in the context block; a stricter rule made it worse. The harness has no fallback that publishes final text, so treat busy multi-agent channels as best-effort with local 35B-class models and keep task channels to one agent. If the relay was down, the agent waits up to 2 min, exits, and Docker restarts it. Look at `docker compose logs buzz-agent` (expect `connected to relay at ws://127.0.0.1:3002`, `presence set to online`, then `llm: call completed` lines when it works).
- **A team agent exits at once with `TEAM_ALLOWLIST is blank in .env` or `no Gitea token for <role>`.** The compose file deliberately does not use `${VAR:?}` for values filled after `make init` (Compose interpolates every service, even with its profile off, so that would break every `docker compose` call before `make team-bootstrap` could run); the entrypoint checks them instead. Fill `TEAM_ALLOWLIST`, or run `make team-bootstrap`, then `docker compose up -d <role>`. `model '<name>' is not in proxy/config.yaml` means `TEAM_MODEL` names something LiteLLM does not serve. The runner with a blank `GITEA_RUNNER_TOKEN` stays unhealthy (`/data/.runner` never appears) until you bootstrap and `docker compose up -d gitea-runner`.
- **An `ollama`/`llamacpp` container keeps running after you removed its profile.** Compose only manages services whose profile is enabled, so `make down` skipped it and printed `Network open-llm-stack Resource is still in use`. Fix: `COMPOSE_PROFILES=ollama docker compose down` (or `llamacpp`), which removes only that container. Avoid it next time by running `make down` before editing `COMPOSE_PROFILES`.
- **Benign log lines.** LiteLLM: `prisma:warn Prisma doesn't know which engines to download for the Linux distro "wolfi"`. Buzz: the `BUZZ_REQUIRE_AUTH_TOKEN is false` WARN. Open WebUI: the five listed in its section. `docker compose config` renders `$$REDIS_PASSWORD` and `$${BUZZ_RELAY_URL...}` in the healthcheck and agent entrypoint: display escaping only, the containers receive a single `$`.
- **Checking what is published.** `docker compose ps --format '{{.Name}} {{.Ports}}'` must show every `->` mapping starting with `127.0.0.1:`. Bare entries such as `5432/tcp`, `22/tcp`, `8080/tcp`, `9102/tcp` are the images' `EXPOSE` metadata, not host bindings.

## Data & backups

Named volumes (Compose prefixes each with the project name, e.g. `open-llm-stack_gitea-data`):

| Volume | Holds |
|---|---|
| `litellm-db-data` | LiteLLM's Postgres (keys, spend logs); the model registry is the file `proxy/config.yaml`, not the DB |
| `open-webui-data` | chats, users, uploads |
| `buzz-db-data`, `buzz-redis-data`, `buzz-minio-data`, `buzz-git-data` | relay Postgres, Redis, media bucket, hosted git repos |
| `gitea-data` | Gitea repos, SQLite database, config |
| `gitea-runner-data` | the runner's registration (`/data/.runner`); delete it to re-register with a new token |
| `team-dinesh`, `team-gilfoyle`, `team-jared`, `team-erlich` | each agent's `/home/agent`: clones, work logs, memory, git credentials |
| `ollama-data` | models pulled into the bundled Ollama (`ollama` profile only) |

Back up `.env` with the volumes: it holds every generated secret, and two of them are identities that cannot be regenerated without breaking things: `BUZZ_RELAY_PRIVATE_KEY` (the relay's key; clients pin it) and `BUZZ_GIT_HOOK_HMAC_SECRET`, plus `BUZZ_AGENT_PRIVATE_KEY` and the `TEAM_*_PRIVATE_KEY`s, whose pubkeys are what your channels have as members. Also keep `proxy/config.yaml` (gitignored).

```bash
docker volume ls --filter name=open-llm-stack_
docker run --rm -v open-llm-stack_gitea-data:/data -v "$PWD":/backup alpine tar czf /backup/gitea-data.tgz -C /data .
```

`make down` keeps every volume. `docker compose down -v` destroys all of them: every chat, every repo, every channel. `./models/` (GGUF files) and `proxy/config.yaml` are plain files in the checkout, untouched by either.

## Make targets

| Target | Runs |
|---|---|
| `make init` | `./scripts/init.sh`: create `.env` from `.env.example` and `proxy/config.yaml` from its `.example`, fill every blank secret (idempotent) |
| `make up` | `./scripts/check-ports.sh`, `docker compose up -d --wait`, `./scripts/preflight.sh` |
| `make down` | `docker compose down` (volumes kept) |
| `make ps` | `docker compose ps` |
| `make logs S=<service>` | `docker compose logs -f <service>`, e.g. `make logs S=litellm` |
| `make test` | `./scripts/smoke-test.sh`: one section per profile in `COMPOSE_PROFILES` (litellm, openwebui, buzz, gitea, gitea-runner; `buzz-agent` runs `scripts/buzz-smoke.sh`, `team` runs `scripts/team-smoke.sh`) |
| `make reload` | `docker compose restart litellm`, after editing `proxy/config.yaml` |
| `make gitea-bootstrap` | `./scripts/bootstrap-gitea.sh`: admin user + API token into `.env` (`--rotate` via the script directly) |
| `make team-bootstrap` | `./scripts/bootstrap-team.sh`: Gitea users + tokens for the agents, org `TEAM_GITEA_ORG` with team `agents`, runner token, fixture repo `<org>/demo-calc` with CI and branch protection (idempotent; migrates an older bootstrap: re-mints under-scoped tokens, transfers `demo-calc` into the org) |
| `make team-smoke` | `./scripts/team-smoke.sh`: job thread → Dinesh PR → green `ci / test (pull_request)` → Gilfoyle review |
| `make team-model M=<model_name>` | check the name against LiteLLM, set `TEAM_MODEL` in `.env`, recreate the four agents (they re-read their context caps from the registry) |

Scripts you can also call directly: `./scripts/preflight.sh` (backend reachability from inside litellm), `./scripts/check-ports.sh`, `./scripts/buzz-smoke.sh` (mention the bundled agent, expect a reply), `./scripts/team-smoke.sh`.

## Layout

```
open-llm-stack/
├── README.md                    # this file
├── AGENTS.md / CLAUDE.md        # rules for coding agents (CLAUDE.md is `@AGENTS.md`)
├── docker-compose.yml           # all services, profile-gated, one network
├── .env.example                 # every variable, documented; `make init` copies it to .env and fills secrets
├── .gitignore                   # .env, proxy/config.yaml, models/, *.gguf, docker-compose.override.yml
├── Makefile                     # init, up, down, ps, logs, test, reload, gitea-bootstrap, team-bootstrap, team-smoke, team-model
├── docs/spec.md                 # binding architecture spec: image tags, env vars, verified per-layer facts, gates
├── plans/                       # implementation plans 01–08, each ending in its execution report with real output
├── proxy/
│   ├── config.yaml.example      # committed LiteLLM model registry sample
│   └── config.yaml              # gitignored, the live registry (`make init` copies it)
├── agents/                      # team personas: TEAM.md (shared norms), dinesh/gilfoyle/jared/erlich.md, jared-heartbeat.md
│   └── ci-python.yaml           # the one Python CI workflow; bootstrap copies it into demo-calc, Dinesh into repos he creates
├── runner/config.yaml           # Gitea Actions runner config (label python, host network)
├── scripts/
│   ├── init.sh                  # .env + secrets + proxy/config.yaml, idempotent
│   ├── check-ports.sh           # refuses `make up` when 3000–3003 are held by something else
│   ├── preflight.sh             # LLM_BASE_URL reachable from inside litellm?
│   ├── smoke-test.sh            # per-layer gates, skips layers whose profile is off
│   ├── bootstrap-gitea.sh       # admin user + API token, idempotent
│   ├── buzz-smoke.sh            # CLI round trip: mention the agent, expect a reply
│   ├── bootstrap-team.sh        # agents' Gitea users + tokens, org TEAM_GITEA_ORG + team, runner token, fixture repo demo-calc, idempotent
│   ├── team-entrypoint.sh       # shared team-agent entrypoint: guards, git credentials, prompt assembly, context caps from LiteLLM
│   └── team-smoke.sh            # job thread → Dinesh PR → green CI → Gilfoyle review
└── models/                      # you create it; gitignored; GGUF files for the llamacpp profile
```

`docs/spec.md` is the source of truth for every tag, variable and verified fact; if this README and the spec disagree, the spec wins.

## Credits / upstream

- [LiteLLM](https://github.com/BerriAI/litellm) — OpenAI-compatible gateway and model registry.
- [Open WebUI](https://github.com/open-webui/open-webui) — chat UI.
- [Buzz](https://github.com/block/buzz) (Apache-2.0) — relay, desktop app, `buzz` CLI, `buzz-acp`/`buzz-agent` (the `buzz-sprig` image).
- [Gitea](https://gitea.com) — git hosting.
- [Ollama](https://github.com/ollama/ollama) and [llama.cpp](https://github.com/ggml-org/llama.cpp) — optional bundled backends.
- [MinIO](https://github.com/minio/minio) — S3-compatible media store behind the relay.
- Postgres and Redis, as pinned in `docker-compose.yml`.

## License

Apache-2.0. See `LICENSE`. The bundled services keep their own licenses (Buzz is Apache-2.0; LiteLLM, Open WebUI, Gitea, Ollama, llama.cpp and MinIO under their respective terms).
