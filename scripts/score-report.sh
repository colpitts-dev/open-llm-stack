#!/usr/bin/env bash
# Calibration report (plan 13): complexity counts and the confidence x outcome table over every scored PR in the org.
# Uses the judge's token (labels need read:issue, which the admin token lacks).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${TEAM_JARED_GITEA_TOKEN:?run make team-bootstrap}"
G="${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}"; B="$G/api/v1"; ORG="${TEAM_GITEA_ORG:-piedpiper}"
J="Authorization: token $TEAM_JARED_GITEA_TOKEN"
api() { curl -fsS -H "$J" "$@"; }
rows=$(for r in $(api "$B/orgs/$ORG/repos?limit=50" | jq -r '.[].name'); do
  api "$B/repos/$ORG/$r/pulls?state=all&limit=50" | jq -c --arg r "$r" '.[] | select(any(.labels[]?; .name|startswith("complexity/"))) |
    {repo:$r, n:.number, state:.state, merged:.merged,
     cx:(([.labels[].name|select(startswith("complexity/"))][0] // "complexity/?")|sub("complexity/";"")),
     cf:(([.labels[].name|select(startswith("confidence/"))][0] // "confidence/?")|sub("confidence/";"")),
     out:(([.labels[].name|select(startswith("outcome/"))][0] // (if .state=="open" then "open" else "unsynced" end))|sub("outcome/";""))}'
done)
[ -n "$rows" ] || { echo "no scored PRs in org $ORG"; exit 0; }
echo "scored PRs: $(wc -l <<<"$rows")"
echo; echo "complexity:"; jq -r '.cx' <<<"$rows" | sort | uniq -c | awk '{printf "  %s: %s\n", $2, $1}'
echo; echo "confidence x outcome (rows: confidence; columns: merged-as-is / merged-after-changes / closed / open / unsynced):"
for cf in low medium high; do
  line=$(jq -r --arg cf "$cf" 'select(.cf==$cf) | .out' <<<"$rows" | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
  printf '  %-7s %s\n' "$cf" "${line:-(none)}"
done
echo; echo "merged-as-is rate per confidence bucket (of PRs with an outcome):"
for cf in low medium high; do
  t=$(jq -r --arg cf "$cf" 'select(.cf==$cf and (.out|startswith("merged") or .=="closed")) | .n' <<<"$rows" | wc -l)
  m=$(jq -r --arg cf "$cf" 'select(.cf==$cf and .out=="merged-as-is") | .n' <<<"$rows" | wc -l)
  if [ "$t" -gt 0 ]; then printf '  %-7s %d/%d\n' "$cf" "$m" "$t"; else printf '  %-7s no outcomes yet\n' "$cf"; fi
done
