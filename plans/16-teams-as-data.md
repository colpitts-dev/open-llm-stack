# Plan 16 — Teams as data: one TOML file per team, rendered into Compose, roles as files, members by role

**Spec:** `docs/spec.md` (this plan adds §5.17 and gates G40–G44, plus G37 for the per-member LiteLLM keys moved here from plan 15). **Rules:** `AGENTS.md`. **Knowledge:** plan 08 §5.8 (team, tokens, entrypoint, scrubbed shell), plan 10 §5.11 (role teams `builders`/`reviewers`/`coordinators` and their unit maps), plan 11 §5.12 (thread conventions), plan 12 §5.13 (runtimes), plan 13 §5.14 (Jared is coordinator and judge), plan 14 §5.15, plan 15 §5.16 (measured cost: `cost-report` groups its per-client lines by the LiteLLM key alias this plan mints).
**Sequence:** 16. Requires plan 14 executed (plan 15 is independent; run it first so the keys show up in its report). Adds one directory (`teams/`), three host scripts (`team-render.py`, `team-roster.py`, `litellm-keys.sh`: one LiteLLM virtual key per member, moved here from plan 15 on 2026-09-14 because members are data here), one shared Compose fragment, four role files, four presets, eight make targets; replaces the five hand-written agent services and the hard-coded member lists in `init.sh`, `bootstrap-team.sh`, `team-smoke.sh`, `smoke-test.sh` and the `Makefile`. No new service, image, port, build, network or dependency (`tomllib` is in Python 3.11+, verified 3.12.3 on the host).
**Execute with:** `/execute plans/16-teams-as-data.md`
**No internet except `docker pull`.** Every Compose behaviour below was verified on Docker Compose v5.1.3 with scratch projects on 2026-09-14; the rendered default team was diffed against the live stack's `docker compose config` the same day (§3).

---

## 1. Overview

**Intent.** A team is a small file; a member is a few lines plus a persona; every script picks agents by role, never by name. One team per deployment (v1). The default team `piedpiper` keeps its five service names, volumes, keys and forge logins, so every gate since plan 08 stays valid and no `.env` migrates.

**What changes.** Adding Monica (commit `de68371`) touched nine files and ten now carry her name (§3). After this plan a member is: one `[[members]]` block in `teams/<team>/team.toml`, one persona file, `make member-add`. The rest is rendered or read at run time:

| Concern | Today | After |
|---|---|---|
| Buzz identity | `init.sh` mints keys from a hard-coded list (`scripts/init.sh:37`) | `team-render.py` mints `TEAM_<MEMBER>_PRIVATE_KEY/PUBKEY` for every member in `team.toml` when blank |
| Container | five hand-written service blocks sharing YAML anchors (`docker-compose.yml:25-62`, `:384-470`) | `teams/<team>/compose.yml`, rendered, one service per member, each `extends` `teams/_base.yml`; included by `docker-compose.yml` through `TEAM_NAME` |
| Forge account | `bootstrap-team.sh:33` member loop, `:63-65` team membership by name | bootstrap reads the roster: login = name + `AGENT_LOGIN_SUFFIX`, `full_name` = `<Name> (AI <role>)`, team by role; refuses a login held by a person |
| Prompt | `TEAM.md` roster sentence, `$GILFOYLE_PUBKEY`/`$JARED_PUBKEY` `sed`-inlined (`team-entrypoint.sh:50-51`) | `TEAM.md` (generic) + `agents/roles/<role>.md` (the tested duties) + `teams/<team>/personas/<member>.md` (flavour) + a roster block expanded from `TEAM_ROSTER`; `$REVIEWER_PUBKEY`, `$COORDINATOR_PUBKEY`, `$REVIEWER_NAME`, `$COORDINATOR_NAME`, `$BUILDER_NAME` inlined by role |
| Operations | `make team-model` recreates a fixed list (`Makefile:39`); smoke tests name `dinesh`/`gilfoyle`/`jared` | `scripts/team-roster.py` answers "who is the builder" for every script; make targets recreate the members of the team |
| LiteLLM keys | every agent, Open WebUI and the Buzz agent send the master key (`&team-env`, `docker-compose.yml:51`, `:131`, `:347`) | one virtual key per member by alias (`scripts/litellm-keys.sh`, from the roster; team alias = the org), master-key fallback in the rendered file; spend rows then carry `user_api_key_alias`, which plan 15's `cost-report` groups by |

**Best practices applied.** Compose `include` for a self-contained service group and `extends` for the shared service shape, as the Compose documentation and the Compose maintainers' guidance recommend (`include` "imports self-contained service groups as reusable units", `extends` gives "a single source of truth" for shared service configuration; Docker Docs, *include* and *services* reference; *Compose Tip #38: when to use include vs extends vs overrides*, lours.me, fetched 2026-09-14). YAML anchors do not cross files (verified: `unknown anchor 'team-agent' referenced`), so the shared shape is a real service in a fragment, not an anchor. A generated file carries a header naming its generator and its source, is deterministic, and renders idempotently (`render` twice is a no-op, `--check` exits non-zero when it would change anything). Secrets are minted only when blank and never overwritten (the `init.sh` rule since plan 01). Roles are the tested unit and a closed list mapped to forge permissions (plan 10); personas are open text. Naming follows Git practice (§3.5 of the retired design note, decided 2026-09-14): users are people or marked machine users unique per instance, organisations are the operator's, teams are function groups.

**Design.**

| Piece | Where | What |
|---|---|---|
| team file | `teams/<team>/team.toml` | `name`, `org`, `model`, `ci_label`, `humans`, `[[members]]` with `name`, `role`, optional `persona`, `display`, `title`, `runtime`, `model`, `heartbeat` |
| shared shape | `teams/_base.yml` | service `agent-base` (profile `never`): today's anchor content; paths relative to `teams/` |
| rendered team | `teams/<team>/compose.yml` (committed for `piedpiper`) | one service per member extending `agent-base`; allowlist and `TEAM_ROSTER` rendered from `${TEAM_<M>_PUBKEY:-}` references, so the committed file is identical on every host |
| include | `docker-compose.yml`: `include: - path: teams/${TEAM_NAME:-piedpiper}/compose.yml` with `project_directory: .` | one Compose project, one network, `make up` unchanged |
| renderer | `scripts/team-render.py`, `make team-render [T=]` | validate, mint, render; `--check` for CI |
| roster for shell | `scripts/team-roster.py` | `members`, `role <r>`, `get <k>`, `humans` |
| roles | `agents/roles/{builder,reviewer,coordinator,assistant}.md`, `agents/roles/coordinator-heartbeat.md` | duties that gates test; `$REVIEWER_*`, `$COORDINATOR_*`, `$BUILDER_NAME` placeholders |
| personas | `teams/<team>/personas/<member>.md` | voice and specialities, 3–30 lines; Monica's design principles live here |
| presets | `teams/_presets/{dev-squad,solo-builder,review-board,content-studio}.toml` (+ persona stubs) | `make team-new T=<x> FROM=<preset>` |
| make | `team-render`, `team-new`, `member-add`, `member-rm`, `member-runtime`, `team-status`; `team-model` and `dinesh-runtime` rewritten on the roster | |

**Success criteria.** G40 — `make team-render` is deterministic and idempotent (second run prints `unchanged`, `--check` exits 0), and the rendered `piedpiper` equals the live stack's `docker compose config` for the five agents and the volumes except the enumerated intentional differences (§3: `TEAM_MEMBER`, `TEAM_NAME`, `TEAM_ROSTER` added; `TEAM_ROLE` now the role; `GILFOYLE_PUBKEY`/`JARED_PUBKEY` removed; the heartbeat prompt path; profiles `[never, team]`; the `/opt/team/teams` mount). G41 — every gate from plans 08–15 reruns green on the rendered team (G11–G28, G35–G39) with `make test` exit 0. G42 — `make member-add T=piedpiper N=bertram R=builder` makes a sixth member that answers a mention by name in a job thread within one restart and opens a PR as `bertram`; `make member-rm N=bertram` removes the service and the forge membership and leaves the keys. G43 — in a scratch checkout, `make team-new T=acme FROM=dev-squad` renders and `docker compose config` validates; on the live instance `bootstrap-team.sh` refuses a login held by a person (a user whose email is not `@agents.invalid`) with `AGENT_LOGIN_SUFFIX` blank and creates `<name>-ai` with `AGENT_LOGIN_SUFFIX=-ai`; every agent shows `full_name` `<Name> (AI <role>)` on the forge. G44 — scripts pick agents by role: with the builder renamed in a scratch team (`ada` instead of `dinesh`) `make team-smoke` passes end to end.

**Out of scope.** Two teams in one deployment (v1 is one; `TEAM_NAME` selects it), per-team channels on the relay, new roles (a role needs a forge team definition and gates), the console (plan 17), `AGENT_LOGIN_SUFFIX` applied to display names (display stays the persona name).

## 2. Relevant files

| Path | Action |
|---|---|
| `teams/piedpiper/team.toml`, `teams/piedpiper/personas/{dinesh,gilfoyle,jared,erlich,monica}.md` | new: the default team as data; personas moved out of `agents/*.md` |
| `teams/piedpiper/compose.yml` | new, generated, committed |
| `teams/_base.yml` | new: the shared service shape (today's anchors) |
| `teams/_presets/*.toml`, `teams/_presets/personas/*.md` | new: four presets |
| `agents/roles/{builder,reviewer,coordinator,assistant}.md`, `agents/roles/coordinator-heartbeat.md` | new: duties (from `agents/dinesh.md`, `gilfoyle.md`, `jared.md`, `erlich.md`, `jared-heartbeat.md`), names replaced by role placeholders |
| `agents/{dinesh,gilfoyle,jared,erlich,monica,jared-heartbeat}.md` | removed (content split into roles and personas) |
| `agents/TEAM.md` | roster sentence replaced by `$TEAM_ROSTER_LINE`; pubkey sentence by role placeholders |
| `scripts/team-render.py`, `scripts/team-roster.py` | new |
| `scripts/team-entrypoint.sh` | prompt assembly from role + persona + roster; `TEAM_MEMBER`/`TEAM_ROLE` semantics |
| `scripts/init.sh` | member key loop replaced by `team-render.py`; `TEAM_SMOKE_*` stays |
| `scripts/bootstrap-team.sh` | members, teams, `full_name`, login suffix, refusal from the roster |
| `scripts/team-smoke.sh`, `scripts/smoke-test.sh` | builder/reviewer/coordinator by role; `test_team_runtime` reads the roster |
| `scripts/litellm-keys.sh` | new: one LiteLLM team per agent team and one virtual key per member, Open WebUI and the Buzz agent, into `.env`; called by `bootstrap-team.sh` |
| `docker-compose.yml` | anchors, five services and five volumes removed; `include:` added |
| `Makefile` | new targets; `team-model`, `dinesh-runtime` rewritten |
| `.env.example` | `TEAM_NAME`, `AGENT_LOGIN_SUFFIX`; member lines kept as the default team's sample; `TEAM_DINESH_RUNTIME`/`TEAM_DINESH_IMAGE` removed |
| `README.md`, `docs/spec.md` §2, §3, §5.8, §5.17, §7, `AGENTS.md` | docs, gates, status |

## 3. Dependencies and verified facts (reference host, 2026-09-14)

- **Anchors do not cross Compose files.** A second file using `<<: *team-agent` fails: `yaml: line 3, column 10: unknown anchor 'team-agent' referenced`. Hence a shared *service* in a fragment and `extends`.
- **`include` with an interpolated path works.** `include: - path: teams/${TEAM_NAME:-piedpiper}/compose.yml` rendered the team; `TEAM_NAME=nope` fails clearly: `open …/teams/nope/compose.yml: no such file or directory`. Project name stays `open-llm-stack`; `docker compose ps --format '{{.Project}}'` prints it. Compose docs: "Relative paths in Compose files being referred by `include` are resolved relative to their own Compose file path"; `project_directory` "establishes a base path for resolving relative references within the included file".
- **`extends` resolution, measured.** With `project_directory: .` on the include, `extends: { file: teams/_base.yml, service: agent-base }` inside `teams/piedpiper/compose.yml` resolves from the repository root. Bind sources written in the *extended* file resolve against that file's own directory (`./scripts/x` in `teams/_base.yml` became `teams/scripts/x`), so `_base.yml` uses `../scripts/…`, `../agents`, `../teams`. Merge rules as documented and observed: mappings (environment) — main service keys override; sequences (volumes) — referenced items first, main items appended; `profiles` merge to `[never, team]`, and `--profile team` / `COMPOSE_PROFILES=…,team` activates the service (the `never` entry is inert). Circular `extends` is unsupported; `_base.yml` extends nothing.
- **Rendered `piedpiper` against the live stack.** A scratch project (the live `docker-compose.yml` with the anchors, the five services and the five `team-*` volumes removed, the `include` added, `teams/_base.yml` and the rendered file from §4) and the live project were both run through `docker compose config --format json` with the live `.env`. Service sets equal, volume sets equal, `BUZZ_ACP_RESPOND_TO_ALLOWLIST` byte-identical for every agent, `healthcheck`, `logging`, image, network mode, entrypoint, session policies and heartbeat interval identical. The only differences, all intended: `env.TEAM_MEMBER` added, `env.TEAM_NAME` added, `env.TEAM_ROSTER` added, `env.TEAM_ROLE` changed (member name → role), `env.GILFOYLE_PUBKEY` and `env.JARED_PUBKEY` removed, `env.BUZZ_ACP_HEARTBEAT_PROMPT_FILE` changed (`agents/jared-heartbeat.md` → `agents/roles/coordinator-heartbeat.md`), `profiles: ['team'] → ['never', 'team']`, volume `+/opt/team/teams`. This list is G40's allow-list.
- **Renderer behaviour.** Rendered five members; second run: `teams/piedpiper/compose.yml unchanged`, `.env unchanged`; `--check` exit 0. Validation rejects a bad role, a duplicate name, a missing persona (`team.toml invalid:` with one line per error, exit 1) and a missing team (`no teams/nope/team.toml: make team-new …`). `--no-mint` left keys untouched; without it a blank key is minted by `docker run --rm --entrypoint /usr/local/bin/buzz-admin ghcr.io/block/buzz:sha-e17cdd9 generate-key` exactly as `init.sh:27`.
- **Roster expansion in bash** (the entrypoint snippet in §4 Task 5) produced from the rendered `TEAM_ROSTER`: the four-line roster block, `REVIEWER=Gilfoyle/<pubkey>`, `COORDINATOR=Jared/<pubkey>`, `BUILDER=Dinesh`, and the roster sentence `Teammates: Dinesh (builder), Gilfoyle (reviewer), Jared (coordinator and judge: …), Erlich (assistant)`. `title` in `team.toml` replaces the role word in the roster (`Monica (UI designer, also a builder)`).
- **`tomllib`** parses a `team.toml` with `[[members]]` into `{"name": …, "members": [{…}, {…}]}` (Python 3.12.3, standard library). `jq` 1.7 present, no `yq`.
- **Today's hard-coded places** (line numbers as of `db51d66`): `scripts/init.sh:37` key loop; `scripts/bootstrap-team.sh:33` member loop, `:63-65` team membership, `:27-31` `ensure_user` (email `<name>@agents.invalid`, no `full_name`); `scripts/team-entrypoint.sh:4,6,7` (`TEAM_ROLE` as name, `erlich` special case), `:36` git email from `TEAM_ROLE`, `:50-51` prompt assembly and `sed`; `scripts/team-smoke.sh:10,14-16,20,22-23,30,32,36-37,41-43,47,52-56,59,61` (names and `TEAM_*_PUBKEY`); `scripts/smoke-test.sh:124,138,155-156,161-166,171-175` (`exec dinesh/jared`, `TEAM_DINESH_RUNTIME`); `Makefile:39` recreate list, `:45-49` `dinesh-runtime`; `docker-compose.yml:25-76` anchors, `:47` allowlist, `:60-61` pubkeys, `:64` `TEAM_RUNTIME`, `:384-470` services, `:19-23` volumes; `agents/TEAM.md:3` roster sentence; personas `dinesh.md` 18 lines, `gilfoyle.md` 11, `jared.md` 32, `erlich.md` 3, `monica.md` 25, `jared-heartbeat.md` 11; `agents/bin/new-repo:8,24` and `score-post:27` use `GITEA_USER` only (already role-neutral).
- **Gitea `full_name`.** `GET /api/v1/users/dinesh` (judge token) → `{"login":"dinesh","full_name":"","email":"4+dinesh@noreply.git.colpitts.dev"}`; the swagger (`/swagger.v1.json`) lists `full_name` in both `CreateUserOption` and `EditUserOption` (also `must_change_password`, `restricted`, `visibility`, …); `GET /api/v1/users/dinesh` with the admin token → 200. Nothing was written. The email the API returns is the instance's no-reply address, not the `@agents.invalid` value sent at creation, so the "held by a person" test in §4 Task 6 reads `GET /admin/users` (admin token, returns the stored `email`) — **verify at execution** that the admin listing shows `<name>@agents.invalid` for agents; if it also masks, fall back to a `description` marker set by the bootstrap (`EditUserOption.description`).
- **LiteLLM virtual keys (verified 2026-09-14 while plan 15 was written; the keys moved here).** `POST /key/generate {"key_alias":"plan15-test","metadata":{…}}` → `{"key":"sk-…","key_alias":"plan15-test","models":[],"max_budget":null}`; a call with that key wrote a spend row with `metadata->>'user_api_key_alias' = plan15-test`; the key reads `/v1/model/info` and `/v1/models` (200), which the entrypoint needs; `GET /key/list?key_alias=…&return_full_object=true` → `total_count 1`; `POST /key/delete {"keys":[…]}` → `deleted_keys`; test keys deleted. On 4597 spend rows `metadata` carries `user_api_key_alias`, `user_api_key_team_alias` and `user_api_key_team_id` (all null under the master key) and the `team_id` column is `''`: a team split groups by the metadata alias. Compose nested default: with `K: ${TEAM_X_LITELLM_KEY:-${LITELLM_MASTER_KEY}}`, `docker compose config` rendered `mk` when only the master key was set and `vk` when the member key was set. **Verify at execution:** `POST /team/new {"team_alias"}` → `team_id`; `GET /team/list` shape; a key minted with `team_id` writes `user_api_key_team_alias` into the spend row's `metadata`.
- **Research.** Network was available: Docker Docs *include* reference (path resolution, `project_directory`, conflicts "displays a warning if resource names conflict and doesn't try to merge them"), Docker Docs *services* reference (`extends` merge rules quoted above), *Compose Tip #38* (include for service groups, extends for shared shape, override files for environment). No document was found on generated-file conventions; the header-names-generator, deterministic, idempotent, `--check` rules follow the common practice of code generators (protobuf, `go generate`, Helm templates) and are gated here rather than cited.

## 4. Tasks

### Task 1 — `teams/_base.yml` (the shared shape)

```yaml
# Shared shape of one team agent (plan 16). Every rendered teams/<team>/compose.yml service extends `agent-base`.
# Paths here are relative to this file's directory (teams/): Compose resolves an extended file's binds against that file.
# Never started itself (profile `never`); per-member values come from the rendered file.
services:
  agent-base:
    image: ghcr.io/block/buzz-sprig:sha-e17cdd9
    profiles: [never]
    restart: unless-stopped
    network_mode: host                 # relay + LiteLLM + Gitea via their public loopback URLs (spec §4.6)
    entrypoint: ["/bin/bash", "/opt/team/team-entrypoint.sh"]
    volumes:
      - ../scripts/team-entrypoint.sh:/opt/team/team-entrypoint.sh:ro
      - ../scripts/team-narrate.sh:/opt/team/team-narrate.sh:ro
      - ../agents:/opt/team/agents:ro
      - ../teams:/opt/team/teams:ro     # personas of the team named by TEAM_NAME
      - ${GITEA_CA_FILE:-/dev/null}:/opt/team/ca.crt:ro   # /dev/null = no private CA (0 bytes; the entrypoint checks -s)
    environment:
      TEAM_NAME: ${TEAM_NAME:-piedpiper}
      BUZZ_RELAY_URL: ${BUZZ_RELAY_URL:-ws://127.0.0.1:3002}
      BUZZ_ACP_AGENT_COMMAND: buzz-agent
      BUZZ_ACP_AGENT_ARGS: ""
      BUZZ_ACP_MCP_COMMAND: buzz-dev-mcp
      BUZZ_ACP_AGENTS: "1"
      BUZZ_ACP_RESPOND_TO: allowlist
      BUZZ_ACP_SYSTEM_PROMPT_FILE: /home/agent/.prompt.md   # assembled by the entrypoint: TEAM.md + role + persona + roster
      BUZZ_AGENT_PROVIDER: openai
      OPENAI_COMPAT_BASE_URL: ${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}/v1
      OPENAI_COMPAT_API: chat
      BUZZ_AGENT_MAX_CONTEXT_TOKENS: ${TEAM_MAX_CONTEXT_TOKENS:-}   # blank = entrypoint fills from the registry
      BUZZ_AGENT_REQUIRE_REPLY: "1"      # reply guard: rerolls a turn that ends without a publish (advisory, max 2)
      GITEA_URL: ${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}
      GITEA_OWNER: ${TEAM_GITEA_ORG:-piedpiper}   # org, not the admin user: a non-admin cannot create repos in another user's namespace
      GITEA_ADMIN: ${GITEA_ADMIN_USER:-stackadmin}    # with GITEA_HUMAN, the only users who may merge (branch-protection merge whitelist)
      GITEA_HUMAN: ${TEAM_HUMAN_USER:-richard}
      TEAM_CI_LABEL: ${TEAM_CI_LABEL:-python}   # runs-on label for generated CI workflows (python = bundled runner; ci = the forge's)
      TEAM_NARRATE: ${TEAM_NARRATE:-off}   # off | tools | both: progress mirror into the job thread (plan 11; the entrypoint raises RUST_LOG when on)
      RUST_LOG: info
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f buzz-acp >/dev/null"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 150s
    logging:                            # acp::wire debug (mirror on) is ~10x the info volume; bound it
      driver: json-file
      options: { max-size: "20m", max-file: "3" }
```

`docker-compose.yml`: delete the `x-team-agent:` block (`:25-76`), the five services (`:384-470`) and the five `team-*` volumes (`:19-23`); after `name: open-llm-stack` add:

```yaml
include:
  - path: teams/${TEAM_NAME:-piedpiper}/compose.yml   # the team (plan 16): rendered from teams/<team>/team.toml by make team-render
    project_directory: .
```

The `# --- profile: team` comment stays as a pointer to `teams/`. `TEAM_GITEA_ORG` in `.env` stays the org variable (`team.toml`'s `org` is written into it by the renderer, like `TEAM_MODEL`).

### Task 2 — the default team as data

`teams/piedpiper/team.toml`:

```toml
# The default team (plan 16). Edit, then `make team-render`. Member order is the roster order and the allowlist order.
name = "piedpiper"          # the team: directory name, TEAM_NAME in .env
org = "piedpiper"           # the Gitea organisation the team works in (TEAM_GITEA_ORG): created if missing, reused if present
model = "ornith-max"        # every member's model unless a member sets its own; a model_name in proxy/config.yaml
ci_label = "python"         # runs-on label for generated CI workflows: python = bundled runner, ci = the forge's
humans = []                 # pubkeys of the people the agents obey, owner first; blank here = TEAM_ALLOWLIST in .env

[[members]]
name = "dinesh"             # login, service, volume team-dinesh, keys TEAM_DINESH_*; display "Dinesh"
role = "builder"

[[members]]
name = "gilfoyle"
role = "reviewer"

[[members]]
name = "jared"
role = "coordinator"
heartbeat = 0               # seconds between proactive triage ticks; 0 = off (plan 14: a tick is ~13 full-prefill calls)

[[members]]
name = "erlich"
role = "assistant"

[[members]]
name = "monica"
role = "builder"
title = "UI designer, also a builder"   # how the roster introduces her; the persona carries the rest
```

Optional member keys: `persona = "<file>.md"` (default `<name>.md`), `display = "…"` (default capitalised name), `runtime = "buzz-agent" | "goose"`, `model = "<model_name>"`. Unknown keys are ignored by the renderer; a persona file that does not exist is an error.

Personas `teams/piedpiper/personas/<name>.md`: the first paragraph of each current `agents/<name>.md` (voice and specialities) plus, for Monica, her "Design principles" list and item 3 ("Look before you design") and the "no browser" sentence of item 5; nothing that the role file carries. Erlich's whole file is persona. Sizes expected: dinesh 2 lines, gilfoyle 2, jared 2, erlich 3, monica ~12.

### Task 3 — roles are files

`agents/roles/builder.md` (exact; the protocol of `agents/dinesh.md` items 1–8 and the closing rule, with role placeholders):

```markdown
Role: builder. You turn requests into pull requests. You have write access to the organisation's repositories through your own forge account and token.

When the owner (or $COORDINATOR_NAME on the owner's behalf) asks for a change in a repository, follow this protocol exactly:
1. Reply "picked up: <one-line plan>" in the thread immediately.
2. Work in `REPOS/<repo>`: clone it if absent (`git clone $GITEA_URL/$GITEA_OWNER/<repo>.git REPOS/<repo>`), otherwise `git fetch origin && git checkout main && git pull`. If `origin` is not under `$GITEA_URL` or the fetch fails, delete the directory and clone again; never push history from another host.
   If the repository does not exist yet and the request is for a NEW project, run the factory once:
   `/opt/team/agents/bin/new-repo <repo>` — it creates `$GITEA_OWNER/<repo>` from the org template (private, CI workflow,
   protected `main`) and drops your admin rights on it. Then clone it, replace `REPO_NAME` in `pyproject.toml` and
   `README.md` with the repo name, and continue on a branch. Never create repositories any other way.
3. Create a branch `agent/<short-slug>` from `main`. Make the change. Add or update tests.
4. This machine has no Python, so you cannot run tests locally; CI runs them on every push. Read the code you changed carefully before pushing. Never edit an existing test's assertions to make it pass.
5. Commit with a clear message, `git push -u origin <branch>`. Immediately after the push succeeds, before anything else, post the push milestone as ONE message: `buzz messages send --channel <uuid> --reply-to <thread root id> --content - <<'EOF'` / `🚩 pushed <branch> (<n> files) — opening the PR, CI running` / `EOF`.
6. Open the PR through the API and capture its URL:
   `. ~/.gitea.env && curl -sS -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" -d @pr.json $GITEA_URL/api/v1/repos/$GITEA_OWNER/<repo>/pulls` where pr.json is `{"title":"<title>","head":"<branch>","base":"main","body":"<what and why, how tested>"}` — the response contains `"html_url":"..."`.
7. Post the deliverable in the thread as `**PR:**` (TEAM.md) — write the body to `pr.txt` with a quoted heredoc and send `--content - < pr.txt` (backticks inside `--content "..."` get eaten by the shell): the PR URL, what you changed, and how you tested it, and `@mention` the requester. Then mention the reviewer asking for review: `@$REVIEWER_NAME review please <url>` with `--mention $REVIEWER_PUBKEY`.
8. After pushing, check CI on your PR: `. ~/.gitea.env && curl -sS -H "Authorization: token $GITEA_TOKEN" $GITEA_URL/api/v1/repos/$GITEA_OWNER/<repo>/commits/<head sha>/status` (`state` is `pending`, `success` or `failure`). As soon as the state is `success` or `failure`, post the CI milestone as ONE message the same way: `🚩 CI success on <sha7>` or `🚩 CI failure on <sha7> — fixing: <one clause>`. Both milestones are mandatory on every job, even when you also post the PR. If CI fails or the reviewer requests changes, fix on the same branch, push, and report again in the same thread.

Only build what was asked. If the request is ambiguous, ask one precise question in the thread instead of guessing.
```

Rule for the other three: move the duty paragraphs of `agents/gilfoyle.md` (items 1–4 and the findings format) into `agents/roles/reviewer.md`, of `agents/jared.md` (Duties, the heartbeat sentence, the scoring procedure and the rubric) into `agents/roles/coordinator.md`, and the second paragraph of `agents/erlich.md` into `agents/roles/assistant.md`, each starting with `Role: <role>. …` in one sentence; replace `Gilfoyle` → `$REVIEWER_NAME`, `$GILFOYLE_PUBKEY` → `$REVIEWER_PUBKEY`, `Jared`/`the judge` → `$COORDINATOR_NAME`, `$JARED_PUBKEY` → `$COORDINATOR_PUBKEY`, `Dinesh` → `$BUILDER_NAME`, `Richard` → `the owner`; keep every command, label and rubric anchor byte-for-byte (they are what gates G22, G26, G27 test). `agents/jared-heartbeat.md` moves to `agents/roles/coordinator-heartbeat.md` unchanged. `agents/TEAM.md:3` becomes:

```
You are one of the agents on a small development team run by the owner. Teammates: $TEAM_ROSTER_LINE. Address people by the exact display name in their message header. The reviewer's pubkey is `$REVIEWER_PUBKEY` and the coordinator's is `$COORDINATOR_PUBKEY` (use them for `--mention`; the members list shows no names).
```

The `**Review:**`/`**Score:**` conventions in `TEAM.md` keep their wording (`@Gilfoyle review please` becomes `@$REVIEWER_NAME review please`; `(Jared only)` becomes `(the coordinator only)`).

### Task 4 — `scripts/team-render.py` and `scripts/team-roster.py`

`scripts/team-render.py` (exact; ran on the scratch project, §3):

```python
#!/usr/bin/env python3
"""Render a team (plan 16): teams/<team>/team.toml -> teams/<team>/compose.yml, plus the .env lines every member needs.
Deterministic and idempotent: the same team.toml always renders the same file; rendering twice changes nothing.
Secrets are minted only when blank and never overwritten. Standard library only (tomllib, Python 3.11+).
Usage: make team-render [T=<team>]      scripts/team-render.py [--team T] [--check] [--no-mint]
  --check    exit 1 if teams/<team>/compose.yml or .env would change (nothing written)
  --no-mint  do not mint missing keypairs (CI, dry runs)"""
import os, re, subprocess, sys, tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
ROLES = {   # role -> (Gitea team, session policy, forge account); the closed list of plan 10 (docs/spec.md §5.11)
    "builder":     ("builders",     "thread",  True),
    "reviewer":    ("reviewers",    "thread",  True),
    "coordinator": ("coordinators", "channel", True),
    "assistant":   (None,           "channel", False),
}
ROLE_WORD = {"builder": "builder", "reviewer": "reviewer", "coordinator": "coordinator and judge: scores every PR after CI and the review", "assistant": "assistant"}
IMAGES = {"buzz-agent": "ghcr.io/block/buzz-sprig:sha-e17cdd9", "goose": "open-llm-stack/goose-agent:1.50.0"}   # spec §1
BUZZ_IMAGE = "ghcr.io/block/buzz:sha-e17cdd9"   # its buzz-admin mints keypairs (same as scripts/init.sh)

args = sys.argv[1:]
check = "--check" in args; mint = "--no-mint" not in args
team = args[args.index("--team") + 1] if "--team" in args else None

def read_env():
    return open(".env").read() if os.path.exists(".env") else ""
env_text = read_env()
def env_get(k):
    m = re.search(rf"(?m)^{re.escape(k)}=(.*)$", env_text); return m.group(1).split("#", 1)[0].strip() if m else None
team = team or env_get("TEAM_NAME") or "piedpiper"
path = f"teams/{team}/team.toml"
if not os.path.exists(path): sys.exit(f"no {path}: make team-new T={team} FROM=<preset>")
t = tomllib.load(open(path, "rb"))

# --- validate ---------------------------------------------------------------------------------------------------
errs = []
if t.get("name") != team: errs.append(f"name = {t.get('name')!r} must equal the directory name {team!r}")
for k in ("org", "model", "ci_label"):
    if not t.get(k): errs.append(f"{k} is required")
members = t.get("members") or []
if not members: errs.append("at least one [[members]] entry")
seen = set()
for m in members:
    n = m.get("name", "")
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,30}", n): errs.append(f"member name {n!r}: lowercase letters, digits, dashes, 2-31 characters")
    if n in seen: errs.append(f"member {n!r} listed twice")
    seen.add(n)
    if m.get("role") not in ROLES: errs.append(f"member {n}: role {m.get('role')!r} not in {sorted(ROLES)}")
    if m.get("runtime", "buzz-agent") not in IMAGES: errs.append(f"member {n}: runtime {m.get('runtime')!r} not in {sorted(IMAGES)}")
    persona = f"teams/{team}/personas/{m.get('persona', n + '.md')}"
    if not os.path.exists(persona): errs.append(f"member {n}: persona file {persona} missing")
if errs: sys.exit("team.toml invalid:\n  " + "\n  ".join(errs))

# --- .env lines: keys minted when blank, the rest ensured present (bootstrap and litellm-keys fill them) ------------
def gen_key():
    out = subprocess.run(["docker", "run", "--rm", "--entrypoint", "/usr/local/bin/buzz-admin", BUZZ_IMAGE, "generate-key"], text=True, capture_output=True, check=True).stdout
    sec = re.search(r"Secret key:\s*(\S+)", out).group(1); pub = re.search(r"Public key:\s*(\S+)", out).group(1); return sec, pub
new_env = env_text; changes = []
def ensure(k, v=None, force=False):
    """Ensure `k=` exists; set it when blank and v is given, or always when force."""
    global new_env
    cur = re.search(rf"(?m)^{re.escape(k)}=(.*)$", new_env)
    if cur is None:
        new_env += ("" if new_env.endswith("\n") or not new_env else "\n") + f"{k}={v or ''}\n"; changes.append(f"added {k}")
    elif v is not None and (force or not cur.group(1).split('#', 1)[0].strip()):
        if cur.group(1).split("#", 1)[0].strip() != v:
            new_env = re.sub(rf"(?m)^{re.escape(k)}=.*$", f"{k}={v}", new_env); changes.append(f"set {k}")
ensure("TEAM_NAME", team, force=True)
ensure("TEAM_MODEL", t["model"], force=True)   # derived from team.toml: scripts that only read .env keep working
ensure("TEAM_GITEA_ORG", t["org"], force=True)
ensure("TEAM_CI_LABEL", t["ci_label"], force=True)
for m in members:
    M = m["name"].upper().replace("-", "_")
    if not env_get(f"TEAM_{M}_PRIVATE_KEY") and mint and not check:
        sec, pub = gen_key(); ensure(f"TEAM_{M}_PRIVATE_KEY", sec); ensure(f"TEAM_{M}_PUBKEY", pub)
    else:
        ensure(f"TEAM_{M}_PRIVATE_KEY"); ensure(f"TEAM_{M}_PUBKEY")
    if ROLES[m["role"]][2]: ensure(f"TEAM_{M}_GITEA_TOKEN")
    ensure(f"TEAM_{M}_LITELLM_KEY")

# --- compose ------------------------------------------------------------------------------------------------------
def display(m): return m.get("display") or m["name"].capitalize()
suffix = env_get("AGENT_LOGIN_SUFFIX") or ""
pubkeys = ",".join(f"${{TEAM_{m['name'].upper().replace('-', '_')}_PUBKEY:-}}" for m in members)
allow = "${TEAM_ALLOWLIST:-},${TEAM_SMOKE_PUBKEY:-}," + pubkeys
roster = ";".join(f"{m['name']}={m['role']}={display(m)}={m.get('title', ROLE_WORD[m['role']])}=${{TEAM_{m['name'].upper().replace('-', '_')}_PUBKEY:-}}" for m in members)
out = [f"# GENERATED by scripts/team-render.py from teams/{team}/team.toml. Do not edit: edit team.toml, then `make team-render`.",
       f"# One service per member, extending teams/_base.yml (the shared shape). Included by docker-compose.yml through TEAM_NAME.",
       "services:"]
for m in members:
    n = m["name"]; M = n.upper().replace("-", "_"); role = m["role"]; gteam, policy, forge = ROLES[role]
    runtime = m.get("runtime", "buzz-agent")
    out += [f"  {n}:",
            "    extends: { file: teams/_base.yml, service: agent-base }",
            "    profiles: [team]",
            f"    image: {IMAGES[runtime]}",
            "    volumes:",
            f"      - team-{n}:/home/agent",
            "    environment:",
            f"      TEAM_MEMBER: {n}",
            f"      TEAM_ROLE: {role}",
            f"      TEAM_RUNTIME: {runtime}",
            f"      BUZZ_ACP_DISPLAY_NAME: {display(m)}",
            f"      BUZZ_PRIVATE_KEY: ${{TEAM_{M}_PRIVATE_KEY:?run make team-render}}",
            f"      BUZZ_ACP_SESSION_POLICY: {policy}",
            f"      BUZZ_ACP_RESPOND_TO_ALLOWLIST: {allow}",
            f"      TEAM_ROSTER: \"{roster}\"",
            f"      OPENAI_COMPAT_MODEL: {m.get('model', t['model'])}",
            f"      OPENAI_COMPAT_API_KEY: ${{TEAM_{M}_LITELLM_KEY:-${{LITELLM_MASTER_KEY}}}}"]
    if forge:
        out += [f"      GITEA_USER: {n}{suffix}", f"      GITEA_TOKEN: ${{TEAM_{M}_GITEA_TOKEN:-}}"]
    if role == "coordinator":
        out += [f"      BUZZ_ACP_HEARTBEAT_INTERVAL: \"{int(m.get('heartbeat', 0))}\"",
                "      BUZZ_ACP_HEARTBEAT_PROMPT_FILE: /opt/team/agents/roles/coordinator-heartbeat.md"]
out += ["volumes:"] + [f"  team-{m['name']}:" for m in members]
compose = "\n".join(out) + "\n"
target = f"teams/{team}/compose.yml"
old = open(target).read() if os.path.exists(target) else None
if check:
    diff = (old != compose) or (new_env != env_text)
    print(f"{target}: {'differs' if old != compose else 'up to date'}; .env: {'would change' if new_env != env_text else 'up to date'}")
    sys.exit(1 if diff else 0)
if old != compose:
    open(target, "w").write(compose); print(f"rendered {target} ({len(members)} members)")
else: print(f"{target} unchanged")
if new_env != env_text:
    open(".env", "w").write(new_env); print(".env: " + ", ".join(changes))
else: print(".env unchanged")
```

Two lines differ from the scratch run: `ensure("TEAM_GITEA_ORG", …)` and `ensure("TEAM_CI_LABEL", …)` (so `.env` readers keep working); **verify at execution** that both stay derived and that `bootstrap-team.sh`'s `ORG` and the entrypoint's `TEAM_CI_LABEL` read the same values.

`scripts/team-roster.py` (exact; ran on the scratch project):

```python
#!/usr/bin/env python3
"""Read teams/<team>/team.toml for shell scripts (plan 16). Standard library only.
  team-roster.py [--team T] members            -> one line per member: name role display login ENV_PREFIX
  team-roster.py [--team T] role <role>        -> names of the members with that role, first one first
  team-roster.py [--team T] get <key>          -> a top-level value (org, model, ci_label, name)
  team-roster.py [--team T] humans             -> comma-separated pubkeys from `humans`
  team-roster.py [--team T] add <name> <role> [title]   -> append a [[members]] block (exit 1 if present)
  team-roster.py [--team T] rm <name>          -> remove that member's block (exit 1 if absent)
  team-roster.py [--team T] set <name> <key> <value>    -> set one member key (runtime, model, title, persona, display)
The team is --team, else TEAM_NAME in .env, else piedpiper. Logins carry AGENT_LOGIN_SUFFIX from .env.
Edits rewrite only the member's block; the rest of team.toml (comments included) is left byte for byte."""
import os, re, sys, tomllib
os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
args = sys.argv[1:]
team = args[args.index("--team") + 1] if "--team" in args else None
if "--team" in args: i = args.index("--team"); del args[i:i + 2]
env = open(".env").read() if os.path.exists(".env") else ""
def env_get(k):
    m = re.search(rf"(?m)^{re.escape(k)}=(.*)$", env); return m.group(1).split("#", 1)[0].strip() if m else ""
team = team or env_get("TEAM_NAME") or "piedpiper"
t = tomllib.load(open(f"teams/{team}/team.toml", "rb"))
suffix = env_get("AGENT_LOGIN_SUFFIX")
cmd = args[0] if args else "members"
if cmd == "members":
    for m in t["members"]:
        print(m["name"], m["role"], m.get("display") or m["name"].capitalize(), m["name"] + suffix, "TEAM_" + m["name"].upper().replace("-", "_"))
elif cmd == "role":
    print("\n".join(m["name"] for m in t["members"] if m["role"] == args[1]))
elif cmd == "get":
    print(t.get(args[1], ""))
elif cmd == "humans":
    print(",".join(t.get("humans", [])))
elif cmd in ("add", "rm", "set"):
    p = f"teams/{team}/team.toml"; s = open(p).read(); n = args[1]
    blk = re.search(rf'(?ms)^\[\[members\]\]\nname = "{re.escape(n)}"\n(?:(?!^\[\[members\]\]).)*', s)
    if cmd == "add":
        if blk: sys.exit(f"{n} is already a member")
        role = args[2]; title = f'title = "{args[3]}"\n' if len(args) > 3 else ""
        s = s.rstrip("\n") + f'\n\n[[members]]\nname = "{n}"\nrole = "{role}"\n{title}'
    elif cmd == "rm":
        if not blk: sys.exit(f"{n} is not a member")
        s = s[:blk.start()].rstrip("\n") + "\n" + s[blk.end():].lstrip("\n")
    else:
        if not blk: sys.exit(f"{n} is not a member")
        key, val = args[2], args[3]; b = blk.group(0).rstrip("\n")
        b = re.sub(rf'(?m)^{key} = .*\n?', '', b + "\n").rstrip("\n") + f'\n{key} = "{val}"\n'
        s = s[:blk.start()] + b + s[blk.end():].lstrip("\n") if s[blk.end():] else s[:blk.start()] + b
    open(p, "w").write(s.rstrip("\n") + "\n"); print(f"{cmd} {n}: ok")
else:
    sys.exit(__doc__)
```

Output verified: `dinesh builder Dinesh dinesh TEAM_DINESH` … ; with `AGENT_LOGIN_SUFFIX=-ai` the login column reads `dinesh-ai`; `role builder` → `dinesh`, `monica`; `get org` → `piedpiper`. Edits verified on the scratch team: `add bertram builder "backend builder"` appended the block, `set bertram runtime goose` added the key, `rm bertram` restored the file byte for byte, `rm nobody` exits 1. `set` writes every value as a TOML string (`heartbeat = "1800"`); the renderer casts `heartbeat` with `int()`, so this is fine for the keys `set` is meant for.

### Task 5 — the entrypoint reads role, persona and roster

`scripts/team-entrypoint.sh`: line 4 becomes `: "${TEAM_MEMBER:?}" "${TEAM_ROLE:?}" "${TEAM_NAME:?}" "${BUZZ_RELAY_URL:?}"`; line 6 and 7 print `$TEAM_MEMBER` and the token check becomes `[ "$TEAM_ROLE" = assistant ] || [ -n "${GITEA_TOKEN:-}" ] || …`; line 36 `"${GITEA_USER:-$TEAM_MEMBER}@localhost"`; line 65 `--about "open-llm-stack team agent (${TEAM_ROLE}), model …"`. Lines 50–51 become:

```bash
# Prompt = team norms + role duties + persona flavour + roster (base prompt is prepended by the harness itself). Plan 16.
# TEAM_ROSTER: name=role=Display=title=pubkey;… rendered by team-render.py from team.toml; the first member of each role fills the placeholders.
roster=""; REVIEWER_NAME=""; REVIEWER_PUBKEY=""; COORDINATOR_NAME=""; COORDINATOR_PUBKEY=""; BUILDER_NAME=""
while IFS='=' read -r n r d t p; do
  [ -n "$n" ] || continue
  roster+="- $d ($t)"$'\n'
  case "$r" in
    reviewer)    [ -n "$REVIEWER_NAME" ]    || { REVIEWER_NAME=$d;    REVIEWER_PUBKEY=$p; } ;;
    coordinator) [ -n "$COORDINATOR_NAME" ] || { COORDINATOR_NAME=$d; COORDINATOR_PUBKEY=$p; } ;;
    builder)     [ -n "$BUILDER_NAME" ]     || BUILDER_NAME=$d ;;
  esac
done <<<"${TEAM_ROSTER//;/$'\n'}"
roster_line=$(printf '%s' "$roster" | sed 's/^- //' | paste -sd ',' | sed 's/,/, /g')
{ cat /opt/team/agents/TEAM.md; echo; cat "/opt/team/agents/roles/${TEAM_ROLE}.md"; echo
  cat "/opt/team/teams/${TEAM_NAME}/personas/${TEAM_PERSONA:-$TEAM_MEMBER.md}"; } > "$HOME/.prompt.md"
sed -i "s|\$GITEA_URL|$GITEA_URL|g; s|\$GITEA_OWNER|$GITEA_OWNER|g; s|\$GITEA_ADMIN|${GITEA_ADMIN:-stackadmin}|g; s|\$GITEA_HUMAN|${GITEA_HUMAN:-richard}|g; s|\$TEAM_CI_LABEL|${TEAM_CI_LABEL:-python}|g; s|\$TEAM_ROSTER_LINE|$roster_line|g; s|\$REVIEWER_NAME|$REVIEWER_NAME|g; s|\$REVIEWER_PUBKEY|$REVIEWER_PUBKEY|g; s|\$COORDINATOR_NAME|$COORDINATOR_NAME|g; s|\$COORDINATOR_PUBKEY|$COORDINATOR_PUBKEY|g; s|\$BUILDER_NAME|$BUILDER_NAME|g" "$HOME/.prompt.md"   # non-secret values inlined: the shell tool cannot read env
```

The renderer adds `TEAM_PERSONA: <file>` to a member's environment only when `persona` is set in `team.toml` (**add this line to the renderer at execution**, inside the `out +=` block: `*( [f"      TEAM_PERSONA: {m['persona']}"] if m.get('persona') else [] )`). Verified in bash with the rendered roster: block, sentence and placeholders as in §3.

### Task 6 — bootstrap, keys, init, smoke and make read the roster

`scripts/init.sh`: replace the `for who in DINESH … MONICA SMOKE` loop (`:37-43`) by the SMOKE keypair alone plus `python3 scripts/team-render.py` (renders the team named by `TEAM_NAME`, minting member keys; on a fresh checkout `teams/piedpiper/compose.yml` is already committed, so the run prints `unchanged` for the file and `added`/`set` for `.env`).

`scripts/bootstrap-team.sh`: replace the member loop (`:33-41`) and the three `ensure_team` calls (`:63-65`) by:

```bash
# Members from the team file (plan 16): login = name + AGENT_LOGIN_SUFFIX; forge accounts for every role but assistant.
ROSTER=$(python3 scripts/team-roster.py members)
is_agent() {   # is_agent <login>: an existing user is ours when its stored email is <login>@agents.invalid (admin listing shows stored emails)
  api "$B/admin/users?limit=200" | jq -e --arg u "$1" '.[] | select(.login==$u) | select(.email|endswith("@agents.invalid"))' >/dev/null; }
while read -r name role display login prefix; do
  [ "$role" = assistant ] && continue
  if [ "$(code -H "$A" "$B/users/$login")" = 200 ] && ! is_agent "$login"; then
    echo "login '$login' exists and is not an agent (a person?). Set AGENT_LOGIN_SUFFIX=-ai in .env, make team-render, then rerun." >&2; exit 1
  fi
  ensure_user "$login" "$TEAM_GITEA_PASSWORD"
  api -o /dev/null -X PATCH -d "{\"login_name\":\"$login\",\"source_id\":0,\"full_name\":\"$display (AI $role)\"}" "$B/admin/users/$login" && echo "full_name: $display (AI $role)"
  var="${prefix}_GITEA_TOKEN"
  if blank "$var" || ! has_org_scope "${!var}"; then
    tok=$(curl -fsS -u "$login:$TEAM_GITEA_PASSWORD" -H 'Content-Type: application/json' -d "{\"name\":\"team-$(date +%s%N)-$$\",\"scopes\":$SCOPES}" "$B/users/$login/tokens" | jq -r .sha1)
    [ ${#tok} -ge 20 ] || { echo "token minting for $login failed (wrong TEAM_GITEA_PASSWORD? mint one in the Gitea UI and paste it as $var)" >&2; exit 1; }
    setenv "$var" "$tok"; echo "$var written"
  fi
done <<<"$ROSTER"
…
logins() { awk -v r="$1" '$2==r {print $4}' <<<"$ROSTER" | paste -sd ' '; }
ensure_team builders     true  '{"repo.code":"write","repo.pulls":"write","repo.issues":"write","repo.actions":"read","repo.releases":"read"}' $(logins builder)
ensure_team reviewers    false '{"repo.code":"read","repo.pulls":"write","repo.issues":"write","repo.actions":"read"}' $(logins reviewer)
ensure_team coordinators false '{"repo.code":"read","repo.pulls":"write","repo.issues":"write","repo.actions":"read"}' $(logins coordinator)   # pulls write: plan 13
```

`EditUserOption` requires `login_name` and `source_id` alongside `full_name` in Gitea 1.27 (**verify at execution**; if the PATCH returns 422 without them, they are required; if it returns 422 with them, drop them). The approvals whitelist (plan 13) lists `$(logins reviewer)` instead of `gilfoyle`. The score labels and the fixture repository are unchanged. `ORG` stays `${TEAM_GITEA_ORG}` (written by the renderer from `team.toml`).

`scripts/litellm-keys.sh` (new; `make litellm-keys`; `bootstrap-team.sh` calls it after the Gitea tokens, LiteLLM is up whenever the team is bootstrapped):

```bash
#!/usr/bin/env bash
# One LiteLLM team per agent team and one virtual key per client, by alias, into .env (plan 16). Members come from the
# roster; Open WebUI and the Buzz agent are the two non-team clients. Idempotent: a blank variable is minted; a set
# variable whose alias no longer exists in LiteLLM (fresh database) is re-minted. The team (team_alias = the org) puts
# user_api_key_team_alias on every spend row; plan 15's cost-report groups by the aliases. The master key stays for the operator.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
base="${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}"; auth="Authorization: Bearer ${LITELLM_MASTER_KEY}"
setenv() { grep -qE "^$1=" .env && sed -i "s|^$1=.*|$1=$2|" .env || echo "$1=$2" >> .env; }
team_alias="${TEAM_GITEA_ORG:-piedpiper}"
tid=$(curl -fsS -H "$auth" "$base/team/list" | jq -r --arg a "$team_alias" '.[] | select(.team_alias==$a) | .team_id' | head -1)   # host jq, no pipefail here
[ -n "$tid" ] || { tid=$(curl -fsS -X POST "$base/team/new" -H "$auth" -H 'Content-Type: application/json' -d "{\"team_alias\":\"$team_alias\"}" | jq -r .team_id); echo "litellm team $team_alias created ($tid)"; }
mint() {   # mint <alias> <ENV_VAR> [team_id]
  local alias=$1 var=$2 cur; cur=$(grep -E "^$var=" .env | cut -d= -f2- | sed 's/[[:space:]]*#.*//')
  if [ -n "$cur" ] && [ "$(curl -fsS -H "$auth" "$base/key/list?key_alias=$alias&return_full_object=true" | jq -r '.total_count')" != 0 ]; then echo "$alias: key present"; return; fi
  local key; key=$(curl -fsS -X POST "$base/key/generate" -H "$auth" -H 'Content-Type: application/json' \
    -d "{\"key_alias\":\"$alias\"${3:+,\"team_id\":\"$3\"},\"metadata\":{\"client\":\"$alias\",\"minted_by\":\"litellm-keys.sh\"}}" | jq -r .key)
  setenv "$var" "$key" && echo "$alias: key minted into $var${3:+ (team $team_alias)}"
}
python3 scripts/team-roster.py members | while read -r name role display login prefix; do mint "$name" "${prefix}_LITELLM_KEY" "$tid"; done
mint buzz-agent BUZZ_AGENT_LITELLM_KEY
mint open-webui OPENWEBUI_LITELLM_KEY
echo "apply: docker compose up -d --force-recreate $(python3 scripts/team-roster.py members | cut -d' ' -f1 | paste -sd ' ') buzz-agent open-webui   (each client re-reads its key)"
```

`docker-compose.yml`: the Buzz agent gets `OPENAI_COMPAT_API_KEY: ${BUZZ_AGENT_LITELLM_KEY:-${LITELLM_MASTER_KEY:?run make init}}`, Open WebUI `OPENAI_API_KEY: ${OPENWEBUI_LITELLM_KEY:-${LITELLM_MASTER_KEY}}`; the rendered team file already carries `${TEAM_<M>_LITELLM_KEY:-${LITELLM_MASTER_KEY}}` per member (Task 4). `.env.example`, next to the Gitea tokens: `BUZZ_AGENT_LITELLM_KEY=` and `OPENWEBUI_LITELLM_KEY=` with the comment `# LiteLLM virtual keys, one per client, so spend is attributed (make litellm-keys; team-bootstrap runs it). Blank = master key.`; member keys are ensured by the renderer. The fallback keeps `make init && make up && make test` working before any key is minted; G37 proves the keys are used once minted. **Verify at execution** that `team-roster.py members` prints `name role display login prefix` in that order (Task 4 defines it) and that the entrypoint needs no change (`/model/info` and `/v1/models` answer to a virtual key, §3).

`scripts/team-smoke.sh`: at the top, after `.env`:

```bash
BUILDER=$(python3 scripts/team-roster.py role builder | head -1); REVIEWER=$(python3 scripts/team-roster.py role reviewer | head -1); COORD=$(python3 scripts/team-roster.py role coordinator | head -1)
read -r _ _ BUILDER_NAME BUILDER_LOGIN BP <<<"$(python3 scripts/team-roster.py members | awk -v n="$BUILDER" '$1==n')"
read -r _ _ REVIEWER_NAME REVIEWER_LOGIN RP <<<"$(python3 scripts/team-roster.py members | awk -v n="$REVIEWER" '$1==n')"
read -r _ _ COORD_NAME _ CP <<<"$(python3 scripts/team-roster.py members | awk -v n="$COORD" '$1==n')"
BUILDER_PUB=${!BP}_PUBKEY; BUILDER_PUB=${!BUILDER_PUB}   # two-step indirection: prefix -> variable name -> value
```

then every `dinesh` → `$BUILDER` (services) / `$BUILDER_LOGIN` (`user.login`) / `$BUILDER_NAME` (`@Dinesh` in bodies and `startswith("@Dinesh")`), `$TEAM_DINESH_PUBKEY` → `$BUILDER_PUB`, and the same for the reviewer and the coordinator (`@Jared score` → `@$COORD_NAME score`). Write the indirection as a small function `pub() { local v="$1_PUBKEY"; printf '%s' "${!v}"; }` and use `$(pub "$BP")`; **verify at execution** with `bash -n` and one dry read before the smoke runs. `scripts/smoke-test.sh`: `docker compose exec -T dinesh` → `$(python3 scripts/team-roster.py role builder | head -1)`, `jared` → the coordinator; `test_team_runtime` reads the runtime from the roster (`python3 - <<'EOF' … tomllib … EOF` printing the builder's `runtime`, default `buzz-agent`) instead of `TEAM_DINESH_RUNTIME`.

`Makefile` (replace `team-model` and `dinesh-runtime`; add the rest; extend `.PHONY`):

```make
MEMBERS = $(shell python3 scripts/team-roster.py members 2>/dev/null | cut -d' ' -f1)

team-render:     ## render teams/$(TEAM_NAME)/compose.yml from team.toml and mint missing member keys (plan 16): make team-render [T=<team>]
	python3 scripts/team-render.py $(if $(T),--team $(T),)

litellm-keys:    ## mint one LiteLLM virtual key per member, Open WebUI and the Buzz agent into .env (plan 16; team-bootstrap runs it)
	./scripts/litellm-keys.sh

team-status:     ## members, roles, runtimes, container state (plan 16)
	@python3 scripts/team-roster.py members | while read -r n r d l p; do printf '%-10s %-12s %-10s %s\n' "$$n" "$$r" "$$l" "$$(docker compose ps --format '{{.Status}}' $$n 2>/dev/null | head -1)"; done

team-model:      ## switch the team's model: make team-model M=qwen3.8-max (edits team.toml, re-renders, recreates the members)
	@test -n "$(M)" || { echo "usage: make team-model M=<model_name from proxy/config.yaml>"; exit 1; }
	@set -a; . ./.env; set +a; curl -fsS -H "Authorization: Bearer $$LITELLM_MASTER_KEY" "$${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}/v1/models" | jq -e --arg m "$(M)" '.data[] | select(.id==$$m)' >/dev/null || { echo "$(M) is not registered in proxy/config.yaml"; exit 1; }
	@set -a; . ./.env; set +a; sed -i 's|^model = .*|model = "$(M)"|' teams/$${TEAM_NAME:-piedpiper}/team.toml
	python3 scripts/team-render.py
	docker compose up -d --force-recreate $(MEMBERS)
	@echo "team now on $(M); each agent re-reads its context window from the registry on start"

member-runtime:  ## switch one member's runtime: make member-runtime N=dinesh R=goose|buzz-agent (plan 12 knob, per member)
	@test -n "$(N)" && test -n "$(R)" || { echo "usage: make member-runtime N=<member> R=goose|buzz-agent"; exit 1; }
	python3 scripts/team-roster.py set $(N) runtime $(R)
	python3 scripts/team-render.py && docker compose up -d --force-recreate --wait $(N) && docker compose logs --since 1m --no-log-prefix $(N) | grep -E 'runtime=|agent initialized|presence set' | cut -c1-120
dinesh-runtime:  ## kept for plan 12's gates: make dinesh-runtime R=goose|buzz-agent
	$(MAKE) member-runtime N=dinesh R=$(R)

member-add:      ## add a member: make member-add N=<name> R=builder|reviewer|coordinator|assistant [TITLE="…"] (plan 16)
	@test -n "$(N)" && test -n "$(R)" || { echo "usage: make member-add N=<name> R=<role> [TITLE=\"…\"]"; exit 1; }
	python3 scripts/team-roster.py add $(N) $(R) $(if $(TITLE),"$(TITLE)",)
	@set -a; . ./.env; set +a; t=teams/$${TEAM_NAME:-piedpiper}; [ -f $$t/personas/$(N).md ] || printf 'You are %s, the %s. (Edit this persona: voice, specialities, what you never do.)\n' "$$(python3 -c 'print("$(N)".capitalize())')" "$(R)" > $$t/personas/$(N).md
	python3 scripts/team-render.py
	./scripts/bootstrap-team.sh      # idempotent: creates the forge user, token and team membership for the new member, keys for LiteLLM
	docker compose up -d --force-recreate --wait $(N) && docker compose logs --since 1m --no-log-prefix $(N) | grep -E 'model=|presence set' | cut -c1-120
	@echo "$(N) is on the team: add its pubkey to your project channels (buzz channels add-member --pubkey \$$TEAM_$$(echo $(N) | tr a-z- A-Z_)_PUBKEY --role bot)"

member-rm:       ## remove a member's service and forge membership; keys stay in .env (PURGE=1 also deletes the forge user and the volume)
	@test -n "$(N)" || { echo "usage: make member-rm N=<name> [PURGE=1]"; exit 1; }
	-docker compose rm -sf $(N)
	python3 scripts/team-roster.py rm $(N)
	python3 scripts/team-render.py
	@set -a; . ./.env; set +a; B="$${GITEA_PUBLIC_URL%/}/api/v1"; A="Authorization: token $$GITEA_ADMIN_TOKEN"; login="$(N)$${AGENT_LOGIN_SUFFIX:-}"; \
	for tm in builders reviewers coordinators; do tid=$$(curl -fsS -H "$$A" "$$B/orgs/$${TEAM_GITEA_ORG:-piedpiper}/teams" | jq -r --arg n $$tm '.[]|select(.name==$$n)|.id'); [ -n "$$tid" ] && curl -sS -o /dev/null -X DELETE -H "$$A" "$$B/teams/$$tid/members/$$login"; done; \
	if [ "$(PURGE)" = 1 ]; then curl -sS -o /dev/null -X DELETE -H "$$A" "$$B/admin/users/$$login?purge=true" && echo "forge user $$login purged"; docker volume rm -f open-llm-stack_team-$(N) >/dev/null && echo "volume removed"; fi
	@echo "$(N) removed; TEAM_$$(echo $(N) | tr a-z- A-Z_)_* stay in .env$(if $(PURGE),, (PURGE=1 deletes the forge user and the volume))"

team-new:        ## start a team from a preset in a fresh deployment: make team-new T=<name> FROM=dev-squad|solo-builder|review-board|content-studio
	@test -n "$(T)" && test -n "$(FROM)" || { echo "usage: make team-new T=<team> FROM=<preset>"; exit 1; }
	@test ! -d teams/$(T) || { echo "teams/$(T) exists"; exit 1; }
	mkdir -p teams/$(T)/personas && sed 's|^name = .*|name = "$(T)"|; s|^org = .*|org = "$(T)"|' teams/_presets/$(FROM).toml > teams/$(T)/team.toml
	@for n in $$(python3 scripts/team-roster.py --team $(T) members | cut -d' ' -f1); do cp -n teams/_presets/personas/$$n.md teams/$(T)/personas/$$n.md 2>/dev/null || printf 'You are %s.\n' "$$n" > teams/$(T)/personas/$$n.md; done
	sed -i 's|^TEAM_NAME=.*|TEAM_NAME=$(T)|' .env; grep -q '^TEAM_NAME=' .env || echo 'TEAM_NAME=$(T)' >> .env
	python3 scripts/team-render.py --team $(T)
	@echo "team $(T) rendered from $(FROM): edit teams/$(T)/team.toml and personas, then make up && make team-bootstrap"
```

`make member-add` on the default team is what G42 runs; `make team-new` switches the deployment's team (v1: one team; the previous team's files stay in `teams/`).

### Task 7 — presets

`teams/_presets/dev-squad.toml` is `teams/piedpiper/team.toml` with `name`/`org` placeholders `"TEAM"` (rewritten by `team-new`) and `humans = []`. `solo-builder.toml`: one builder `ada` and one coordinator `grace` (the coordinator briefs and scores; reviews come from the humans, so `required_approvals` is met by a person). `review-board.toml`: reviewers `linus` and `margaret`, coordinator `grace`, no builder (a team that reviews human PRs; the smoke does not apply, documented). `content-studio.toml`: builder `ada` titled "writer", reviewer `edsger` titled "editor", builder `barbara` titled "designer", coordinator `grace`. Preset persona stubs in `teams/_presets/personas/<name>.md` (one line each: "You are Ada, the writer …"). Presets carry distinct name pools so a second workforce on the same forge never collides with `piedpiper`'s logins. **Verify at execution** that each preset renders (`make team-new` in a scratch checkout) and that `docker compose config` validates.

### Task 8 — `.env.example`, docs

`.env.example`: under the team block add `TEAM_NAME=piedpiper    # the team in teams/<name>/ (plan 16); make team-new switches it` and `AGENT_LOGIN_SUFFIX=    # blank: agent logins are the persona names; -ai when your forge already has people with those logins`; remove `TEAM_DINESH_RUNTIME` and `TEAM_DINESH_IMAGE` (runtime is per member in `team.toml`); keep the five members' key/token lines as the default team's sample and note that `make team-render` appends lines for new members. Docs: `docs/spec.md` §2 layout (`teams/`), §3 rows, §5.8 (services now rendered), new §5.17 "Teams as data (plan 16)" (the file, the roles, the renderer, the Compose facts from §3, naming rules, `full_name`, `AGENT_LOGIN_SUFFIX`, the allow-list of intentional differences), §7 gates G40–G44; `README.md`: "The agent team" gains "Adding a member" (`make member-add`, persona, channel membership), "Your own team" (`make team-new`, presets), the naming rule, and the runtime switch per member; make-targets table; `AGENTS.md`: layout line, status line, and one non-negotiable: "Members exist only in `teams/<team>/team.toml`; `teams/<team>/compose.yml` is generated (`make team-render`) and never edited; scripts find agents by role through `scripts/team-roster.py`, never by name; roles are the closed list in `agents/roles/` mapped to forge teams (spec §5.17)."

## 5. Considerations

- **One team per deployment.** `TEAM_NAME` selects the included file; a second team is a second deployment. Two teams in one stack would need per-team channels, per-team `humans` and six slots on the GPU (plan 14); not designed here.
- **Names are the identity.** Service, volume, forge login and `.env` prefix all derive from `name`; renaming a member is remove + add (new keys, new forge user). Presets carry distinct name pools for that reason.
- **`profiles: [never, team]`** on every member is a Compose merge artefact of `extends`; harmless (a service starts when any listed profile is active). Recorded in G40's allow-list rather than worked around.
- **The committed rendered file** is portable because it references `${TEAM_<M>_PUBKEY:-}` and `${TEAM_<M>_*_KEY}` rather than values; `make init` re-renders when `team.toml` is newer, so a checkout with an edited team file never runs stale.
- **Roles are the tested unit.** Gates G22, G26, G27 test the role files' commands and labels; a persona cannot break a gate unless it contradicts the role, which is the operator's judgement, visible in the PR scores per member (plan 13).
- **Forge login refusal** depends on the admin user listing exposing stored emails (§3, verify at execution). The `description` fallback keeps the rule enforceable on any Gitea.
- **`TEAM_ROLE` changed meaning** (member name → role). Every consumer is listed in §3 and updated in §4; the one external consumer, `docker logs` greps in the READMEs for `model=…`, is unaffected.
- **Keys are least privilege too.** Per-client keys let the operator cap a client's budget (`max_budget` on `/key/generate`) and revoke one client without rotating the master key. Not gated; documented. Before `make litellm-keys` runs, every fallback points at the master key, which still works.

## 6. Testing strategy

Render first, without touching the running stack: `make team-render` then the G40 config diff (scratch copy of the live project as in §3, both configs through `docker compose config --format json`, the allow-list check). Then cut over: `docker compose up -d --remove-orphans --force-recreate <members>` (same service names, same volumes, so the agents keep their clones and logs), `make team-bootstrap` (adds `full_name`, refuses nothing on the default team), and G41 as `make test` (exit 0) plus `make team-smoke` twice. G42 on the fixture team with `bertram`, then `member-rm`. G43 and G44 in a scratch checkout (`git worktree add`) against the same forge with a new org name so the default team is untouched; the scratch team is bootstrapped and removed (`PURGE=1`) afterwards. Numbers into §8.

## 7. Validation commands

```bash
# G40 render, idempotency, config diff against the pre-plan stack (run BEFORE cutting over; keep a copy of the old compose)
cp docker-compose.yml /tmp/compose.before.yml; make team-render; make team-render | grep -c unchanged   # 2
python3 scripts/team-render.py --check; echo "check exit $?"                                             # 0
docker compose -f /tmp/compose.before.yml config --format json > /tmp/before.json; docker compose config --format json > /tmp/after.json
python3 - <<'EOF'
import json; a=json.load(open("/tmp/before.json")); b=json.load(open("/tmp/after.json"))
allow={"env.TEAM_MEMBER","env.TEAM_NAME","env.TEAM_ROSTER","env.TEAM_ROLE","env.GILFOYLE_PUBKEY","env.JARED_PUBKEY","env.BUZZ_ACP_HEARTBEAT_PROMPT_FILE","profiles","volumes:/opt/team/teams"}
bad=set(); assert sorted(a["services"])==sorted(b["services"]) and sorted(a["volumes"])==sorted(b["volumes"])
for s in ["dinesh","gilfoyle","jared","erlich","monica"]:
    x,y=a["services"][s],b["services"][s]
    for k in set(x)|set(y):
        if k=="environment":
            for e in set(x[k])|set(y[k]):
                if x[k].get(e)!=y[k].get(e) and f"env.{e}" not in allow: bad.add(f"{s}.env.{e}")
        elif k=="volumes":
            for t in {v['target'] for v in y[k]}^{v['target'] for v in x[k]}:
                if f"volumes:{t}" not in allow: bad.add(f"{s}.volumes.{t}")
        elif x.get(k)!=y.get(k) and k not in allow: bad.add(f"{s}.{k}")
print("unexpected differences:", sorted(bad) or "none")
EOF

# G41 cut-over and every gate
docker compose up -d --remove-orphans --force-recreate dinesh gilfoyle jared erlich monica && make team-bootstrap && make test   # exit 0
docker compose exec -T dinesh sh -c 'grep -c "Teammates: Dinesh (builder)" ~/.prompt.md; grep -c "\$REVIEWER" ~/.prompt.md'  # 1, 0 (placeholders inlined)
make team-smoke && make team-smoke

# G37 per-member LiteLLM keys (gate number kept from plan 15, where the keys were first specified)
make litellm-keys && docker compose up -d --force-recreate $(python3 scripts/team-roster.py members | cut -d' ' -f1 | paste -sd ' ') buzz-agent open-webui
docker compose exec -T dinesh sh -c 'env | grep -c "OPENAI_COMPAT_API_KEY=$LITELLM_MASTER_KEY"'   # 0
make team-smoke; docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "select metadata->>'user_api_key_alias', metadata->>'user_api_key_team_alias', count(*) from \"LiteLLM_SpendLogs\" where \"startTime\" > now()-interval '10 minutes' group by 1,2"   # dinesh, gilfoyle, jared rows, team piedpiper
make cost-report SINCE="10 minutes" | sed -n '/per client/,/^$/p'   # one line per member alias (plan 15 executed)

# G42 sixth member
make member-add N=bertram R=builder TITLE="backend builder"; make team-status
# a job thread mentioning @Bertram (smoke identity, as in team-smoke.sh) -> "picked up" reply, PR by bertram
curl -fsS -H "Authorization: token $TEAM_JARED_GITEA_TOKEN" "$GITEA_PUBLIC_URL/api/v1/users/bertram" | jq -r .full_name       # Bertram (AI builder)
make member-rm N=bertram PURGE=1; docker compose ps bertram | grep -c bertram                                                  # 0

# G43 presets, suffix, refusal (scratch worktree, new org)
git worktree add /tmp/t16 && cd /tmp/t16 && cp ../../.env .env && make team-new T=acme FROM=dev-squad && docker compose config --quiet && echo "renders"
# refusal: a person holds "ada" -> bootstrap exits 1 with the AGENT_LOGIN_SUFFIX message; then AGENT_LOGIN_SUFFIX=-ai -> ada-ai created with full_name "Ada (AI builder)"

# G44 builder not named dinesh
# in the scratch team: make up (team profile), make team-bootstrap, make team-smoke -> TEAM SMOKE PASS with a PR by ada
```

## 8. Execution report

(to be written at execution: the G40 allow-list check output, the cut-over log, `make test` summary, the sixth-member thread, the refusal message and the `-ai` login, the scratch team smoke, and every deviation from the tasks above with its reason)
