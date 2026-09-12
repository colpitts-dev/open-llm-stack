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

## 7. Execution report (fill in)
