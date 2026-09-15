#!/usr/bin/env bash
# G-team: a human (throwaway smoke identity, on the allowlist) asks the builder for a change in demo-calc;
# expect a PR from the builder with a green `ci / test (pull_request)` check, then the reviewer's review, then the coordinator's score.
# Members come from teams/<TEAM_NAME>/team.toml by role (plan 16): the first builder, reviewer and coordinator.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
BUILDER=$(python3 scripts/team-roster.py role builder | head -1); REVIEWER=$(python3 scripts/team-roster.py role reviewer | head -1); COORD=$(python3 scripts/team-roster.py role coordinator | head -1)
read -r _ _ BUILDER_NAME BUILDER_LOGIN BP <<<"$(python3 scripts/team-roster.py members | awk -v n="$BUILDER" '$1==n')"
read -r _ _ REVIEWER_NAME REVIEWER_LOGIN RP <<<"$(python3 scripts/team-roster.py members | awk -v n="$REVIEWER" '$1==n')"
read -r _ _ COORD_NAME _ CP <<<"$(python3 scripts/team-roster.py members | awk -v n="$COORD" '$1==n')"
pub() { local v="$1_PUBKEY"; printf '%s' "${!v}"; }   # pub <ENV_PREFIX>: the member's pubkey from .env (prefix -> variable name -> value)
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9
URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
B="${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}/api/v1"; A="Authorization: token ${GITEA_ADMIN_TOKEN}"; OWNER="${TEAM_GITEA_ORG:-piedpiper}"; REPO=demo-calc
for s in $BUILDER $REVIEWER $COORD; do docker compose ps --status running $s | grep -q $s || { echo "$s not running (COMPOSE_PROFILES needs team; make up)" >&2; exit 1; }; done
bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_SMOKE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@"; }
bz users set-profile --name Richard-smoke >/dev/null
ch=$(bz channels create --name "job-$(date +%s)" --type stream --visibility open --ttl 7200 | jq -r .channel_id)
bz channels add-member --channel "$ch" --pubkey "$(pub "$BP")" --role bot >/dev/null
bz channels add-member --channel "$ch" --pubkey "$(pub "$RP")" --role bot >/dev/null
bz channels add-member --channel "$ch" --pubkey "$(pub "$CP")" --role bot >/dev/null      # the judge: delivery is members-only, and `@<coordinator>` in a message body fails to send unless they are a member (plan 13)
sleep 3; echo "channel $ch"
n0=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls?state=all" | jq '[.[].number] | max // 0')   # only a PR numbered above this counts
feature="subtract-$(date +%s | tail -c 5)"
bz messages send --channel "$ch" --mention "$(pub "$BP")" --content "@$BUILDER_NAME in the repository ${REPO}, add a function \`${feature//-/_}(a, b)\` that returns a - b, with a test, and open a pull request." >/dev/null
echo "job posted; waiting for a PR from $BUILDER_LOGIN (up to 15 min)"
pr=""; for i in $(seq 1 90); do sleep 10; pr=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls?state=open" | jq -r --argjson n0 "$n0" --arg b "$BUILDER_LOGIN" '[.[] | select(.user.login==$b and .number > $n0)] | sort_by(.created_at) | last | .number // empty'); [ -n "$pr" ] && break; done
[ -n "$pr" ] || { echo "FAIL: no PR from $BUILDER_LOGIN within 15 min; see docker compose logs $BUILDER" >&2; exit 1; }
echo "PR #$pr opened after ~$((i*10))s"
sha=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr" | jq -r .head.sha)
# read the ci / test (pull_request) context itself: the combined .state turns failure as soon as ANY context fails, e.g. the push-event run
st=""; for i in $(seq 1 60); do sleep 10; st=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/commits/$sha/status" | jq -r '[.statuses[] | select(.context=="ci / test (pull_request)") | .status][0] // "pending"'); [ "$st" = "success" ] || [ "$st" = "failure" ] && break; done
echo "CI on PR #$pr: $st"; [ "$st" = "success" ] || { echo "FAIL: CI not green" >&2; exit 1; }
url=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr" | jq -r .html_url)
bz messages send --channel "$ch" --mention "$(pub "$RP")" --content "@$REVIEWER_NAME review please $url" >/dev/null
# a PENDING review is an unsubmitted draft nobody but the reviewer can see; only a submitted state counts
rv=""; for i in $(seq 1 60); do sleep 10; rv=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr/reviews" | jq -r --arg r "$REVIEWER_LOGIN" '[.[] | select(.user.login==$r and .state!="PENDING")] | last | .state // empty'); [ -n "$rv" ] && break; done
echo "$REVIEWER_NAME review: ${rv:-(none within 10 min)}"; [ -n "$rv" ] || exit 1
echo "TEAM SMOKE PASS: PR #$pr, CI success, review $rv. Merge it in Gitea to close the loop (not automated on purpose)."
# Thread conventions (plan 11, G22): milestones + labelled deliverables from the agents' own posts; the mirror line only when it is on
root=$(bz messages get --channel "$ch" --limit 20 | jq -r --arg b "$BUILDER_NAME" '[.[] | select(.content|startswith("@" + $b + " "))][0].id')
rroot=$(bz messages get --channel "$ch" --limit 20 | jq -r --arg r "$REVIEWER_NAME" '[.[] | select(.content|startswith("@" + $r + " review please"))][0].id')
# The builder's turn may still be running after the reviewer answered (CI milestone and deliverable come in either order): wait up to 3 min for PR + CI milestone + Review
for i in $(seq 1 18); do
  th=$(bz messages thread --channel "$ch" --event "$root"); rth=$(bz messages thread --channel "$ch" --event "$rroot")
  jq -e --arg d "$(pub "$BP")" '[.[] | select(.pubkey==$d and (.content|test("^\\*\\*PR:\\*\\* ")))] | length > 0' <<<"$th" >/dev/null \
    && jq -e --arg d "$(pub "$BP")" '[.[] | select(.pubkey==$d and (.content|test("^(🚩 )?CI (success|failure)")))] | length > 0' <<<"$th" >/dev/null \
    && jq -e --arg g "$(pub "$RP")" '[.[] | select(.pubkey==$g and (.content|test("^\\*\\*Review:\\*\\* ")))] | length > 0' <<<"$(jq -s add <(printf '%s' "$th") <(printf '%s' "$rth"))" >/dev/null && break
  sleep 10   # the reviewer's thread post lands a few seconds after the Gitea review; the builder may still be finishing
done
th=$(jq -s 'add' <(printf '%s' "$th") <(printf '%s' "$rth"))   # job thread + review-request thread (the reviewer replies to the request)
jq -r --arg d "$(pub "$BP")" --arg g "$(pub "$RP")" '.[] | select(.pubkey==$d or .pubkey==$g) | (.content | split("\n")[0])' <<<"$th" | sed 's/^/thread: /' | head -40
chk() { jq -e --arg p "$1" --arg re "$2" '[.[] | select(.pubkey==$p and (.content|test($re)))] | length > 0' <<<"$th" >/dev/null && echo "PASS: $3" || { echo "FAIL: $3"; return 1; }; }
ok=0
# Milestones are persona posts: reported, not gated (2026-09-13: present in 8 of 11 runs, once without the flag). Labels are gated.
rep() { jq -e --arg p "$1" --arg re "$2" '[.[] | select(.pubkey==$p and (.content|test($re)))] | length > 0' <<<"$th" >/dev/null && echo "milestone: $3 present" || echo "milestone: $3 ABSENT (model skipped a persona step; not gated)"; }
rep "$(pub "$BP")" '^🚩 pushed '              "push"
rep "$(pub "$BP")" '^🚩 CI (success|failure)' "CI"
chk "$(pub "$BP")"   '^\*\*PR:\*\* http'        "PR deliverable label"   || ok=1
chk "$(pub "$RP")" '^\*\*Review:\*\* '        "review label"           || ok=1
case "${TEAM_NARRATE:-off}" in tools|both) chk "$(pub "$BP")" '^```\n\$ [^`]*git push' "mirror: git push command" || ok=1 ;; esac
[ "$ok" = 0 ] || { echo "THREAD CONVENTIONS FAIL (see above)" >&2; exit 1; }
# Score (plan 13, G27): the reviewer asks the coordinator after the verdict; the smoke asks too (fallback), then waits for the judge's line + labels
bz messages send --channel "$ch" --reply-to "$root" --mention "$(pub "$CP")" --content "@$COORD_NAME score $url" >/dev/null
sc=""; for i in $(seq 1 18); do
  # the judge answers whichever ask came first: the reviewer's (review thread) or the smoke's fallback (job thread); either thread counts (plan 16 §8)
  sc=$( { bz messages thread --channel "$ch" --event "$root"; bz messages thread --channel "$ch" --event "$rroot"; } | jq -rs --arg b "$(pub "$CP")" '[.[][] | select(.pubkey==$b and (.content|startswith("**Score:**")))] | last | .content // empty' | tr '\n' ' ')   # no `| head`: SIGPIPE under pipefail kills the script (plan 08 gotcha 2)
  [ -n "$sc" ] && break; sleep 10
done
if [ -n "$sc" ]; then echo "PASS: score line: $sc"; else echo "FAIL: no **Score:** line from $COORD_NAME within 3 min"; ok=1; fi
lb=$(curl -fsS -H "Authorization: token $(v="${CP}_GITEA_TOKEN"; printf '%s' "${!v}")" "$B/repos/$OWNER/$REPO/issues/$pr/labels" | jq -r 'map(.name)|join(",")')
grep -q 'complexity/' <<<"$lb" && grep -q 'confidence/' <<<"$lb" && echo "PASS: score labels: $lb" || { echo "FAIL: score labels missing ($lb)"; ok=1; }
[ "$ok" = 0 ] || { echo "SCORE FAIL (see above)" >&2; exit 1; }
