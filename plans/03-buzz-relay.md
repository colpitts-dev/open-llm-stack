# Plan 03 — Buzz relay (port 3002)

**Spec:** `docs/spec.md` §4, **§5.3 (read all of it — the host-binding rule is the one thing that bites)**, §7. **Rules:** `AGENTS.md`.
**Sequence:** 3 of 7. Requires plan 01 (compose skeleton, `.env` with generated Buzz secrets, `smoke-test.sh`). Independent of plan 02.
**Execute with:** `/execute plans/03-buzz-relay.md`

---

## 1. Overview

Add the `buzz` profile: the Buzz relay (`ghcr.io/block/buzz:sha-e17cdd9`) with its Postgres, Redis, MinIO and a one-shot bucket initialiser, published on `${BIND_HOST}:3002`, running as an **open** local-dev relay (no membership, no API token). Humans connect with the Buzz desktop app or the `buzz` CLI at `ws://127.0.0.1:3002`; the relay's browser UI (repo browser + invites) is on at `http://127.0.0.1:3002/`.

**Success criteria:** G0 (with `buzz`), G5, G8 with real output. The relay logs `Deployment community ensured host=127.0.0.1:3002`, `/_readiness` is 200, NIP-11 is served, and a `buzz channels list` from a real client succeeds.

**Out of scope:** the LLM agent (plan 06). Closed-relay mode is documented, not exercised.

---

## 2. Relevant files

| Path | Action |
|---|---|
| `docker-compose.yml` | add `buzz`, `buzz-db`, `buzz-redis`, `buzz-minio`, `buzz-minio-init` + 4 volumes |
| `scripts/smoke-test.sh` | add `test_buzz`, dispatch it |
| `README.md` | add "Buzz relay" section |

## 3. Dependencies (all verified 2026-09-12, spec §5.3)

- Images: `ghcr.io/block/buzz:sha-e17cdd9` (on host), `postgres:17.11-alpine` (on host), `redis:7.4.11-alpine` (on host), `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z` and `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z` (**quay.io**, not Docker Hub — Hub denies anonymous pulls of these). For the client check: `ghcr.io/block/buzz-sprig:sha-e17cdd9` (on host).
- `.env` from plan 01 already holds `BUZZ_RELAY_PRIVATE_KEY`, `BUZZ_GIT_HOOK_HMAC_SECRET`, `BUZZ_DB_PASSWORD`, `BUZZ_REDIS_PASSWORD`, `BUZZ_S3_ACCESS_KEY`, `BUZZ_S3_SECRET_KEY`, `BUZZ_PUBLIC_HOST`, `BUZZ_RELAY_URL`, `BUZZ_PORT`, the two `BUZZ_REQUIRE_*` flags and `BUZZ_SERVE_GIT_WEB_GUI`.
- The exact service definitions below were booted on this host during planning and reached healthy (db/redis/minio ~16 s, relay ~10 s later).

---

## 4. Tasks

### Task 1 — compose services

File: `docker-compose.yml` (modify). Add to `volumes:`:

```yaml
  buzz-db-data:
  buzz-redis-data:
  buzz-minio-data:
  buzz-git-data:
```

Append under `services:`:

```yaml
  # ---------------------------------------------------------------- profile: buzz (port 3002)
  buzz:
    image: ghcr.io/block/buzz:sha-e17cdd9   # main@e17cdd9 2026-09-11; newest commit with relay AND buzz-sprig images
    profiles: [buzz]
    restart: unless-stopped
    environment:
      # The relay binds a community to the exact host:port in RELAY_URL and rejects every other Host
      # header with 404 (spec §5.3). Bind the same port inside the container as outside so one number
      # (BUZZ_PORT) is the truth everywhere.
      BUZZ_BIND_ADDR: 0.0.0.0:${BUZZ_PORT:-3002}
      BUZZ_HEALTH_PORT: "8080"
      BUZZ_METRICS_PORT: "9102"
      RELAY_URL: ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}
      BUZZ_MEDIA_BASE_URL: http://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}/media
      BUZZ_CORS_ORIGINS: http://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002},http://localhost:${BUZZ_PORT:-3002}
      BUZZ_REQUIRE_AUTH_TOKEN: ${BUZZ_REQUIRE_AUTH_TOKEN:-false}
      BUZZ_REQUIRE_RELAY_MEMBERSHIP: ${BUZZ_REQUIRE_RELAY_MEMBERSHIP:-false}
      RELAY_OWNER_PUBKEY: ${RELAY_OWNER_PUBKEY:-}       # only needed for closed mode; blank is ignored
      BUZZ_SERVE_GIT_WEB_GUI: ${BUZZ_SERVE_GIT_WEB_GUI:-true}
      BUZZ_AUTO_MIGRATE: "true"
      BUZZ_GIT_CONFORMANCE_PROBE: "true"
      BUZZ_RELAY_PRIVATE_KEY: ${BUZZ_RELAY_PRIVATE_KEY:?run make init}
      BUZZ_GIT_HOOK_HMAC_SECRET: ${BUZZ_GIT_HOOK_HMAC_SECRET:?run make init}
      DATABASE_URL: postgres://buzz:${BUZZ_DB_PASSWORD}@buzz-db:5432/buzz
      REDIS_URL: redis://:${BUZZ_REDIS_PASSWORD}@buzz-redis:6379
      BUZZ_S3_ENDPOINT: http://buzz-minio:9000
      BUZZ_S3_ADDRESSING_STYLE: path                    # Docker DNS resolves buzz-minio, not <bucket>.buzz-minio
      BUZZ_S3_ACCESS_KEY: ${BUZZ_S3_ACCESS_KEY}
      BUZZ_S3_SECRET_KEY: ${BUZZ_S3_SECRET_KEY}
      BUZZ_S3_BUCKET: buzz-media
      BUZZ_GIT_REPO_PATH: /data/git
    volumes:
      - buzz-git-data:/data/git
    ports:
      - "${BIND_HOST:-127.0.0.1}:${BUZZ_PORT:-3002}:${BUZZ_PORT:-3002}"
    depends_on:
      buzz-db:
        condition: service_healthy
      buzz-redis:
        condition: service_healthy
      buzz-minio:
        condition: service_healthy
      buzz-minio-init:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8080/_readiness"]
      interval: 10s
      timeout: 3s
      retries: 12
      start_period: 30s

  buzz-db:
    image: postgres:17.11-alpine
    profiles: [buzz]
    restart: unless-stopped
    environment:
      POSTGRES_DB: buzz
      POSTGRES_USER: buzz
      POSTGRES_PASSWORD: ${BUZZ_DB_PASSWORD:?run make init}
    volumes:
      - buzz-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U buzz -d buzz"]
      interval: 5s
      timeout: 5s
      retries: 12
      start_period: 10s

  buzz-redis:
    image: redis:7.4.11-alpine
    profiles: [buzz]
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "${BUZZ_REDIS_PASSWORD:?run make init}"]
    environment:
      REDIS_PASSWORD: ${BUZZ_REDIS_PASSWORD}
    volumes:
      - buzz-redis-data:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$${REDIS_PASSWORD}\" ping | grep -q PONG"]
      interval: 5s
      timeout: 3s
      retries: 12

  buzz-minio:
    image: quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z   # pull from quay.io; Docker Hub denies anonymous access
    profiles: [buzz]
    restart: unless-stopped
    command: ["server", "/data"]
    environment:
      MINIO_ROOT_USER: ${BUZZ_S3_ACCESS_KEY:?run make init}
      MINIO_ROOT_PASSWORD: ${BUZZ_S3_SECRET_KEY:?run make init}
    volumes:
      - buzz-minio-data:/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:9000/minio/health/live"]
      interval: 5s
      timeout: 5s
      retries: 12
      start_period: 10s

  buzz-minio-init:
    image: quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z
    profiles: [buzz]
    restart: "no"
    depends_on:
      buzz-minio:
        condition: service_healthy
    # $0/$1 are the two trailing args -- avoids $$ escaping games and never puts a secret in `ps` output twice
    entrypoint:
      - /bin/sh
      - -euc
      - mc alias set local http://buzz-minio:9000 "$0" "$1" && mc mb --ignore-existing local/buzz-media && mc anonymous set none local/buzz-media
      - ${BUZZ_S3_ACCESS_KEY}
      - ${BUZZ_S3_SECRET_KEY}
```

Acceptance: `COMPOSE_PROFILES=buzz docker compose config --services` prints exactly `buzz buzz-db buzz-redis buzz-minio buzz-minio-init`; `docker compose up -d --wait` shows `buzz` healthy and `buzz-minio-init` `Exited (0)`; `docker compose logs buzz | grep 'Deployment community ensured'` shows `"host":"127.0.0.1:3002"`.

### Task 2 — smoke test section

File: `scripts/smoke-test.sh` (modify). Insert before the dispatcher:

```bash
test_buzz() {
  local host="${BUZZ_PUBLIC_HOST:-127.0.0.1:${BUZZ_PORT:-3002}}"
  echo "--- buzz: readiness (health listener inside the container)"
  docker compose exec -T buzz curl -fsS -o /dev/null -w 'readiness %{http_code}\n' http://127.0.0.1:8080/_readiness
  curl -fsS -o /dev/null -w "liveness on ${host}: %{http_code}\n" "http://${host}/_liveness"
  echo "--- buzz: NIP-11"
  curl -fsS -H 'Accept: application/nostr+json' "http://${host}/" | jq -r '"\(.name) \(.version) nips=\(.supported_nips|length) self=\(.self[0:16])..."'
  echo "--- buzz: community host == BUZZ_PUBLIC_HOST"
  local seeded; seeded=$(docker compose logs --no-log-prefix buzz 2>/dev/null | grep -o '"Deployment community ensured","host":"[^"]*"' | tail -1 | sed 's/.*"host":"//;s/"$//')
  [ "$seeded" = "$host" ] && echo "community host: $seeded" || fail "relay seeded community for '$seeded' but BUZZ_PUBLIC_HOST is '$host' -- clients will get 404"
  if [ "${BUZZ_SERVE_GIT_WEB_GUI:-true}" = "true" ]; then
    echo "--- buzz: browser UI"
    curl -fsS -H 'Accept: text/html' "http://${host}/" | grep -q '<title>Buzz</title>' && echo "web UI served at http://${host}/"
  fi
  echo "--- buzz: real client (buzz CLI from the sprig image, agent identity)"
  docker run --rm --network host -e BUZZ_PRIVATE_KEY="${BUZZ_AGENT_PRIVATE_KEY}" -e BUZZ_RELAY_URL="${BUZZ_RELAY_URL:-ws://${host}}" \
    --entrypoint buzz ghcr.io/block/buzz-sprig:sha-e17cdd9 channels list | jq -r 'if type=="array" then "channels visible: \(length)" else . end'
}
```

Dispatcher line to add: `has_profile buzz && test_buzz`.

Acceptance (G5): prints `readiness 200`, `liveness ... 200`, `Buzz Relay 0.2.1 nips=14 self=...`, `community host: 127.0.0.1:3002`, `web UI served ...`, `channels visible: 0` (or a number).

### Task 3 — README section

File: `README.md` (append)

```markdown
## Buzz relay (port 3002)

The relay is up at `ws://127.0.0.1:3002` (open mode: anyone with the URL can join; fine on a laptop, see below for closed mode). Chat clients:

- **Buzz desktop app** (packaged builds: https://github.com/block/buzz/releases): launch with `BUZZ_RELAY_URL=ws://127.0.0.1:3002`, or switch relay inside the app.
- **`buzz` CLI** without installing anything: `docker run --rm --network host -e BUZZ_PRIVATE_KEY=<64-hex secret> -e BUZZ_RELAY_URL=ws://127.0.0.1:3002 --entrypoint buzz ghcr.io/block/buzz-sprig:sha-e17cdd9 channels list`. Mint a key with `docker compose exec buzz buzz-admin generate-key`.
- Browser: http://127.0.0.1:3002/ serves the repo browser and invite pages (not a chat client).

**Use exactly `127.0.0.1:3002`.** The relay creates one community keyed on `BUZZ_PUBLIC_HOST` and answers HTTP 404 to any other host name, so `localhost:3002` is a different (non-existent) community. To expose the relay on your LAN set `BIND_HOST=0.0.0.0` and `BUZZ_PUBLIC_HOST=<your-ip>:3002` (and `BUZZ_RELAY_URL` to match), then `docker compose up -d buzz`.

Closed relay (members only): set `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true` and `RELAY_OWNER_PUBKEY=<your 64-hex pubkey>` in `.env`, `docker compose up -d buzz`, then add members with `docker compose exec buzz buzz-admin add-member --pubkey <hex-or-npub>`.

External relay: remove `buzz` from `COMPOSE_PROFILES` and set `BUZZ_RELAY_URL=wss://your-relay.example` -- only the optional `buzz-agent` profile reads it.

Data lives in the `buzz-db-data`, `buzz-redis-data`, `buzz-minio-data` and `buzz-git-data` volumes; back up `.env` too (the relay key and HMAC secret must stay stable).
```

---

## 5. Validation commands

```bash
for p in buzz litellm,openwebui,buzz; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: $p"; done
COMPOSE_PROFILES=buzz docker compose config --services
make up && docker compose ps -a
docker compose logs buzz | grep -E 'Deployment community ensured|WARN|ERROR' | head
make test                                              # G3 (+G4) + G5
docker compose ps --format '{{.Name}} {{.Ports}}'      # G8
# negative proof of the host rule (expect 404):
curl -s -o /dev/null -w '%{http_code}\n' -H 'Accept: text/html' http://localhost:3002/
```

## 6. Integration notes

- Expected WARN on every boot: `BUZZ_REQUIRE_AUTH_TOKEN is false — REST API requests bypass token auth`. Not an error.
- The health listener (8080) is not published; the smoke test reaches it with `docker compose exec`.
- Plan 06 adds the agent; it connects through `BUZZ_RELAY_URL` on the host network, so nothing here changes for it.
- Upstream reference for these five services: `github.com/block/buzz` `deploy/compose/compose.yml` at commit ad9591c (2026-09-09), adapted to this project's names and `.env`.

## 7. Execution report

**Date:** 2026-09-12 (17:13–17:17 UTC). Validated live on the reference host, Compose v5.1.3, `COMPOSE_PROFILES=litellm,openwebui,buzz,gitea` (gitea has no services yet). No fixes were needed; no file other than this report was changed.

### G0 — compose valid per profile

```
$ for p in buzz litellm,openwebui,buzz; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: $p"; done
G0 ok: buzz
G0 ok: litellm,openwebui,buzz
$ COMPOSE_PROFILES=buzz docker compose config --services
buzz-minio
buzz-minio-init
buzz-redis
buzz-db
buzz
```

### `make up` + `docker compose ps -a`

```
$ make up
./scripts/check-ports.sh
port 3000: in use by this stack (ok)
port 3001: in use by this stack (ok)
ports ok
docker compose up -d --wait
 Volume open-llm-stack_buzz-git-data Created      (+ buzz-db-data, buzz-redis-data, buzz-minio-data)
 Container open-llm-stack-buzz-minio-1 Healthy
 Container open-llm-stack-buzz-redis-1 Healthy
 Container open-llm-stack-buzz-db-1 Healthy
 Container open-llm-stack-buzz-minio-init-1 Exited
 Container open-llm-stack-buzz-1 Healthy
./scripts/preflight.sh
OK  backend reachable at http://host.docker.internal:11434/v1/models
make up  17.782 total

$ docker compose ps -a
NAME                               SERVICE           STATUS
open-llm-stack-buzz-1              buzz              Up 10 seconds (healthy)     3000/tcp, 8080/tcp, 9102/tcp, 127.0.0.1:3002->3002/tcp
open-llm-stack-buzz-db-1           buzz-db           Up 17 seconds (healthy)     5432/tcp
open-llm-stack-buzz-minio-1        buzz-minio        Up 17 seconds (healthy)     9000/tcp
open-llm-stack-buzz-minio-init-1   buzz-minio-init   Exited (0) 11 seconds ago
open-llm-stack-buzz-redis-1        buzz-redis        Up 17 seconds (healthy)     6379/tcp
open-llm-stack-litellm-1           litellm           Up 27 minutes (healthy)     127.0.0.1:3000->4000/tcp
open-llm-stack-litellm-db-1        litellm-db        Up 30 minutes (healthy)     5432/tcp
open-llm-stack-open-webui-1        open-webui        Up 11 minutes (healthy)     127.0.0.1:3001->8080/tcp
```

### Relay log: community line + expected WARN, no ERROR

```
$ docker compose logs buzz | grep -E 'Deployment community ensured|WARN|ERROR' | head
{"timestamp":"2026-09-12T17:13:49.632690Z","level":"WARN","message":"BUZZ_REQUIRE_AUTH_TOKEN is false — REST API requests bypass token auth. WebSocket protocol auth is unaffected. Set to true for production.","target":"buzz_relay::config"}
{"timestamp":"2026-09-12T17:13:50.643103Z","level":"INFO","message":"Deployment community ensured","host":"127.0.0.1:3002","community":"18502f1c-9ef1-4fcb-b473-4dc7df797163","target":"buzz_relay"}
```

The WARN is the documented open-mode notice (§6). Zero ERROR lines.

### G3 + G4 + G5 — `make test` (58.6 s, exit 0)

```
--- litellm: registry
embed / laguna-max / ornith-max / qwen3.6-max / qwen3.8-max   (max_input_tokens 237568/237568/237568/106496, all execution_locus=local)
--- litellm: chat round-trip
qwen3.6-max -> OK   ornith-max -> OK   laguna-max -> OK   qwen3.8-max -> OK
--- litellm: embeddings
1024
--- litellm: no closed-weight model or router registered
ok
--- open-webui: health
healthy
version 0.11.3  auth=false
--- open-webui: models via LiteLLM
embed / laguna-max / ornith-max / qwen3.6-max / qwen3.8-max
--- open-webui: chat round-trip via qwen3.6-max
OK
--- buzz: readiness (health listener inside the container)
readiness 200
liveness on 127.0.0.1:3002: 200
--- buzz: NIP-11
Buzz Relay 0.2.1 nips=14 self=938eb3301c0c6c13...
--- buzz: community host == BUZZ_PUBLIC_HOST
community host: 127.0.0.1:3002
--- buzz: browser UI
web UI served at http://127.0.0.1:3002/
--- buzz: real client (buzz CLI from the sprig image, agent identity)
channels visible: 0
smoke test finished
```

### G8 — nothing published beyond `BIND_HOST`

```
$ docker compose ps --format '{{.Name}} {{.Ports}}'
open-llm-stack-buzz-1 3000/tcp, 8080/tcp, 9102/tcp, 127.0.0.1:3002->3002/tcp
open-llm-stack-buzz-db-1 5432/tcp
open-llm-stack-buzz-minio-1 9000/tcp
open-llm-stack-buzz-redis-1 6379/tcp
open-llm-stack-litellm-1 127.0.0.1:3000->4000/tcp
open-llm-stack-litellm-db-1 5432/tcp
open-llm-stack-open-webui-1 127.0.0.1:3001->8080/tcp
```

Every host mapping (`->`) starts with `127.0.0.1:`. The bare `3000/tcp, 8080/tcp, 9102/tcp` on `buzz-1` are the image's `EXPOSE` declarations (health + metrics listeners), not host bindings; db/redis/minio publish nothing.

### Negative proof of the host rule

```
$ curl -s -o /dev/null -w '%{http_code}\n' -H 'Accept: text/html' http://localhost:3002/
404            # body: "relay: no community is configured for this host"
$ curl -s -o /dev/null -w '%{http_code}\n' -H 'Accept: text/html' http://127.0.0.1:3002/
200
```

`localhost:3002` and `127.0.0.1:3002` are two different communities, exactly as §5.3 states.

### Restart durability

```
$ docker compose restart buzz && sleep 20
open-llm-stack-buzz-1 Up 20 seconds (healthy)
$ docker compose logs --no-log-prefix buzz | grep -o '"Deployment community ensured",.*community":"[^"]*"'
"Deployment community ensured","host":"127.0.0.1:3002","community":"18502f1c-9ef1-4fcb-b473-4dc7df797163"
"Deployment community ensured","host":"127.0.0.1:3002","community":"18502f1c-9ef1-4fcb-b473-4dc7df797163"
$ make test
... (litellm + open-webui sections identical) ...
readiness 200
liveness on 127.0.0.1:3002: 200
Buzz Relay 0.2.1 nips=14 self=938eb3301c0c6c13...
community host: 127.0.0.1:3002
web UI served at http://127.0.0.1:3002/
channels visible: 0
smoke test finished           # exit 0
```

Same community UUID (upsert, not re-create) and same relay pubkey (`938eb3301c0c6c13…`, from the pinned `BUZZ_RELAY_PRIVATE_KEY`) across the restart.

### Timings

| Event | Measured |
|---|---|
| `make up` wall clock (check-ports + up --wait + preflight) | 17.8 s |
| buzz-db / buzz-redis / buzz-minio healthy, minio-init `Exited (0)` | ~7 s after start (faster than the ~16 s seen during planning) |
| relay container start → `buzz-relay TCP listening addr=0.0.0.0:3002` | 17:13:49.6 → 17:13:57.5 = ~8 s |
| relay container start → Compose `Healthy` | ~10 s (`Up 10 seconds (healthy)` in `ps -a`) |
| `docker compose restart buzz` → first passing `/_readiness` probe | 17:15:18.1 → 17:15:38.3 = 20 s (healthy at the `sleep 20` mark) |
| `make test` (all three layers, 4 chat round-trips through Ollama) | 58.6 s |

### Fixes

None. Every command in §5 passed on the first run with the files as written. `docker compose config` renders the redis healthcheck as `$$REDIS_PASSWORD` — that is display escaping only, the container receives `$REDIS_PASSWORD`; nothing to change.

