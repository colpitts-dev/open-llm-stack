#!/usr/bin/env bash
# Idempotent: Gitea users + tokens for the agents, the team organization, runner registration token,
# fixture repo with CI + branch protection. Safe to re-run; it only mints what is blank or under-scoped.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${GITEA_ADMIN_TOKEN:?run make gitea-bootstrap first}" "${TEAM_GITEA_PASSWORD:?run make init}" "${TEAM_HUMAN_PASSWORD:?run make init}"
G="${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}"; B="$G/api/v1"; ORG="${TEAM_GITEA_ORG:-piedpiper}"; ADMIN="${GITEA_ADMIN_USER:-stackadmin}"; HUMAN="${TEAM_HUMAN_USER:-richard}"
blank() { grep -qE "^$1=[[:space:]]*(#.*)?$" .env; }
setenv() { sed -i "s|^$1=.*|$1=$2|" .env; }
gitea() { docker compose exec -T -u git gitea gitea "$@"; }
mint() { gitea admin user generate-access-token --username "$1" --token-name "$2-$(date +%s%N)-$$" --scopes "$3" --raw | tr -d '\r\n'; }
# A token minted before the org route lacks write:organization; Gitea answers 403 "required scope" to GET /user/orgs.
has_org_scope() { curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: token $1" "$B/user/orgs" | grep -q '^200$'; }

# 1. admin token must be able to manage the org
if ! has_org_scope "$GITEA_ADMIN_TOKEN"; then
  GITEA_ADMIN_TOKEN=$(mint "$ADMIN" stack write:repository,write:user,write:organization); setenv GITEA_ADMIN_TOKEN "$GITEA_ADMIN_TOKEN"
  echo "GITEA_ADMIN_TOKEN re-minted with write:organization (the old token stays valid until you delete it in Gitea)"
fi
A="Authorization: token ${GITEA_ADMIN_TOKEN}"

# 2. agent users + tokens (write:organization lets them create repositories in the org)
SCOPES=write:repository,write:issue,read:user,write:organization
for who in dinesh gilfoyle jared; do
  set +e; out=$(gitea admin user create --username "$who" --password "$TEAM_GITEA_PASSWORD" --email "$who@localhost" --must-change-password=false 2>&1); rc=$?; set -e
  if [ $rc -eq 0 ]; then echo "created gitea user $who"; elif grep -q "already exists" <<<"$out"; then echo "gitea user $who exists"; else echo "$out" >&2; exit 1; fi
  var="TEAM_$(echo "$who" | tr a-z A-Z)_GITEA_TOKEN"
  if blank "$var" || ! has_org_scope "${!var}"; then
    setenv "$var" "$(mint "$who" team "$SCOPES")"; echo "$var written ($SCOPES)"
  fi
done

# Your own login (non-admin). Password from .env; change it in Gitea afterwards if you like -- nothing in the stack uses it.
set +e; out=$(gitea admin user create --username "$HUMAN" --password "$TEAM_HUMAN_PASSWORD" --email "$HUMAN@localhost" --must-change-password=false 2>&1); rc=$?; set -e
if [ $rc -eq 0 ]; then echo "created gitea user $HUMAN (you): log in at $G with TEAM_HUMAN_USER / TEAM_HUMAN_PASSWORD from .env"
elif grep -q "already exists" <<<"$out"; then echo "gitea user $HUMAN (you) exists"; else echo "$out" >&2; exit 1; fi

if blank GITEA_RUNNER_TOKEN; then
  setenv GITEA_RUNNER_TOKEN "$(gitea actions generate-runner-token | tail -1 | tr -d '\r\n')"; echo "GITEA_RUNNER_TOKEN written"
fi

# 3. the organization + one team: write on every repo, may create repos. (write is enough for branch protection on a repo
#    the member created -- verified 2026-09-13.) Gilfoyle is read-only by persona, not by permission.
if ! curl -fsS -o /dev/null -H "$A" "$B/orgs/$ORG" 2>/dev/null; then
  curl -fsS -o /dev/null -H "$A" -H 'Content-Type: application/json' -d "{\"username\":\"$ORG\",\"visibility\":\"private\",\"description\":\"open-llm-stack agent team\"}" "$B/orgs" && echo "created org $ORG"
else echo "org $ORG exists"; fi
tid=$(curl -fsS -H "$A" "$B/orgs/$ORG/teams" | jq -r '.[] | select(.name=="agents") | .id')
if [ -z "$tid" ]; then
  tid=$(curl -fsS -H "$A" -H 'Content-Type: application/json' \
    -d '{"name":"agents","description":"builder, reviewer, coordinator","permission":"write","can_create_org_repo":true,"includes_all_repositories":true,"units":["repo.code","repo.issues","repo.pulls","repo.releases","repo.actions"]}' \
    "$B/orgs/$ORG/teams" | jq -r .id) && echo "created team $ORG/agents (write, can create repos)"
else echo "team $ORG/agents exists"; fi
for who in dinesh gilfoyle jared; do
  curl -fsS -o /dev/null -X PUT -H "$A" "$B/teams/$tid/members/$who" && echo "team member $who"
done
oid=$(curl -fsS -H "$A" "$B/orgs/$ORG/teams" | jq -r '.[] | select(.name=="Owners") | .id')
curl -fsS -o /dev/null -X PUT -H "$A" "$B/teams/$oid/members/$HUMAN" && echo "org owner $HUMAN"

# 4. fixture repository demo-calc in the org (transferred from the admin user if an older bootstrap created it there)
REPO=demo-calc
if ! curl -fsS -o /dev/null -H "$A" "$B/repos/$ORG/$REPO" 2>/dev/null; then
  if curl -fsS -o /dev/null -H "$A" "$B/repos/$ADMIN/$REPO" 2>/dev/null; then
    curl -fsS -o /dev/null -H "$A" -H 'Content-Type: application/json' -d "{\"new_owner\":\"$ORG\"}" "$B/repos/$ADMIN/$REPO/transfer" && echo "transferred $ADMIN/$REPO -> $ORG/$REPO"
  else
    curl -fsS -H "$A" -H 'Content-Type: application/json' -d "{\"name\":\"$REPO\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\"}" "$B/orgs/$ORG/repos" >/dev/null
    tmp=$(mktemp -d); git -c http.extraHeader="$A" clone -q "$G/$ORG/$REPO.git" "$tmp/r"
    mkdir -p "$tmp/r/.gitea/workflows" "$tmp/r/calc" "$tmp/r/tests"
    printf 'def add(a, b):\n    return a + b\n' > "$tmp/r/calc/__init__.py"
    printf 'from calc import add\n\n\ndef test_add():\n    assert add(2, 2) == 4\n' > "$tmp/r/tests/test_calc.py"
    printf '[project]\nname = "calc"\nversion = "0.0.1"\n\n[build-system]\nrequires = ["setuptools>=68"]\nbuild-backend = "setuptools.build_meta"\n\n[tool.setuptools]\npackages = ["calc"]\n' > "$tmp/r/pyproject.toml"
    printf '# demo-calc\n\nFixture repository for the agent team. Tests: `pip install -e . && pytest -q` (run by CI).\n' > "$tmp/r/README.md"
    cp agents/ci-python.yaml "$tmp/r/.gitea/workflows/ci.yaml"
    (cd "$tmp/r" && git add -A && git -c user.name="$ADMIN" -c user.email="$ADMIN@localhost" commit -qm "ci: python + pytest workflow" && git -c http.extraHeader="$A" push -q origin main)
    rm -rf "$tmp"; echo "created $ORG/$REPO with CI workflow"
  fi
else echo "$ORG/$REPO exists"; fi
if ! curl -fsS -o /dev/null -H "$A" "$B/repos/$ORG/$REPO/branch_protections/main" 2>/dev/null; then
  curl -fsS -o /dev/null -H "$A" -H 'Content-Type: application/json' \
    -d "{\"branch_name\":\"main\",\"enable_push\":false,\"enable_status_check\":true,\"status_check_contexts\":[\"ci / test (pull_request)\"],\"required_approvals\":1,\"block_on_rejected_reviews\":true,\"enable_merge_whitelist\":true,\"merge_whitelist_usernames\":[\"$ADMIN\",\"$HUMAN\"]}" \
    "$B/repos/$ORG/$REPO/branch_protections" && echo "branch protection on main: CI check + 1 approval, no direct push"
elif [ "$(curl -fsS -H "$A" "$B/repos/$ORG/$REPO/branch_protections/main" | jq -r '[.enable_merge_whitelist, (.merge_whitelist_usernames|sort|join(","))] | join(" ")')" != "true $(printf '%s\n' "$ADMIN" "$HUMAN" | sort | paste -sd,)" ]; then
  curl -fsS -o /dev/null -X PATCH -H "$A" -H 'Content-Type: application/json' -d "{\"enable_merge_whitelist\":true,\"merge_whitelist_usernames\":[\"$ADMIN\",\"$HUMAN\"]}" \
    "$B/repos/$ORG/$REPO/branch_protections/main" && echo "branch protection on main: merge restricted to $ADMIN,$HUMAN"
else echo "branch protection on main exists"; fi
echo "team bootstrap complete"
