#!/usr/bin/env bash
# Outcome labels for scored PRs (plan 13): read each closed PR that carries a confidence/* label and record what happened.
# Uses the judge's token: the admin token has no read:issue (plan 10). merged at the scored sha = merged-as-is; merged with
# a different head = merged-after-changes; closed unmerged = closed.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${TEAM_JARED_GITEA_TOKEN:?run make team-bootstrap}"
G="${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}"; B="$G/api/v1"; ORG="${TEAM_GITEA_ORG:-piedpiper}"
J="Authorization: token $TEAM_JARED_GITEA_TOKEN"
api() { curl -fsS -H "$J" -H 'Content-Type: application/json' "$@"; }
for r in $(api "$B/orgs/$ORG/repos?limit=50" | jq -r '.[].name'); do
  api "$B/repos/$ORG/$r/pulls?state=closed&limit=50" \
    | jq -c '.[] | select(any(.labels[]?; .name|startswith("confidence/"))) | select(all(.labels[]?; (.name|startswith("outcome/"))|not)) | {number, merged, head:.head.sha}' \
    | while read -r pr; do
      n=$(jq -r .number <<<"$pr"); merged=$(jq -r .merged <<<"$pr"); head=$(jq -r .head <<<"$pr")
      scored=$(api "$B/repos/$ORG/$r/issues/$n/comments" | jq -r '[.[] | select(.body|startswith("**Score:**"))] | last | .body // ""' | sed -n 's/.*"sha":"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
      if [ "$merged" = true ] && [ -n "$scored" ] && [ "$head" = "$scored" ]; then o=outcome/merged-as-is
      elif [ "$merged" = true ]; then o=outcome/merged-after-changes
      else o=outcome/closed; fi
      api -o /dev/null -d "{\"labels\":[\"$o\"]}" "$B/repos/$ORG/$r/issues/$n/labels" && echo "$r#$n: $o"
    done
done
echo "score sync complete"
