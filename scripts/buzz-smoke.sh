#!/usr/bin/env bash
# G7: from a throwaway human identity, create a channel, add the agent, mention it, expect a reply via LiteLLM.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9
RELAY_IMG=ghcr.io/block/buzz:sha-e17cdd9
URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
AGENT_PUB=${BUZZ_AGENT_PUBKEY:?run make init}
NAME=${BUZZ_AGENT_NAME:-stack-agent}
docker compose ps --status running buzz-agent | grep -q buzz-agent || { echo "buzz-agent is not running (add buzz-agent to COMPOSE_PROFILES and make up)" >&2; exit 1; }

HSEC=$(docker run --rm --entrypoint /usr/local/bin/buzz-admin "$RELAY_IMG" generate-key | awk '/Secret key:/{print $3}')
bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$HSEC" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@"; }
bz users set-profile --name smoke-human >/dev/null
ch=$(bz channels create --name "smoke-$(date +%s)" --type stream --visibility open --ttl 3600 | jq -r .channel_id)
[ -n "$ch" ] && [ "$ch" != "null" ] || { echo "channel creation failed" >&2; exit 1; }
echo "channel $ch"
bz channels add-member --channel "$ch" --pubkey "$AGENT_PUB" --role bot >/dev/null
sleep 3   # let the membership notification reach the harness
bz messages send --channel "$ch" --content "@${NAME} Reply with exactly the single word: PONG" --mention "$AGENT_PUB" >/dev/null
echo "mention sent; waiting for the agent (up to 240s)"
for i in $(seq 1 24); do
  sleep 10
  reply=$(bz messages get --channel "$ch" --limit 20 | jq -r --arg pk "$AGENT_PUB" '[.[] | select(.pubkey==$pk) | .content][0] // empty')
  if [ -n "$reply" ]; then echo "agent replied after ~$((i*10))s: $reply"; exit 0; fi
done
echo "FAIL: no reply within 240s. Inspect: docker compose logs buzz-agent" >&2
exit 1
