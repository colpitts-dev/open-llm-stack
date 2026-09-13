# Plan 10 — Repository factory: agents create governed repos in one command, never as repo admins

**Spec:** `docs/spec.md` (this plan adds §5.11 and gates G18–G19). **Rules:** `AGENTS.md`. **Knowledge:** plan 08 §5.8 (team, protection, scrubbed shell), plan 09 §5.10 (both Gitea modes).
**Sequence:** 10. Requires plan 09 executed (either mode). Adds no service, no profile, no `.env` variable.
**Execute with:** `/execute plans/10-repo-factory.md`
**No internet except `docker pull`.** Every API behaviour below was verified live on 2026-09-13 against the operator's own Gitea 1.27.3 ("the forge"); the bundled instance is the same version and is re-validated by the gates.

---

## 1. Overview

Agents can already create repositories in the team org (plan 08/09), but the governance that must follow creation (CI workflow, branch protection, merge whitelist) is performed by the model through a persona recipe, and the model sometimes skips a step (plan 09 finding 8). Worse, Gitea makes the **creator a collaborator with admin rights** on that repo, so the creating agent can edit or remove the protection and could delete the repo. Verified: Dinesh PATCHed the protection on a repo he created (200) but not on one he did not (403).

This plan replaces the recipe with a **factory**: one deterministic command the agent runs, backed by a Gitea **template repository** that carries the workflow and the protection rule, followed by **self-demotion** so the agent keeps only the team's write access.

| Before | After |
|---|---|
| persona: create repo → copy template → commit → push → protect (5 curl/git steps) | persona: `new-repo <name>` (1 command) |
| creator = repo admin (can strip protection, delete repo) | creator removed from collaborators; team write only |
| protection depends on the model | protection copied from the template at birth, with `block_admin_merge_override` |
| `make team-bootstrap` repairs drift by hand | bootstrap still reconciles (protection + demotion on every org repo), but rarely has anything to do |

**Team split (folded in 2026-09-13).** One `agents` team with write + create for all three agents made Gilfoyle read-only by persona only and let anyone create repos. Three teams enforce the roles in Gitea: `builders` (Dinesh: code/pulls/issues write, may create repos), `reviewers` (Gilfoyle: code read, pulls write, issues write), `coordinators` (Jared: issues write, code/pulls read, may not create). The bootstrap creates them, moves the members, and deletes `agents`. Nobody is an org owner but the humans.

**Success criteria (§6):** G18 — the factory command run inside `dinesh` produces a repo with the workflow, the full protection rule, and no collaborators, in both modes; G19 — an LLM new-project request ends with a PR whose repo was made by the factory (verified by the absence of collaborators and presence of protection without any bootstrap run in between). G20 — permissions enforce the roles: Gilfoyle cannot create a branch (403) but can post a review; Jared cannot generate a repo (403) but can label an issue; Dinesh can do both of his.

**Out of scope:** an org webhook + listener (new service), org-wide policy (not in Gitea 1.27), non-Python templates (the template layout allows more later), retroactive demotion on the bundled instance (the bootstrap's reconcile loop does it the next time bundled mode is bootstrapped; the forge's three repos were demoted by hand on 2026-09-13).

## 2. Relevant files

| Path | Action |
|---|---|
| `agents/template/` | new: `pyproject.toml`, `README.md`, `src/.gitkeep`… the Python starter; the workflow comes from `agents/ci-python.yaml` |
| `agents/bin/new-repo` | new: the factory command (bash, runs inside the agent container, agent token, no jq) |
| `scripts/bootstrap-team.sh` | template repo create/update; reconcile: protection with `block_admin_merge_override` + remove agent collaborators |
| `agents/dinesh.md`, `agents/TEAM.md` | persona: run the command |
| `scripts/smoke-test.sh` | `test_team_factory` (G18) in the team section |
| `docs/spec.md` §5.11, §7; `README.md`; `AGENTS.md` | docs |

## 3. Dependencies and verified facts (2026-09-13, Gitea 1.27.3)

- `POST /repos/{template_owner}/{template_repo}/generate` (`GenerateRepoOption`: `owner, name, private, default_branch, git_content, protected_branch, labels, topics, webhooks, avatar, git_hooks`) creates a repo from a repository whose `template` flag is set (`PATCH /repos/{o}/{r} {"template":true}` → 200). Verified with `git_content:true, protected_branch:true, labels:true`: the new repo had `.gitea/workflows/ci.yaml` (200) and the protection rule copied intact (`status_check_contexts`, `required_approvals`, `merge_whitelist_usernames`, `block_admin_merge_override: true`). Generation triggers **no** Actions run (no push event): the first PR is the first check.
- A team member with write and `can_create_org_repo` may call `generate` (201 as dinesh). The creator is added as a **collaborator** (`GET …/collaborators` → `["dinesh"]`, `permissions.admin: true`) on both `create` and `generate`.
- **Self-demotion works:** `DELETE /repos/{o}/{r}/collaborators/{self}` as the creator → 204; afterwards `permissions {admin:false, push:true}` (write via the team), `PATCH branch_protections` → 403, creating a branch → 201. Repo deletion needs admin, so it is gone too.
- `CreateBranchProtectionOption.block_admin_merge_override` exists; set `true` on every rule so repo admins (the human included) cannot merge around the rule. Applied to the forge's three repos on 2026-09-13 (PATCH → `true`).
- A protected `main` with `enable_push:false` rejects direct pushes for everyone, admins included (verified: an empty commit pushed with the admin token → `remote: error: Not allowed to push to protected branch main`, pre-receive hook declined). The bootstrap therefore drops and recreates the template's protection around a content update, the pattern plan 08 used.
- The sprig image has **no jq/python**: the factory parses JSON with `grep -o`/`sed`. It reads the token from `~/.gitea.env` (plan 08) and the CA from `~/.curlrc` (plan 09), so it works from the scrubbed shell tool unchanged. `agents/` is bind-mounted read-only at `/opt/team/agents`, so `agents/bin/new-repo` is available as `/opt/team/agents/bin/new-repo` with its executable bit.
- `CreateTeamOption` carries `units_map` (`{"repo.code":"read","repo.pulls":"write",…}`), `can_create_org_repo`, `includes_all_repositories`; Gitea 1.27 reports the per-unit access back in `units_map` while `permission` reads `none` (plan 08 addendum). **verify** at execution: a `read` on `repo.code` refuses branch creation (403) while `write` on `repo.pulls` still accepts a review.
- `GET /orgs/{org}/repos?limit=50` lists org repos (`[api] MAX_RESPONSE_ITEMS` default 50; bump the page or paginate if the org grows past it).

## 4. Tasks

### Task 1 — `agents/template/` (the Python starter)

`agents/template/pyproject.toml`:
```toml
[project]
name = "REPO_NAME"
version = "0.0.1"
requires-python = ">=3.11"

[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
where = ["."]
exclude = ["tests*"]
```
`agents/template/README.md`:
```markdown
# REPO_NAME

Created by the agent team from the org's `python-template`. Tests run in CI on every push and pull request
(`pip install -e . && pytest -q` inside a venv). `main` is protected: CI must pass, one approval, a human merges.
```
`agents/template/tests/test_smoke.py`:
```python
def test_smoke():
    assert True
```
The workflow is not duplicated here: the bootstrap copies `agents/ci-python.yaml` into the template with `runs-on` rewritten to `TEAM_CI_LABEL`. `REPO_NAME` stays literal in the template repo; the factory replaces it after generation (Task 2) — **verify** whether `generate` already substitutes `${REPO_NAME}` via Gitea's `.gitea/template` mechanism; if it does, use that instead of the sed in Task 2 and record it.

### Task 2 — `agents/bin/new-repo`

```bash
#!/usr/bin/env bash
# Factory: create a governed repository in the team org from its python-template, then drop the creator's admin rights.
# Runs inside an agent container: token from ~/.gitea.env, CA from ~/.curlrc (plan 09), no jq/python in this image.
set -euo pipefail
name="${1:-}"
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || { echo "usage: new-repo <name>   (lowercase letters, digits, dashes)" >&2; exit 2; }
. "$HOME/.gitea.env"
: "${GITEA_URL:?}" "${GITEA_OWNER:?}" "${GITEA_USER:?}" "${GITEA_TOKEN:?}"
B="$GITEA_URL/api/v1"; H=(-H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json")
code() { curl -sS -o /dev/null -w '%{http_code}' "${H[@]}" "$@"; }

[ "$(code "$B/repos/$GITEA_OWNER/$name")" = 404 ] || { echo "$GITEA_OWNER/$name already exists: $GITEA_URL/$GITEA_OWNER/$name" >&2; exit 1; }
[ "$(code "$B/repos/$GITEA_OWNER/python-template")" = 200 ] || { echo "template $GITEA_OWNER/python-template missing -- ask Richard to run make team-bootstrap" >&2; exit 1; }

# 1. generate: content + labels + the protected main (required CI check, one approval, merge by humans only)
out=$(curl -sS "${H[@]}" -d "{\"owner\":\"$GITEA_OWNER\",\"name\":\"$name\",\"private\":true,\"default_branch\":\"main\",\"git_content\":true,\"protected_branch\":true,\"labels\":true}" \
  "$B/repos/$GITEA_OWNER/python-template/generate")
grep -q '"full_name":"'"$GITEA_OWNER/$name"'"' <<<"$out" || { echo "generate failed: $(sed 's/.*"message":"\([^"]*\)".*/\1/' <<<"$out")" >&2; exit 1; }

# 2. sanity while I am still repo admin (reading the rule needs admin; after step 3 I could not check it)
[ "$(code "$B/repos/$GITEA_OWNER/$name/branch_protections/main")" = 200 ] || echo "warning: main is NOT protected on $name; tell Richard" >&2

# 3. self-demotion: Gitea made me a repo admin; the team's write access is all I should keep
rc=$(code -X DELETE "$B/repos/$GITEA_OWNER/$name/collaborators/$GITEA_USER")
[ "$rc" = 204 ] || echo "warning: could not remove myself as collaborator (HTTP $rc); tell Richard" >&2

echo "created $GITEA_URL/$GITEA_OWNER/$name (private, main protected, you have write via the team)"
echo "next: git clone $GITEA_URL/$GITEA_OWNER/$name.git REPOS/$name && cd REPOS/$name && sed -i \"s/REPO_NAME/$name/g\" pyproject.toml README.md && git checkout -b agent/<slug>"
```
`chmod +x agents/bin/new-repo`. Acceptance: `bash -n`; run inside `dinesh` (see G18).

### Task 3 — `scripts/bootstrap-team.sh`

Replace the single `agents` team with three role teams (idempotent; migrates an existing install):

```bash
# 3. organization + three role teams. Permissions enforce the roles; personas only describe them.
#    builders: write code/pulls/issues, may create repos (the factory). reviewers: read code, write pulls (reviews) and issues.
#    coordinators: write issues (triage), read code/pulls/actions. Nobody is an owner but the humans.
ensure_team() {   # ensure_team <name> <can_create_org_repo> <units_map json> <member>...
  local name="$1" create="$2" units="$3"; shift 3
  local tid; tid=$(api "$B/orgs/$ORG/teams" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id')
  if [ -z "$tid" ]; then
    tid=$(api -d "{\"name\":\"$name\",\"permission\":\"read\",\"can_create_org_repo\":$create,\"includes_all_repositories\":true,\"units_map\":$units}" "$B/orgs/$ORG/teams" | jq -r .id) && echo "created team $ORG/$name"
  else echo "team $ORG/$name exists"; fi
  for who in "$@"; do api -o /dev/null -X PUT "$B/teams/$tid/members/$who" && echo "team $name: member $who"; done
}
ensure_team builders     true  '{"repo.code":"write","repo.pulls":"write","repo.issues":"write","repo.actions":"read","repo.releases":"read"}' dinesh
ensure_team reviewers    false '{"repo.code":"read","repo.pulls":"write","repo.issues":"write","repo.actions":"read"}' gilfoyle
ensure_team coordinators false '{"repo.code":"read","repo.pulls":"read","repo.issues":"write","repo.actions":"read"}' jared
old=$(api "$B/orgs/$ORG/teams" | jq -r '.[] | select(.name=="agents") | .id'); [ -n "$old" ] && api -o /dev/null -X DELETE "$B/teams/$old" && echo "removed legacy team $ORG/agents (write+create for everyone)"
oid=$(api "$B/orgs/$ORG/teams" | jq -r '.[] | select(.name=="Owners") | .id')
api -o /dev/null -X PUT "$B/teams/$oid/members/$HUMAN" && echo "org owner $HUMAN"
```

After the teams and before the fixture repo:

```bash
# Template repository: python-template (workflow for THIS mode's runner label + starter files + the protection rule).
# Agents generate new repos from it (agents/bin/new-repo); `protected_branch:true` copies the rule at birth.
TPL=python-template
PROT="{\"branch_name\":\"main\",\"enable_push\":false,\"enable_status_check\":true,\"status_check_contexts\":[\"ci / test (pull_request)\"],\"required_approvals\":1,\"block_on_rejected_reviews\":true,\"block_admin_merge_override\":true,\"enable_merge_whitelist\":true,\"merge_whitelist_usernames\":[\"$ADMIN\",\"$HUMAN\"]}"
if [ "$(code -H "$A" "$B/repos/$ORG/$TPL")" != 200 ]; then
  api -d "{\"name\":\"$TPL\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\",\"template\":true,\"description\":\"template for repositories the agent team creates\"}" "$B/orgs/$ORG/repos" >/dev/null && echo "created $ORG/$TPL"
fi
tmp=$(mktemp -d); git -c http.extraHeader="$A" clone -q "$G/$ORG/$TPL.git" "$tmp/t"
mkdir -p "$tmp/t/.gitea/workflows" "$tmp/t/tests"
cp agents/template/pyproject.toml agents/template/README.md "$tmp/t/"; cp agents/template/tests/test_smoke.py "$tmp/t/tests/"
sed "s/^    runs-on: .*/    runs-on: $LABEL/" agents/ci-python.yaml > "$tmp/t/.gitea/workflows/ci.yaml"
if [ -n "$(git -C "$tmp/t" status --porcelain)" ]; then
  # a protected main rejects pushes for everyone; drop the rule for the update, the loop below restores it
  curl -fsS -o /dev/null -X DELETE -H "$A" "$B/repos/$ORG/$TPL/branch_protections/main" 2>/dev/null || true
  (cd "$tmp/t" && git add -A && git -c user.name="$ADMIN" -c user.email="$ADMIN@localhost" commit -qm "template: sync from agents/ (runs-on: $LABEL)" && git -c http.extraHeader="$A" push -q origin main) && echo "$ORG/$TPL updated"
else echo "$ORG/$TPL up to date"; fi
rm -rf "$tmp"
api -o /dev/null -X PATCH -d '{"template":true}' "$B/repos/$ORG/$TPL"
```

Replace the existing per-repo protection loop with a reconcile loop that also demotes agents (and uses the `PROT` above, which now carries `block_admin_merge_override`):

```bash
# Reconcile every org repo (template, fixture, agent-created): protection present and complete; no agent left as a
# collaborator (Gitea makes the creator a repo admin; the factory demotes itself, this is the backstop).
want=$(printf '%s\n' "$ADMIN" "$HUMAN" | sort -u | paste -sd,)
for r in $(api "$B/orgs/$ORG/repos?limit=50" | jq -r '.[].name'); do
  if [ "$(code -H "$A" "$B/repos/$ORG/$r/branch_protections/main")" != 200 ]; then
    api -o /dev/null -d "$PROT" "$B/repos/$ORG/$r/branch_protections" && echo "$r: branch protection on main: CI check + 1 approval, merge by $want only"
  elif [ "$(api "$B/repos/$ORG/$r/branch_protections/main" | jq -r '[.enable_merge_whitelist, .block_admin_merge_override, (.merge_whitelist_usernames|sort|unique|join(","))] | join(" ")')" != "true true $want" ]; then
    api -o /dev/null -X PATCH -d "{\"enable_merge_whitelist\":true,\"block_admin_merge_override\":true,\"merge_whitelist_usernames\":[\"$ADMIN\",\"$HUMAN\"]}" "$B/repos/$ORG/$r/branch_protections/main" && echo "$r: protection repaired (merge by $want, admins cannot override)"
  else echo "$r: branch protection on main exists"; fi
  for c in $(api "$B/repos/$ORG/$r/collaborators" | jq -r '.[] | select(.login=="dinesh" or .login=="gilfoyle" or .login=="jared") | .login'); do
    api -o /dev/null -X DELETE "$B/repos/$ORG/$r/collaborators/$c" && echo "$r: removed collaborator $c (team write only)"
  done
done
```

Acceptance: two runs; the second prints only `up to date` / `exists` lines; `GET /repos/$ORG/python-template` shows `"template": true`; protection on the template carries `block_admin_merge_override: true`.

### Task 4 — personas

`agents/dinesh.md` step 2, replace the "If the repository does not exist yet …" sub-steps (create via API, copy workflow, protect main) with:

```markdown
   If the repository does not exist yet and the request is for a NEW project, run the factory once:
   `/opt/team/agents/bin/new-repo <repo>` — it creates `$GITEA_OWNER/<repo>` from the org template (private, CI workflow,
   protected `main`) and drops your admin rights on it. Then clone it, replace `REPO_NAME` in `pyproject.toml` and
   `README.md` with the repo name, and continue on a branch. Never create repositories any other way.
```

`agents/TEAM.md`, environment facts: add `- New repositories are created ONLY with /opt/team/agents/bin/new-repo <name>; it applies the team's rules for you.`

### Task 5 — `scripts/smoke-test.sh`: `test_team_factory` (G18)

```bash
test_team_factory() {
  local base="${GITEA_PUBLIC_URL:-http://${BIND_HOST}:${GITEA_PORT:-3003}}/api/v1" auth="Authorization: token ${GITEA_ADMIN_TOKEN}" org="${TEAM_GITEA_ORG:-piedpiper}"
  local name="factory-$(date +%s | tail -c 6)"
  echo "--- team: repository factory (new-repo inside dinesh, no LLM)"
  docker compose exec -T dinesh /opt/team/agents/bin/new-repo "$name" | head -1
  curl -fsS -o /dev/null -H "$auth" "$base/repos/$org/$name/contents/.gitea/workflows/ci.yaml" && echo "workflow present"
  curl -fsS -H "$auth" "$base/repos/$org/$name/branch_protections/main" | jq -r '"protection: contexts=\(.status_check_contexts|join(",")) approvals=\(.required_approvals) merge=\(.merge_whitelist_usernames|join(",")) admin_override_blocked=\(.block_admin_merge_override)"'
  local collab; collab=$(curl -fsS -H "$auth" "$base/repos/$org/$name/collaborators" | jq -r 'length')
  [ "$collab" = 0 ] && echo "collaborators: none (creator demoted)" || fail "factory left $collab collaborator(s) on $name"
  curl -fsS -o /dev/null -X DELETE -H "$auth" "$base/repos/$org/$name" && echo "deleted $name"
}
```
Dispatcher: after the team smoke line, `has_profile team && test_team_factory`.

### Task 6 — docs

- `docs/spec.md`: new **§5.11 Repository factory** with the facts of §3 (generate copies protection, creator = admin, self-demotion, `block_admin_merge_override`, no run on generate, protected main rejects admin pushes); §7 gates **G18** (factory inside `dinesh`, both modes), **G19** (LLM new-project request → repo made by the factory: protection present, collaborators empty, no bootstrap in between), **G20** (role permissions enforced by teams).
- `README.md` agent-team section: "New repositories" paragraph (what the factory does, that agents are never repo admins, that `python-template` is the org's template and how to change it: edit `agents/template/` or `agents/ci-python.yaml`, run `make team-bootstrap`).
- `AGENTS.md`: status line; one non-negotiable: repos are created by the factory, agents are never repo admins.
- `plans/10-repo-factory.md` §7: execution report.

## 5. Testing strategy

Gates in whichever mode `.env` is in first (the forge today), then the other mode via `.env.bundled`/`.env.forge` (plan 09 §5.10 switching), so both instances prove G18. G19 once, on the forge (an LLM job).

## 6. Validation commands

```bash
bash -n agents/bin/new-repo scripts/bootstrap-team.sh scripts/smoke-test.sh && test -x agents/bin/new-repo
make team-bootstrap && make team-bootstrap        # template created then "up to date"; protection + demotion reconciled
# G18 (current mode)
make test | sed -n '/repository factory/,/^deleted/p'
# G19 (forge): in a job channel ask Dinesh: "@Dinesh new project: create a repository named <x> with ..., a pytest test, CI, and open a pull request."
#   then: GET /repos/<org>/<x>/collaborators -> [] ; GET .../branch_protections/main -> 200 with block_admin_merge_override true ; PR opened; CI success
# switch mode (plan 09 §5.10) and repeat make team-bootstrap x2 + G18; switch back
docker compose exec -T dinesh /opt/team/agents/bin/new-repo 'Bad Name'; echo "exit=$? (expect 2)"
# G20 -- roles enforced by Gitea, not personas (tokens from .env; <org>/demo-calc; a PR must exist for the review probe)
curl -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: token $TEAM_GILFOYLE_GITEA_TOKEN" -d '{"new_branch_name":"probe","old_branch_name":"main"}' .../repos/<org>/demo-calc/branches   # 403
curl -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: token $TEAM_JARED_GITEA_TOKEN" -d '{"owner":"<org>","name":"probe"}' .../repos/<org>/python-template/generate           # 403
curl -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: token $TEAM_JARED_GITEA_TOKEN" -d '{"labels":[...]}' .../repos/<org>/demo-calc/issues/<n>/labels                   # 200
docker compose exec -T gilfoyle /opt/team/agents/bin/new-repo probe-x; echo "exit=$? (expect 1: generate refused)"
```

## 7. Execution report (executed 2026-09-13; forge first, then bundled, then back on the forge)

### Findings and fixes

1. **The factory's sanity check must run before self-demotion.** Reading a branch-protection rule needs repo admin; after `DELETE collaborators/{self}` the check returned 403 and the command printed a false "main is NOT protected" warning. Reordered: check while still admin, then demote. Re-run clean.
2. **A non-builder generating from the template gets 422, not 403** (`Given user is not allowed to create repository in organization`). Gate G20 accepts it; the factory surfaces the message and exits 1.
3. **The admin token has no `write:issue`** (by design: `write:admin,write:organization,write:repository,write:user`), so the coordinator probes create the issue and label with Jared's own token.
4. `REPO_NAME` in the template is replaced by the agent after cloning (the factory prints the exact `sed`); Gitea's own `.gitea/template` substitution was not used. Dinesh did the replacement in G19 (`pyproject.toml` is in the PR's file list).

### Gate output

```
# forge -- make team-bootstrap (run 1 / run 2)
created team piedpiper/builders / team builders: member dinesh / created team piedpiper/reviewers / … gilfoyle / created team piedpiper/coordinators / … jared /
removed legacy team piedpiper/agents (write+create for everyone) / org owner <admin> / created piedpiper/python-template / piedpiper/python-template updated /
demo-calc|greeter-787|tic-tac-toe: branch protection on main exists / python-template: branch protection on main: CI check + 1 approval, merge by <admin> only / team bootstrap complete
run 2: piedpiper/python-template up to date / team bootstrap complete
teams: builders {code,pulls,issues:write; actions,releases:read; can_create_org_repo true} / reviewers {code:read; pulls,issues:write} / coordinators {issues:write; code,pulls,actions:read}
python-template: {"template":true,"private":true}, rule {contexts [ci / test (pull_request)], approvals 1, merge [<admin>], block_admin_merge_override true}, contents: .gitea README.md pyproject.toml tests

# G18 (forge) -- docker compose exec -T dinesh /opt/team/agents/bin/new-repo factory-19625
created https://<forge>/piedpiper/factory-19625 (private, main protected, you have write via the team)
workflow file: 200 / rule copied {contexts, approvals 1, merge [<admin>], block_admin_merge_override true} / collaborators: [] / dinesh permissions {admin:false, push:true}
new-repo 'Bad Name' → usage…, exit 2 / new-repo demo-calc → "already exists", exit 1 / gilfoyle new-repo probe-x → "generate failed: Given user is not allowed to create repository in organization", exit 1

# G20 -- roles enforced by Gitea (each agent's own token)
gilfoyle: create branch 403 / POST review COMMENT 200
jared: generate 422 / create branch 403 / create issue #5 201 / create label 201 / label issue 200 / assign dinesh 201 / PATCH protection 403
dinesh: generate 201 (G18)

# G19 (forge) -- "@Dinesh new project: create a repository named palindrome-586 … a pytest test, CI, and open a pull request."
PR: 1 after ~30s / collaborators: [] / protection {block_admin_merge_override true, merge [<admin>]} (no bootstrap ran in between) /
PR files: README.md palindrome/__init__.py pyproject.toml tests/test_palindrome.py / CI (pull_request): success
Dinesh's first line: "Picked up. Let me check the template structure to match conventions."

# bundled -- .env.bundled, make up, make team-bootstrap x2 (migration of an existing install)
created team builders/reviewers/coordinators / removed legacy team piedpiper/agents / created piedpiper/python-template / updated /
demo-calc|hello-py|wordcount-968: protection repaired (merge by richard,stackadmin, admins cannot override) /
hello-py: removed collaborator dinesh / wordcount-968: removed collaborator dinesh / python-template: branch protection on main: … / complete
run 2: nothing changed. teams: Owners,builders,coordinators,reviewers. hello-py/wordcount-968 collaborators: []
make test (bundled): … TEAM SMOKE PASS: PR #14 … / repository factory: workflow present / protection: contexts=ci / test (pull_request) approvals=1 merge=richard,stackadmin admin_override_blocked=true / collaborators: none (creator demoted) / deleted factory-19797 / smoke test finished

# back on the forge -- make test
TEAM SMOKE PASS: PR #6, CI success, review APPROVED / repository factory: workflow present / protection … merge=<admin> admin_override_blocked=true / collaborators: none (creator demoted) / deleted factory-19940 / smoke test finished
non-healthy services: 0
```

### Timings

Bootstrap first run on an existing install ~20 s (three teams, template create + push, reconcile), second ~8 s. Factory command ~2 s. G19: PR 30 s after the mention, CI green ~40 s later. Full `make test`: bundled 1 min 53 s, forge 2 min 8 s.

### Not run and why

- Gitea's `.gitea/template` variable substitution: not needed (the factory prints the rename step and Dinesh performed it); left for a later template.
- Jared as provisioner: deferred by decision (v1 keeps Dinesh creating); the team definitions make it a one-line change.
- Merging the PRs left on the forge (#4, #6 in demo-calc; palindrome-586 #1; tic-tac-toe #1 after Dinesh's fix): the operator's.
