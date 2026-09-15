#!/usr/bin/env bash
# Plan 16.5 gates into one log. Usage: VALIDATE_LOG=<file> scripts/validate-16.5.sh   (default /tmp/validate-16.5.log; ends with "## DONE")
# Order: render + bootstrap + recreate -> static barriers (G47/G48 halves that need no LLM) -> smoke 1 (G46 G47 G48) -> G45 on that PR -> smoke 2 + make test (G49)
set -uo pipefail; cd "$(dirname "$0")/.."
LOG="${VALIDATE_LOG:-/tmp/validate-16.5.log}"; exec >>"$LOG" 2>&1
pgrep -af '[v]alidate-16.5.sh' | grep -v "^$$ " | grep -q . && { echo "another validate-16.5.sh is running"; exit 1; }
pgrep -af '[t]eam-smoke.sh' >/dev/null && { echo "a team-smoke is running; wait for it"; exit 1; }
g() { if [ "$1" = 0 ]; then echo "PASS $2 $3"; else echo "FAIL $2 $3"; fi; }
echo "## validate 16.5 $(date -Is)"
unset TEAM_NAME TEAM_ATTACK_CHANNEL TEAM_GATE_CHANNEL
make team-render
./scripts/bootstrap-team.sh > "$LOG.bootstrap" 2>&1; rb=$?; grep -E 'created|exists|channel|gate|readers|labels|written|WARN|rror' "$LOG.bootstrap" | tail -30; echo "bootstrap exit $rb"
set -a; . ./.env; set +a
MEMBERS=$(python3 scripts/team-roster.py members | cut -d' ' -f1 | paste -sd ' '); NM=$(wc -w <<<"$MEMBERS")
docker compose up -d --remove-orphans --force-recreate $MEMBERS; ru=$?
for i in $(seq 1 40); do n=$(docker compose ps --format '{{.Service}} {{.Health}}' | grep -cE "^($(tr ' ' '|' <<<"$MEMBERS")) healthy"); [ "$n" = "$NM" ] && break; sleep 10; done; echo "healthy members: $n/$NM"
first() { python3 scripts/team-roster.py role "$1" | awk 'NR==1'; }; row() { python3 scripts/team-roster.py members | awk -v n="$1" '$1==n'; }
read -r _ _ _ BL BP <<<"$(row "$(first builder)")"; read -r _ _ _ RL RP <<<"$(row "$(first reviewer)")"; read -r _ _ _ CL CP <<<"$(row "$(first coordinator)")"
read -r _ _ _ AL AP <<<"$(row "$(first adversary)")"; read -r _ _ _ GL GP <<<"$(row "$(first gatekeeper)")"
tok() { local v="$1_GITEA_TOKEN"; printf '%s' "${!v}"; }; pub() { local v="$1_PUBKEY"; printf '%s' "${!v}"; }
B="${GITEA_PUBLIC_URL%/}/api/v1"; ORG="${TEAM_GITEA_ORG:-piedpiper}"
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }
echo "## static barriers $(date -Is)"
spec=$(curl -sS -H "Authorization: token $(tok "$CP")" "$B/repos/$ORG/demo-calc/issues?state=all&type=issues&limit=1" | jq -r '.[0].number // 1')
a1=$(code -H "Authorization: token $(tok "$AP")" "$B/repos/$ORG/demo-calc/issues?type=issues"); a2=$(code -H "Authorization: token $(tok "$AP")" "$B/repos/$ORG/demo-calc/issues/$spec"); a3=$(code -H "Authorization: token $(tok "$AP")" "$B/repos/$ORG/demo-calc/pulls")
echo "adversary token: issues list $a1 (404), issue #$spec $a2 (404), pulls $a3 (200)"
g1=$(code -X PATCH -H "Authorization: token $(tok "$GP")" -H 'Content-Type: application/json' -d '{"body":"tamper"}' "$B/repos/$ORG/demo-calc/issues/$spec"); g2=$(code -H "Authorization: token $(tok "$GP")" "$B/repos/$ORG/demo-calc/issues/$spec"); g3=$(code -H "Authorization: token $(tok "$GP")" "$B/repos/$GL/gate")
echo "gatekeeper token: patch issue $g1 (403), read issue $g2 (200), own ledger $g3 (200)"
b1=$(code -H "Authorization: token $(tok "$BP")" "$B/repos/$GL/gate"); r1=$(code -H "Authorization: token $(tok "$RP")" "$B/repos/$GL/gate"); c1=$(code -H "Authorization: token $(tok "$CP")" "$B/repos/$GL/gate/issues"); x1=$(code -H "Authorization: token $(tok "$AP")" "$B/repos/$GL/gate")
echo "ledger $GL/gate: builder $b1 (404), reviewer $r1 (404), adversary $x1 (404), coordinator issues $c1 (200)"
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9; URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
bzk() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$1" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "${@:2}"; }
bkey="TEAM_$(tr 'a-z-' 'A-Z_' <<<"$(first builder)")_PRIVATE_KEY"; s1=$(bzk "${!bkey}" messages send --channel "$TEAM_GATE_CHANNEL" --content "intrude" 2>&1 | grep -o 'not a channel member' || echo "ACCEPTED")
akey="TEAM_$(tr 'a-z-' 'A-Z_' <<<"$(first adversary)")_PRIVATE_KEY"; s2=$(bzk "${!akey}" messages send --channel "$TEAM_GATE_CHANNEL" --content "intrude" 2>&1 | grep -o 'not a channel member' || echo "ACCEPTED")
echo "builder -> #gate: $s1; adversary -> #gate: $s2 (want: not a channel member)"
m1=$(bzk "$TEAM_SMOKE_PRIVATE_KEY" channels members --channel "$TEAM_ATTACK_CHANNEL" | jq -r '[.[].pubkey]'); m2=$(bzk "$TEAM_SMOKE_PRIVATE_KEY" channels members --channel "$TEAM_GATE_CHANNEL" | jq -r '[.[].pubkey]')
ma=$(jq -r --arg a "$(pub "$AP")" --arg c "$(pub "$CP")" --arg g "$(pub "$GP")" 'index($a) != null and index($c) != null and index($g) == null' <<<"$m1"); mg=$(jq -r --arg a "$(pub "$AP")" --arg c "$(pub "$CP")" --arg g "$(pub "$GP")" 'index($g) != null and index($c) != null and index($a) == null' <<<"$m2")
echo "#attack has adversary+coordinator, not gatekeeper: $ma; #gate has gatekeeper+coordinator, not adversary: $mg"
[ "$a1" = 404 ] && [ "$a2" = 404 ] && [ "$a3" = 200 ] && [ "$g1" = 403 ] && [ "$g2" = 200 ] && [ "$g3" = 200 ] && [ "$b1" = 404 ] && [ "$r1" = 404 ] && [ "$x1" = 404 ] && [ "$c1" = 200 ] && [ "$s1" != ACCEPTED ] && [ "$s2" != ACCEPTED ] && [ "$ma" = true ] && [ "$mg" = true ]; g $? G47-G48-static "issues=$a1/$a2 patch=$g1 ledger=$b1/$r1/$x1/$c1 send=$s1/$s2 members=$ma/$mg"
echo "## smoke 1 (G46 G47 G48) $(date -Is)"
./scripts/team-smoke.sh > "$LOG.smoke1" 2>&1; s1=$?; grep -E '^(PASS|FAIL|milestone|channel|PR #|CI on|attack line|TEAM SMOKE)' "$LOG.smoke1" | cut -c1-160; echo "smoke 1 exit $s1"
grep -q 'PASS: plan posted' "$LOG.smoke1" && grep -q 'PASS: acceptance checklist' "$LOG.smoke1" && grep -q 'PASS: nothing opened before approval' "$LOG.smoke1" && grep -q 'PASS: PR body links the spec issue' "$LOG.smoke1"; g $? G46 "plan, checklist, no PR before approved, Spec: #n"
grep -q 'PASS: attack review' "$LOG.smoke1" && grep -q 'PASS: defect label' "$LOG.smoke1" && grep -q 'PASS: barrier: the adversary' "$LOG.smoke1"; g $? G47 "attack review + defect label + issues 404"
grep -q 'PASS: verdict:' "$LOG.smoke1" && grep -q 'PASS: score line' "$LOG.smoke1" && grep -q 'PASS: ledger' "$LOG.smoke1" && grep -q 'PASS: verdict equals gate-signals' "$LOG.smoke1" && grep -q 'PASS: barrier: the builder' "$LOG.smoke1"; g $? G48 "verdict + score + ledger + equals gate-signals + builder 404"
echo "## G45 script path on the smoke PR $(date -Is)"
pr=$(grep -oE '^PR #[0-9]+' "$LOG.smoke1" | grep -oE '[0-9]+' | tail -1)
sig=$(docker compose exec -T "$(first gatekeeper)" /opt/team/agents/bin/gate-signals demo-calc "$pr" 2>&1 | sed '/^--- diff/,$d'); grep -E '^(CI|REVIEW|APPROVALS|CONFORMANCE|ATTACK|DEFECT|SPEC|CRITERIA|VERDICT|REASONS)=' <<<"$sig"
sig2=$(docker compose exec -T "$(first gatekeeper)" /opt/team/agents/bin/gate-signals demo-calc "$pr" 2>&1 | sed '/^--- diff/,$d'); v1=$(sed -n 's/^VERDICT=//p' <<<"$sig"); v2=$(sed -n 's/^VERDICT=//p' <<<"$sig2")
docker compose exec -T "$(first gatekeeper)" bash -c 'printf "{\"scope\":0,\"novelty\":3}" > /tmp/bad.json; /opt/team/agents/bin/gate-post demo-calc '"$pr"' /tmp/bad.json' >/dev/null 2>&1; bad=$?
led=$(curl -sS -H "Authorization: token $(tok "$CP")" "$B/repos/$GL/gate/issues?state=all&limit=20" | jq -r --arg t "demo-calc#$pr " '[.[] | select(.title|startswith($t))] | length')
[ -n "$v1" ] && [ "$v1" = "$v2" ] && [ "$bad" != 0 ] && [ "$led" -ge 1 ]; g $? G45 "verdict=$v1 deterministic=$([ "$v1" = "$v2" ] && echo yes || echo no) bad-rubric-exit=$bad ledger-entries=$led"
echo "## smoke 2 + make test (G49) $(date -Is)"
./scripts/team-smoke.sh > "$LOG.smoke2" 2>&1; s2=$?; grep -E '^(PASS|FAIL|TEAM SMOKE)' "$LOG.smoke2" | cut -c1-160; echo "smoke 2 exit $s2"
make test > "$LOG.maketest" 2>&1; mt=$?; grep -E 'PASS|FAIL|ok|gate|ledger|TEAM SMOKE' "$LOG.maketest" | tail -30 | cut -c1-160; echo "make test exit $mt"
[ "$s1" = 0 ] && [ "$s2" = 0 ] && [ "$mt" = 0 ]; g $? G49 "smoke=$s1/$s2 make-test=$mt"
echo "## DONE $(date -Is)"
