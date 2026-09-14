#!/usr/bin/env bash
# G-team: a human (throwaway smoke identity, on the allowlist) asks Dinesh for a change in demo-calc;
# expect a PR from dinesh with a green `ci / test (pull_request)` check, then a Gilfoyle review.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9
URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
B="${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}/api/v1"; A="Authorization: token ${GITEA_ADMIN_TOKEN}"; OWNER="${TEAM_GITEA_ORG:-piedpiper}"; REPO=demo-calc
for s in dinesh gilfoyle; do docker compose ps --status running $s | grep -q $s || { echo "$s not running (COMPOSE_PROFILES needs team; make up)" >&2; exit 1; }; done
bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_SMOKE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@"; }
bz users set-profile --name Richard-smoke >/dev/null
ch=$(bz channels create --name "job-$(date +%s)" --type stream --visibility open --ttl 7200 | jq -r .channel_id)
bz channels add-member --channel "$ch" --pubkey "$TEAM_DINESH_PUBKEY" --role bot >/dev/null
bz channels add-member --channel "$ch" --pubkey "$TEAM_GILFOYLE_PUBKEY" --role bot >/dev/null
sleep 3; echo "channel $ch"
n0=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls?state=all" | jq '[.[].number] | max // 0')   # only a PR numbered above this counts
feature="subtract-$(date +%s | tail -c 5)"
bz messages send --channel "$ch" --mention "$TEAM_DINESH_PUBKEY" --content "@Dinesh in the repository ${REPO}, add a function \`${feature//-/_}(a, b)\` that returns a - b, with a test, and open a pull request." >/dev/null
echo "job posted; waiting for a PR from dinesh (up to 15 min)"
pr=""; for i in $(seq 1 90); do sleep 10; pr=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls?state=open" | jq -r --argjson n0 "$n0" '[.[] | select(.user.login=="dinesh" and .number > $n0)] | sort_by(.created_at) | last | .number // empty'); [ -n "$pr" ] && break; done
[ -n "$pr" ] || { echo "FAIL: no PR from dinesh within 15 min; see docker compose logs dinesh" >&2; exit 1; }
echo "PR #$pr opened after ~$((i*10))s"
sha=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr" | jq -r .head.sha)
# read the ci / test (pull_request) context itself: the combined .state turns failure as soon as ANY context fails, e.g. the push-event run
st=""; for i in $(seq 1 60); do sleep 10; st=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/commits/$sha/status" | jq -r '[.statuses[] | select(.context=="ci / test (pull_request)") | .status][0] // "pending"'); [ "$st" = "success" ] || [ "$st" = "failure" ] && break; done
echo "CI on PR #$pr: $st"; [ "$st" = "success" ] || { echo "FAIL: CI not green" >&2; exit 1; }
url=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr" | jq -r .html_url)
bz messages send --channel "$ch" --mention "$TEAM_GILFOYLE_PUBKEY" --content "@Gilfoyle review please $url" >/dev/null
# a PENDING review is an unsubmitted draft nobody but the reviewer can see; only a submitted state counts
rv=""; for i in $(seq 1 60); do sleep 10; rv=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr/reviews" | jq -r '[.[] | select(.user.login=="gilfoyle" and .state!="PENDING")] | last | .state // empty'); [ -n "$rv" ] && break; done
echo "Gilfoyle review: ${rv:-(none within 10 min)}"; [ -n "$rv" ] || exit 1
echo "TEAM SMOKE PASS: PR #$pr, CI success, review $rv. Merge it in Gitea to close the loop (not automated on purpose)."
# Thread conventions (plan 11, G22): milestones + labelled deliverables from the agents' own posts; the mirror line only when it is on
root=$(bz messages get --channel "$ch" --limit 20 | jq -r '[.[] | select(.content|startswith("@Dinesh"))][0].id')
rroot=$(bz messages get --channel "$ch" --limit 20 | jq -r '[.[] | select(.content|startswith("@Gilfoyle review please"))][0].id')
# Dinesh's turn may still be running after Gilfoyle answered (CI milestone and deliverable come in either order): wait up to 3 min for PR + CI milestone + Review
for i in $(seq 1 18); do
  th=$(bz messages thread --channel "$ch" --event "$root"); rth=$(bz messages thread --channel "$ch" --event "$rroot")
  jq -e --arg d "$TEAM_DINESH_PUBKEY" '[.[] | select(.pubkey==$d and (.content|test("^\\*\\*PR:\\*\\* ")))] | length > 0' <<<"$th" >/dev/null \
    && jq -e --arg d "$TEAM_DINESH_PUBKEY" '[.[] | select(.pubkey==$d and (.content|test("^(🚩 )?CI (success|failure)")))] | length > 0' <<<"$th" >/dev/null \
    && jq -e --arg g "$TEAM_GILFOYLE_PUBKEY" '[.[] | select(.pubkey==$g and (.content|test("^\\*\\*Review:\\*\\* ")))] | length > 0' <<<"$(jq -s add <(printf '%s' "$th") <(printf '%s' "$rth"))" >/dev/null && break
  sleep 10   # Gilfoyle's thread post lands a few seconds after his Gitea review; Dinesh may still be finishing
done
th=$(jq -s 'add' <(printf '%s' "$th") <(printf '%s' "$rth"))   # job thread + review-request thread (Gilfoyle replies to the request)
jq -r --arg d "$TEAM_DINESH_PUBKEY" --arg g "$TEAM_GILFOYLE_PUBKEY" '.[] | select(.pubkey==$d or .pubkey==$g) | (.content | split("\n")[0])' <<<"$th" | sed 's/^/thread: /' | head -40
chk() { jq -e --arg p "$1" --arg re "$2" '[.[] | select(.pubkey==$p and (.content|test($re)))] | length > 0' <<<"$th" >/dev/null && echo "PASS: $3" || { echo "FAIL: $3"; return 1; }; }
ok=0
# Milestones are persona posts: reported, not gated (2026-09-13: present in 8 of 11 runs, once without the flag). Labels are gated.
rep() { jq -e --arg p "$1" --arg re "$2" '[.[] | select(.pubkey==$p and (.content|test($re)))] | length > 0' <<<"$th" >/dev/null && echo "milestone: $3 present" || echo "milestone: $3 ABSENT (model skipped a persona step; not gated)"; }
rep "$TEAM_DINESH_PUBKEY" '^🚩 pushed '              "push"
rep "$TEAM_DINESH_PUBKEY" '^🚩 CI (success|failure)' "CI"
chk "$TEAM_DINESH_PUBKEY"   '^\*\*PR:\*\* http'        "PR deliverable label"   || ok=1
chk "$TEAM_GILFOYLE_PUBKEY" '^\*\*Review:\*\* '        "review label"           || ok=1
case "${TEAM_NARRATE:-off}" in tools|both) chk "$TEAM_DINESH_PUBKEY" '^```\n\$ [^`]*git push' "mirror: git push command" || ok=1 ;; esac
[ "$ok" = 0 ] || { echo "THREAD CONVENTIONS FAIL (see above)" >&2; exit 1; }
