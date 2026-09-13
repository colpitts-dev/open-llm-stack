#!/usr/bin/env bash
# Idempotent, API-only, same code for the bundled Gitea and an external one (GITEA_PUBLIC_URL):
# agent users + tokens, the team organization, your login, fixture repo with CI + branch protection.
# Bundled-only step: the runner registration token (needs the gitea-runner profile and the Gitea CLI).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${GITEA_ADMIN_TOKEN:?bundled: run make gitea-bootstrap; external: paste an admin token (see .env.example)}" "${TEAM_GITEA_PASSWORD:?run make init}" "${TEAM_HUMAN_PASSWORD:?run make init}"
G="${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}"; B="$G/api/v1"; ORG="${TEAM_GITEA_ORG:-piedpiper}"; ADMIN="${GITEA_ADMIN_USER:-stackadmin}"; HUMAN="${TEAM_HUMAN_USER:-richard}"
LABEL="${TEAM_CI_LABEL:-python}"; A="Authorization: token ${GITEA_ADMIN_TOKEN}"
has_profile() { [[ ",${COMPOSE_PROFILES:-}," == *",$1,"* ]]; }
blank() { grep -qE "^$1=[[:space:]]*(#.*)?$" .env; }
setenv() { sed -i "s|^$1=.*|$1=$2|" .env; }
api() { curl -fsS -H "$A" -H 'Content-Type: application/json' "$@"; }          # host curl: the OS trust store must know the CA (make trust-ca)
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }
# A token is org-capable when GET /user/orgs is 200 (403 = "required scope"); admin-capable when GET /admin/users is 200.
has_org_scope() { [ "$(code -H "Authorization: token $1" "$B/user/orgs")" = 200 ]; }

# 0. the admin token must really be admin-scoped on this instance
case "$(code -H "$A" "$B/admin/users?limit=1")" in
  200) ;;
  401|403) echo "GITEA_ADMIN_TOKEN is not an admin token on $G (needs write:admin,write:organization,write:repository,write:user)" >&2; exit 1 ;;
  *) echo "cannot reach $B (is GITEA_PUBLIC_URL right? does this host trust its CA?)" >&2; exit 1 ;;
esac

# 1. users: three agents + you. Created with the admin token; tokens minted by each agent with ITS OWN password (no admin needed).
ensure_user() {   # ensure_user <name> <password>. Email: the API validates syntax (user@localhost is rejected with 422 "[Email]: Email");
                  # .invalid is reserved for exactly this (RFC 2606) and no mail is ever sent (send_notify false).
  if [ "$(code -H "$A" "$B/users/$1")" = 200 ]; then echo "gitea user $1 exists"
  else api -d "{\"username\":\"$1\",\"email\":\"$1@agents.invalid\",\"password\":\"$2\",\"must_change_password\":false,\"send_notify\":false}" "$B/admin/users" >/dev/null && echo "created gitea user $1"; fi
}
SCOPES='["write:repository","write:issue","read:user","write:organization"]'
for who in dinesh gilfoyle jared; do
  ensure_user "$who" "$TEAM_GITEA_PASSWORD"
  var="TEAM_$(echo "$who" | tr a-z A-Z)_GITEA_TOKEN"
  if blank "$var" || ! has_org_scope "${!var}"; then
    tok=$(curl -fsS -u "$who:$TEAM_GITEA_PASSWORD" -H 'Content-Type: application/json' -d "{\"name\":\"team-$(date +%s%N)-$$\",\"scopes\":$SCOPES}" "$B/users/$who/tokens" | jq -r .sha1)
    [ ${#tok} -ge 20 ] || { echo "token minting for $who failed (wrong TEAM_GITEA_PASSWORD? mint one in the Gitea UI and paste it as $var)" >&2; exit 1; }
    setenv "$var" "$tok"; echo "$var written"
  fi
done
ensure_user "$HUMAN" "$TEAM_HUMAN_PASSWORD"   # external: your existing login -> "exists"

# 2. runner registration token: bundled runner only (the CLI lives in the bundled container)
if has_profile gitea-runner && blank GITEA_RUNNER_TOKEN; then
  setenv GITEA_RUNNER_TOKEN "$(docker compose exec -T -u git gitea gitea actions generate-runner-token | tail -1 | tr -d '\r\n')"; echo "GITEA_RUNNER_TOKEN written"
fi

# 3. organization + `agents` team (write on every repo, may create repos; write is enough for branch protection -- plan 08) + you as owner
if [ "$(code -H "$A" "$B/orgs/$ORG")" != 200 ]; then
  api -d "{\"username\":\"$ORG\",\"visibility\":\"private\",\"description\":\"open-llm-stack agent team\"}" "$B/orgs" >/dev/null && echo "created org $ORG"
else echo "org $ORG exists"; fi
tid=$(api "$B/orgs/$ORG/teams" | jq -r '.[] | select(.name=="agents") | .id')
if [ -z "$tid" ]; then
  tid=$(api -d '{"name":"agents","description":"builder, reviewer, coordinator","permission":"write","can_create_org_repo":true,"includes_all_repositories":true,"units":["repo.code","repo.issues","repo.pulls","repo.releases","repo.actions"]}' "$B/orgs/$ORG/teams" | jq -r .id) && echo "created team $ORG/agents"
else echo "team $ORG/agents exists"; fi
for who in dinesh gilfoyle jared; do api -o /dev/null -X PUT "$B/teams/$tid/members/$who" && echo "team member $who"; done
oid=$(api "$B/orgs/$ORG/teams" | jq -r '.[] | select(.name=="Owners") | .id')
api -o /dev/null -X PUT "$B/teams/$oid/members/$HUMAN" && echo "org owner $HUMAN"

# 4. fixture repository demo-calc (Python + pytest) with the CI workflow for THIS mode's runner label
REPO=demo-calc
if [ "$(code -H "$A" "$B/repos/$ORG/$REPO")" != 200 ]; then
  if [ "$(code -H "$A" "$B/repos/$ADMIN/$REPO")" = 200 ]; then
    api -o /dev/null -d "{\"new_owner\":\"$ORG\"}" "$B/repos/$ADMIN/$REPO/transfer" && echo "transferred $ADMIN/$REPO -> $ORG/$REPO"
  else
    api -d "{\"name\":\"$REPO\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\"}" "$B/orgs/$ORG/repos" >/dev/null
    tmp=$(mktemp -d); git -c http.extraHeader="$A" clone -q "$G/$ORG/$REPO.git" "$tmp/r"
    mkdir -p "$tmp/r/.gitea/workflows" "$tmp/r/calc" "$tmp/r/tests"
    printf 'def add(a, b):\n    return a + b\n' > "$tmp/r/calc/__init__.py"
    printf 'from calc import add\n\n\ndef test_add():\n    assert add(2, 2) == 4\n' > "$tmp/r/tests/test_calc.py"
    printf '[project]\nname = "calc"\nversion = "0.0.1"\n\n[build-system]\nrequires = ["setuptools>=68"]\nbuild-backend = "setuptools.build_meta"\n\n[tool.setuptools]\npackages = ["calc"]\n' > "$tmp/r/pyproject.toml"
    printf '# demo-calc\n\nFixture repository for the agent team. Tests: `pip install -e . && pytest -q` (run by CI).\n' > "$tmp/r/README.md"
    sed "s/^    runs-on: .*/    runs-on: $LABEL/" agents/ci-python.yaml > "$tmp/r/.gitea/workflows/ci.yaml"
    (cd "$tmp/r" && git add -A && git -c user.name="$ADMIN" -c user.email="$ADMIN@localhost" commit -qm "ci: python + pytest workflow (runs-on: $LABEL)" && git -c http.extraHeader="$A" push -q origin main)
    rm -rf "$tmp"; echo "created $ORG/$REPO with CI workflow (runs-on: $LABEL)"
  fi
else echo "$ORG/$REPO exists"; fi
# Branch protection on EVERY org repo (the fixture and whatever the agents created since): required check, one approval,
# merge by the admin and the human only. Dinesh's persona applies it to repos he creates, but a model can skip a step;
# re-running this bootstrap is the deterministic backstop.
PROT="{\"branch_name\":\"main\",\"enable_push\":false,\"enable_status_check\":true,\"status_check_contexts\":[\"ci / test (pull_request)\"],\"required_approvals\":1,\"block_on_rejected_reviews\":true,\"enable_merge_whitelist\":true,\"merge_whitelist_usernames\":[\"$ADMIN\",\"$HUMAN\"]}"
want=$(printf '%s\n' "$ADMIN" "$HUMAN" | sort -u | paste -sd,)
for r in $(api "$B/orgs/$ORG/repos?limit=50" | jq -r '.[].name'); do
  if [ "$(code -H "$A" "$B/repos/$ORG/$r/branch_protections/main")" != 200 ]; then
    api -o /dev/null -d "$PROT" "$B/repos/$ORG/$r/branch_protections" && echo "$r: branch protection on main: CI check + 1 approval, merge by $want only"
  elif [ "$(api "$B/repos/$ORG/$r/branch_protections/main" | jq -r '[.enable_merge_whitelist, (.merge_whitelist_usernames|sort|unique|join(","))] | join(" ")')" != "true $want" ]; then
    api -o /dev/null -X PATCH -d "{\"enable_merge_whitelist\":true,\"merge_whitelist_usernames\":[\"$ADMIN\",\"$HUMAN\"]}" "$B/repos/$ORG/$r/branch_protections/main" && echo "$r: merge restricted to $want"
  else echo "$r: branch protection on main exists"; fi
done
# 5. a runner that serves TEAM_CI_LABEL must exist, or every PR waits forever
if ! api "$B/admin/actions/runners" | jq -e --arg l "$LABEL" '.runners[]? | select(.status=="online" and any(.labels[]?.name; .==$l))' >/dev/null; then
  echo "WARNING: no ONLINE runner with label '$LABEL' on $G (bundled: add gitea-runner to COMPOSE_PROFILES; external: TEAM_CI_LABEL must match that instance's runner)" >&2
fi
echo "team bootstrap complete"
