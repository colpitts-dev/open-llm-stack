#!/usr/bin/env bash
# Poll open job-* channels for a bare, case-insensitive "approved"/"#approved" reply from an
# allowlisted human (no @mention needed) and approve automatically via console/approve-job.sh.
# Plan 19: Buzz Desktop's @mention picker doesn't resolve server (bot-role) agents, and a bare
# unmentioned "approved" never reaches a builder subscribed to mentions only (BUZZ_ACP_SUBSCRIBE
# default). This script closes that gap without touching any agent's config.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${CONSOLE_PRIVATE_KEY:?run make init}"
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9
URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
INTERVAL=${I:-15}
SEEN=console/.watch-since
STATE=console/.watch-approved

LOCK=console/.approve-watch.lock
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "another approve-watch.sh is already running: $(cat "$LOCK")"; exit 1
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

[ -f "$SEEN" ] || date +%s > "$SEEN"
[ -f "$STATE" ] || : > "$STATE"

bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$CONSOLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }

echo "watching job-* channels for a human 'approved' reply, poll every ${INTERVAL}s (Ctrl-C to stop)"
trap 'echo; echo "stopped"; exit 0' INT TERM

while true; do
  since=$(cat "$SEEN"); now=$(date +%s)
  for ch in $(bz channels list --member --limit 500 | jq -r '.[] | select(.name // "" | startswith("job-")) | .channel_id'); do
    while IFS= read -r ev; do
      [ -n "$ev" ] || continue
      pk=$(jq -r '.pubkey' <<<"$ev")
      content=$(jq -r '.content' <<<"$ev")
      root=$(jq -r '[.tags[]? | select(.[0]=="e" and (.[3] // "")=="reply")][0][1] // empty' <<<"$ev")
      [ -n "$root" ] || continue
      case ",${TEAM_ALLOWLIST:-},${TEAM_SMOKE_PUBKEY:-}," in *",$pk,"*) : ;; *) continue ;; esac
      grep -qiE '^#?approved([[:space:]:]|$)' <<<"$content" || continue
      grep -qF "$root" "$STATE" && continue
      note=$(sed -E 's/^#?[Aa][Pp][Pp][Rr][Oo][Vv][Ee][Dd][:[:space:]]*//' <<<"$content")
      echo "approving $ch/$root (from $pk): ${content}"
      start=$(date +%s.%N)
      rc=0
      ./console/approve-job.sh "$ch" "$root" "$note" </dev/null || rc=$?
      dur=$(awk -v s="$start" -v e="$(date +%s.%N)" 'BEGIN{printf "%.1f", e-s}')
      echo "$root" >> "$STATE"
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      cmd="console/approve-job.sh $ch $root${note:+ $note}"
      jq -nc --arg ts "$ts" --arg cmd "$cmd" --argjson exit "$rc" --argjson seconds "$dur" \
        '{ts:$ts, actor:"watcher", action:"approve-job", cmd:$cmd, exit:$exit, seconds:$seconds, job:"watch"}' >> console/audit.log
    done < <(bz messages get --channel "$ch" --since "$since" --kinds 9 2>/dev/null | jq -c '.[]?')
  done
  echo "$now" > "$SEEN"
  sleep "$INTERVAL"
done
