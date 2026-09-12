# Plan 02 — Open WebUI (port 3001)

**Spec:** `docs/spec.md` §4, §5.2, §7. **Rules:** `AGENTS.md`.
**Sequence:** 2 of 7. Requires plan 01 executed (compose file, `.env`, `smoke-test.sh` exist and G3 passes).
**Execute with:** `/execute plans/02-open-webui.md`

---

## 1. Overview

Add the `openwebui` profile: Open WebUI v0.11.3 on `${BIND_HOST}:3001`, talking **only** to LiteLLM (`LITELLM_URL`, default `http://litellm:4000`) with the master key, single-user no-login mode by default, and with persistent-config disabled so a later change of `LITELLM_URL` takes effect on restart.

**Success criteria:** G0 (with `openwebui`), G4, G8 pass with real output. Open WebUI lists the five registered models and completes a chat through LiteLLM → Ollama.

---

## 2. Relevant files

| Path | Action |
|---|---|
| `docker-compose.yml` | add `open-webui` service + `open-webui-data` volume |
| `scripts/smoke-test.sh` | add `test_openwebui` and dispatch it |
| `README.md` | add an "Open WebUI" section |

## 3. Dependencies

- Image `ghcr.io/open-webui/open-webui:v0.11.3` (multi-arch, verified; already on this host). Container port 8080. Ships its own HEALTHCHECK (curl + jq on `/health`) — do not add one.
- Verified env semantics (spec §5.2). `WEBUI_AUTH=false` disables login; `ENABLE_SIGNUP` is forced false in that mode. `ENABLE_PERSISTENT_CONFIG=false` makes env win on every boot. `ENABLE_OLLAMA_API=false` is mandatory or the UI also probes `http://localhost:11434` directly.
- No `depends_on` on `litellm` (spec §4.3): Open WebUI tolerates the gateway coming up later.

---

## 4. Tasks

### Task 1 — compose service

File: `docker-compose.yml` (modify). Add to `volumes:`:

```yaml
  open-webui-data:
```

Append under `services:`:

```yaml
  # ---------------------------------------------------------------- profile: openwebui (port 3001)
  open-webui:
    image: ghcr.io/open-webui/open-webui:v0.11.3   # verified 2026-09-12
    profiles: [openwebui]
    restart: unless-stopped
    environment:
      WEBUI_AUTH: ${WEBUI_AUTH:-false}            # false = single user, no login screen
      WEBUI_SECRET_KEY: ${WEBUI_SECRET_KEY:?run make init}
      ENABLE_PERSISTENT_CONFIG: "false"           # env wins on every boot; otherwise first-boot values freeze in the DB
      ENABLE_OPENAI_API: "true"
      OPENAI_API_BASE_URL: ${LITELLM_URL:-http://litellm:4000}/v1
      OPENAI_API_KEY: ${LITELLM_MASTER_KEY}
      ENABLE_OLLAMA_API: "false"                  # default true would bypass the gateway
    volumes:
      - open-webui-data:/app/backend/data
    extra_hosts:
      - "host.docker.internal:host-gateway"       # lets LITELLM_URL point at a gateway running on the host
    ports:
      - "${BIND_HOST:-127.0.0.1}:${OPENWEBUI_PORT:-3001}:8080"
```

Acceptance: `COMPOSE_PROFILES=openwebui docker compose config --services` prints `open-webui` only; `COMPOSE_PROFILES=litellm,openwebui docker compose up -d --wait` reports `open-webui` healthy (its own healthcheck) within ~90 s (first boot runs DB migrations).

### Task 2 — smoke test section

File: `scripts/smoke-test.sh` (modify). Insert before the dispatcher:

```bash
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
```

And extend the dispatcher:

```bash
has_profile litellm && test_litellm
has_profile openwebui && test_openwebui
```

Acceptance (G4): prints `healthy`, `version 0.11.3  auth=false`, the model names from `proxy/config.yaml`, and `OK`.

### Task 3 — README section

File: `README.md` (append)

```markdown
## Open WebUI (port 3001)

Open http://127.0.0.1:3001. With the default `WEBUI_AUTH=false` there is no login; every model in `proxy/config.yaml` is in the picker because Open WebUI talks only to LiteLLM (`LITELLM_URL`). Set `WEBUI_AUTH=true` in `.env` and `docker compose up -d open-webui` to get normal signup/login (the first account becomes admin).

Using an external gateway instead of the bundled LiteLLM: remove `litellm` from `COMPOSE_PROFILES`, set `LITELLM_URL` to that gateway (reachable from inside Docker -- for a gateway on this machine use `http://host.docker.internal:<port>`) and `LITELLM_MASTER_KEY` to its key, then `docker compose up -d`.
```

---

## 5. Validation commands

```bash
for p in openwebui litellm,openwebui; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: $p"; done
make up && docker compose ps
make test                                              # G3 + G4
docker compose ps --format '{{.Name}} {{.Ports}}'      # G8: only 127.0.0.1:
# persistent-config check: change nothing, restart, models still listed
docker compose restart open-webui && sleep 20 && make test
```

## 6. Integration notes

- Nothing else consumes `WEBUI_*`. Plan 07's G9 external-swap test uses this service (`LITELLM_URL` → `http://host.docker.internal:3000` with `BIND_HOST=0.0.0.0`).
- Startup warnings seen and benign: `CORS_ALLOW_ORIGIN IS SET TO '*'`, `USER_AGENT environment variable not set`, an SQLAlchemy `SAWarning` about `_alembic_tmp_tag`.

## 7. Execution report

Executed 2026-09-12 (17:00–17:06 UTC) against the live stack; images already pulled, no internet. No file changes were needed: every gate passed on first run. `.env` has `COMPOSE_PROFILES=litellm,openwebui,buzz,gitea` (buzz/gitea have no services yet; Compose ignores them).

### G0 — config validates with and without the litellm profile

```
$ for p in openwebui litellm,openwebui; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: $p"; done
G0 ok: openwebui
G0 ok: litellm,openwebui
```

### G2 — `make up`: three services healthy, preflight OK

```
$ time make up && docker compose ps
port 3000: in use by this stack (ok)
ports ok
docker compose up -d --wait
 Volume open-llm-stack_open-webui-data Created
 Container open-llm-stack-open-webui-1 Started
 Container open-llm-stack-litellm-db-1 Healthy
 Container open-llm-stack-litellm-1 Healthy
 Container open-llm-stack-open-webui-1 Healthy
./scripts/preflight.sh
OK  backend reachable at http://host.docker.internal:11434/v1/models
make up  1:32.09 total
NAME                          IMAGE                                   SERVICE      STATUS                        PORTS
open-llm-stack-litellm-1      ghcr.io/berriai/litellm:v1.89.7         litellm      Up 15 minutes (healthy)       127.0.0.1:3000->4000/tcp
open-llm-stack-litellm-db-1   postgres:17.11-alpine                   litellm-db   Up 17 minutes (healthy)       5432/tcp
open-llm-stack-open-webui-1   ghcr.io/open-webui/open-webui:v0.11.3   open-webui   Up About a minute (healthy)   127.0.0.1:3001->8080/tcp
```

Time to healthy (first boot, DB migrations): container `StartedAt` 17:00:02Z; image HEALTHCHECK probes at +30 s and +60 s returned exit 1, first exit 0 at 17:01:32Z — **90 s**.

### G3 + G4 — `make test`

```
$ time make test
--- litellm: registry
embed
laguna-max
ornith-max
qwen3.6-max
qwen3.8-max
--- litellm: chat round-trip (every mode:chat model; reasoning models need a generous max_tokens)
qwen3.6-max -> OK
ornith-max -> OK
laguna-max -> OK
qwen3.8-max -> OK
--- litellm: embeddings
1024
--- litellm: no closed-weight model or router registered
ok
--- open-webui: health
healthy
version 0.11.3  auth=false
--- open-webui: models via LiteLLM
embed
laguna-max
ornith-max
qwen3.6-max
qwen3.8-max
--- open-webui: chat round-trip via qwen3.6-max
OK
smoke test finished
make test  48.485 total
```

Smoke test duration: **48.5 s** (first run; includes four LiteLLM chat round-trips plus the Open WebUI one).

### G8 — every published port is loopback

```
$ docker compose ps --format '{{.Name}} {{.Ports}}'
open-llm-stack-litellm-1 127.0.0.1:3000->4000/tcp
open-llm-stack-litellm-db-1 5432/tcp
open-llm-stack-open-webui-1 127.0.0.1:3001->8080/tcp
```

(`litellm-db` has no host mapping; 5432 is container-internal only.)

### Persistent-config check — restart, models still listed

Used `sleep 25` rather than the plan's `sleep 20` (parent instruction; a restart with an already-migrated DB is well under that).

```
$ docker compose restart open-webui && sleep 25 && time make test
 Container open-llm-stack-open-webui-1 Restarting
 Container open-llm-stack-open-webui-1 Started
[litellm section identical to above]
--- open-webui: health
healthy
version 0.11.3  auth=false
--- open-webui: models via LiteLLM
embed
laguna-max
ornith-max
qwen3.6-max
qwen3.8-max
--- open-webui: chat round-trip via qwen3.6-max
OK
smoke test finished
make test  35.701 total
```

Second smoke run: **35.7 s**. `ENABLE_PERSISTENT_CONFIG=false` confirmed: LiteLLM connection survives a restart from env alone.

### Browser-facing sanity

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3001/
200
$ curl -s http://127.0.0.1:3001/api/config | jq '.features.auth'
false
```

### Logs

The three warnings listed in §6 all appeared (`CORS_ALLOW_ORIGIN`, `USER_AGENT`, `_alembic_tmp_tag` SAWarning). Two additional benign lines not in §6, worth knowing so nobody chases them: a `FutureWarning` from `google/auth/transport/grpc.py` about grpcio < 1.83.0, and a `huggingface_hub` "unauthenticated requests to the HF Hub" notice from the embedding-model fetch (no internet on this host; the container still went healthy). No errors or tracebacks.

### Fixes

None. No image tag, flag, env name, or script was changed. Stack left running (litellm, litellm-db, open-webui all healthy); `.env` untouched.
