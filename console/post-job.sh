#!/usr/bin/env bash
# Post a job thread as the console identity (plan 17): a new job channel with the team's builder, reviewer and coordinator
# as bot members, then the ask, mentioning the builder. Same commands as scripts/team-smoke.sh. Usage: post-job.sh <team> <text>
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
team=$1; text=$2; SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9; URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
: "${CONSOLE_PRIVATE_KEY:?run make init}"
bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$CONSOLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@"; }
member() { python3 -c 'import sys,tomllib; t=tomllib.load(open(sys.argv[1],"rb")); print(next(m["name"] for m in t["members"] if m["role"]==sys.argv[2]))' "teams/$team/team.toml" "$1"; }
pub() { local v="TEAM_$(echo "$1" | tr a-z A-Z)_PUBKEY"; echo "${!v}"; }
b=$(member builder); r=$(member reviewer); c=$(member coordinator)
bz users set-profile --name Console >/dev/null
ch=$(bz channels create --name "job-$(date +%s)" --type stream --visibility private --ttl 86400 | jq -r .channel_id)   # private: the adversary and the gatekeeper stay out (plan 16.5)
for who in "$b" "$r" "$c"; do bz channels add-member --channel "$ch" --pubkey "$(pub "$who")" --role bot >/dev/null; done
for h in $(tr ',' ' ' <<<"${TEAM_ALLOWLIST:-}"); do bz channels add-member --channel "$ch" --pubkey "$h" --role member >/dev/null; done   # the humans who may reply `approved`
bz messages send --channel "$ch" --mention "$(pub "$b")" --content "@${b^} $text" >/dev/null
root=$(bz messages get --channel "$ch" --limit 5 | jq -r --arg b "${b^}" '[.[] | select(.content|startswith("@" + $b + " "))][0].id')
echo "posted to channel $ch (thread root $root), mentioning ${b^}; the builder answers with **Plan:** and waits for a human \`approved\` (Buzz app, or console/approve-job.sh $ch $root)"
