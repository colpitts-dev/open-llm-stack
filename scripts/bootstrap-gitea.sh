#!/usr/bin/env bash
# Idempotent: create the admin user from .env, mint an API token, store it in .env as GITEA_ADMIN_TOKEN.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
has_profile() { [[ ",${COMPOSE_PROFILES:-}," == *",$1,"* ]]; }
has_profile gitea || { echo "gitea profile is off: external Gitea at $GITEA_PUBLIC_URL -- paste GITEA_ADMIN_TOKEN (write:admin,write:organization,write:repository,write:user) into .env instead"; exit 0; }
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

# The team bootstrap needs an admin-scoped token (POST /admin/users). Probe the stored one; re-mint when it predates that scope.
if [ -n "${GITEA_ADMIN_TOKEN:-}" ] && [ "${1:-}" != "--rotate" ]; then
  case "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: token $GITEA_ADMIN_TOKEN" "${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}/api/v1/admin/users?limit=1")" in
    200) echo "GITEA_ADMIN_TOKEN already set and admin-scoped (pass --rotate to mint a new one)"; exit 0 ;;
    401|403) echo "GITEA_ADMIN_TOKEN lacks write:admin -- re-minted with write:admin; delete the old token in Gitea" ;;
    *) echo "ERROR: cannot reach ${GITEA_PUBLIC_URL:-http://127.0.0.1:3003} to check the token" >&2; exit 1 ;;
  esac
fi
# token names must be unique per call -- nanoseconds + pid
token=$(docker compose exec -T -u git gitea gitea admin user generate-access-token \
  --username "$GITEA_ADMIN_USER" --token-name "stack-$(date +%s%N)-$$" \
  --scopes write:admin,write:organization,write:repository,write:user --raw | tr -d '\r\n')   # write:admin: agent users; write:organization: the team org
[ ${#token} -ge 20 ] || { echo "ERROR: token generation returned '$token'" >&2; exit 1; }
sed -i "s|^GITEA_ADMIN_TOKEN=.*|GITEA_ADMIN_TOKEN=${token}|" .env
echo "GITEA_ADMIN_TOKEN written to .env"
