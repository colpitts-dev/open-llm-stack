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
