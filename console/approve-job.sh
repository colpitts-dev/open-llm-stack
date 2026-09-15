#!/usr/bin/env bash
# Approve a builder's **Plan:** as the console identity (plan 16.5 checkpoint). Usage: approve-job.sh <channel-uuid> <thread-root-id> [note]
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
ch=${1:?channel}; root=${2:?thread root}; note=${3:-}
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9; URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
: "${CONSOLE_PRIVATE_KEY:?run make init}"
team="${TEAM_NAME:?TEAM_NAME is blank in .env}"
builder=$(python3 -c 'import sys,tomllib; t=tomllib.load(open(sys.argv[1],"rb")); print(next(m["name"] for m in t["members"] if m["role"]=="builder"))' "teams/$team/team.toml")
builder_pub_var="TEAM_$(echo "$builder" | tr a-z A-Z)_PUBKEY"
docker run --rm --network host -e BUZZ_PRIVATE_KEY="$CONSOLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" messages send --channel "$ch" --reply-to "$root" --mention "${!builder_pub_var}" --content "approved${note:+: $note}" >/dev/null
echo "approved in $ch/$root"
