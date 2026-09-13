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

for who in DINESH GILFOYLE JARED ERLICH SMOKE; do
  if blank "TEAM_${who}_PRIVATE_KEY"; then
    out=$(gen_key)
    set_if_blank "TEAM_${who}_PRIVATE_KEY" "$(awk '/Secret key:/{print $3}' <<<"$out")"
    set_if_blank "TEAM_${who}_PUBKEY" "$(awk '/Public key:/{print $3}' <<<"$out")"
  fi
done
set_if_blank TEAM_GITEA_PASSWORD "$(hex 12)"
set_if_blank TEAM_HUMAN_PASSWORD "$(hex 12)"

echo "init complete. Next: check LLM_BASE_URL in .env and the models in proxy/config.yaml, then: make up"
