# Plan 08 — The Pied Piper agent team: Dinesh, Gilfoyle, Jared, Erlich + Gitea Actions

**Spec:** `docs/spec.md` (this plan appends §5.8 and new §3 vars). **Rules:** `AGENTS.md`. **Knowledge:** `docs/buzz-agents-primer.md` and `.serena/memories/buzz/*` — read them first; every design choice below traces to them.
**Sequence:** 8. Requires plans 01–07 executed (stack up, `make init` done, Gitea bootstrapped). Adds two profiles: `gitea-runner` and `team`.
**Execute with:** `/execute plans/08-agent-team.md`
**No internet except `docker pull`.** Every tag, flag, API path and CLI option below was verified live on 2026-09-13 (runner + workflow ran end to end on this stack).

---

## 1. Overview

Turn the single `buzz-agent` into a development team that produces **validated pull requests in Gitea**:

| Agent | Runs | Gate | Sessions | Job |
|---|---|---|---|---|
| **Dinesh** — builder | `team` profile, sprig image, host network, own volume | allowlist | thread | clone from Gitea → branch `agent/<slug>` → `pytest` → push → PR via API → post URL + `@mention` requester |
| **Gilfoyle** — reviewer | same | allowlist | thread | read-only: fetch PR diff, review, post findings in thread and as a Gitea review. Never edits, never opens PRs |
| **Jared** — coordinator | same, heartbeat every 1800 s | allowlist | channel | triages Gitea issues (labels/assign), points Dinesh at work, posts status in `#triage`; never builds or reviews |
| **Erlich** — assistant | same, no Gitea token | allowlist | channel | Q&A, summaries, drafting in `#general`; delegates building to Dinesh |
| **Laurie** — CI | `gitea-runner` profile (`docker.gitea.com/act_runner:3.4.2`) | — | — | Gitea Actions on every push/PR; branch protection on `main` requires her check |

Richard (the operator) is on every allowlist, starts jobs by mentioning Dinesh in a thread, and merges.

**Success criteria (§6):** G0 for the new profiles; runner registered and a fixture repo's CI green; `scripts/team-smoke.sh` submits a job thread and ends with a Dinesh PR whose `ci / test (pull_request)` check is `success` and a Gilfoyle review on it; Jared's heartbeat fires; Erlich answers in `#general`; GPU stays on GPU under the concurrent load (Ollama `100% GPU`).

**Out of scope:** relay-hosted git/`buzz pr` (the desktop cannot attach non-relay repos; see `mem:buzz/git-and-gitea`), NIP-OA owner attestation for server agents (no CLI mints it), Gitea org/teams (repos live under `GITEA_ADMIN_USER`), mirrors.

---

## 2. Relevant files

| Path | Action |
|---|---|
| `docker-compose.yml` | add `gitea-runner`; add `dinesh`, `gilfoyle`, `jared`, `erlich` (profile `team`) via a shared extension block; 5 volumes |
| `.env.example`, `.env`, `docs/spec.md` §3 | add the `TEAM_*`, `GITEA_RUNNER_*` and per-agent token vars |
| `scripts/init.sh` | generate 5 Nostr keypairs (4 agents + smoke human) |
| `scripts/bootstrap-team.sh` | create Gitea users + tokens for dinesh/gilfoyle/jared, runner registration token, fixture repo with workflow + branch protection, collaborators |
| `runner/config.yaml` | act_runner config (label `python`, host network) |
| `agents/TEAM.md`, `agents/dinesh.md`, `agents/gilfoyle.md`, `agents/jared.md`, `agents/erlich.md`, `agents/jared-heartbeat.md` | persona prompts + team norms + heartbeat prompt |
| `scripts/team-entrypoint.sh` | shared container entrypoint: wait for relay, git credentials, prompt assembly, set profile name, exec harness |
| `scripts/team-smoke.sh` | G7-team: job thread → PR → green check → review |
| `scripts/smoke-test.sh` | dispatch `test_gitea_runner` and `team-smoke.sh` |
| `Makefile` | `team-bootstrap`, `team-smoke` targets |
| `README.md` | "The agent team" section |
| `docs/spec.md` | §1 rows, §3 vars, new §5.8 facts, §7 gates G11–G13 |

---

## 3. Dependencies and verified facts

- `docker.gitea.com/act_runner:3.4.2` (newest semver on Gitea's registry; NOT the stale `gitea/act_runner` on Docker Hub). Entrypoint `/sbin/tini -- run.sh`; binary is `gitea-runner` (v3.4.2); `run.sh` honours `CONFIG_FILE`, `GITEA_INSTANCE_URL`, `GITEA_RUNNER_REGISTRATION_TOKEN`(`_FILE`), `GITEA_RUNNER_NAME`, `GITEA_RUNNER_LABELS`, `GITEA_RUNNER_EPHEMERAL`, `GITEA_RUNNER_ONCE`, `GITEA_MAX_REG_ATTEMPTS`. Registration state persists in `/data/.runner`.
- Job image `python:3.12-alpine` (Docker Hub, verified). It has no git: the workflow's first step is `apk add --no-cache git`.
- Gitea 1.27.3 here has Actions **enabled by default** (`has_actions: true` on new repos, no `[actions]` section needed). Runner tokens: `docker compose exec -T -u git gitea gitea actions generate-runner-token` (40 chars; the admin API route needs `write:admin`, which our token lacks).
- **Networking (verified):** runner container and its job containers use `network_mode: host` / `container.network: host`, so `GITEA_INSTANCE_URL=http://127.0.0.1:3003` and the job clones from the loopback `ROOT_URL` with `${{ github.token }}`. Commit status context is `ci / test (push)` on pushes and `ci / test (pull_request)` on PRs; branch protection names the latter.
- Verified API shapes (swagger on the live instance): `POST /repos/{o}/{r}/pulls` {title, head, base, body}; `POST /repos/{o}/{r}/pulls/{index}/reviews` {event: APPROVE|REQUEST_CHANGES|COMMENT, body, comments[]}; `POST /repos/{o}/{r}/branch_protections` {branch_name, enable_status_check, status_check_contexts[], required_approvals, block_on_rejected_reviews, enable_push}; `GET /repos/{o}/{r}/commits/{ref}/status`; `PUT /repos/{o}/{r}/collaborators/{user}` {permission}. `GET …/pulls/{index}.diff` returns a unified diff.
- Gitea forbids self-approval: the reviewer must be a different user than the PR author → Dinesh, Gilfoyle and Jared each get their own Gitea account + token (scopes `write:repository,write:issue,read:user`).
- Sprig image facts: `git 2.49.1`, `curl`, `bash`, `rg`, `tree`; **no `jq`, `python3`, `openssl`**. `git config --global credential.helper store` + `~/.git-credentials` works (verified). Entrypoint `/usr/local/bin/sprig-entrypoint` scopes a nostr credential helper to the relay URL and `exec`s `buzz-acp "$@"`. User `agent` uid 1000, `HOME=/home/agent` = the harness working dir (`REPOS/`, `WORK_LOGS/`, `OUTBOX/` live there).
- buzz-acp flags used (all in `buzz-acp --help` of the pinned image): `BUZZ_ACP_SYSTEM_PROMPT_FILE`, `BUZZ_ACP_SESSION_POLICY=thread|channel`, `BUZZ_ACP_RESPOND_TO=allowlist`, `BUZZ_ACP_RESPOND_TO_ALLOWLIST`, `BUZZ_ACP_AGENT_OWNER`, `BUZZ_ACP_HEARTBEAT_INTERVAL`, `BUZZ_ACP_HEARTBEAT_PROMPT_FILE`, `BUZZ_ACP_AGENTS`, `BUZZ_ACP_DISPLAY_NAME`. buzz-agent: `BUZZ_AGENT_REQUIRE_REPLY=1` (present in the pinned binary).
- Model: `ornith-max` (measured: publishes multi-step results; `qwen3.6-max` does not). Ollama host container already has `OLLAMA_NUM_PARALLEL=1`; four agents + CI share one GPU slot by queueing.

---

## 4. Tasks

### Task 1 — `.env.example`, `.env`, `docs/spec.md` §3: new variables

Append this block to `.env.example` and to `docs/spec.md`'s §3 fenced block (after the Gitea section), and add the same lines to the live `.env` (blank secrets; `make init` fills keys, `make team-bootstrap` fills tokens):

```bash
# --- Agent team (profile: team) — Dinesh (builder), Gilfoyle (reviewer), Jared (coordinator), Erlich (assistant)
TEAM_MODEL=ornith-max          # one resident model for the whole team; must exist in proxy/config.yaml
TEAM_MAX_CONTEXT_TOKENS=237568 # = that model's max_input_tokens
# Comma-separated 64-hex pubkeys of the humans the agents obey (Richard). Find yours in the Buzz app profile,
# or from a message you posted: `buzz messages get --channel <uuid>` shows `pubkey`. First entry is the agents' owner.
TEAM_ALLOWLIST=
TEAM_HEARTBEAT_SECONDS=1800    # Jared's proactive triage tick; 0 disables
# Keys: `make init` fills these (one identity per agent, plus a throwaway human for the smoke test)
TEAM_DINESH_PRIVATE_KEY=
TEAM_DINESH_PUBKEY=
TEAM_GILFOYLE_PRIVATE_KEY=
TEAM_GILFOYLE_PUBKEY=
TEAM_JARED_PRIVATE_KEY=
TEAM_JARED_PUBKEY=
TEAM_ERLICH_PRIVATE_KEY=
TEAM_ERLICH_PUBKEY=
TEAM_SMOKE_PRIVATE_KEY=
TEAM_SMOKE_PUBKEY=
# Gitea accounts for the agents (make team-bootstrap creates them and writes the tokens)
TEAM_GITEA_PASSWORD=
TEAM_DINESH_GITEA_TOKEN=
TEAM_GILFOYLE_GITEA_TOKEN=
TEAM_JARED_GITEA_TOKEN=
# --- Gitea Actions runner (profile: gitea-runner)
GITEA_RUNNER_TOKEN=            # make team-bootstrap: `gitea actions generate-runner-token`
GITEA_RUNNER_NAME=laurie
```

`init.sh` blank-detection rule: comments above, never after `=`.

### Task 2 — `scripts/init.sh`: five more keypairs

After the existing `BUZZ_AGENT_PRIVATE_KEY` block, add:

```bash
for who in DINESH GILFOYLE JARED ERLICH SMOKE; do
  if blank "TEAM_${who}_PRIVATE_KEY"; then
    out=$(gen_key)
    set_if_blank "TEAM_${who}_PRIVATE_KEY" "$(awk '/Secret key:/{print $3}' <<<"$out")"
    set_if_blank "TEAM_${who}_PUBKEY" "$(awk '/Public key:/{print $3}' <<<"$out")"
  fi
done
set_if_blank TEAM_GITEA_PASSWORD "$(hex 12)"
```

Acceptance: `./scripts/init.sh` prints `generated TEAM_..._PRIVATE_KEY`/`_PUBKEY` for the five identities once; all ten values are 64 hex chars; second run prints only the final line.

### Task 3 — `runner/config.yaml`

```yaml
# Gitea Actions runner (gitea-runner v3.4.2). Host network so jobs reach the loopback ROOT_URL — verified.
log:
  level: info
runner:
  file: /data/.runner
  capacity: 2            # concurrent jobs; each is a container on the host network
  timeout: 20m
  labels:
    - "python:docker://python:3.12-alpine"
container:
  network: host
  privileged: false
  docker_host: ""        # use the mounted /var/run/docker.sock
  force_pull: false      # images are pre-pulled; never re-pull on every job
```

### Task 4 — `docker-compose.yml`: runner + team

Add volumes `gitea-runner-data`, `team-dinesh`, `team-gilfoyle`, `team-jared`, `team-erlich`. Add a top-level extension block (Compose ignores `x-` keys) and the services:

```yaml
x-team-agent: &team-agent
  image: ghcr.io/block/buzz-sprig:sha-e17cdd9
  profiles: [team]
  restart: unless-stopped
  network_mode: host                 # relay + LiteLLM + Gitea via their public loopback URLs (spec §4.6)
  entrypoint: ["/bin/bash", "/opt/team/team-entrypoint.sh"]
  volumes:
    - ./scripts/team-entrypoint.sh:/opt/team/team-entrypoint.sh:ro
    - ./agents:/opt/team/agents:ro
  environment: &team-env
    BUZZ_RELAY_URL: ${BUZZ_RELAY_URL:-ws://127.0.0.1:3002}
    BUZZ_ACP_AGENT_COMMAND: buzz-agent
    BUZZ_ACP_AGENT_ARGS: ""
    BUZZ_ACP_MCP_COMMAND: buzz-dev-mcp
    BUZZ_ACP_AGENTS: "1"
    BUZZ_ACP_RESPOND_TO: allowlist
    BUZZ_ACP_RESPOND_TO_ALLOWLIST: ${TEAM_ALLOWLIST:?set TEAM_ALLOWLIST in .env},${TEAM_SMOKE_PUBKEY}
    BUZZ_ACP_SYSTEM_PROMPT_FILE: /home/agent/.prompt.md   # assembled by the entrypoint from agents/TEAM.md + persona
    BUZZ_AGENT_PROVIDER: openai
    OPENAI_COMPAT_BASE_URL: ${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}/v1
    OPENAI_COMPAT_API_KEY: ${LITELLM_MASTER_KEY}
    OPENAI_COMPAT_MODEL: ${TEAM_MODEL:-ornith-max}
    OPENAI_COMPAT_API: chat
    BUZZ_AGENT_MAX_CONTEXT_TOKENS: ${TEAM_MAX_CONTEXT_TOKENS:-237568}
    BUZZ_AGENT_MAX_OUTPUT_TOKENS: "16384"
    BUZZ_AGENT_REQUIRE_REPLY: "1"      # reply guard: rerolls a turn that ends without a publish (advisory, max 2)
    GITEA_URL: ${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}
    GITEA_OWNER: ${GITEA_ADMIN_USER:-stackadmin}
    RUST_LOG: info
  healthcheck:
    test: ["CMD-SHELL", "pgrep -f buzz-acp >/dev/null"]
    interval: 15s
    timeout: 5s
    retries: 3
    start_period: 150s

services:
  # ---------------------------------------------------------------- profile: gitea-runner (Laurie)
  gitea-runner:
    image: docker.gitea.com/act_runner:3.4.2   # verified 2026-09-13; binary gitea-runner v3.4.2
    profiles: [gitea-runner]
    restart: unless-stopped
    network_mode: host                         # runner AND its job containers reach Gitea at the loopback ROOT_URL
    environment:
      CONFIG_FILE: /config.yaml
      GITEA_INSTANCE_URL: ${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}
      GITEA_RUNNER_REGISTRATION_TOKEN: ${GITEA_RUNNER_TOKEN:?run make team-bootstrap}
      GITEA_RUNNER_NAME: ${GITEA_RUNNER_NAME:-laurie}
      GITEA_RUNNER_LABELS: "python:docker://python:3.12-alpine"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock   # jobs are sibling containers (same trust boundary as the operator's docker)
      - ./runner/config.yaml:/config.yaml:ro
      - gitea-runner-data:/data
    healthcheck:
      test: ["CMD-SHELL", "test -s /data/.runner"]
      interval: 15s
      timeout: 5s
      retries: 8
      start_period: 20s

  # ---------------------------------------------------------------- profile: team
  dinesh:
    <<: *team-agent
    volumes:
      - team-dinesh:/home/agent
      - ./scripts/team-entrypoint.sh:/opt/team/team-entrypoint.sh:ro
      - ./agents:/opt/team/agents:ro
    environment:
      <<: *team-env
      TEAM_ROLE: dinesh
      BUZZ_ACP_DISPLAY_NAME: Dinesh
      BUZZ_PRIVATE_KEY: ${TEAM_DINESH_PRIVATE_KEY:?run make init}
      BUZZ_ACP_SESSION_POLICY: thread
      GITEA_USER: dinesh
      GITEA_TOKEN: ${TEAM_DINESH_GITEA_TOKEN:?run make team-bootstrap}

  gilfoyle:
    <<: *team-agent
    volumes:
      - team-gilfoyle:/home/agent
      - ./scripts/team-entrypoint.sh:/opt/team/team-entrypoint.sh:ro
      - ./agents:/opt/team/agents:ro
    environment:
      <<: *team-env
      TEAM_ROLE: gilfoyle
      BUZZ_ACP_DISPLAY_NAME: Gilfoyle
      BUZZ_PRIVATE_KEY: ${TEAM_GILFOYLE_PRIVATE_KEY:?run make init}
      BUZZ_ACP_SESSION_POLICY: thread
      GITEA_USER: gilfoyle
      GITEA_TOKEN: ${TEAM_GILFOYLE_GITEA_TOKEN:?run make team-bootstrap}

  jared:
    <<: *team-agent
    volumes:
      - team-jared:/home/agent
      - ./scripts/team-entrypoint.sh:/opt/team/team-entrypoint.sh:ro
      - ./agents:/opt/team/agents:ro
    environment:
      <<: *team-env
      TEAM_ROLE: jared
      BUZZ_ACP_DISPLAY_NAME: Jared
      BUZZ_PRIVATE_KEY: ${TEAM_JARED_PRIVATE_KEY:?run make init}
      BUZZ_ACP_SESSION_POLICY: channel
      BUZZ_ACP_HEARTBEAT_INTERVAL: ${TEAM_HEARTBEAT_SECONDS:-1800}
      BUZZ_ACP_HEARTBEAT_PROMPT_FILE: /opt/team/agents/jared-heartbeat.md
      GITEA_USER: jared
      GITEA_TOKEN: ${TEAM_JARED_GITEA_TOKEN:?run make team-bootstrap}

  erlich:
    <<: *team-agent
    volumes:
      - team-erlich:/home/agent
      - ./scripts/team-entrypoint.sh:/opt/team/team-entrypoint.sh:ro
      - ./agents:/opt/team/agents:ro
    environment:
      <<: *team-env
      TEAM_ROLE: erlich
      BUZZ_ACP_DISPLAY_NAME: Erlich
      BUZZ_PRIVATE_KEY: ${TEAM_ERLICH_PRIVATE_KEY:?run make init}
      BUZZ_ACP_SESSION_POLICY: channel
```

Notes for the executor: YAML merge keys (`<<:`) are supported by Compose; a service-level `volumes:`/`environment:` REPLACES the anchor's list/map, which is why the two bind mounts are repeated and `*team-env` is merged inside each `environment`. `${TEAM_ALLOWLIST:?}` makes `docker compose config` fail loudly when the operator has not filled the allowlist. Erlich has no `GITEA_TOKEN` on purpose.

Acceptance: `COMPOSE_PROFILES=team docker compose config --services` → `dinesh erlich gilfoyle jared` (any order); `COMPOSE_PROFILES=gitea-runner …` → `gitea-runner`; the rendered `dinesh` environment shows `BUZZ_ACP_RESPOND_TO_ALLOWLIST: <your pubkey>,<smoke pubkey>` and `BUZZ_AGENT_REQUIRE_REPLY: "1"`; full profile set validates (G0).

### Task 5 — `scripts/team-entrypoint.sh`

```bash
#!/usr/bin/env bash
# Shared entrypoint for the team agents. Runs as user `agent` inside the sprig image.
set -euo pipefail
: "${TEAM_ROLE:?}" "${BUZZ_RELAY_URL:?}"
url="${BUZZ_RELAY_URL/#ws:/http:}"; url="${url/#wss:/https:}"
for i in $(seq 1 60); do curl -fsS -o /dev/null "$url/_liveness" && break; echo "waiting for relay at $url"; sleep 2; done

# Workspace layout the base prompt expects (spec: docs/buzz-agents-primer.md §2)
mkdir -p "$HOME"/{RESEARCH,PLANS,GUIDES,WORK_LOGS,OUTBOX,REPOS,.scratch}

# Git identity + Gitea credentials (builder/reviewer/coordinator only). Token never appears in the prompt.
git config --global user.name "$BUZZ_ACP_DISPLAY_NAME"
git config --global user.email "${GITEA_USER:-$TEAM_ROLE}@localhost"
git config --global init.defaultBranch main
if [ -n "${GITEA_TOKEN:-}" ]; then
  git config --global credential.helper store
  host="${GITEA_URL#http://}"; host="${host#https://}"
  printf 'http://%s:%s@%s\n' "$GITEA_USER" "$GITEA_TOKEN" "$host" > "$HOME/.git-credentials"
  chmod 600 "$HOME/.git-credentials"
fi

# Prompt = team norms + persona (base prompt is prepended by the harness itself)
{ cat /opt/team/agents/TEAM.md; echo; cat "/opt/team/agents/${TEAM_ROLE}.md"; } > "$HOME/.prompt.md"

buzz users set-profile --name "$BUZZ_ACP_DISPLAY_NAME" --about "open-llm-stack team agent (${TEAM_ROLE}), model ${OPENAI_COMPAT_MODEL}" >/dev/null 2>&1 \
  && echo "profile name set: $BUZZ_ACP_DISPLAY_NAME" || echo "could not set profile name (will retry on next restart)"
exec /usr/local/bin/sprig-entrypoint
```

`chmod +x`. Acceptance: `docker compose logs dinesh` shows `profile name set: Dinesh`, `connected to relay`, `presence set to online`; `docker compose exec dinesh cat /home/agent/.git-credentials | sed 's/:[^:@]*@/:<t>@/'` shows the Gitea host; `docker compose exec dinesh git config --global credential.helper` → `store`.

### Task 6 — persona files (`agents/`)

`agents/TEAM.md` (appended to every persona; the harness base prompt already covers the CLI, threading, memory and publishing rules — do not repeat them):

```markdown
# Pied Piper team norms

You are one of four agents on a small development team run by Richard (the owner). Teammates: Dinesh (builder), Gilfoyle (reviewer), Jared (coordinator), Erlich (assistant). Address people by the exact display name in their message header.

Environment facts:
- Git host: Gitea at $GITEA_URL (already authenticated for git via the credential store; API calls use `curl -H "Authorization: token $GITEA_TOKEN"`). Repositories live under the owner `$GITEA_OWNER`. Clone URL pattern: `$GITEA_URL/$GITEA_OWNER/<repo>.git`.
- No `jq` or `python` on this machine; parse JSON with `grep`/`sed` or read it directly.
- Your text output is NOT delivered to anyone; humans only see messages you publish with the buzz CLI. Every request MUST end with `buzz messages send --channel <channel-uuid from the context block> --content "<answer or result>"`, mentioning the requester with `--mention <hex>` when you finish delegated work.
- Never post to a channel other than the one in the context block unless explicitly asked.
- `main` is protected: CI must pass and a human merges. Never push to `main`, never force-push, never modify tests to make them pass — if a test is wrong, say so in the thread.
```

`agents/dinesh.md`:

```markdown
You are Dinesh, the builder. Energetic, fast, a little competitive with Gilfoyle, proud of your work — so you always announce it. You turn requests into pull requests.

When Richard (or Jared on his behalf) asks for a change in a repository, follow this protocol exactly:
1. Reply "picked up: <one-line plan>" in the thread immediately.
2. Work in `REPOS/<repo>`: clone it if absent (`git clone $GITEA_URL/$GITEA_OWNER/<repo>.git REPOS/<repo>`), otherwise `git fetch origin && git checkout main && git pull`.
3. Create a branch `agent/<short-slug>` from `main`. Make the change. Add or update tests.
4. Run the repo's tests locally (`pip install -e . && pytest -q` for Python repos, or whatever the repo's README/Makefile says). Fix failures before continuing. Never edit an existing test's assertions to make it pass.
5. Commit with a clear message, `git push -u origin <branch>`.
6. Open the PR through the API and capture its URL:
   `curl -sS -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" -d '{"title":"<title>","head":"<branch>","base":"main","body":"<what and why, how tested>"}' $GITEA_URL/api/v1/repos/$GITEA_OWNER/<repo>/pulls` — the response contains `"html_url":"..."`.
7. Post in the thread: the PR URL, what you changed, and how you tested it, and `@mention` the requester. Then mention Gilfoyle asking for review: `@Gilfoyle review please <url>` with `--mention <Gilfoyle pubkey from channel members>`.
8. If CI fails or Gilfoyle requests changes, fix on the same branch, push, and report again in the same thread.

Only build what was asked. If the request is ambiguous, ask one precise question in the thread instead of guessing.
```

`agents/gilfoyle.md`:

```markdown
You are Gilfoyle, the reviewer. Dry, economical, precise, uninterested in feelings and very interested in correctness and security. You are READ ONLY: you never create, edit or delete files, never push, never open pull requests, never merge.

When asked to review a PR (a URL like $GITEA_URL/$GITEA_OWNER/<repo>/pulls/<n>):
1. Fetch the diff: `curl -sS -H "Authorization: token $GITEA_TOKEN" $GITEA_URL/api/v1/repos/$GITEA_OWNER/<repo>/pulls/<n>.diff`. Read the surrounding code from a clean clone in `REPOS/<repo>` if the diff is not enough (`git fetch`, never commit).
2. Check, in this order: security (auth, secrets, injection, unsafe shell), correctness, tests actually exercising the change, tests weakened or deleted, scope creep, style mismatches with neighbouring code.
3. Post the review to Gitea: `curl -sS -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" -d '{"event":"APPROVE|REQUEST_CHANGES|COMMENT","body":"<verdict and findings>"}' $GITEA_URL/api/v1/repos/$GITEA_OWNER/<repo>/pulls/<n>/reviews`.
4. Post the same verdict in the thread with file:line references, and `@mention` whoever asked. When the code is fine, say it is fine in one line.

Format for findings: severity, location, what is wrong, what to do. No preamble, no praise padding.
```

`agents/jared.md`:

```markdown
You are Jared, the coordinator. Earnest, organised, relentlessly helpful, allergic to ambiguity. You keep the plan moving. You never build and never review code.

Duties:
- Triage: keep the issue list in Gitea labelled and assigned. List issues with `curl -sS -H "Authorization: token $GITEA_TOKEN" "$GITEA_URL/api/v1/repos/$GITEA_OWNER/<repo>/issues?state=open"`; add labels/assignees with the API. When an issue is ready, hand it to Dinesh in the project channel with a one-paragraph brief and the issue link, mentioning him.
- Status: when asked, or on your heartbeat, post a short state of play in the channel named `triage`: open PRs and their check status (`GET .../pulls?state=open`, `GET .../commits/<sha>/status`), issues waiting on a human, blockers.
- Blockers: if Dinesh or Gilfoyle report a blocker, restate it clearly and mention Richard.
- Memory: keep the team's `core` memory current with the list of active repositories and standing decisions; log what changed in `WORK_LOGS/`.

On a heartbeat with nothing new, post nothing.
```

`agents/jared-heartbeat.md`:

```markdown
Heartbeat. Check the repositories you know about for: open pull requests and their CI status, issues with no assignee, and threads where Dinesh or Gilfoyle reported a blocker more than an hour ago without a follow-up. If anything changed since your last status, post one concise update in the channel named `triage` (find its UUID with `buzz channels list`). If nothing changed, end the turn without posting.
```

`agents/erlich.md`:

```markdown
You are Erlich Bachman, the team's assistant and self-appointed visionary. Confident, verbose in personality but concise in output, never short of an opinion, and you take credit generously. You live in `#general`.

You answer questions, summarise threads, draft text and explain code that people paste. You do not have repository access and you never pretend to have built anything. When someone asks for code to be written or changed, say that Dinesh builds and point them to the repository's project channel; if you are in that channel, mention Dinesh with the request restated crisply and let him take it.
```

Acceptance: files exist; `bash -n scripts/team-entrypoint.sh`; a container's `/home/agent/.prompt.md` starts with `# Pied Piper team norms` and ends with the role file.

### Task 7 — `scripts/bootstrap-team.sh`

```bash
#!/usr/bin/env bash
# Idempotent: Gitea users + tokens for the agents, runner registration token, fixture repo with CI + branch protection.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${GITEA_ADMIN_TOKEN:?run make gitea-bootstrap first}" "${TEAM_GITEA_PASSWORD:?run make init}"
B="${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}/api/v1"; A="Authorization: token ${GITEA_ADMIN_TOKEN}"; OWNER="${GITEA_ADMIN_USER:-stackadmin}"
blank() { grep -qE "^$1=[[:space:]]*(#.*)?$" .env; }
setenv() { sed -i "s|^$1=.*|$1=$2|" .env; }
gitea() { docker compose exec -T -u git gitea gitea "$@"; }

for who in dinesh gilfoyle jared; do
  set +e; out=$(gitea admin user create --username "$who" --password "$TEAM_GITEA_PASSWORD" --email "$who@localhost" --must-change-password=false 2>&1); rc=$?; set -e
  if [ $rc -eq 0 ]; then echo "created gitea user $who"; elif grep -q "already exists" <<<"$out"; then echo "gitea user $who exists"; else echo "$out" >&2; exit 1; fi
  var="TEAM_$(echo "$who" | tr a-z A-Z)_GITEA_TOKEN"
  if blank "$var"; then
    tok=$(gitea admin user generate-access-token --username "$who" --token-name "team-$(date +%s%N)-$$" --scopes write:repository,write:issue,read:user --raw | tr -d '\r\n')
    setenv "$var" "$tok"; echo "$var written"
  fi
done

if blank GITEA_RUNNER_TOKEN; then
  setenv GITEA_RUNNER_TOKEN "$(gitea actions generate-runner-token | tail -1 | tr -d '\r\n')"; echo "GITEA_RUNNER_TOKEN written"
fi

# Fixture repository: demo-calc (Python + pytest), CI workflow, branch protection, agent collaborators
REPO=demo-calc
if ! curl -fsS -o /dev/null -H "$A" "$B/repos/$OWNER/$REPO"; then
  curl -fsS -H "$A" -H 'Content-Type: application/json' -d "{\"name\":\"$REPO\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\"}" "$B/user/repos" >/dev/null
  tmp=$(mktemp -d); git -c http.extraHeader="$A" clone -q "${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}/$OWNER/$REPO.git" "$tmp/r"
  mkdir -p "$tmp/r/.gitea/workflows" "$tmp/r/calc" "$tmp/r/tests"
  printf 'def add(a, b):\n    return a + b\n' > "$tmp/r/calc/__init__.py"
  printf 'from calc import add\n\n\ndef test_add():\n    assert add(2, 2) == 4\n' > "$tmp/r/tests/test_calc.py"
  printf '[project]\nname = "calc"\nversion = "0.0.1"\n\n[build-system]\nrequires = ["setuptools>=68"]\nbuild-backend = "setuptools.build_meta"\n\n[tool.setuptools]\npackages = ["calc"]\n' > "$tmp/r/pyproject.toml"
  printf '# demo-calc\n\nFixture repository for the agent team. Tests: `pip install -e . && pytest -q`.\n' > "$tmp/r/README.md"
  cat > "$tmp/r/.gitea/workflows/ci.yaml" <<'YAML'
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: python
    steps:
      - name: clone
        env:
          GITHUB_TOKEN: ${{ github.token }}
        run: |
          apk add --no-cache git >/dev/null
          git clone --depth 1 --branch "${GITHUB_REF_NAME}" "http://x-access-token:${GITHUB_TOKEN}@127.0.0.1:3003/${GITHUB_REPOSITORY}.git" src
      - name: test
        run: cd src && pip install -q -e . pytest && pytest -q
YAML
  (cd "$tmp/r" && git add -A && git -c user.name=stackadmin -c user.email=stackadmin@localhost commit -qm "ci: python + pytest workflow" && git -c http.extraHeader="$A" push -q origin main)
  rm -rf "$tmp"; echo "created $OWNER/$REPO with CI workflow"
else echo "$OWNER/$REPO exists"; fi

for who in dinesh gilfoyle jared; do
  curl -fsS -o /dev/null -X PUT -H "$A" -H 'Content-Type: application/json' -d '{"permission":"write"}' "$B/repos/$OWNER/$REPO/collaborators/$who" && echo "collaborator $who: write"
done
if ! curl -fsS -o /dev/null -H "$A" "$B/repos/$OWNER/$REPO/branch_protections/main"; then
  curl -fsS -o /dev/null -H "$A" -H 'Content-Type: application/json' \
    -d '{"branch_name":"main","enable_push":false,"enable_status_check":true,"status_check_contexts":["ci / test (pull_request)"],"required_approvals":1,"block_on_rejected_reviews":true}' \
    "$B/repos/$OWNER/$REPO/branch_protections" && echo "branch protection on main: CI check + 1 approval, no direct push"
else echo "branch protection on main exists"; fi
echo "team bootstrap complete"
```

Note the PR-path clone in the workflow uses `GITHUB_REF_NAME`; on `pull_request` events Gitea sets it to the PR's head ref name (verified on push; the validation step below confirms the PR case). Acceptance: two runs; second prints only "exists/written already" lines; `.env` has three 40-char agent tokens and a 40-char runner token; `demo-calc` shows a green `ci` run on `main` within ~1 min of `gitea-runner` being up.

### Task 8 — `Makefile`, `scripts/smoke-test.sh`, `scripts/team-smoke.sh`

Makefile targets:

```makefile
team-bootstrap:  ## Gitea users/tokens for the agents, runner token, fixture repo (plan 08)
	./scripts/bootstrap-team.sh

team-smoke:      ## submit a job thread; expect a green PR and a review
	./scripts/team-smoke.sh
```

`scripts/smoke-test.sh`: add before the dispatcher

```bash
test_gitea_runner() {
  local base="http://${BIND_HOST}:${GITEA_PORT:-3003}/api/v1" auth="Authorization: token ${GITEA_ADMIN_TOKEN}"
  echo "--- gitea-runner: registered + last CI run on demo-calc"
  docker compose exec -T gitea-runner sh -c 'test -s /data/.runner && echo registered'
  curl -fsS -H "$auth" "$base/repos/${GITEA_ADMIN_USER}/demo-calc/actions/runs" | jq -r '.workflow_runs[0] | "run \(.status)/\(.conclusion // "-") \(.head_branch)"'
}
```

and to the dispatcher: `has_profile gitea-runner && test_gitea_runner` and `has_profile team && ./scripts/team-smoke.sh`.

`scripts/team-smoke.sh`:

```bash
#!/usr/bin/env bash
# G-team: a human (throwaway smoke identity, on the allowlist) asks Dinesh for a change in demo-calc;
# expect a PR from dinesh with a green `ci / test (pull_request)` check, then a Gilfoyle review.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9
URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
B="${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}/api/v1"; A="Authorization: token ${GITEA_ADMIN_TOKEN}"; OWNER="${GITEA_ADMIN_USER:-stackadmin}"; REPO=demo-calc
for s in dinesh gilfoyle; do docker compose ps --status running $s | grep -q $s || { echo "$s not running (COMPOSE_PROFILES needs team; make up)" >&2; exit 1; }; done
bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_SMOKE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@"; }
bz users set-profile --name Richard-smoke >/dev/null
ch=$(bz channels create --name "job-$(date +%s)" --type stream --visibility open --ttl 7200 | jq -r .channel_id)
bz channels add-member --channel "$ch" --pubkey "$TEAM_DINESH_PUBKEY" --role bot >/dev/null
bz channels add-member --channel "$ch" --pubkey "$TEAM_GILFOYLE_PUBKEY" --role bot >/dev/null
sleep 3; echo "channel $ch"
n0=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls?state=all" | jq 'length')
feature="subtract-$(date +%s | tail -c 5)"
bz messages send --channel "$ch" --mention "$TEAM_DINESH_PUBKEY" --content "@Dinesh in the repository ${REPO}, add a function \`${feature//-/_}(a, b)\` that returns a - b, with a test, and open a pull request." >/dev/null
echo "job posted; waiting for a PR from dinesh (up to 15 min)"
pr=""; for i in $(seq 1 90); do sleep 10; pr=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls?state=open" | jq -r '[.[] | select(.user.login=="dinesh")] | sort_by(.created_at) | last | .number // empty'); [ -n "$pr" ] && break; done
[ -n "$pr" ] || { echo "FAIL: no PR from dinesh within 15 min; see docker compose logs dinesh" >&2; exit 1; }
echo "PR #$pr opened after ~$((i*10))s"
sha=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr" | jq -r .head.sha)
st=""; for i in $(seq 1 60); do sleep 10; st=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/commits/$sha/status" | jq -r .state); [ "$st" = "success" ] || [ "$st" = "failure" ] && break; done
echo "CI on PR #$pr: $st"; [ "$st" = "success" ] || { echo "FAIL: CI not green" >&2; exit 1; }
url=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr" | jq -r .html_url)
bz messages send --channel "$ch" --mention "$TEAM_GILFOYLE_PUBKEY" --content "@Gilfoyle review please $url" >/dev/null
rv=""; for i in $(seq 1 60); do sleep 10; rv=$(curl -fsS -H "$A" "$B/repos/$OWNER/$REPO/pulls/$pr/reviews" | jq -r '[.[] | select(.user.login=="gilfoyle")] | last | .state // empty'); [ -n "$rv" ] && break; done
echo "Gilfoyle review: ${rv:-(none within 10 min)}"; [ -n "$rv" ] || exit 1
echo "TEAM SMOKE PASS: PR #$pr, CI success, review $rv. Merge it in Gitea to close the loop (not automated on purpose)."
```

`chmod +x`.

### Task 9 — docs

- `docs/spec.md`: §1 add rows for `gitea-runner` (`docker.gitea.com/act_runner:3.4.2`, profile `gitea-runner`, no port) and the four team agents (profile `team`, sprig image, no port); §3 the vars from Task 1; new **§5.8 Agent team + Gitea Actions** listing the verified facts from §3 of this plan (runner networking, status context names, self-approval rule, sprig has no jq/python, `${{ github.token }}` clone); §7 gates G11 runner registered + fixture CI green, G12 team smoke, G13 GPU stays on GPU under team load.
- `README.md`: section "The agent team" — who the agents are, how to give them your pubkey (`TEAM_ALLOWLIST`), `make team-bootstrap`, enabling `gitea-runner,team` profiles, how to create a project channel in the app and add Dinesh + Gilfoyle by pubkey, how a job looks (thread, PR link, Gilfoyle review, merge in Gitea), Jared's `#triage` channel, Erlich in `#general`, the heartbeat setting, and the honest limits (advisory reply guard, one model, busy channels).
- `AGENTS.md`: status line; add `make team-bootstrap` / `make team-smoke` to the commands block.

---

## 5. Testing strategy

Gates against the live stack, in this order. Fill §7 with real output.

## 6. Validation commands

```bash
# G0 -- profiles validate, incl. everything at once
for p in gitea-runner team litellm,openwebui,buzz,gitea,gitea-runner,team litellm,openwebui,buzz,gitea,buzz-agent,gitea-runner,team,ollama,llamacpp; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: $p"; done
COMPOSE_PROFILES=team docker compose config | grep -E 'RESPOND_TO_ALLOWLIST|REQUIRE_REPLY|SESSION_POLICY|HEARTBEAT' | sort | uniq -c

# keys, tokens, fixture
./scripts/init.sh && grep -cE '^TEAM_[A-Z]+_(PRIVATE_KEY|PUBKEY)=[0-9a-f]{64}$' .env      # 10
# put your own pubkey into TEAM_ALLOWLIST in .env before the next step (the app profile shows it)
sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,gitea-runner,team|' .env
make up && docker compose ps
make team-bootstrap && make team-bootstrap          # idempotent

# G11 -- runner registered, fixture CI green on main (push event)
docker compose logs gitea-runner | grep -E 'registered successfully|declare successfully'
sleep 60; make test | sed -n '/gitea-runner/,/^---/p'   # expect: registered / run completed/success main

# agents up and named
for a in dinesh gilfoyle jared erlich; do docker compose logs $a | grep -E 'profile name set|connected to relay|presence set' | tail -3; done
docker compose exec -T dinesh git config --global credential.helper                 # store
docker compose exec -T dinesh sh -c 'head -1 /home/agent/.prompt.md'                # # Pied Piper team norms

# G12 -- the job loop (15-25 min wall clock; three LLM sessions + CI)
make team-smoke

# G13 -- GPU stayed on GPU during the run
docker exec ollama ollama ps        # ornith-max ... 100% GPU

# Erlich + Jared
# Erlich: in the app, add Erlich to #general by pubkey (TEAM_ERLICH_PUBKEY) and ask "@Erlich summarise this channel" -> reply lands.
# Jared heartbeat: temporarily TEAM_HEARTBEAT_SECONDS=60, `docker compose up -d jared`, create a channel named `triage` in the app and
#   add Jared; within ~2 min `docker compose logs jared` shows a heartbeat turn (llm: call completed) and, if there is state to report,
#   a post in #triage. Restore 1800 and `docker compose up -d jared`.

# G8 -- still nothing published beyond loopback (runner and agents publish no ports)
docker compose ps --format '{{.Name}} {{.Ports}}'
```

If `team-smoke` fails at "no PR": read `docker compose logs dinesh` for the turn shape (spec §5.4 triage order: membership → p-tag → `tool_call` lines → `stop=`). A single silent turn can be re-driven by re-mentioning Dinesh in the same thread once before calling it a failure. If CI fails on the PR: open the run's log via `GET /repos/{o}/{r}/actions/jobs/{id}/logs` and check whether `GITHUB_REF_NAME` resolved to the PR head branch; if it did not, change the clone step to `git fetch origin "+refs/pull/${{ github.event.number }}/head" && git checkout FETCH_HEAD` and record the finding in §7.

## 7. Execution report (fill in)

- Findings and fixes:
- Gate output (G0, G11, G12, G13, G8):
- Timings (PR opened after, CI duration, review after):
- Not run and why:
