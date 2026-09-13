# Plan 09 — Point the agent team at your own Gitea, keep the bundled one as local mode

**Spec:** `docs/spec.md` (this plan adds §3 vars, a §4.2 note, new §5.10, gates G16–G17). **Rules:** `AGENTS.md`. **Knowledge:** plan 08 §3/§5.8 (team facts), `docs/buzz-agents-primer.md`.
**Sequence:** 9. Requires plan 08 executed (team + org route + human login). Adds no service and no profile; makes the `gitea` and `gitea-runner` profiles optional in practice.
**Execute with:** `/execute plans/09-external-gitea.md`
**No internet except `docker pull`.** Every route, flag and behaviour below was verified live on 2026-09-13 against the bundled Gitea 1.27.3 and, read-only, against the operator's own Gitea (same version, behind Caddy with a private CA; called "the forge" below, `https://git.example.com` in examples). Items marked **verify** are checked during execution and recorded in §7.

---

## 1. Overview

The operator's own Gitea (the forge) is the organisation's single source of truth. Plan 08 built the team's confinement (org, `agents` team with write, merge whitelist, required CI check) on the stack's bundled SQLite Gitea, a second forge nobody else uses. This plan makes the team work against **either** instance from the same scripts:

| Mode | `COMPOSE_PROFILES` | `GITEA_PUBLIC_URL` | Admin token | CI runner |
|---|---|---|---|---|
| bundled (default, `.env.example`) | `…,gitea,gitea-runner,team` | `http://127.0.0.1:3003` | minted by `make gitea-bootstrap` | stack's `gitea-runner`, label `python` |
| external (operator's `.env`) | `…,team` (no `gitea`, no `gitea-runner`) | `https://git.example.com` | pasted, from the operator's admin account | the forge's runner, label `ci` |

Design rules: the bundled `gitea-runner` (docker.sock, host network) **never** registers against the forge; agents reach the forge over HTTPS with the internal CA mounted read-only; every bootstrap step is a Gitea API call so one code path serves both modes; the org `TEAM_GITEA_ORG` is the containment boundary on the forge (agents are members of that org only). No mirror/sync feature: the forge's own backups cover the org.

**Success criteria (§6):** G0 in both modes; bundled mode still passes the whole `make test` after the rewrite (regression); external mode: `make team-bootstrap` twice creates users/org/team/fixture on the forge idempotently, agents authenticate over TLS, `make team-smoke` ends with a green PR and an APPROVED review on `piedpiper/demo-calc` at the forge, Gilfoyle's merge is refused, the operator merges in the forge UI.

**Out of scope:** SSH remotes (HTTPS + token only), mirroring, migrating repos from the bundled instance (its volume stays; nothing is deleted), an ADR in the forge's own repo (recommended, operator's call), remote access from outside the LAN.

## 2. Relevant files

| Path | Action |
|---|---|
| `.env.example`, `.env`, `docs/spec.md` §3 | `GITEA_CA_FILE`, `TEAM_CI_LABEL`; comments on `GITEA_PUBLIC_URL`, `GITEA_ADMIN_USER`, `GITEA_ADMIN_TOKEN` |
| `docker-compose.yml` | team block: CA mount + `TEAM_CI_LABEL`; comment on `gitea-runner` |
| `scripts/bootstrap-team.sh` | rewrite: API only (users via `/admin/users`, tokens via basic auth), both modes |
| `scripts/bootstrap-gitea.sh` | bundled only; mints admin token with `write:admin`; re-mints an under-scoped one |
| `scripts/team-entrypoint.sh` | CA env vars when the mounted file is non-empty; inline `$TEAM_CI_LABEL` |
| `agents/ci-python.yaml` | venv (PEP 668 on Debian job images); `runs-on` rewritten per mode |
| `agents/dinesh.md` | `runs-on` rewrite when copying the template |
| `scripts/smoke-test.sh` | gitea section by token, not profile; base = `GITEA_PUBLIC_URL`; probe repo inside the org; runner presence check |
| `scripts/check-ports.sh` | check only ports of enabled profiles |
| `README.md`, `docs/spec.md`, `AGENTS.md` | docs (Task 9) |

## 3. Dependencies and verified facts

- **The forge (its compose file, read 2026-09-13):** Gitea 1.27.3 behind Caddy (`tls internal`), API on 443 only, port 80 serves only `/root.crt`; `DISABLE_REGISTRATION=true`, `REQUIRE_SIGNIN_VIEW=true` (anonymous API → 403), `DEFAULT_PRIVATE=private`, push-to-create off, `[api] MAX_RESPONSE_ITEMS` at the default 50, Actions on with `DEFAULT_ACTIONS_URL=github`. Hostname resolves on the LAN only. One admin user (2FA on; API tokens bypass 2FA). No scripted user/org creation there; users are made with `gitea admin user create` on its host.
- **CA:** this host trusts it via `/usr/local/share/ca-certificates/<forge-ca>.crt` (installed with the forge's own trust-CA script; root valid for years). The sprig image runs as uid 1000 and cannot run `update-ca-certificates`, but with the file mounted, `CURL_CA_BUNDLE=<file>` → curl 200 and `GIT_SSL_CAINFO=<file>` → `git ls-remote` passes TLS (fails only at the credential prompt, as expected with sign-in required). A `/dev/null` bind mount as the placeholder renders as a 0-byte device file, so `[ -s file ]` distinguishes "CA provided" from "none" (verified). An **empty** `CURL_CA_BUNDLE`/`GIT_SSL_CAINFO` is not safe (curl/git treat it as a path), so the entrypoint sets the variables only when the file is non-empty; Compose `${VAR:+x}` is not used.
- **The forge runner:** one global runner, label **`ci`** only, capacity 2, job image `gitea-ci:latest` (Debian bookworm: git, curl, jq, python3/pip/venv 3.11, uv; no pytest), 2 CPU / 4 GB per job, no bind mounts. Jobs reach Gitea as `http://gitea:3000` via `--add-host`; `github.server_url` inside a job is therefore `http://gitea:3000`, and the https domain is unreachable from jobs (empty trust store). Our template clones from `GITHUB_SERVER_URL` with `github.token`, which is exactly that URL on the forge and the loopback ROOT_URL in bundled mode.
- **Debian pip refuses system installs (PEP 668)** → the template installs into a venv. Verified on the bundled job image `python:3.12-alpine`: `python3 -m venv /tmp/v && . /tmp/v/bin/activate && pip install pytest` → `pytest 9.1.1`. **verify** on `gitea-ci` during G17.
- **API routes (bundled 1.27.3, live):** `POST /users/{u}/tokens` with basic auth **as that user** mints a token with the requested scopes (no admin involved) → used for the three agent tokens with `TEAM_GITEA_PASSWORD`; `DELETE /users/{u}/tokens/{id}` likewise. `GET /admin/users?limit=1` answers 403 to a token without `read:admin`/`write:admin` → scope probe for the admin token. `POST /admin/users` (`CreateUserOption`: `username,email,password,must_change_password,send_notify`) needs `write:admin`. `GET /admin/actions/runners` lists global runners with their labels (org-level `GET /orgs/{org}/actions/runners` does **not** show global runners: `total_count 0` while `laurie` was registered). `POST /orgs`, teams, members, org repos, transfer, branch protections: as in plan 08 §addendum. Compose `${GITEA_CA_FILE:-/dev/null}` in a `volumes:` entry renders `source: /dev/null` when blank and the file path when set (verified with `docker compose config`).
- **Scopes:** admin token `write:admin,write:organization,write:repository,write:user`; agent tokens `write:repository,write:issue,read:user,write:organization` (unchanged). `write:organization` lets an agent create repos only in orgs it belongs to.
- **Bundled runner label** stays `python:docker://python:3.12-alpine`; the forge label is `ci`. `TEAM_CI_LABEL` selects which one generated workflows target.

## 4. Tasks

### Task 1 — variables

`.env.example` and `docs/spec.md` §3, Gitea section: replace the three lines and add one:

```bash
# --- Gitea (profile: gitea) -----------------------------------------------------------------
GITEA_PORT=3003
# Bundled: the loopback ROOT_URL (keep the port in sync). External: https://git.example.com -- and drop gitea AND gitea-runner
# from COMPOSE_PROFILES (the bundled runner must never register against a the forge instance).
GITEA_PUBLIC_URL=http://127.0.0.1:3003
# Bundled: created by make gitea-bootstrap. External: the account that owns GITEA_ADMIN_TOKEN (an admin there).
GITEA_ADMIN_USER=stackadmin
# make init: 24 hex (bundled only)
GITEA_ADMIN_PASSWORD=
# Bundled: written by make gitea-bootstrap. External: paste a token of GITEA_ADMIN_USER with scopes
#   write:admin,write:organization,write:repository,write:user  (agents never see it; delete/rotate it in Gitea at will)
GITEA_ADMIN_TOKEN=
# Root CA of a Gitea behind a private CA, mounted read-only into the team agents. Blank = system trust store.
# External example: /usr/local/share/ca-certificates/<forge-ca>.crt  (the same file your OS trust store got from the forge's docs)
GITEA_CA_FILE=
```

Agent-team section, after `TEAM_GITEA_ORG`:

```bash
# runs-on label for the CI workflows the team generates: python = the bundled gitea-runner profile; ci = the forge's runner
TEAM_CI_LABEL=python
```

Live `.env`: add `GITEA_CA_FILE=` and `TEAM_CI_LABEL=python` (bundled values; the external switch is Task 10, step 3). `TEAM_HUMAN_USER` keeps its meaning; in external mode it is the operator's existing login and the bootstrap creates it only when absent.

### Task 2 — `docker-compose.yml`

In `x-team-agent` and in each of the four services' `volumes:` (the anchor rule from plan 08), add:

```yaml
    - ${GITEA_CA_FILE:-/dev/null}:/opt/team/ca.crt:ro   # /dev/null = no private CA (0 bytes; the entrypoint checks -s)
```

In `&team-env` add `TEAM_CI_LABEL: ${TEAM_CI_LABEL:-python}`. On `gitea-runner` add the comment `# bundled mode only: this runner mounts the host docker socket -- never point GITEA_INSTANCE_URL at a the forge Gitea`.

Acceptance: `docker compose config` shows `source: /dev/null` with `GITEA_CA_FILE` blank and the file path when set; G0 for all profile sets.

### Task 3 — `scripts/team-entrypoint.sh`

After the relay wait, before the git config:

```bash
# Private CA (GITEA_CA_FILE mounted at /opt/team/ca.crt; /dev/null when unset). Empty values would break curl/git, so set only when present.
if [ -s /opt/team/ca.crt ]; then
  export CURL_CA_BUNDLE=/opt/team/ca.crt GIT_SSL_CAINFO=/opt/team/ca.crt SSL_CERT_FILE=/opt/team/ca.crt
  echo "private CA loaded for $GITEA_URL"
fi
```

Extend the prompt `sed` with `s|\$TEAM_CI_LABEL|${TEAM_CI_LABEL:-python}|g`. Acceptance (external): `docker compose exec dinesh sh -c '. ~/.gitea.env; curl -sS -H "Authorization: token $GITEA_TOKEN" $GITEA_URL/api/v1/user'` → `"login":"dinesh"`; bundled: no `private CA loaded` line, everything as before.

### Task 4 — `agents/ci-python.yaml`

```yaml
# Gitea Actions workflow for Python repos in the team org. Copied verbatim into <repo>/.gitea/workflows/ci.yaml with
# `runs-on` rewritten to TEAM_CI_LABEL (python = bundled gitea-runner; ci = the forge's runner, image gitea-ci).
# Jobs clone from GITHUB_SERVER_URL: the loopback ROOT_URL in bundled mode, http://gitea:3000 (add-host) on the forge.
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: python
    steps:
      - name: clone
        env:
          GITHUB_TOKEN: ${{ github.token }}
          PR_NUMBER: ${{ github.event.number }}   # set on pull_request only; GITHUB_REF_NAME is the PR index there, not a branch
        run: |
          command -v git >/dev/null || apk add --no-cache git >/dev/null   # python:alpine has no git; gitea-ci has
          git clone -q "$(echo "$GITHUB_SERVER_URL" | sed "s|://|://x-access-token:${GITHUB_TOKEN}@|")/${GITHUB_REPOSITORY}.git" src && cd src
          if [ -n "${PR_NUMBER}" ]; then git fetch -q origin "+refs/pull/${PR_NUMBER}/head" && git checkout -q FETCH_HEAD; else git checkout -q "${GITHUB_REF_NAME}"; fi
          git log -1 --oneline
      - name: test
        run: |
          cd src && python3 -m venv .venv && . .venv/bin/activate   # Debian job images refuse system pip installs (PEP 668)
          pip install -q -e . pytest && pytest -q
```

`agents/dinesh.md` step 2: replace "copy `/opt/team/agents/ci-python.yaml` verbatim" with "copy it and set its `runs-on` line to `$TEAM_CI_LABEL`: `sed 's/^    runs-on: .*/    runs-on: $TEAM_CI_LABEL/' /opt/team/agents/ci-python.yaml > .gitea/workflows/ci.yaml`". Status context stays `ci / test (pull_request)`.

### Task 5 — `scripts/bootstrap-gitea.sh` (bundled only)

- First line after loading `.env`: `has_profile gitea || { echo "gitea profile is off: external Gitea at $GITEA_PUBLIC_URL -- paste GITEA_ADMIN_TOKEN (write:admin,write:organization,write:repository,write:user) into .env instead"; exit 0; }` (copy `has_profile` from `smoke-test.sh`).
- Scopes: `write:admin,write:organization,write:repository,write:user`.
- Replace the "already set" early exit with a probe: if `GITEA_ADMIN_TOKEN` is set and `curl -o /dev/null -w %{http_code} -H "Authorization: token …" $GITEA_PUBLIC_URL/api/v1/admin/users?limit=1` is `200` → "already set"; on `403` → re-mint (message: "re-minted with write:admin; delete the old token in Gitea"); `--rotate` unchanged.

### Task 6 — `scripts/bootstrap-team.sh` (rewrite; API only)

```bash
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
ensure_user() {   # ensure_user <name> <password>
  if [ "$(code -H "$A" "$B/users/$1")" = 200 ]; then echo "gitea user $1 exists"
  else api -d "{\"username\":\"$1\",\"email\":\"$1@localhost\",\"password\":\"$2\",\"must_change_password\":false,\"send_notify\":false}" "$B/admin/users" >/dev/null && echo "created gitea user $1"; fi
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
PROT="{\"branch_name\":\"main\",\"enable_push\":false,\"enable_status_check\":true,\"status_check_contexts\":[\"ci / test (pull_request)\"],\"required_approvals\":1,\"block_on_rejected_reviews\":true,\"enable_merge_whitelist\":true,\"merge_whitelist_usernames\":[\"$ADMIN\",\"$HUMAN\"]}"
want=$(printf '%s\n' "$ADMIN" "$HUMAN" | sort -u | paste -sd,)
if [ "$(code -H "$A" "$B/repos/$ORG/$REPO/branch_protections/main")" != 200 ]; then
  api -o /dev/null -d "$PROT" "$B/repos/$ORG/$REPO/branch_protections" && echo "branch protection on main: CI check + 1 approval, merge by $want only"
elif [ "$(api "$B/repos/$ORG/$REPO/branch_protections/main" | jq -r '[.enable_merge_whitelist, (.merge_whitelist_usernames|sort|unique|join(","))] | join(" ")')" != "true $want" ]; then
  api -o /dev/null -X PATCH -d "{\"enable_merge_whitelist\":true,\"merge_whitelist_usernames\":[\"$ADMIN\",\"$HUMAN\"]}" "$B/repos/$ORG/$REPO/branch_protections/main" && echo "branch protection on main: merge restricted to $want"
else echo "branch protection on main exists"; fi
# 5. a runner that serves TEAM_CI_LABEL must exist, or every PR waits forever
if ! api "$B/admin/actions/runners" | jq -e --arg l "$LABEL" '.runners[]? | select(.labels[]?.name==$l)' >/dev/null; then
  echo "WARNING: no runner with label '$LABEL' is registered on $G (bundled: add gitea-runner to COMPOSE_PROFILES; external: TEAM_CI_LABEL must match that instance's runner)" >&2
fi
echo "team bootstrap complete"
```

Notes: `$ADMIN`/`$HUMAN` may be the same user in external mode (the whitelist is de-duplicated for the comparison; Gitea accepts a duplicate name). `sort -u` and `unique` keep the idempotence check stable. The `admin/actions/runners` route needs the admin token (verified route; **verify** its `status`/`labels` fields on the live response and tighten to `status=="online"` if present).

### Task 7 — `scripts/smoke-test.sh` and `scripts/check-ports.sh`

- `test_gitea`: `local base="${GITEA_PUBLIC_URL:-http://${BIND_HOST}:${GITEA_PORT:-3003}}"`; the create/clone/delete probe uses `POST $base/api/v1/orgs/${TEAM_GITEA_ORG:-piedpiper}/repos` and clones/deletes `${TEAM_GITEA_ORG}/${repo}` (never a human's namespace). Dispatcher: `{ has_profile gitea || [ -n "${GITEA_ADMIN_TOKEN:-}" ]; } && test_gitea`.
- `test_gitea_runner`: unchanged (profile-gated); its `demo-calc` run query already uses the org.
- `check-ports.sh`: build `ports` from enabled profiles (`litellm`→`LITELLM_PORT`, `openwebui`→`OPENWEBUI_PORT`, `buzz`→`BUZZ_PORT`, `gitea`→`GITEA_PORT`) so a foreign 3003 listener does not block `make up` when the bundled Gitea is off.

### Task 8 — README, spec, AGENTS.md (Task 9 in the plan's numbering is documentation; keep both)

- `docs/spec.md`: §3 (Task 1 text); §4.2 note "`gitea-runner` is bundled-mode only"; new **§5.10 External Gitea** with the facts from §3 of this plan (CA handling and why not `${VAR:+}`, runner label/image, `http://gitea:3000` rule, admin-token scopes and the `/admin/users` probe, basic-auth token minting, PEP 668, `MAX_RESPONSE_ITEMS` 50, org as the containment boundary, "never register the bundled runner there"); §7 gates **G16** external bootstrap idempotent + agents authenticate over TLS, **G17** team smoke on the forge.
- `README.md`: subsection **"Using your own Gitea"** under the agent team: the `.env` diff (profiles, URL, admin user/token with scopes, CA file, `TEAM_CI_LABEL=ci`, `TEAM_HUMAN_USER`), prerequisite: the forge's root CA in this host's OS trust store, what the admin token can do and how to delete/rotate it, that agents hold org-scoped write tokens on the company forge and how to revoke them (delete the three tokens in Gitea), that the fixture `demo-calc` is created in the org, the honest limit that jobs on the forge must use `http://gitea:3000` (covered by the template), and a recommendation to record the machine users in the forge's own ADRs. Security notes: bundled runner never against the forge.
- `AGENTS.md`: status line (plan 09), two non-negotiable facts (jobs on the forge reach Gitea as `http://gitea:3000`; the bundled runner mounts docker.sock and stays bundled-only), commands unchanged.

## 5. Testing strategy

Bundled regression first (nothing may get worse), then the external cutover on the operator's `.env`, both with real output in §7. The external run touches the forge: only the org `piedpiper`, three machine users, one fixture repo and whatever `make team-smoke` creates inside that org.

## 6. Validation commands

```bash
# G0 -- both modes render and validate
docker compose config --quiet && echo "G0 bundled ok"
GITEA_CA_FILE=/usr/local/share/ca-certificates/gitea-internal-ca.crt COMPOSE_PROFILES=litellm,openwebui,buzz,buzz-agent,team docker compose config --quiet && echo "G0 external ok"
COMPOSE_PROFILES=team docker compose config | grep -E 'ca.crt|TEAM_CI_LABEL'

# Bundled regression (current .env)
make gitea-bootstrap                      # re-mints GITEA_ADMIN_TOKEN with write:admin (probe 403 -> re-mint)
make team-bootstrap && make team-bootstrap   # API-only path; second run prints only exists/member/owner lines
make test                                 # every section incl. gitea-runner and team smoke

# External cutover (operator: paste the admin token and fill the placeholders first; make down the two profiles)
docker compose down gitea gitea-runner
sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=litellm,openwebui,buzz,buzz-agent,team|; s|^GITEA_PUBLIC_URL=.*|GITEA_PUBLIC_URL=https://git.example.com|; s|^GITEA_ADMIN_USER=.*|GITEA_ADMIN_USER=<your-admin>|; s|^GITEA_CA_FILE=.*|GITEA_CA_FILE=/usr/local/share/ca-certificates/<forge-ca>.crt|; s|^TEAM_CI_LABEL=.*|TEAM_CI_LABEL=ci|; s|^TEAM_HUMAN_USER=.*|TEAM_HUMAN_USER=<your-login>|' .env
sed -i 's|^GITEA_ADMIN_TOKEN=.*|GITEA_ADMIN_TOKEN=<pasted>|; s|^TEAM_DINESH_GITEA_TOKEN=.*|TEAM_DINESH_GITEA_TOKEN=|; s|^TEAM_GILFOYLE_GITEA_TOKEN=.*|TEAM_GILFOYLE_GITEA_TOKEN=|; s|^TEAM_JARED_GITEA_TOKEN=.*|TEAM_JARED_GITEA_TOKEN=|' .env   # agent tokens are per instance
make up && docker compose ps
# G16
make team-bootstrap && make team-bootstrap
for a in dinesh gilfoyle jared erlich; do docker compose logs $a | grep -E 'private CA loaded|connected to relay|presence set' | tail -3; done
docker compose exec -T dinesh sh -c '. ~/.gitea.env; curl -sS -H "Authorization: token $GITEA_TOKEN" $GITEA_URL/api/v1/user | grep -o "\"login\":\"[a-z]*\""'
docker compose exec -T dinesh sed -E 's/:[^:@]*@/:<t>@/' /home/agent/.git-credentials     # https://dinesh:<t>@git.example.com
curl -sS -H "Authorization: token $GITEA_ADMIN_TOKEN" "$GITEA_PUBLIC_URL/api/v1/repos/piedpiper/demo-calc/actions/runs" | jq -r '.workflow_runs[0] | "\(.status)/\(.conclusion)"'   # push run on the ci runner
# G17
make team-smoke                            # PR on piedpiper/demo-calc at the forge, CI success, review APPROVED
make test                                  # gitea section against the forge, no runner section, team section
# new-project path on the forge, then Gilfoyle's merge refused (405 "User not allowed to merge PR"); the operator merges in the UI
```

If `make team-bootstrap` fails at "not an admin token": the pasted token lacks `write:admin`. If agents log TLS errors: `GITEA_CA_FILE` path wrong (the entrypoint prints `private CA loaded` only when the mounted file is non-empty). If CI never starts on the forge: `TEAM_CI_LABEL` must be `ci`, and the fixture workflow's `runs-on` must show it (`git show main:.gitea/workflows/ci.yaml`). If the venv step fails on `gitea-ci`: record the error; fallback `uv venv .venv && uv pip install -e . pytest`.

## 7. Execution report (fill in)

- Findings and fixes:
- Gate output (G0 both modes, bundled `make test`, G16, G17, `make test` external):
- Timings (bootstrap, PR opened after, CI on `ci` runner, review after):
- Not run and why:
