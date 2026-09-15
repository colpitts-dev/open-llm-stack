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

Every chat model carries the **context contract** (plan 14), the same for every backend:

```
context_window     the physical window PER SLOT the backend is configured for (a declaration, proved by make context-probe)
max_output_tokens  the output budget: 32768 for reasoning models, thinking counts as output
max_input_tokens = context_window − max_output_tokens − margin,     margin = max(context_window / 4, 8192)
```

The 25% margin covers the agents' own token estimate (measured 23% under the real count on this host) plus template and tool scaffolding. Ollama entries mirror the window as `litellm_params.num_ctx` (LiteLLM forwards it per request, so the backend runs exactly that window) and carry `keep_alive: "5m"` (the GPU empties five minutes after the last call). For llama.cpp, vLLM or any other server the window is a server flag; declare it here and prove it.

| `context_window` | `max_output_tokens` | margin | `max_input_tokens` |
|---|---|---|---|
| 262144 | 32768 | 65536 | 163840 |
| 131072 | 32768 | 32768 | 65536 |
| 65536 | 16384 | 16384 | 32768 |
| 32768 | 4096 | 8192 | 20480 |

After every registry edit: `make reload && make context-probe` (fails on a window the backend does not honour) and `make test` (fails on the arithmetic). Never raise a window by hand: `make model-fit M=<tag>` on Ollama, or the server's flags plus the probe. If the bundled Buzz agent uses a model, keep `BUZZ_AGENT_MAX_CONTEXT_TOKENS` in `.env` equal to that model's `max_input_tokens`. The team agents need no such variable: they read both caps for `TEAM_MODEL` from LiteLLM's registry when they start.

## GPU budget

One 32 GB GPU, three properties for every backend: no response is ever truncated (prompt or output), the model never spills off the GPU, and the card draws nothing beyond its display floor when no job runs. The registry declares the contract; the backend is configured to honour it; `make context-probe` proves it black-box through LiteLLM; `make context-report` shows what real prompts look like against the caps. Measured on the reference host (RTX 5090, 2026-09-14) before this: 34 prompts silently cut at a 131072 window while the agent's own estimate stayed under its cap, 7 completions cut at 16384 output tokens, a 262144 window kept resident for a p95 prompt of 93 k tokens, and the model never leaving VRAM (80 W idle instead of 45 W) because a heartbeat refreshed `keep_alive` every 30 min.

**Any backend.** Write the budget down and re-measure it when anything changes: weights + KV × slots + checkpoints + compute + display + headroom. Size the window to the p95 of real prompts (`make context-report`) plus the output budget, never to the model's architectural maximum. Then:

```bash
make context-probe                # every registered chat model: prompts at 50% and 100% of max_input_tokens and at max_input + max_output − 128 must come back whole
make context-probe M=ornith-max   # one model; FULL=1 also generates max_output_tokens once (slow)
make context-report               # per model, last 7 days: p50/p95/max prompt, max completion, over_in (prompts above the cap), at_out (completions at the cap)
```

`over_in > 0` means the margin is too small for that model's tokenizer; `at_out > 0` means the output budget is (or the model loops in thought: lower its temperature or disable thinking before raising the cap). A probe run adds one `over_in` per model on purpose (its third prompt is above the cap), so judge real work over its own interval: `SINCE="2 hours" make context-report`.

**Ollama** (host container or the bundled `ollama` profile). Slots and residency are container variables, the window is per request:

```bash
# host Ollama on the reference host (outside this repo); the bundled profile reads the same names from .env
docker run -d --name ollama --restart unless-stopped --gpus all -p 0.0.0.0:11434:11434 -v ollama:/root/.ollama \
  -e OLLAMA_HOST=0.0.0.0:11434 -e OLLAMA_NUM_PARALLEL=3 -e OLLAMA_MAX_LOADED_MODELS=2 \
  -e OLLAMA_FLASH_ATTENTION=1 -e OLLAMA_KV_CACHE_TYPE=q8_0 -e OLLAMA_KEEP_ALIVE=5m ollama/ollama:0.34.0
make model-fit M=ornith-max       # loads the model at candidate windows (largest first, capped by MAX_WINDOW=131072), keeps the largest fully on the GPU within budget, prints the registry block
```

Ollama runs the model at `num_ctx × OLLAMA_NUM_PARALLEL` and, with the variable set explicitly, does not shrink an oversized window to fit: it spills to the CPU instead (`size_vram < size` in `/api/ps`), which `model-fit` reports as `spills to CPU`. Found 2026-09-14 on Ollama 0.33.3: **the qwen3.5 family (`qwen35`, `qwen35moe`) gets one slot regardless** (`model architecture does not currently support parallel requests`), so every model in the shipped registry runs `-np 1`; `OLLAMA_NUM_PARALLEL=3` costs nothing there and applies to architectures that support it. Anything that calls Ollama without LiteLLM gets the tag's own default window (262144 on the `*-max` tags) and forces a runner reload each way; recreate the tags with `PARAMETER num_ctx 131072` if that matters to you.

**llama.cpp.** `-c` is the total: `LLAMACPP_CTX_SIZE = context_window × slots`, plus `-np <slots>`, `--no-context-shift` (an overflow is an HTTP 400, never a silent cut), `-ctk q8_0 -ctv q8_0`, `-fa on`. One model per process, no idle unload: stop the container to free the GPU. Register as `openai/<name>` with `context_window` = the per-slot value, then `make context-probe`.

**vLLM.** `--max-model-len <context_window>`, `--max-num-seqs <slots>`, `--gpu-memory-utilization` as the OOM guard. Register as `openai/<name>`, probe.

**Same repo, another backend.** Develop against a local Ollama, deploy against an intranet OpenAI-compatible server by `.env` and the registry alone: set `LLM_BASE_URL` (and `LLM_API_KEY` if the server wants one), turn each entry from `ollama_chat/<tag>` into `openai/<name>` + `api_base: <server>/v1` + `api_key: os.environ/LLM_API_KEY` with the same `model_name` (personas and `TEAM_MODEL` do not change), `context_window` from that server's flags, the embedding entry as `openai/<name>` with `mode: embedding`; then `make reload && make context-probe && make team-model M=<name> && make test`. The probe proves the window on the new server; `make team-smoke` is the behavioural acceptance test there (tool-call and thinking parsers differ per server; fix persona misses in the server's template flags, never in personas).

**Idle.** Jared's heartbeat is off by default (`TEAM_HEARTBEAT_SECONDS=0`): one tick is up to 12 shell commands, each a full-prefill LLM call, every interval, and each call refreshes `keep_alive`. Set it to `7200` when you want proactive triage, then `docker compose up -d jared`.

**Power cap** (opt-in, host setting, lost at reboot). Bursts reach 570 W in prefill; the card's floor is 400 W. Measured: decode on `ornith-max` is 253.6 tok/s at 450 W and 250.3 tok/s at 600 W, so the cap is free on decode:

```bash
sudo nvidia-smi -pl 450          # bursts capped at 450 W (this card: min 400, max 600); lost at reboot
# persist: /etc/systemd/system/nvidia-power-limit.service
# [Unit]\nDescription=GPU power limit\nAfter=nvidia-persistenced.service\n[Service]\nType=oneshot\nExecStart=/usr/bin/nvidia-smi -pl 450\n[Install]\nWantedBy=multi-user.target
```

## What local inference costs

Local models are not free: the card draws 470–570 W in prefill, about 80 W with a model resident, 45 W empty, and the gateway's spend log says `$0.00`. Plan 15 meters the energy and prices it with your tariff. Four lines in `.env`:

```
POWER_COST_PER_KWH=18.13       # cents per kWh; blank = accounting off
POWER_PROBES=nvml              # nvml = every NVIDIA card; add hwmon:<sensor> for a PSU with telemetry (whole machine); APU: hwmon:amdgpu:power1=soc
POWER_SCOPE=gpu                # what is attributed to calls: gpu | soc | host
POWER_HOST_OVERHEAD=100        # watts the rest of the box draws; ignored while a host-scope probe runs
```

**Meter** (host process, one row per second per domain, into the bundled `litellm-db`):

```bash
make power-meter                 # foreground; Ctrl-C to stop. Probes from POWER_PROBES
# as a user service:
# ~/.config/systemd/user/stack-power-meter.service
# [Unit]\nDescription=open-llm-stack energy meter\nAfter=docker.service
# [Service]\nExecStart=/usr/bin/make -C /home/adam/code/open-llm-stack power-meter\nRestart=on-failure
# [Install]\nWantedBy=default.target
# systemctl --user enable --now stack-power-meter
# a second inference host, nothing installed there (clocks in sync: NTP):
ssh gpu2 python3 - --probes nvml < scripts/power-meter.py | make power-ingest
```

The NVIDIA probe reads the card's own energy counter (a millijoule integral, exact whatever the load did between reads). A PSU with hwmon telemetry (Corsair HX/RM-i: `hwmon:corsairpsu`) gives the whole machine at 1 Hz; without one, `POWER_HOST_OVERHEAD` is a typed constant (read it once at a plug or UPS: whole box minus GPU idle). An APU (Strix Halo) has no separable GPU: meter the package (`hwmon:amdgpu:power1=soc` where the driver exposes it, or a RAPL probe, not built yet: `/sys/class/powercap/*/energy_uj` is root-only on stock kernels) and set `POWER_SCOPE=soc`.

**Report:**

```bash
make cost-report SINCE="24 hours"
# == TOTAL: measured = the scope's counters; host = the whole machine; cost = host x tariff; idle = measured - calls
#  measured_kwh | host_kwh | host_kwh_is | cost | calls_kwh | idle_kwh | avg_w | seconds
#  ...then per model (wh_per_1k_tok), per client (gateway key alias), per domain (every probe)
```

`measured_kwh` is the GPU's counter (±5%); `host_kwh` is measured at the PSU or estimated as measured + overhead, and the report says which. Idle energy (a model kept warm, the display floor) is printed beside the calls' energy and charged to nobody. The sentence for a client: "measured at the GPU's energy counter, attributed to your calls; the whole-machine figure is measured at the PSU / an estimate".

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

Profiles `team` and `gitea-runner` turn the single bundled agent into a small development team that delivers **validated pull requests in Gitea**. Each agent is its own container from the sprig image (same harness as `buzz-agent`, host network, own volume at `/home/agent`, prompt = the shared `agents/TEAM.md` + its role's duties in `agents/roles/<role>.md` + its persona in `teams/<team>/personas/<name>.md`), talks to one model through LiteLLM, and obeys the pubkeys in `TEAM_ALLOWLIST` plus its teammates (agent-to-agent mentions such as Dinesh asking Gilfoyle for a review are otherwise dropped). Validated end to end on the reference host on 2026-09-13; the verified facts are in `docs/spec.md` §5.8. Since plan 16 the team is **data**: members, roles, titles, runtimes and the model live in `teams/<team>/team.toml`, and `make team-render` turns that file into the Compose services (`teams/<team>/compose.yml`, generated, never edited by hand). The default team `piedpiper` is:

| Agent | Role | Answers in | What it does |
|---|---|---|---|
| **Dinesh** | builder | threads | clones from Gitea (or, for a new project, creates the repository in the team org with CI and branch protection), branches `agent/<slug>`, pushes and lets CI run the tests (the image has no Python), opens the PR through the API, posts the URL, @mentions you and asks Gilfoyle for a review; reads the PR's commit status and fixes on the same branch |
| **Monica** | UI designer | threads | a second builder for user-facing work: layout, styling, states, accessibility; delivers PRs like Dinesh, does not touch game logic or tests; persona condensed from the VoltAgent `ui-designer` subagent |
| **Gilfoyle** | reviewer | threads | read-only: fetches the PR diff, posts a review in Gitea (approve / request changes / comment) and in the thread. Never edits, never opens PRs |
| **Jared** | coordinator and judge | channels; heartbeat every `TEAM_HEARTBEAT_SECONDS` (1800) | triages Gitea issues, hands ready work to Dinesh, posts status in a channel named `triage`; scores every PR after CI and the review: `complexity/1..5` and `confidence/low\|medium\|high` labels, a breakdown comment in Gitea, one `**Score:**` line in the thread (plan 13); never builds or reviews |
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

**Giving Dinesh a job.** In the Buzz app, create a project channel, add Dinesh, Gilfoyle and Jared as members by pubkey (`TEAM_DINESH_PUBKEY`, `TEAM_GILFOYLE_PUBKEY`, `TEAM_JARED_PUBKEY` in `.env`, role bot; Jared scores the PR, and a message that names him does not even send unless he is a member), then start a thread mentioning Dinesh with the request and the repository name:

```
@Dinesh in the repository demo-calc, add a function subtract(a, b) that returns a - b, with a test, and open a pull request.
```

Expect, in that thread: `picked up: <plan>`, then the PR URL with what changed and the CI state (Dinesh reads the PR's commit status; CI is where the tests run), then Dinesh's own `@Gilfoyle review please <url>`, then Gilfoyle's verdict, which lands as a Gitea review (`APPROVED`, `REQUEST_CHANGES` or `COMMENT`) and in the thread. You can also ask Gilfoyle yourself with the same sentence. When the `ci / test (pull_request)` check is green and the review is an approval, log in at http://127.0.0.1:3003 as `TEAM_HUMAN_USER` (password `TEAM_HUMAN_PASSWORD` in `.env`; the admin `GITEA_ADMIN_USER` works too) and merge in Gitea as `GITEA_ADMIN_USER`. Merging stays with a human, and Gitea enforces it: the branch protection blocks direct pushes to `main` and whitelists only `GITEA_ADMIN_USER` for merges, because the agents' team write permission plus Gilfoyle's own approval would otherwise let an agent merge (Gilfoyle once told a thread a PR was "approved and merged"; it was not, but Gitea would have allowed it). Re-running `make team-bootstrap` adds the merge whitelist to a protection created by an older bootstrap. If CI fails or Gilfoyle requests changes, Dinesh fixes on the same branch and reports in the same thread; nudge him there if he does not.

A request for a new project works the same way: `@Dinesh create a repository named wordcount with a function count_words(text) and a test, and open a pull request.` Dinesh creates `wordcount` in the org through the API (a member of the `agents` team may create repos there, and only there), puts the CI workflow (`agents/ci-python.yaml`, mounted into his container) and a `pyproject.toml` in his first commit so Laurie can run the tests, opens the PR, and then protects `main` with the same rule the bootstrap uses (CI check plus one approval, no direct push, merge only by `GITEA_ADMIN_USER`). Measured on the reference host: `@Dinesh create a repository named hello-py with a Python package, a pytest test, CI, and open a pull request` gave `piedpiper/hello-py` with the workflow, `pyproject.toml`, package and test in the first commit, PR #1 open after ~50 s, CI green, branch protection set by Dinesh, and Gilfoyle's `APPROVED` ~40 s after the review request.

Jared and Erlich live in channels rather than threads: add Jared to a channel named `triage` (he posts status there on his heartbeat when `TEAM_HEARTBEAT_SECONDS` is set; off by default since plan 14, see "GPU budget"; `docker compose up -d jared` after changing it) and Erlich to `#general`.

Prove the loop with `make team-smoke` (also run by `make test` when the profile is on): the throwaway smoke identity creates a job channel, adds Dinesh and Gilfoyle, asks for a `subtract_<n>` function in `demo-calc`, waits for a new PR by `dinesh` (numbered above any earlier one; up to 15 min), for its `ci / test (pull_request)` status to be `success` (up to 10 min), then asks Gilfoyle for a review and waits for a submitted (non-pending) one (up to 10 min). It ends with `TEAM SMOKE PASS: PR #<n>, CI success, review <state>`. Measured on the reference host with `ornith-max`, Jared's heartbeat running on the same GPU slot: PR opened 70 s after the mention (10–20 s with the GPU idle), CI green ~25 s after the push, `APPROVED` review ~30 s after the request, 96 s in total. Merge that PR in Gitea yourself. If it fails at "no PR", read `docker compose logs dinesh`; a single silent turn can be re-driven by mentioning Dinesh once more in the same thread.

**Following a job.** The thread carries, from the builder itself, `picked up: <plan>`, then `🚩 pushed <branch> (<n> files) — opening the PR, CI running`, then the deliverable `**PR:** <url>` (the only kind of message that @mentions you), then `🚩 CI success|failure on <sha7>`; Gilfoyle answers with `**Review:** APPROVED|REQUEST_CHANGES|COMMENT — <one line>`. Bold labels and @mentions appear on deliverables only, the flag only on the two milestones, so a thread scans at a glance. To watch more, set `TEAM_NARRATE=tools` (every state-changing shell command the agent runs, as a fenced `$ …` reply: `git push`, API writes, the factory) or `TEAM_NARRATE=both` (also the model's narration between commands, as `› …` lines, minus the final answer it posts anyway), then `docker compose up -d dinesh gilfoyle monica`. Off is the default: a job adds two messages, nothing else. Jared and Erlich never mirror (their turns have no thread). The mirror is `scripts/team-narrate.sh`, fed by the harness log inside the container; when on, the harness logs ACP wire frames at debug (~10× volume, rotated at 20 MB × 3 per agent).

**The pipeline (plan 16.5).** A job runs through six seats with independent checks. You ask Gilfoyle in a project channel; he answers with `**Plan:**` (intent, files, tests, a 3–6 line acceptance checklist) and waits. Reply `approved` in that thread (any human may; anything else is a change request). He files the checklist as a spec issue, builds, and opens the PR (`Spec: #n` on the first line) mentioning Jared. Jared routes: Dinesh reviews and posts `**Conformance:** m/n` against the checklist; Jared posts only the PR URL in the private `#attack` channel, where Monica attacks blind (she cannot read issues and is not in your channel) and files defects as a PR review plus a `defect/*` label; critical or high defects go back to Gilfoyle, otherwise Jared asks Erlich in the private `#gate` channel. Erlich runs `gate-signals` (CI, official approval, conformance m = n, attack done, no critical/high defect, spec linked) and `gate-post` records the `**Verdict:** ship|no-ship`, the `**Score:**` (plan 13 rubric) and a ledger issue in `erlich/gate`, which Gilfoyle, Dinesh and Monica cannot see. Jared relays open items to Gilfoyle, or `ready to merge` to you. The verdict is advisory: `main` still needs CI, Dinesh's approval and your merge. `make team-bootstrap` creates the two channels (ids in `.env`), the ledger repository and the `defect/*` labels; recreate the team afterwards so the coordinator learns the channel ids.

**Runtimes.** The harness speaks ACP to the runtime that owns the model loop. Default is `buzz-agent` (inside the sprig image). Dinesh can run on **goose** instead: `make goose-image` (builds `open-llm-stack/goose-agent:1.50.0` from a pinned Debian digest and the pinned goose release; the one build in this repository, needs the download and `apt-get`), then `make member-runtime N=dinesh R=goose` (sets `runtime = "goose"` on his block in `team.toml`, re-renders, force-recreates `dinesh`; `make dinesh-runtime R=goose` is the plan 12 alias); `make member-runtime N=dinesh R=buzz-agent` switches back. The runtime is per member: any builder, reviewer or coordinator can run on goose while the rest stay on buzz-agent. Same persona, same LiteLLM model (`TEAM_MODEL`), same thread conventions and mirror. What changes: goose brings its own shell and file-editing tools and its own context management; its shell sees the container environment (the Gitea token included), whereas buzz-agent's shell is scrubbed; there is no reply guard on goose. Numbers from the first comparison are in `plans/12-goose-runtime.md` §7. Closed-weight runtimes (Claude Code's `claude-agent-acp`) are not wired: they would need an API key or subscription and are never a default here.

**Switching the model.** `model` in `team.toml` is the only knob (`make team-model` edits it and copies it into `TEAM_MODEL` in `.env` for the scripts that read only `.env`): each agent reads `max_input_tokens`/`max_output_tokens` for it from LiteLLM's registry at start (logged as `model=<name> context=<in> output=<out>`), so there is no context variable to keep in sync. A member may also set its own `model = "…"` in its block.

```bash
make team-model M=qwen3.8-max    # checks the name against /v1/models, sets model in team.toml, re-renders, recreates every member
docker compose logs --since 2m dinesh | grep model=    # model=qwen3.8-max context=106496 output=16384
make team-model M=nope-model     # prints "not registered in proxy/config.yaml"; make exits 2
```

Measured 2026-09-13: `ornith-max`, `qwen3.8-max` and `laguna-max` publish multi-step results; `qwen3.6-max` does not, so it is a poor choice for the team. On `qwen3.8-max` Dinesh answered a mention in ~20 s. The agents plus CI share one GPU slot on the host Ollama by queueing (Ollama 0.33.3 gives the qwen3.5 family a single slot whatever `OLLAMA_NUM_PARALLEL` says, see "GPU budget"); throughout the smoke run `docker exec ollama ollama ps` showed `100% GPU`.

**Adding a member.** A member is a block in `teams/piedpiper/team.toml` plus a persona file; everything else is derived:

```bash
make member-add N=bertram R=builder TITLE="backend builder"   # appends the block, stubs teams/piedpiper/personas/bertram.md, renders,
                                                              # creates the forge user bertram (full_name "Bertram (AI builder)"), token, team
                                                              # membership and LiteLLM key, starts the service
make team-status                                              # members, roles, logins, container state
```

Then edit the persona (voice, specialities, what the member never does; the duties come from the role file, do not repeat them) and add the new pubkey to your project channels: `buzz channels add-member --pubkey $TEAM_BERTRAM_PUBKEY --role bot` (members are not added to channels automatically). Roles are the closed list `builder`, `reviewer`, `coordinator`, `assistant` in `agents/roles/`, each mapped to a Gitea team; `TITLE` only changes how the roster introduces the member. Names are `[a-z][a-z0-9-]{1,30}`: the name is the service, the volume, the forge login and the `TEAM_<NAME>_*` prefix in `.env`. If your forge already has a person with that login, set `AGENT_LOGIN_SUFFIX=-ai` in `.env` and re-render: every agent then logs in as `<name>-ai`, and the bootstrap refuses to adopt a login that is not one of its own machine users. `make member-rm N=bertram` stops the service and removes the block and the forge team memberships (keys stay in `.env`); `PURGE=1` also deletes the forge user and the volume.

**Your own team.** `make team-new T=<name> FROM=<preset>` copies a preset into `teams/<name>/`, sets `TEAM_NAME` in `.env` and renders it; then edit `team.toml` and the personas, `make up && make team-bootstrap`. Presets in `teams/_presets/`: `dev-squad` (the default five roles), `solo-builder` (one builder, one coordinator; reviews come from you, so a person satisfies the one required approval), `review-board` (two reviewers and a coordinator, no builder: a team that reviews human pull requests; `make team-smoke` does not apply) and `content-studio` (a writer and a designer as builders, an editor as reviewer, a coordinator). Presets use their own name pool (`ada`, `grace`, `linus`, `margaret`, `edsger`, `barbara`), so a second workforce on the same forge never collides with `piedpiper`'s logins. One team is active per deployment; the previous team's files stay in `teams/`.

**Using your own Gitea.** The same scripts drive an instance you already run (on the LAN behind a private CA, or on the internet with a public certificate). Switch with `.env` only, after `make down`:

```bash
COMPOSE_PROFILES=litellm,openwebui,buzz,buzz-agent,team      # no gitea, no gitea-runner: the bundled runner must never register against your instance
GITEA_PUBLIC_URL=https://git.example.com
GITEA_ADMIN_USER=<your admin login>                          # owner of the token below
GITEA_ADMIN_TOKEN=<token with write:admin,write:organization,write:repository,write:user>   # Settings -> Applications on your Gitea
GITEA_CA_FILE=/usr/local/share/ca-certificates/<your-ca>.crt # private CA only; blank for a public certificate
TEAM_CI_LABEL=ci                                             # the runs-on label your runner registered
TEAM_HUMAN_USER=<your login>                                 # existing account: becomes org owner and may merge
TEAM_DINESH_GITEA_TOKEN= TEAM_GILFOYLE_GITEA_TOKEN= TEAM_JARED_GITEA_TOKEN= TEAM_MONICA_GITEA_TOKEN=   # blank: tokens are per instance, the bootstrap mints new ones
AGENT_LOGIN_SUFFIX=-ai                                       # when your instance already has people named dinesh, gilfoyle, jared or monica
```

Then `make up && make team-bootstrap` (twice is fine; it prints what it created). Re-running `make team-bootstrap` is the backstop: it protects every repo in the org and strips any agent that is still a repo admin. Prerequisites: this host trusts your instance's certificate (for a private CA, install its root in the OS store; `GITEA_CA_FILE` is what the agent containers get), and your runner's job image has `git`, `python3` and `venv` (the generated workflow installs into a venv because Debian images refuse system pip installs). What lands on your instance: three machine users (`dinesh`, `gilfoyle`, `jared`), a private org `TEAM_GITEA_ORG` with an `agents` team (write, may create repos), the fixture `demo-calc` with its workflow, and branch protection on `main` (required check, one approval, merge restricted to the admin and you). The admin token stays on this host in `.env`; delete it on your Gitea when you no longer need to re-run the bootstrap. To revoke the agents, delete their three tokens there. Inside a CI job your Gitea is reached through your runner's internal URL, which the workflow gets from the runner, so nothing in the template names your host. Keep a copy of each mode's env (`.env.bundled`, `.env.forge`; gitignored) to switch back and forth.

One thing to record in your instance's own decision log: on a pull_request event the runner executes the workflow file from the PR branch before anyone reviews it, so an agent can change CI in its own PR. Your runner's isolation is what bounds that.

**New repositories.** Agents never create repositories by hand. Dinesh runs `/opt/team/agents/bin/new-repo <name>`, which generates the repo from the org's `python-template` (private, CI workflow, protected `main` with the merge whitelist and admin-override blocked) and then removes his own admin rights, so every repo an agent creates is born governed and the agent keeps only the team's write access. The template is built by `make team-bootstrap` from `agents/template/` and `agents/ci-python.yaml`; edit those and re-run the bootstrap to change what new repos look like. Roles are enforced by Gitea teams, not by personas: `builders` (Dinesh, Monica) may push and create repos, `reviewers` (Gilfoyle) may only review and comment, `coordinators` (Jared) may only triage issues. `make test` proves the factory without an LLM (`test_team_factory`).

**Limits, honestly.**

- The reply guard (`BUZZ_AGENT_REQUIRE_REPLY=1`, at most two rerolls) is advisory: a turn can still end in text nobody sees. Re-mention once before calling it a failure. With `TEAM_NARRATE=both` that text is visible as `›` lines in the thread.
- The agents' shell tool starts with an empty environment (`HOME` and `PATH` only; the harness scrubs it and has no passthrough flag). Git clone/push still work because credentials are in the file-based store, and the entrypoint writes `~/.gitea.env` for the roles with a token; the personas source it per API call (`. ~/.gitea.env && curl …`). If you edit a role in `agents/roles/` or a persona in `teams/<team>/personas/`, you may write `$GITEA_URL`, `$GITEA_OWNER` and `$GITEA_ADMIN` bare (substituted into the prompt at container start), but `$GITEA_TOKEN` only after `. ~/.gitea.env` in the same command. Erlich has no env file.
- Agents can misreport. Gilfoyle once announced a merge that had not happened, and Dinesh once posted an `https://` link to the plain-http Gitea. The team norms now say never claim a merge (Gitea's merge whitelist makes one impossible for an agent anyway) and post links exactly as the API's `html_url` returns them; check the PR page in Gitea rather than trusting the thread.
- One model for the whole team by default (`model` in `team.toml`; a member may override it in its block). A local model does not know its own name (on `qwen3.8-max` Dinesh said it was "Claude"): read `TEAM_MODEL` or the `model=` log line, never ask the agent.
- Shell quoting trips the models: backticks or `--` inside a command string got mangled (then self-corrected, costing turns). The team norms tell them to write message bodies and JSON to files with a quoted heredoc; keep that rule if you edit `agents/TEAM.md`.
- Busy channels where several agents talk to each other are unreliable with local 35B-class models (see the `buzz-agent` note in Troubleshooting): keep task channels to one agent plus you, and put jobs in threads.
- No NIP-OA owner attestation for these server-side agents; no CLI mints it. The allowlist is the access control.
- Gitea repositories cannot be attached as Projects in the Buzz desktop app (it only attaches relay-hosted repos), so the PR link is the hand-off, not an in-app view.
- The bundled Gitea is its own database: your account there is the one `make team-bootstrap` creates, and an account on some other Gitea you run does not exist here (nor do the agents there). Pointing the team at an external Gitea is not supported: the bootstrap drives the Gitea CLI through `docker compose exec`, the runner would need that instance's trust and CA, and the agents would be creating orgs and repos on it.
- Never point the bundled `gitea-runner` at an external Gitea: it mounts the host docker socket and runs on the host network. External mode drops that profile and uses your instance's own runner.
- The runner mounts `/var/run/docker.sock`: CI jobs are sibling containers with the same trust boundary as your own `docker` command. Only run workflows you would run by hand.

## Console (port 3004)

A host-side window onto the stack's own files and scripts — not a second control plane. Every screen reads what `make stack-status`, `team-status`, `context-report` and `score-report` already read; every action it runs is a make target or a script the terminal has, and it shows you the exact command before running it.

```bash
make console                     # http://127.0.0.1:3004  (host process: it must run make init/up before the stack exists)
```

- **Screens.** Setup (get it running: profiles, `BIND_HOST`, the backend, `make init/up/gitea-bootstrap/team-bootstrap/test`), Overview (services, gateway, power, 24 h tokens and cost, cap alerts, open PRs), Models (the registry vs the gateway's proved windows, `context-probe`, `model-fit`, `reload`, `team-model`), Teams (`team.toml`, members, personas, `member-add`/`member-rm`), Jobs (ask the team, see the PR and its scores, `score-sync`), Runs & logs (why an agent is quiet, milestone-filtered logs, `team-smoke`), Audit (every action, read-only).
- **The drawer.** A bar fixed to the bottom of every screen shows the last command it ran, streams new output live while an action is in flight, and turns green or red on exit.
- **The audit log.** `console/audit.log` (gitignored, append-only): one line per action with who ran it, the exact command, its exit code and how long it took.
- **The rule.** The console never does anything the terminal cannot. Every write shows a diff first; destructive actions (`make down`, `member-rm`, a model unload) need you to type the action's name back.
- **As a user service**, mirroring the meter's:

```bash
# ~/.config/systemd/user/stack-console.service
# [Unit]\nDescription=open-llm-stack console\nAfter=docker.service
# [Service]\nExecStart=/usr/bin/make -C /home/adam/code/open-llm-stack console\nRestart=on-failure
# [Install]\nWantedBy=default.target
# systemctl --user enable --now stack-console
```

Loopback only, today with no login (any process on your machine that can reach 127.0.0.1:3004 can drive it). Exposing it beyond loopback — Gitea OIDC behind TLS at a reverse proxy — waits for a later plan.

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
| `make test` | `./scripts/smoke-test.sh` (chat round-trip on `TEAM_MODEL` only; `SMOKE_CHAT_MODELS=all` for every chat model, one model swap each): one section per profile in `COMPOSE_PROFILES` (litellm, openwebui, buzz, gitea, gitea-runner; `buzz-agent` runs `scripts/buzz-smoke.sh`, `team` runs `scripts/team-smoke.sh`) |
| `make reload` | `docker compose restart litellm`, after editing `proxy/config.yaml` |
| `make gitea-bootstrap` | `./scripts/bootstrap-gitea.sh`: admin user + API token into `.env` (`--rotate` via the script directly) |
| `make team-bootstrap` | `./scripts/bootstrap-team.sh`: Gitea users + tokens for the agents, org `TEAM_GITEA_ORG` with team `agents`, runner token, fixture repo `<org>/demo-calc` with CI and branch protection (idempotent; migrates an older bootstrap: re-mints under-scoped tokens, transfers `demo-calc` into the org) |
| `make team-smoke` | `./scripts/team-smoke.sh`: job thread → Dinesh PR → green `ci / test (pull_request)` → Gilfoyle review |
| `make team-model M=<model_name>` | check the name against LiteLLM, set `model` in `teams/<team>/team.toml`, re-render, recreate every member (they re-read their context caps from the registry) |
| `make team-render [T=<team>]` | `scripts/team-render.py`: `teams/<team>/team.toml` → `teams/<team>/compose.yml` and the `.env` lines every member needs; mints missing member keypairs (plan 16; `make init` runs it) |
| `make litellm-keys` | `scripts/litellm-keys.sh`: one LiteLLM team per agent team, one virtual key per member, Open WebUI and the Buzz agent, into `.env` (plan 16; `make team-bootstrap` runs it) |
| `make team-status` | members, roles, logins and container state from the roster |
| `make member-add N=<name> R=<role> [TITLE="…"]` | append the member to `team.toml`, stub its persona, render, bootstrap its forge user, token, team membership and LiteLLM key, start it |
| `make member-rm N=<name> [PURGE=1]` | stop the service, remove the member from `team.toml` and the forge teams, re-render; `PURGE=1` also deletes the forge user and the volume |
| `make member-runtime N=<name> R=goose\|buzz-agent` | switch one member's runtime in `team.toml`, re-render, force-recreate it (plan 12 knob, per member) |
| `make team-new T=<name> FROM=dev-squad\|solo-builder\|review-board\|content-studio` | start a team from a preset: copy it to `teams/<name>/`, set `TEAM_NAME`, render |
| `make goose-image` | build `open-llm-stack/goose-agent:1.50.0`, the goose runtime image (plan 12; the one build here) |
| `make dinesh-runtime R=goose\|buzz-agent` | plan 12 alias for `make member-runtime N=dinesh R=…` |
| `make score-sync` | outcome labels for scored PRs from their final state in Gitea (plan 13) |
| `make score-report` | complexity counts and the confidence × outcome reliability table |
| `make context-probe [M=<model>] [FULL=1]` | prove every chat model's declared window through the gateway, any backend (plan 14) |
| `make model-fit M=<tag> [OUT=32768] [MAX_WINDOW=131072]` | Ollama: measure a model's window on the live backend, print its registry block |
| `make context-report` | real prompt/completion sizes per model vs the registry caps, from LiteLLM's spend log |
| `make power-meter` | meter energy into `litellm-db`, one row per second per domain, probes from `POWER_PROBES` (plan 15; foreground) |
| `make power-ingest` | meter lines on stdin into `litellm-db` (a second host over ssh) |
| `make cost-report [SINCE="24 hours"]` | kWh the local models burned and what it cost, then per model, client, domain |

Scripts you can also call directly: `./scripts/preflight.sh` (backend reachability from inside litellm), `./scripts/check-ports.sh`, `./scripts/buzz-smoke.sh` (mention the bundled agent, expect a reply), `./scripts/team-smoke.sh`, `scripts/team-roster.py members|role <role>|get <key>` (read `team.toml` from the shell), `scripts/team-render.py --check` (exit 1 when `compose.yml` or `.env` would change).

## Layout

```
open-llm-stack/
├── README.md                    # this file
├── AGENTS.md / CLAUDE.md        # rules for coding agents (CLAUDE.md is `@AGENTS.md`)
├── docker-compose.yml           # all services, profile-gated, one network
├── .env.example                 # every variable, documented; `make init` copies it to .env and fills secrets
├── .gitignore                   # .env, proxy/config.yaml, models/, *.gguf, docker-compose.override.yml
├── Makefile                     # init, up, down, ps, logs, test, reload, gitea-bootstrap, team-bootstrap, team-smoke, team-model, team-render, member-add/rm, team-new
├── docs/spec.md                 # binding architecture spec: image tags, env vars, verified per-layer facts, gates
├── plans/                       # implementation plans 01–08, each ending in its execution report with real output
├── proxy/
│   ├── config.yaml.example      # committed LiteLLM model registry sample
│   └── config.yaml              # gitignored, the live registry (`make init` copies it)
├── agents/                      # what every team shares: TEAM.md (norms), roles/ (builder, reviewer, coordinator, assistant), bin/, template/
│   └── ci-python.yaml           # the one Python CI workflow; bootstrap copies it into demo-calc, the factory into new repos
├── teams/                       # teams as data (plan 16)
│   ├── _base.yml                # the shared service shape every member extends
│   ├── _presets/                # dev-squad, solo-builder, review-board, content-studio: `make team-new T=<name> FROM=<preset>`
│   └── piedpiper/               # the default team: team.toml, personas/<name>.md, compose.yml (generated by make team-render, committed)
├── runner/config.yaml           # Gitea Actions runner config (label python, host network)
├── scripts/
│   ├── init.sh                  # .env + secrets + proxy/config.yaml, idempotent
│   ├── check-ports.sh           # refuses `make up` when 3000–3003 are held by something else
│   ├── preflight.sh             # LLM_BASE_URL reachable from inside litellm?
│   ├── smoke-test.sh            # per-layer gates, skips layers whose profile is off
│   ├── bootstrap-gitea.sh       # admin user + API token, idempotent
│   ├── buzz-smoke.sh            # CLI round trip: mention the agent, expect a reply
│   ├── bootstrap-team.sh        # agents' Gitea users + tokens, org TEAM_GITEA_ORG + team, runner token, fixture repo demo-calc, idempotent
│   ├── team-entrypoint.sh       # shared team-agent entrypoint: guards, git credentials, prompt = TEAM.md + role + persona + roster, context caps from LiteLLM
│   ├── team-smoke.sh            # job thread → builder PR → green CI → reviewer review (members found by role)
│   ├── team-render.py           # team.toml → compose.yml + .env lines (plan 16)
│   ├── team-roster.py           # team.toml for shell scripts: members, role, get, add/rm/set
│   └── litellm-keys.sh          # one LiteLLM virtual key per member and client, into .env
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
