# Plan 01 — Foundation + LiteLLM gateway (port 3000)

**Spec:** `docs/spec.md` (binding; read §1–§4, §5.1, §6, §7 first). **Rules:** `AGENTS.md`.
**Sequence:** 1 of 7. Nothing depends on earlier plans. Plans 02–07 build on the files this plan creates.
**Execute with:** `/execute plans/01-foundation-and-litellm.md`
**No internet needed** except `docker pull` (allowed). Every value below was verified on 2026-09-12; do not "improve" a tag, path, or flag without re-verifying it.

---

## 1. Overview

Create the repository skeleton (`.gitignore`, `.env.example`, `Makefile`, `scripts/`, `proxy/`) and the first layer of `docker-compose.yml`: the `litellm` profile (LiteLLM proxy + its Postgres) published on `${BIND_HOST}:3000`, pointed at a bring-your-own OpenAI-compatible backend via `LLM_BASE_URL`.

**Success criteria:** on this host, from a clean checkout, `make init && make up && make test` passes gates G0, G1, G2, G3, G8 (spec §7) with real output shown, using the Ollama already running at `0.0.0.0:11434`.

**Out of scope (later plans):** Open WebUI (02), Buzz (03, 06), Gitea (04), optional backends (05), the full README (07). Do write the `.env.example` **complete** now (spec §3) so later plans only touch compose/scripts, never the variable list.

---

## 2. Relevant files

| Path | Action | Purpose |
|---|---|---|
| `.gitignore` | modify | keep `examples/`; add secrets/data ignores |
| `.env.example` | create | the complete variable list from spec §3 |
| `Makefile` | create | `init up down ps logs test reload gitea-bootstrap` |
| `scripts/init.sh` | create | idempotent `.env` + secrets + `proxy/config.yaml` |
| `scripts/check-ports.sh` | create | G1 |
| `scripts/preflight.sh` | create | G2 |
| `scripts/smoke-test.sh` | create | G3 now; later plans append sections |
| `proxy/config.yaml.example` | create | model registry sample (spec §6) |
| `docker-compose.yml` | create | `name`, network, `litellm`, `litellm-db` |
| `README.md` | modify | replace the stub with a short quick start (plan 07 writes the full doc) |

---

## 3. Dependencies

- Docker Engine with Compose v2 (host has v5.1.3), `openssl`, `curl`, `jq`, `ss` (iproute2), `python3` on the host.
- Images: `ghcr.io/berriai/litellm:v1.89.7`, `postgres:17.11-alpine` (both already on this host), `ghcr.io/block/buzz:sha-e17cdd9` (already on host; `init.sh` runs its `buzz-admin generate-key`).
- A reachable backend: this host's Ollama at `http://host.docker.internal:11434` (default `LLM_BASE_URL`).

---

## 4. Tasks

### Task 1 — `.gitignore`

File: `.gitignore` (modify; currently contains only `examples/`)

```gitignore
examples/
.env
proxy/config.yaml
docker-compose.override.yml
models/
*.gguf
.DS_Store
```

Acceptance: `git check-ignore -q .env proxy/config.yaml models/x.gguf` exits 0 for each (after `git init`, which this repo already has from the scaffold commit).

### Task 2 — `.env.example`

File: `.env.example` (create). Copy spec §3 **verbatim** (the fenced block, including comments). Every variable in spec §3 must be present, in that order. Blank values stay blank; `init.sh` fills them.

Acceptance: `grep -cE '^[A-Z0-9_]+=' .env.example` prints 33; every variable that `init.sh` fills is a bare `VAR=` line with its comment on the line above (a trailing comment after `=` becomes part of the value and breaks blank-detection — verified during planning); `diff <(grep -oE '^[A-Z0-9_]+=' .env.example | sort) <(awk '/^## 3\. Environment/{f=1} f&&/^```bash/{b=1;next} f&&b&&/^```/{exit} f&&b' docs/spec.md | grep -oE '^[A-Z0-9_]+=' | sort)` prints nothing.

### Task 3 — `scripts/init.sh`

File: `scripts/init.sh` (create, `chmod +x`)

```bash
#!/usr/bin/env bash
# Idempotent first-run setup: .env, secrets, proxy/config.yaml. Never overwrites a non-blank value.
set -euo pipefail
cd "$(dirname "$0")/.."
BUZZ_IMAGE="ghcr.io/block/buzz:sha-e17cdd9"   # its buzz-admin generates Nostr keys; keep in sync with docker-compose.yml

[ -f .env ] || { cp .env.example .env; echo "created .env from .env.example"; }
[ -f proxy/config.yaml ] || { cp proxy/config.yaml.example proxy/config.yaml; echo "created proxy/config.yaml from proxy/config.yaml.example"; }

blank() { grep -qE "^$1=[[:space:]]*(#.*)?$" .env; }   # blank, or blank + trailing comment
set_if_blank() {            # set_if_blank VAR VALUE
  if blank "$1"; then sed -i "s|^$1=.*|$1=$2|" .env; echo "generated $1"; fi
}
hex() { openssl rand -hex "$1"; }

set_if_blank LITELLM_MASTER_KEY "sk-$(hex 24)"
set_if_blank LITELLM_DB_PASSWORD "$(hex 16)"
set_if_blank WEBUI_SECRET_KEY "$(hex 16)"
set_if_blank BUZZ_GIT_HOOK_HMAC_SECRET "$(hex 32)"
set_if_blank BUZZ_DB_PASSWORD "$(hex 16)"
set_if_blank BUZZ_REDIS_PASSWORD "$(hex 16)"
set_if_blank BUZZ_S3_ACCESS_KEY "$(hex 8)"
set_if_blank BUZZ_S3_SECRET_KEY "$(hex 16)"
set_if_blank GITEA_ADMIN_PASSWORD "$(hex 12)"

# Nostr keypairs come from the relay image's own tool -- no host-side nostr dependency.
gen_key() { docker run --rm --entrypoint /usr/local/bin/buzz-admin "$BUZZ_IMAGE" generate-key; }
if blank BUZZ_RELAY_PRIVATE_KEY; then
  out=$(gen_key); set_if_blank BUZZ_RELAY_PRIVATE_KEY "$(awk '/Secret key:/{print $3}' <<<"$out")"
fi
if blank BUZZ_AGENT_PRIVATE_KEY; then
  out=$(gen_key)
  set_if_blank BUZZ_AGENT_PRIVATE_KEY "$(awk '/Secret key:/{print $3}' <<<"$out")"
  set_if_blank BUZZ_AGENT_PUBKEY "$(awk '/Public key:/{print $3}' <<<"$out")"
fi

echo "init complete. Next: check LLM_BASE_URL in .env and the models in proxy/config.yaml, then: make up"
```

Acceptance: run twice from a clean state; first run prints `generated ...` for 12 variables (9 secrets, relay key, agent key, agent pubkey), second run prints only the final line; `grep -E '^[A-Z0-9_]+=[[:space:]]*$' .env` prints exactly `GITEA_ADMIN_TOKEN=` (blank until plan 04); `grep -E '^(BUZZ_RELAY_PRIVATE_KEY|BUZZ_AGENT_PRIVATE_KEY|BUZZ_AGENT_PUBKEY)=' .env | awk -F= '{print length($2)}'` prints `64` three times; `LITELLM_MASTER_KEY` starts with `sk-`.

### Task 4 — `scripts/check-ports.sh`

File: `scripts/check-ports.sh` (create, `chmod +x`)

```bash
#!/usr/bin/env bash
# G1: refuse to start when one of our ports is held by something that is not this stack.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a
ports=("${LITELLM_PORT:-3000}" "${OPENWEBUI_PORT:-3001}" "${BUZZ_PORT:-3002}" "${GITEA_PORT:-3003}")
ours=$(docker ps --filter label=com.docker.compose.project=open-llm-stack --format '{{.Ports}}' 2>/dev/null || true)
rc=0
for p in "${ports[@]}"; do
  if ss -Htln | awk '{print $4}' | grep -qE "[:.]${p}$"; then
    if grep -qE ":${p}->" <<<"$ours"; then
      echo "port ${p}: in use by this stack (ok)"
    else
      echo "port ${p}: BUSY -- $(ss -Htlnp 2>/dev/null | grep -E "[:.]${p} " | head -1)"; rc=1
    fi
  fi
done
[ $rc -eq 0 ] || { echo "Free the ports above (or change *_PORT in .env) and re-run make up." >&2; exit 1; }
echo "ports ok"
```

Acceptance: with the stack down and nothing on 3000–3003 → prints `ports ok`, exit 0. Start `python3 -m http.server 3003 --bind 127.0.0.1 &` → prints `port 3003: BUSY -- ...`, exit 1; kill it. With the stack up → each running port reports `(ok)`.

### Task 5 — `scripts/preflight.sh`

File: `scripts/preflight.sh` (create, `chmod +x`). Runs **inside** the litellm container (reachability from the host proves nothing).

```bash
#!/usr/bin/env bash
# G2: is LLM_BASE_URL reachable from INSIDE the litellm container?
set -euo pipefail
cd "$(dirname "$0")/.."
if ! docker compose ps --status running litellm 2>/dev/null | grep -q litellm; then
  echo "preflight: litellm is not running (profile off or not started) -- skipping"; exit 0
fi
docker compose exec -T litellm python3 - <<'PY'
import os, urllib.request, sys
base = os.environ["LLM_BASE_URL"].rstrip("/")
last = None
for path in ("/v1/models", "/api/tags"):
    try:
        urllib.request.urlopen(base + path, timeout=5)
        print(f"OK  backend reachable at {base}{path}")
        sys.exit(0)
    except Exception as e:
        last = e
print(f"FAIL {base} unreachable from inside the litellm container: {last}")
print("""
Which case are you in?
  1. Backend is a container      -> put it on the 'open-llm-stack' network and use http://<container>:<port>,
                                    or use the bundled profile: COMPOSE_PROFILES=...,ollama + LLM_BASE_URL=http://ollama:11434
  2. Host process bound to 0.0.0.0 -> http://host.docker.internal:<port> (extra_hosts is already set on litellm)
  3. Host process bound to 127.0.0.1 only -> host.docker.internal resolves to the Docker bridge gateway, never loopback,
     so this cannot be reached. Bind the backend to the docker0 bridge address (see `ip addr show docker0`)
     or use case 1. Do NOT bind an unauthenticated inference server to 0.0.0.0 on a LAN you do not trust.
""")
sys.exit(1)
PY
```

Acceptance: with the default `LLM_BASE_URL` and this host's Ollama → `OK  backend reachable at http://host.docker.internal:11434/v1/models`, exit 0. With `LLM_BASE_URL=http://127.0.0.1:59999` (edit `.env`, `docker compose up -d litellm` to re-render env) → the `FAIL` block, exit 1. Restore the value afterwards and re-create litellm.

### Task 6 — `proxy/config.yaml.example`

File: `proxy/config.yaml.example` (create)

```yaml
# proxy/config.yaml.example -- copy to proxy/config.yaml (gitignored; `make init` does this) and edit
# to match the models YOUR backend actually serves. This sample registers the tags present on the
# project's reference host (Ollama). THE REGISTRY IS HAND-MAINTAINED: nothing discovers models.
#
# max_input_tokens = physical_window - max_output_tokens - 8192   (template/tool scaffolding)
# The physical window (num_ctx in Ollama, -c in llama.cpp) is set at the BACKEND, not here, and is
# not enforced anywhere: exceed it and the backend silently drops the oldest tokens.
#
# Prefixes: ollama_chat/<tag> for Ollama chat models (applies the model's chat template; plain
# ollama/ degrades tool calling); ollama/<tag> for Ollama embeddings; openai/<name> + api_base for
# llama.cpp / vLLM / any OpenAI-compatible server. Never register a closed-weight model or a router.
# Adding a model = edit this file + `make reload`.

model_list:
  - model_name: qwen3.6-max
    litellm_params:
      model: ollama_chat/qwen3.6-max
      api_base: os.environ/LLM_BASE_URL
    model_info:
      mode: chat
      max_input_tokens: 237568        # 262144 - 16384 - 8192
      max_output_tokens: 16384
      supports_vision: true
      model_revision: "ollama:qwen3.6-max:2026-09-12"
      execution_locus: local

  - model_name: ornith-max
    litellm_params:
      model: ollama_chat/ornith-max
      api_base: os.environ/LLM_BASE_URL
    model_info:
      mode: chat
      max_input_tokens: 237568
      max_output_tokens: 16384
      model_revision: "ollama:ornith-max:2026-09-12"
      execution_locus: local

  - model_name: laguna-max
    litellm_params:
      model: ollama_chat/laguna-max
      api_base: os.environ/LLM_BASE_URL
    model_info:
      mode: chat
      max_input_tokens: 237568
      max_output_tokens: 16384
      model_revision: "ollama:laguna-max:2026-09-12"
      execution_locus: local

  - model_name: qwen3.8-max
    litellm_params:
      model: ollama_chat/qwen3.8-max
      api_base: os.environ/LLM_BASE_URL
    model_info:
      mode: chat
      max_input_tokens: 106496        # operator capped this tag's window at 131072 for VRAM headroom
      max_output_tokens: 16384
      model_revision: "ollama:qwen3.8-max:2026-09-12"
      execution_locus: local

  - model_name: embed
    litellm_params:
      model: ollama/embed               # plain ollama/ is correct for embeddings
      api_base: os.environ/LLM_BASE_URL
    model_info:
      mode: embedding
      model_revision: "ollama:embed:2026-09-12"
      execution_locus: local

  # Also present on the reference host -- uncomment to register (same window formula applies):
  # ornith-1.5:35b, laguna-xs-2.1, qwen3.8:27b, qwen3.6:35b (chat), qwen3-embedding:0.6b (embedding)

  # --- llama.cpp / vLLM / LM Studio (OpenAI-compatible) example ---
  # - model_name: my-gguf-model
  #   litellm_params:
  #     model: openai/my-gguf-model
  #     api_base: http://llamacpp:8080/v1     # bundled profile; or http://host.docker.internal:8080/v1
  #     api_key: sk-unused                     # the client requires *a* key; the server ignores it
  #   model_info:
  #     mode: chat
  #     max_input_tokens: 20480               # 32768 - 4096 - 8192 -- match your -c
  #     max_output_tokens: 4096
  #     execution_locus: local

litellm_settings:
  drop_params: true      # unsupported client params are dropped, not errored -- backends vary
  num_retries: 0         # a retry produces a second generation attributed to the first
  request_timeout: 900   # long prefills on large local contexts

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
```

Acceptance: after Task 7, `GET /v1/model/info` returns five entries with the declared `max_input_tokens` and `execution_locus`.

### Task 7 — `docker-compose.yml` (first layer)

File: `docker-compose.yml` (create)

```yaml
# Open LLM Stack -- see docs/spec.md. Every layer is a Compose profile; COMPOSE_PROFILES in .env
# selects what runs. No depends_on ever crosses a profile boundary (spec §4.3).
name: open-llm-stack

networks:
  default:
    name: open-llm-stack

volumes:
  litellm-db-data:

services:
  # ---------------------------------------------------------------- profile: litellm (port 3000)
  litellm-db:
    image: postgres:17.11-alpine
    profiles: [litellm]
    restart: unless-stopped
    environment:
      POSTGRES_DB: litellm
      POSTGRES_USER: litellm
      POSTGRES_PASSWORD: ${LITELLM_DB_PASSWORD:?run make init}
    volumes:
      - litellm-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d litellm -U litellm"]
      interval: 10s
      timeout: 5s
      retries: 5

  litellm:
    image: ghcr.io/berriai/litellm:v1.89.7   # verified 2026-09-12; never 1.82.7/1.82.8 (compromised PyPI releases)
    profiles: [litellm]
    restart: unless-stopped
    command: ["--config", "/app/config.yaml", "--num_workers", "1"]   # one worker: single-GPU hosts thrash otherwise
    depends_on:
      litellm-db:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://litellm:${LITELLM_DB_PASSWORD}@litellm-db:5432/litellm
      LITELLM_MASTER_KEY: ${LITELLM_MASTER_KEY:?run make init}
      LLM_BASE_URL: ${LLM_BASE_URL:-http://host.docker.internal:11434}
    volumes:
      - ./proxy/config.yaml:/app/config.yaml:ro   # gitignored; make init copies it from the .example
    extra_hosts:
      - "host.docker.internal:host-gateway"       # bring-your-own backend running on the host
    ports:
      - "${BIND_HOST:-127.0.0.1}:${LITELLM_PORT:-3000}:4000"
    healthcheck:
      # image has no curl/wget; python3 is there
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s
```

Acceptance: `docker compose config --quiet` exits 0; `docker compose config --services` with `COMPOSE_PROFILES=litellm` lists exactly `litellm-db litellm`; with `COMPOSE_PROFILES=` (empty) lists nothing.

### Task 8 — `Makefile`

File: `Makefile` (create; recipes are TAB-indented)

```makefile
.PHONY: init up down ps logs test reload gitea-bootstrap

init:            ## first run: .env + secrets + proxy/config.yaml (idempotent)
	./scripts/init.sh

up:              ## start every layer in COMPOSE_PROFILES, wait for healthy, check the LLM backend
	./scripts/check-ports.sh
	docker compose up -d --wait
	./scripts/preflight.sh

down:
	docker compose down

ps:
	docker compose ps

logs:            ## make logs S=litellm
	docker compose logs -f $(S)

test:            ## smoke test every running layer
	./scripts/smoke-test.sh

reload:          ## after editing proxy/config.yaml
	docker compose restart litellm

gitea-bootstrap: ## admin user + API token for the bundled Gitea (plan 04)
	./scripts/bootstrap-gitea.sh
```

Acceptance: `make -n up` prints the three commands; `make up` on this host ends with the preflight `OK` line.

### Task 9 — `scripts/smoke-test.sh` (litellm section)

File: `scripts/smoke-test.sh` (create, `chmod +x`). Later plans **append** a function per layer and add it to the dispatcher; keep the structure.

```bash
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

# --- dispatcher (later plans add: openwebui, buzz, gitea) ---
has_profile litellm && test_litellm
echo "smoke test finished"
```

Acceptance (G3): all four sub-sections print real output; every chat model returns `OK` (this host's models do), embeddings prints `1024`, scope check prints `ok`.

### Task 10 — `README.md` quick start (temporary)

File: `README.md` (modify: keep the existing title, description and "Batteries Included" list; append)

```markdown
## Quick start

Requires Docker (Compose v2) and an OpenAI-compatible LLM backend you already run (Ollama, llama.cpp, vLLM, LM Studio). Bundled backends are optional, see docs/spec.md §5.6.

    make init     # .env + generated secrets + proxy/config.yaml
    make up       # starts every layer in COMPOSE_PROFILES, waits for healthy, checks your backend
    make test     # smoke-tests every running layer

| Service | URL |
|---|---|
| LiteLLM (OpenAI-compatible API) | http://127.0.0.1:3000/v1 -- key: `LITELLM_MASTER_KEY` from `.env` |
| Open WebUI | http://127.0.0.1:3001 |
| Buzz relay | ws://127.0.0.1:3002 |
| Gitea | http://127.0.0.1:3003 |

Full documentation: `docs/spec.md` (architecture, every env var, verified facts). Plans in `plans/` build the layers one at a time.
```

---

## 5. Testing strategy

No application code; the tests are the gates. Run them against the live stack on this host and paste real output into §8 of this file when done (per `AGENTS.md`).

## 6. Validation commands (in order)

```bash
# G0 -- compose validity, every profile alone and none
for p in "" litellm; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: '$p'"; done
COMPOSE_PROFILES=litellm docker compose config --services

# G1
./scripts/check-ports.sh

# bring it up (this host: default LLM_BASE_URL hits the running Ollama)
make init && make up && docker compose ps

# G2 (already ran inside make up; run again for the record)
./scripts/preflight.sh

# G3
make test

# G8 -- nothing beyond loopback
docker compose ps --format '{{.Name}} {{.Ports}}'     # every mapping must start with 127.0.0.1:

# negative path for G2 (then restore)
sed -i 's|^LLM_BASE_URL=.*|LLM_BASE_URL=http://127.0.0.1:59999|' .env && docker compose up -d litellm && ./scripts/preflight.sh; echo "exit=$?"
sed -i 's|^LLM_BASE_URL=.*|LLM_BASE_URL=http://host.docker.internal:11434|' .env && docker compose up -d litellm && ./scripts/preflight.sh

# idempotency
./scripts/init.sh && ./scripts/init.sh
```

## 7. Integration notes

- Plans 02–06 each add a `profiles:`-gated service block to `docker-compose.yml`, a `test_<layer>` function to `scripts/smoke-test.sh`, and a README section. They must not edit `.env.example` except to fix a defect (then update spec §3 too).
- `init.sh` already generates the Buzz and agent keys so plan 03/06 need no extra bootstrap.
- Known benign log line: `prisma:warn Prisma doesn't know which engines to download for the Linux distro "wolfi"`.

## 8. Execution report

**Date:** 2026-09-12. **Host:** reference host (Ollama at 0.0.0.0:11434, outside this project). **Result:** every gate passed on the first run; no fix to any script, compose file or env was needed. Stack left running, `.env` restored to `LLM_BASE_URL=http://host.docker.internal:11434`.

### G0 -- compose validity

```
$ for p in "" litellm; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: '$p'"; done
G0 ok: ''
G0 ok: 'litellm'
$ COMPOSE_PROFILES=litellm docker compose config --services
litellm-db
litellm
```

### G1 -- check-ports.sh (positive and negative)

```
$ ./scripts/check-ports.sh
ports ok                                  # exit 0

$ python3 -m http.server 3003 --bind 127.0.0.1 &   # simulate a foreign process on a stack port
$ ./scripts/check-ports.sh
port 3003: BUSY -- LISTEN 0      5               127.0.0.1:3003  0.0.0.0:* users:(("python3",pid=165926,fd=3))
Free the ports above (or change *_PORT in .env) and re-run make up.
exit=1
$ kill 165926 && ./scripts/check-ports.sh
ports ok
```

### Bring-up -- `make init && make up && docker compose ps` (57.6 s wall clock)

```
./scripts/init.sh
init complete. Next: check LLM_BASE_URL in .env and the models in proxy/config.yaml, then: make up
./scripts/check-ports.sh
ports ok
docker compose up -d --wait
 Network open-llm-stack Created
 Volume open-llm-stack_litellm-db-data Created
 Container open-llm-stack-litellm-db-1 Healthy
 Container open-llm-stack-litellm-1 Healthy
./scripts/preflight.sh
OK  backend reachable at http://host.docker.internal:11434/v1/models
NAME                          IMAGE                             SERVICE      STATUS                    PORTS
open-llm-stack-litellm-1      ghcr.io/berriai/litellm:v1.89.7   litellm      Up 46 seconds (healthy)   127.0.0.1:3000->4000/tcp
open-llm-stack-litellm-db-1   postgres:17.11-alpine             litellm-db   Up 56 seconds (healthy)   5432/tcp
```

Timings: litellm-db healthy in ~10 s; litellm healthy ~46 s after start (start_period 30 s + first 15 s probe). Only log noise: the known benign `prisma:warn Prisma doesn't know which engines to download for the Linux distro "wolfi"` (twice). No errors or tracebacks.

### G2 -- preflight.sh

```
$ ./scripts/preflight.sh
OK  backend reachable at http://host.docker.internal:11434/v1/models
exit=0
```

### G3 -- `make test` (52.1 s wall clock; all four chat models already warm on the host)

```
--- litellm: registry
embed
laguna-max
ornith-max
qwen3.6-max
qwen3.8-max
qwen3.6-max	237568	local
ornith-max	237568	local
laguna-max	237568	local
qwen3.8-max	106496	local
embed	null	local
--- litellm: chat round-trip (every mode:chat model; reasoning models need a generous max_tokens)
qwen3.6-max -> OK
ornith-max -> OK
laguna-max -> OK
qwen3.8-max -> OK
--- litellm: embeddings
1024
--- litellm: no closed-weight model or router registered
ok
smoke test finished
exit=0
```

5 models registered, every chat model returned exactly `OK`, embedding vector length 1024, scope check `ok`. (`embed` has `max_input_tokens: null` -- expected; the embedding entry sets no window in `proxy/config.yaml`.)

### G8 -- loopback only

```
$ docker compose ps --format '{{.Name}} {{.Ports}}'
open-llm-stack-litellm-1 127.0.0.1:3000->4000/tcp
open-llm-stack-litellm-db-1 5432/tcp
```

The single published mapping starts with `127.0.0.1:`. `5432/tcp` on litellm-db is the image's EXPOSE (container-network only, no host binding).

### G2 negative path, then restore

```
$ sed -i 's|^LLM_BASE_URL=.*|LLM_BASE_URL=http://127.0.0.1:59999|' .env && docker compose up -d --wait litellm && ./scripts/preflight.sh; echo "exit=$?"
 Container open-llm-stack-litellm-1 Recreated
 Container open-llm-stack-litellm-1 Healthy           # 29.7 s
FAIL http://127.0.0.1:59999 unreachable from inside the litellm container: <urlopen error [Errno 111] Connection refused>

Which case are you in?
  1. Backend is a container      -> put it on the 'open-llm-stack' network and use http://<container>:<port>, ...
  2. Host process bound to 0.0.0.0 -> http://host.docker.internal:<port> (extra_hosts is already set on litellm)
  3. Host process bound to 127.0.0.1 only -> host.docker.internal resolves to the Docker bridge gateway, never loopback, ...
exit=1

$ sed -i 's|^LLM_BASE_URL=.*|LLM_BASE_URL=http://host.docker.internal:11434|' .env && docker compose up -d --wait litellm && ./scripts/preflight.sh
 Container open-llm-stack-litellm-1 Recreated
 Container open-llm-stack-litellm-1 Healthy           # 29.4 s
OK  backend reachable at http://host.docker.internal:11434/v1/models
exit=0
```

Deviation from the §6 command as written: `--wait` was added to `docker compose up -d litellm` so preflight runs against a healthy container after the env-triggered recreate (§6 text left unchanged; the check itself is a pure network probe and does not depend on it).

### Idempotency -- `./scripts/init.sh && ./scripts/init.sh`

```
$ md5sum .env proxy/config.yaml
78ae295051fb1c29d1c60285b6189c7c  .env
0b0931a54b8b551584f43cea15bb29e4  proxy/config.yaml
$ ./scripts/init.sh && ./scripts/init.sh
init complete. Next: check LLM_BASE_URL in .env and the models in proxy/config.yaml, then: make up
init complete. Next: check LLM_BASE_URL in .env and the models in proxy/config.yaml, then: make up
$ md5sum .env proxy/config.yaml
78ae295051fb1c29d1c60285b6189c7c  .env
0b0931a54b8b551584f43cea15bb29e4  proxy/config.yaml
```

Both runs print only the final line; checksums unchanged, so no secret was regenerated.

### Final state

```
open-llm-stack-litellm-1 Up (healthy) 127.0.0.1:3000->4000/tcp
open-llm-stack-litellm-db-1 Up (healthy) 5432/tcp
LLM_BASE_URL=http://host.docker.internal:11434
OK  backend reachable at http://host.docker.internal:11434/v1/models
```

### Fixes made

None. No script, compose, env or image tag was changed.
