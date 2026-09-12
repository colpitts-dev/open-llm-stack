# Plan 04 — Gitea (port 3003)

**Spec:** `docs/spec.md` §4, §5.5, §7. **Rules:** `AGENTS.md`.
**Sequence:** 4 of 7. Requires plan 01. Independent of plans 02 and 03.
**Execute with:** `/execute plans/04-gitea.md`

---

## 1. Overview

Add the `gitea` profile: Gitea 1.27.3 with SQLite on `${BIND_HOST}:3003`, install-locked, plus `scripts/bootstrap-gitea.sh` which idempotently creates the admin user from `.env` and mints an API token into `GITEA_ADMIN_TOKEN`. HTTP only; no SSH port is published.

**Success criteria:** G0 (with `gitea`), G6, G8 with real output: healthz passes, bootstrap runs twice cleanly, a private repo is created through the API and cloned over HTTP with the token.

---

## 2. Relevant files

| Path | Action |
|---|---|
| `docker-compose.yml` | add `gitea` service + `gitea-data` volume |
| `scripts/bootstrap-gitea.sh` | create |
| `scripts/smoke-test.sh` | add `test_gitea`, dispatch it |
| `README.md` | add "Gitea" section |

## 3. Dependencies

- Image `docker.gitea.com/gitea:1.27.3` (newest 1.27.x; multi-arch; on host). Container port 3000; has `curl`; no built-in healthcheck; `/api/healthz` returns `{"status":"pass",...}`.
- Verified admin commands (spec §5.5): `gitea admin user create ... --admin --must-change-password=false` (run as user `git`), re-run prints `Command error: CreateUser: user already exists [name: X]` and exits non-zero; `gitea admin user generate-access-token --username X --token-name <unique> --scopes write:repository,write:user --raw` prints a 40-char token. Token names must be unique per call.
- `.env` from plan 01 holds `GITEA_PORT`, `GITEA_PUBLIC_URL`, `GITEA_ADMIN_USER`, `GITEA_ADMIN_PASSWORD` (generated), `GITEA_ADMIN_TOKEN` (blank until bootstrap).

---

## 4. Tasks

### Task 1 — compose service

File: `docker-compose.yml` (modify). Add to `volumes:` → `gitea-data:`. Append under `services:`:

```yaml
  # ---------------------------------------------------------------- profile: gitea (port 3003)
  gitea:
    image: docker.gitea.com/gitea:1.27.3   # verified 2026-09-12 (Gitea publishes to its own registry)
    profiles: [gitea]
    restart: unless-stopped
    environment:
      USER_UID: "1000"
      USER_GID: "1000"
      GITEA__security__INSTALL_LOCK: "true"       # skip the web installer
      GITEA__database__DB_TYPE: sqlite3
      GITEA__server__HTTP_PORT: "3000"
      GITEA__server__ROOT_URL: ${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}/   # what clone URLs and links show
      GITEA__service__DISABLE_REGISTRATION: "false"
    volumes:
      - gitea-data:/data
    ports:
      - "${BIND_HOST:-127.0.0.1}:${GITEA_PORT:-3003}:3000"   # HTTP only; no SSH port published
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:3000/api/healthz"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
```

Acceptance: `COMPOSE_PROFILES=gitea docker compose config --services` → `gitea`; `docker compose up -d --wait gitea` healthy in ≤ 30 s; `curl -fsS http://127.0.0.1:3003/api/v1/version` → `{"version":"1.27.3"}`.

### Task 2 — `scripts/bootstrap-gitea.sh`

File: `scripts/bootstrap-gitea.sh` (create, `chmod +x`)

```bash
#!/usr/bin/env bash
# Idempotent: create the admin user from .env, mint an API token, store it in .env as GITEA_ADMIN_TOKEN.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${GITEA_ADMIN_USER:?set in .env}" "${GITEA_ADMIN_PASSWORD:?run make init}"
docker compose ps --status running gitea | grep -q gitea || { echo "gitea is not running (is 'gitea' in COMPOSE_PROFILES? did you run make up?)" >&2; exit 1; }

set +e
out=$(docker compose exec -T -u git gitea gitea admin user create \
  --username "$GITEA_ADMIN_USER" --password "$GITEA_ADMIN_PASSWORD" \
  --email "${GITEA_ADMIN_USER}@localhost" --admin --must-change-password=false 2>&1)
rc=$?
set -e
if [ $rc -eq 0 ]; then echo "created admin user $GITEA_ADMIN_USER"
elif grep -q "already exists" <<<"$out"; then echo "admin user $GITEA_ADMIN_USER already exists"   # the only error we expect
else echo "ERROR creating admin user: $out" >&2; exit 1; fi

if [ -n "${GITEA_ADMIN_TOKEN:-}" ] && [ "${1:-}" != "--rotate" ]; then
  echo "GITEA_ADMIN_TOKEN already set in .env (pass --rotate to mint a new one)"; exit 0
fi
# token names must be unique per call -- nanoseconds + pid
token=$(docker compose exec -T -u git gitea gitea admin user generate-access-token \
  --username "$GITEA_ADMIN_USER" --token-name "stack-$(date +%s%N)-$$" \
  --scopes write:repository,write:user --raw | tr -d '\r\n')
[ ${#token} -ge 20 ] || { echo "ERROR: token generation returned '$token'" >&2; exit 1; }
sed -i "s|^GITEA_ADMIN_TOKEN=.*|GITEA_ADMIN_TOKEN=${token}|" .env
echo "GITEA_ADMIN_TOKEN written to .env"
```

Acceptance: first run prints `created admin user ...` and `GITEA_ADMIN_TOKEN written to .env`; second run prints `already exists` and `already set`; `--rotate` mints a new token. Old tokens stay valid until deleted in Gitea (Settings → Applications).

### Task 3 — smoke test section

File: `scripts/smoke-test.sh` (modify). Insert before the dispatcher:

```bash
test_gitea() {
  local base="http://${BIND_HOST}:${GITEA_PORT:-3003}"
  echo "--- gitea: health + version"
  curl -fsS "$base/api/healthz" | jq -r '"healthz: \(.status)"'
  curl -fsS "$base/api/v1/version" | jq -r '"version \(.version)"'
  [ -n "${GITEA_ADMIN_TOKEN:-}" ] || { echo "(GITEA_ADMIN_TOKEN blank -- run make gitea-bootstrap for the API checks)"; return 0; }
  local auth="Authorization: token ${GITEA_ADMIN_TOKEN}"
  echo "--- gitea: token works"
  curl -fsS -H "$auth" "$base/api/v1/user" | jq -r '"user \(.login) admin=\(.is_admin)"'
  echo "--- gitea: create + clone + delete a private repo"
  local repo="smoke-$(date +%s)"
  curl -fsS -H "$auth" -H 'Content-Type: application/json' -d "{\"name\":\"$repo\",\"private\":true,\"auto_init\":true}" \
    "$base/api/v1/user/repos" | jq -r '"created \(.full_name) private=\(.private) clone=\(.clone_url)"'
  local tmp; tmp=$(mktemp -d)
  git -c http.extraHeader="$auth" clone -q "$base/${GITEA_ADMIN_USER}/${repo}.git" "$tmp/repo" && echo "cloned ($(ls "$tmp/repo" | tr '\n' ' '))"
  rm -rf "$tmp"
  curl -fsS -X DELETE -H "$auth" "$base/api/v1/repos/${GITEA_ADMIN_USER}/${repo}" && echo "deleted $repo"
}
```

Dispatcher line: `has_profile gitea && test_gitea`.

Acceptance (G6): `healthz: pass`, `version 1.27.3`, `user stackadmin admin=true`, `created stackadmin/smoke-... private=true clone=http://127.0.0.1:3003/...`, `cloned (README.md )`, `deleted ...`.

### Task 4 — README section

File: `README.md` (append)

```markdown
## Gitea (port 3003)

http://127.0.0.1:3003 -- SQLite, HTTP only, install already locked. Create the admin account and an API token once:

    make gitea-bootstrap        # uses GITEA_ADMIN_USER / GITEA_ADMIN_PASSWORD from .env, writes GITEA_ADMIN_TOKEN

Log in with those credentials, or use the token: `curl -H "Authorization: token $GITEA_ADMIN_TOKEN" http://127.0.0.1:3003/api/v1/user`. Push over HTTP with the token (`git -c http.extraHeader="Authorization: token ..." push`) or with the user's password.

External Gitea/GitHub: remove `gitea` from `COMPOSE_PROFILES`; nothing else in this stack depends on it. `GITEA_PUBLIC_URL` only controls the bundled instance's `ROOT_URL` (what its clone URLs show), so change it together with `GITEA_PORT` or `BIND_HOST`.
```

---

## 5. Validation commands

```bash
for p in gitea litellm,openwebui,buzz,gitea; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: $p"; done
make up && docker compose ps
make gitea-bootstrap && make gitea-bootstrap           # idempotent
make test                                              # ... + G6
docker compose ps --format '{{.Name}} {{.Ports}}'      # G8: no 22/tcp published, everything 127.0.0.1:
```

## 6. Integration notes

- `bootstrap-gitea.sh` edits `.env`; `make test` re-sources it, so no restart is needed.
- The `(healthz)` response also lists DB/cache checks; only `status` is asserted.

## 7. Execution report (fill in)
