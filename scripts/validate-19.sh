#!/usr/bin/env bash
# Validate plan 19 (job approval watcher): gates G60-G63. Usage: scripts/validate-19.sh
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
LOG=${VALIDATE_LOG:-/tmp/validate-19.log}
: > "$LOG"
log(){ echo "$@" | tee -a "$LOG"; }

LOCK=/tmp/.validate-19.lock
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  log "FAIL guard another validate-19.sh is already running: $(cat "$LOCK")"; exit 1
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9
URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
bz_console()   { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$CONSOLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }
bz_smoke()     { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_SMOKE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }
bz_gilfoyle()  { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_GILFOYLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }

ch=$(bz_console channels create --name "job-validate-$(date +%s)" --type stream --visibility private --ttl 3600 | jq -r .channel_id)
bz_console channels add-member --channel "$ch" --pubkey "$TEAM_SMOKE_PUBKEY" --role member >/dev/null
bz_console channels add-member --channel "$ch" --pubkey "$TEAM_GILFOYLE_PUBKEY" --role bot >/dev/null
bz_console messages send --channel "$ch" --content "validate-19 fixture root" >/dev/null
root=$(bz_console messages get --channel "$ch" --limit 5 | jq -r '[.[] | select(.content=="validate-19 fixture root")][0].id')
log "fixture channel $ch root $root"

audit_count(){ grep -c "\"cmd\":\"console/approve-job.sh $ch $root" console/audit.log 2>/dev/null; }

setsid nohup env I=5 ./console/approve-watch.sh > /tmp/validate-19-watch.log 2>&1 < /dev/null &
WPID=$!
sleep 1
PGID=$(ps -o pgid= "$WPID" 2>/dev/null | tr -d ' ')
log "watcher pid $WPID pgid $PGID"

# G60: bare, unmentioned, case-varied "approved" from an allowlisted (smoke) human reaches approve-job.sh
bz_smoke messages send --channel "$ch" --reply-to "$root" --content "Approved" >/dev/null
for i in $(seq 1 20); do [ "$(audit_count)" -ge 1 ] && break; sleep 1; done
c=$(audit_count)
if [ "$c" -ge 1 ] && grep -qF "$root" console/.watch-approved; then
  log "PASS G60 bare mention-less 'Approved' reached approve-job.sh (audit_count=$c)"
else
  log "FAIL G60 no approve-job.sh call recorded for $root within 20s (audit_count=$c)"
fi

# G61: a teammate's reply and non-matching content are both ignored
bz_gilfoyle messages send --channel "$ch" --reply-to "$root" --content "approved" >/dev/null
bz_smoke    messages send --channel "$ch" --reply-to "$root" --content "not approved yet" >/dev/null
sleep 8
c2=$(audit_count)
if [ "$c2" -eq "$c" ]; then
  log "PASS G61 teammate reply and non-matching content ignored (audit_count still $c2)"
else
  log "FAIL G61 audit count changed from $c to $c2 on a non-approval"
fi

# G62: a second matching reply on the SAME root does not double-approve
bz_smoke messages send --channel "$ch" --reply-to "$root" --content "#APPROVED again" >/dev/null
sleep 8
c3=$(audit_count)
if [ "$c3" -eq "$c" ]; then
  log "PASS G62 duplicate approved reply did not re-fire (audit_count still $c3)"
else
  log "FAIL G62 duplicate approved reply fired again ($c -> $c3)"
fi

# G63: a second watcher instance refuses to start; the first stops cleanly on SIGTERM
if env I=5 ./console/approve-watch.sh > /tmp/validate-19-second.log 2>&1 </dev/null; then
  log "FAIL G63 a second approve-watch.sh instance was allowed to start"
else
  if grep -qi "already running" /tmp/validate-19-second.log; then
    log "PASS G63a second instance refused: $(cat /tmp/validate-19-second.log)"
  else
    log "FAIL G63a second instance exited nonzero for the wrong reason: $(cat /tmp/validate-19-second.log)"
  fi
fi
[ -n "$PGID" ] && kill -TERM -- -"$PGID" 2>/dev/null
sleep 1
if pgrep -f '[a]pprove-watch\.sh' >/dev/null; then
  log "FAIL G63b watcher still running after SIGTERM"
else
  log "PASS G63b watcher stopped cleanly on SIGTERM"
fi

log "## DONE"
