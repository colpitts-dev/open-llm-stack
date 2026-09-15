#!/usr/bin/env bash
# G-team (plan 16.5): the smoke identity plays the owner. Job -> **Plan:** -> `approved` -> PR by the builder (body `Spec: #n`), green CI
# -> the coordinator routes: reviewer (**Review:** + **Conformance:** comment) -> adversary in #attack (review + defect/* label)
# -> gatekeeper in #gate (**Verdict:** + **Score:** + ledger issue). The smoke asks a stage itself when the coordinator has not within the budget.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
first() { python3 scripts/team-roster.py role "$1" | awk 'NR==1'; }
BUILDER=$(first builder); REVIEWER=$(first reviewer); COORD=$(first coordinator); ADV=$(first adversary); GATE=$(first gatekeeper)
[ -n "$BUILDER" ] && [ -n "$REVIEWER" ] && [ -n "$COORD" ] && [ -n "$ADV" ] && [ -n "$GATE" ] || { echo "team.toml needs a builder, a reviewer, a coordinator, an adversary and a gatekeeper" >&2; exit 1; }
row() { python3 scripts/team-roster.py members | awk -v n="$1" '$1==n'; }
read -r _ _ BUILDER_NAME BUILDER_LOGIN BP <<<"$(row "$BUILDER")"; read -r _ _ REVIEWER_NAME REVIEWER_LOGIN RP <<<"$(row "$REVIEWER")"
read -r _ _ COORD_NAME _ CP <<<"$(row "$COORD")"; read -r _ _ ADV_NAME ADV_LOGIN AP <<<"$(row "$ADV")"; read -r _ _ GATE_NAME GATE_LOGIN GP <<<"$(row "$GATE")"
pub() { local v="$1_PUBKEY"; printf '%s' "${!v}"; }; tok() { local v="$1_GITEA_TOKEN"; printf '%s' "${!v}"; }
: "${TEAM_ATTACK_CHANNEL:?run make team-bootstrap (creates #attack)}" "${TEAM_GATE_CHANNEL:?run make team-bootstrap (creates #gate)}"
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9; URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
B="${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}/api/v1"; A="Authorization: token ${GITEA_ADMIN_TOKEN}"; J="Authorization: token $(tok "$CP")"; OWNER="${TEAM_GITEA_ORG:-piedpiper}"; REPO=demo-calc
for s in $BUILDER $REVIEWER $COORD $ADV $GATE; do docker compose ps --status running $s | grep -q $s || { echo "$s not running (COMPOSE_PROFILES needs team; make up)" >&2; exit 1; }; done
bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_SMOKE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@"; }
bz users set-profile --name Richard-smoke >/dev/null
# a PRIVATE job channel (plan 16.5): the adversary and the gatekeeper are not members and cannot read it; the builder, reviewer and coordinator are
ch=$(bz channels create --name "job-$(date +%s)" --type stream --visibility private --ttl 7200 | jq -r .channel_id)
for p in "$BP" "$RP" "$CP"; do bz channels add-member --channel "$ch" --pubkey "$(pub "$p")" --role bot >/dev/null; done
sleep 3; echo "channel $ch"
ok=0; pass() { echo "PASS: $1"; }; fail() { echo "FAIL: $1"; ok=1; }
n0=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls?state=all" | jq '[.[].number] | max // 0')
feature="divide-$(date +%s | tail -c 5)"; fn="${feature//-/_}"
bz messages send --channel "$ch" --mention "$(pub "$BP")" --content "@$BUILDER_NAME in the repository ${REPO}, add a function \`${fn}(a, b)\` that returns a / b, with a test, and open a pull request." >/dev/null
root=$(bz messages get --channel "$ch" --limit 20 | jq -r --arg b "$BUILDER_NAME" '[.[] | select(.content|startswith("@" + $b + " "))][0].id')
thread() { bz messages thread --channel "$ch" --event "$root"; }
# Stage 1 (G46): the plan, then nothing until a human approves
echo "job posted; waiting for **Plan:** from $BUILDER_NAME (up to 5 min)"
plan=""; for i in $(seq 1 30); do sleep 10; plan=$(thread | jq -r --arg b "$(pub "$BP")" '[.[] | select(.pubkey==$b and (.content|startswith("**Plan:** ")))] | last | .content // empty'); [ -n "$plan" ] && break; done
if [ -n "$plan" ]; then pass "plan posted after ~$((i*10))s: $(jq -r 'split("\n")[0]' <<<"$(jq -Rs . <<<"$plan")" | cut -c1-100)"; else fail "no **Plan:** within 5 min"; fi
# grep -c exits 1 on a zero count; under set -e that killed the smoke instead of printing the FAIL
crit=$(sed 's/`//g' <<<"$plan" | grep -cE '^- (- )?\[ \] ' || true); if [ "$crit" -ge 3 ] && [ "$crit" -le 6 ]; then pass "acceptance checklist: $crit items"; else fail "acceptance checklist: $crit items (want 3-6)"; fi
sleep 20   # the builder must be idle: no PR before approval
pre=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls?state=all" | jq --argjson n0 "$n0" '[.[] | select(.number > $n0)] | length'); if [ "$pre" = 0 ]; then pass "nothing opened before approval (PRs above #$n0: 0)"; else fail "PR opened before approval"; fi
bz messages send --channel "$ch" --reply-to "$root" --mention "$(pub "$BP")" --content "approved" >/dev/null; echo "approved by Richard-smoke"
# Stage 2: PR by the builder with Spec: #n and green CI
pr=""; for i in $(seq 1 90); do sleep 10; pr=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls?state=open" | jq -r --argjson n0 "$n0" --arg b "$BUILDER_LOGIN" '[.[] | select(.user.login==$b and .number > $n0)] | sort_by(.number) | last | .number // empty'); [ -n "$pr" ] && break; done
[ -n "$pr" ] || { echo "FAIL: no PR from $BUILDER_LOGIN within 15 min; see docker compose logs $BUILDER" >&2; exit 1; }
echo "PR #$pr opened after ~$((i*10))s"
prj=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr"); sha=$(jq -r .head.sha <<<"$prj"); url=$(jq -r .html_url <<<"$prj")
spec=$(jq -r '(.body // "") | capture("Spec: #(?<n>[0-9]+)") | .n' <<<"$prj" 2>/dev/null || true)
if [ -n "$spec" ] && [ "$(curl -sS -o /dev/null -w '%{http_code}' -H "$J" "$B/repos/$OWNER/$REPO/issues/$spec")" = 200 ]; then pass "PR body links the spec issue #$spec"; else fail "PR body has no valid 'Spec: #n' line"; fi
st=""; for i in $(seq 1 60); do sleep 10; st=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/commits/$sha/status" | jq -r '[.statuses[] | select(.context=="ci / test (pull_request)") | .status][0] // "pending"'); { [ "$st" = success ] || [ "$st" = failure ]; } && break; done
echo "CI on PR #$pr: $st"; [ "$st" = success ] || { echo "FAIL: CI not green" >&2; exit 1; }
# Stage 3: review + conformance (the coordinator routes; the smoke asks the reviewer itself after 4 min)
rv=""; conf=""; for i in $(seq 1 60); do sleep 10
  [ "$i" = 24 ] && { bz messages send --channel "$ch" --reply-to "$root" --mention "$(pub "$RP")" --content "@$REVIEWER_NAME review please $url" >/dev/null; echo "(fallback: the smoke asked the reviewer)"; }
  rv=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr/reviews" | jq -r --arg r "$REVIEWER_LOGIN" '[.[] | select(.user.login==$r and .state!="PENDING")] | last | .state // empty')
  conf=$(curl -fsS -H "$J" "$B/repos/$OWNER/$REPO/issues/$pr/comments" | jq -r --arg r "$REVIEWER_LOGIN" '[.[] | select(.user.login==$r and (.body|startswith("**Conformance:** ")))] | last | ((.body // "") | split("\n")[0]) // ""')
  [ -n "$rv" ] && [ -n "$conf" ] && break; done
if [ -n "$rv" ]; then pass "review by $REVIEWER_NAME: $rv"; else fail "no review from $REVIEWER_LOGIN within 10 min"; fi
if [ -n "$conf" ]; then pass "conformance comment: $(cut -c1-80 <<<"$conf")"; else fail "no **Conformance:** comment from $REVIEWER_LOGIN"; fi
# Stage 4 (G47): the adversary attacks blind in #attack (the coordinator routes; the smoke asks after 4 min)
att=""; lab=""; for i in $(seq 1 60); do sleep 10
  [ "$i" = 24 ] && { bz messages send --channel "$TEAM_ATTACK_CHANNEL" --mention "$(pub "$AP")" --content "@$ADV_NAME attack $url · return $ch/$root" >/dev/null; echo "(fallback: the smoke asked the adversary)"; }
  att=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr/reviews" | jq -r --arg a "$ADV_LOGIN" '[.[] | select(.user.login==$a and .state!="PENDING")] | last | if . == null then empty else .state + " " + (((.body // "") | split("\n")[0]) // "") end')
  lab=$(curl -fsS -H "$J" "$B/repos/$OWNER/$REPO/issues/$pr/labels" | jq -r '[.[].name | select(startswith("defect/"))] | first // empty')
  [ -n "$att" ] && [ -n "$lab" ] && break; done
if [ -n "$att" ]; then pass "attack review by $ADV_LOGIN: $(cut -c1-90 <<<"$att")"; else fail "no attack review from $ADV_LOGIN within 10 min"; fi
if [ -n "$lab" ]; then pass "defect label: $lab"; else fail "no defect/* label on PR #$pr"; fi
echo "attack line in #attack: $(bz messages get --channel "$TEAM_ATTACK_CHANNEL" --limit 30 | jq -r --arg a "$(pub "$AP")" '[.[] | select(.pubkey==$a and (.content|startswith("**Attack:**")))] | last | (.content // "(none)") | split("\n")[0]' | cut -c1-120)"
if [ "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: token $(tok "$AP")" "$B/repos/$OWNER/$REPO/issues/${spec:-1}")" = 404 ]; then pass "barrier: the adversary's token cannot read issues (404)"; else fail "the adversary can read issues"; fi
# Stage 5 (G48): the gate (the coordinator routes when nothing critical/high is open; the smoke asks after 4 min either way; both verdicts are valid)
ver=""; sc=""; for i in $(seq 1 48); do sleep 10
  [ "$i" = 24 ] && { bz messages send --channel "$TEAM_GATE_CHANNEL" --mention "$(pub "$GP")" --content "@$GATE_NAME gate $url · return $ch/$root" >/dev/null; echo "(fallback: the smoke asked the gatekeeper)"; }
  msgs=$(bz messages get --channel "$TEAM_GATE_CHANNEL" --limit 40)
  ver=$(jq -r --arg g "$(pub "$GP")" --arg k "$REPO#$pr (" '[.[] | select(.pubkey==$g and (.content|startswith("**Verdict:** ")) and (.content|contains($k)))] | last | ((.content // "") | split("\n")[0]) // ""' <<<"$msgs")
  sc=$(jq -r --arg g "$(pub "$GP")" '[.[] | select(.pubkey==$g and (.content|startswith("**Score:** ")))] | last | ((.content // "") | split("\n")[0]) // ""' <<<"$msgs")
  [ -n "$ver" ] && break; done
if [ -n "$ver" ]; then pass "verdict: $(cut -c1-110 <<<"$ver")"; else fail "no **Verdict:** for $REPO#$pr from $GATE_NAME within 8 min"; fi
if [ -n "$sc" ]; then pass "score line: $(cut -c1-80 <<<"$sc")"; else fail "no **Score:** line from $GATE_NAME"; fi
lb=$(curl -fsS -H "$J" "$B/repos/$OWNER/$REPO/issues/$pr/labels" | jq -r '[.[].name | select(startswith("complexity/") or startswith("confidence/"))] | join(",")')
if [[ $lb == *complexity/* && $lb == *confidence/* ]]; then pass "score labels: $lb"; else fail "score labels missing: '$lb'"; fi
led=$(curl -fsS -H "$J" "$B/repos/$GATE_LOGIN/gate/issues?state=all&limit=20" | jq -r --arg t "$REPO#$pr " '[.[] | select(.title|startswith($t))] | last | .title // empty')
if [ -n "$led" ]; then pass "ledger: $GATE_LOGIN/gate '$led'"; else fail "no ledger issue in $GATE_LOGIN/gate for $REPO#$pr"; fi
want=$(docker compose exec -T "$GATE" /opt/team/agents/bin/gate-signals "$REPO" "$pr" 2>/dev/null | grep -E '^VERDICT=' | cut -d= -f2 || true)
got=$(grep -oE '^\*\*Verdict:\*\* (ship|no-ship)' <<<"$ver" | awk '{print $2}' || true)
if [ -n "$want" ] && [ "$got" = "$want" ]; then pass "verdict equals gate-signals ($want)"; else fail "verdict '$got' vs gate-signals '$want'"; fi
if [ "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: token $(tok "$BP")" "$B/repos/$GATE_LOGIN/gate")" = 404 ]; then pass "barrier: the builder cannot see $GATE_LOGIN/gate (404)"; else fail "the builder can see the ledger"; fi
# Thread conventions (plan 11): milestones reported, labels gated
th=$(thread)
rep() { jq -e --arg p "$1" --arg re "$2" '[.[] | select(.pubkey==$p and (.content|test($re)))] | length > 0' <<<"$th" >/dev/null && echo "milestone: $3 present" || echo "milestone: $3 ABSENT (model skipped a persona step; not gated)"; }
chk() { jq -e --arg p "$1" --arg re "$2" '[.[] | select(.pubkey==$p and (.content|test($re)))] | length > 0' <<<"$th" >/dev/null && pass "$3" || fail "$3"; }
rep "$(pub "$BP")" '^🚩 pushed '              "push"
rep "$(pub "$BP")" '^🚩 CI (success|failure)' "CI"
chk "$(pub "$BP")" '^\*\*Plan:\*\* '  "plan deliverable label"
chk "$(pub "$BP")" '^\*\*PR:\*\* http' "PR deliverable label"
chk "$(pub "$RP")" '^\*\*Review:\*\* ' "review label in the job thread"
jq -r --arg d "$(pub "$BP")" --arg g "$(pub "$RP")" --arg c "$(pub "$CP")" '.[] | select(.pubkey==$d or .pubkey==$g or .pubkey==$c) | (.content | split("\n")[0])' <<<"$th" | sed 's/^/thread: /' | cut -c1-140
if [ "$ok" = 0 ]; then echo "TEAM SMOKE PASS: PR #$pr, CI success, review $rv, attack $lab, verdict $got. Merge it in Gitea to close the loop (not automated on purpose)."; else echo "TEAM SMOKE FAIL (see above)" >&2; exit 1; fi
