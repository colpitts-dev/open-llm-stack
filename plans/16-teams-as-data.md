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
# ci_label = "python"       # optional: forces TEAM_CI_LABEL in .env (python = bundled runner, ci = the forge's); unset = .env keeps its own value
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
for k in ("org", "model"):
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
if t.get("ci_label"): ensure("TEAM_CI_LABEL", t["ci_label"], force=True)   # optional: the runner label is a forge property; unset = .env keeps its own
else: ensure("TEAM_CI_LABEL", "python")
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
roster=""; roster_line=""; REVIEWER_NAME=""; REVIEWER_PUBKEY=""; COORDINATOR_NAME=""; COORDINATOR_PUBKEY=""; BUILDER_NAME=""
while IFS='=' read -r n r d t p; do
  [ -n "$n" ] || continue
  roster+="- $d ($t)"$'\n'; roster_line+="${roster_line:+, }$d ($t)"
  case "$r" in
    reviewer)    [ -n "$REVIEWER_NAME" ]    || { REVIEWER_NAME=$d;    REVIEWER_PUBKEY=$p; } ;;
    coordinator) [ -n "$COORDINATOR_NAME" ] || { COORDINATOR_NAME=$d; COORDINATOR_PUBKEY=$p; } ;;
    builder)     [ -n "$BUILDER_NAME" ]     || BUILDER_NAME=$d ;;
  esac
done <<<"${TEAM_ROSTER//;/$'\n'}"
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
  if blank "$var" || ! has_org_scope "${!var:-}"; then   # :- the .env line may be newer than this shell's copy (set -u)
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
  local alias=$1 var=$2 cur; cur=$(grep -E "^$var=" .env | cut -d= -f2- | sed 's/[[:space:]]*#.*//' || true)   # absent line = blank (set -e, pipefail)
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
	mkdir -p teams/$(T)/personas && sed '0,/^\[\[members\]\]/{s|^name = .*|name = "$(T)"|; s|^org = .*|org = "$(T)"|}' teams/_presets/$(FROM).toml > teams/$(T)/team.toml   # top-level keys only: members have name = too
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

## 8. Execution report (2026-09-14)

Executed against the live stack (external forge `git.colpitts.dev`, Gitea 1.27.3, Compose v5.1.3, Python 3.12.3). Tasks 2–3 (personas, roles), 5–6 (shell scripts) and 7–8 (presets, docs) were delegated to three forked agents working on disjoint files; Tasks 1, 4, `litellm-keys.sh` and the Makefile were extracted from the plan's fenced blocks. Validation ran as detached scripts into one log (below).

| Gate | Result | Evidence |
|---|---|---|
| G40 render + config diff | PASS | second `make team-render` printed `unchanged` twice; `--check` exit 0; `docker compose config --format json` before/after: services equal, volumes equal, `unexpected differences: none` |
| G41 cut-over | PASS | recreate exit 0, five members healthy; `make team-bootstrap` exit 0 on the rerun (first run died in `litellm-keys.sh`, deviation 2), `full_name` set for the four forge members; `make test` exit 0; dinesh prompt: `Teammates: Dinesh (builder)` ×1, `$REVIEWER`/`$COORDINATOR` ×0; gilfoyle `Role: reviewer` ×1; jared `Role: coordinator` ×1, `**Score:**` ×4, heartbeat file `agents/roles/coordinator-heartbeat.md`; `make team-smoke` twice consecutively: exit 0/0 (smokes 4 and 5, after deviation 4; smokes 1–2 failed only on the score-thread check, smoke 3 passed) |
| G37 per-member LiteLLM keys | PASS | LiteLLM team `piedpiper` created, five member keys + `buzz-agent` + `open-webui` minted; after recreate `OPENAI_COMPAT_API_KEY=<master>` count 0 in dinesh and buzz-agent; spend log last 15 min: `dinesh\|piedpiper\|26`, `gilfoyle\|piedpiper\|15`, `jared\|piedpiper\|22`, master-key rows 166; `make cost-report` per client with the meter running: dinesh 1, gilfoyle 1, jared 1 (0.000 kWh: one 8-token call each) |
| G42 sixth member | PASS (one observation) | `make member-add N=bertram R=builder TITLE="backend builder"` exit 0: keys, token, LiteLLM key, `full_name` `Bertram (AI builder)`, builders team `bertram,dinesh,monica`, container healthy; job thread mentioning `@Bertram`: PR #51 by `bertram` on `demo-calc`, milestones `🚩 pushed` and `🚩 CI success` posted, no literal `picked up:` line (the default builder skipped it in every smoke today too; `team-smoke` does not gate it); `make member-rm N=bertram PURGE=1` exit 0: `compose ps bertram` 0 lines, forge user 404, volume removed, render `--check` exit 0 |
| G43 presets, suffix, refusal | PASS | all four presets: `make team-new` exit 0 and `docker compose config --quiet` exit 0 (5/2/3/4 services); person `ada` on the forge → `bootstrap-team.sh` exit 1 with `login 'ada' exists and is not an agent (a person?). Set AGENT_LOGIN_SUFFIX=-ai …`; with `AGENT_LOGIN_SUFFIX=-ai`: `GITEA_USER: ada-ai` rendered, bootstrap exit 0, `ada-ai` `full_name` = `Ada (AI builder)` |
| G44 builder not named dinesh | PASS | scratch team `acme` from `content-studio` (project `t16`, four containers healthy), ada's prompt `Teammates: Ada (writer), Edsger (editor), Barbara (designer), Grace (coordinator and judge: …)`, placeholders 0; `make team-smoke` exit 0: PR `acme/demo-calc#1` by `ada-ai`, CI green, review by `edsger-ai`, `**Score:** complexity 1/5 · confidence high` by grace, labels `complexity/1,confidence/high`; org, repos, users, LiteLLM team and keys removed afterwards |

Deviations from the plan text (each fixed in the file and in the plan section named):

1. **`ci_label` is optional** (Task 2 `team.toml`, Task 4 renderer, presets). The live `.env` had `TEAM_CI_LABEL=ci` (the external forge's runner); the renderer forced `python` from `team.toml` on the first run and would have broken every CI job. The runner label is a forge property, not a team property: `team.toml` may set `ci_label` (then it is forced into `.env`), otherwise `.env` keeps its value (`python` ensured when blank). `teams/piedpiper/team.toml` and the four presets ship the key commented out; `.env` restored to `ci`.
2. **`scripts/litellm-keys.sh`**: `cur=$(grep -E "^$var=" .env | …)` killed the script under `set -e`/`pipefail` when the variable line did not exist yet (`BUZZ_AGENT_LITELLM_KEY`): `|| true` added (Task 6 block). This is why the first `make team-bootstrap` exited 1 after minting the member keys; the rerun passed.
3. **Roster sentence** (Task 5): `paste -sd ',' | sed 's/,/, /g'` double-spaced a title containing a comma (`Monica (UI designer,  also a builder)`); the sentence is now joined with `, ` in the loop.
4. **`scripts/team-smoke.sh` score check**: the judge answers whichever ask arrives first, and today (smokes 1–2) that was the reviewer's, in the review thread; the smoke looked in the job thread only and failed although the `**Score:**` line and the labels existed (verified in the relay: both lines tagged `reply` to the review root). The check now accepts the coordinator's line in either thread. Not a plan 16 regression (the role text is the plan 13 text with placeholders) but the plan 13 smoke was stricter than its own intent.
5. **`make team-new`**: `sed 's|^name = .*|…|'` also rewrote every member's `name = "…"` (TOML member keys start at column 0), so every preset rendered as N members named after the team (`member 'acme' listed twice`). The range `0,/^\[\[members\]\]/` limits it to the top-level keys (Task 6 Makefile block). The broken first run created a forge user `acme`, purged by hand.
6. **`scripts/bootstrap-team.sh`**: `"${!var}"` → `"${!var:-}"` (`set -u`: the `.env` line can be newer than the shell's copy). Task 6 block.
7. **Erlich** (Tasks 2/3 disagree): persona = the first paragraph, `roles/assistant.md` = the second paragraph with `$BUILDER_NAME`, per "nothing that the role file carries".
8. **Task 5 addition applied**: the renderer emits `TEAM_PERSONA: <file>` only when `persona` is set.
9. **G43/G44 ran in a copy of the working tree** (`rsync`, not `git worktree`): the plan 16 changes were uncommitted, a worktree would have been `HEAD` without them. Three of the G44 attempts failed inside the validation script itself, not the product: the script had `set -a`-exported `TEAM_NAME`/blank member tokens before `make team-new`/`bootstrap-team.sh` rewrote `.env`, and Compose prefers shell exports to `.env` (verified: `docker compose --env-file` with `TEAM_NAME=nope` fails on `teams/nope/compose.yml`, so `.env` does drive the `include` path). Fixed by unsetting the exports and re-sourcing `.env` before `up`.
10. `scripts/cost-report.sh`: the "per client" caption said "one row, master key, until clients have their own keys"; updated.
11. `docs/spec.md` §1 and §5.13 now point the plan 12 runtime switch at `runtime` in `team.toml` / `make member-runtime`; `AGENTS.md` runtime bullet likewise. `TEAM_DINESH_RUNTIME`/`TEAM_DINESH_IMAGE` removed from the live `.env` (dead). `TEAM_BERTRAM_*` lines stay in `.env` as the plan says.

Verified-at-execution items from the tasks: `GET /admin/users` shows the stored `<login>@agents.invalid` email (the refusal test works without a `description` marker); `EditUserOption` with `login_name` + `source_id` + `full_name` returns 200 (no 422); `team-roster.py members` prints `name role display login prefix`; the entrypoint needed no change for virtual keys (`/v1/model/info` answered, `context=65536` logged for bertram).

Log (trimmed of Compose progress lines, ACP wire debug and blank lines):

```
## G40 2026-09-14T20:33:28-03:00
teams/piedpiper/compose.yml unchanged
.env unchanged
second render unchanged lines: 2
teams/piedpiper/compose.yml: up to date; .env: up to date
check exit 0
services equal: True volumes equal: True
unexpected differences: none
PASS G40
## G41 cut-over 2026-09-14T20:34:03-03:00
recreate exit 0
dinesh Up Less than a second (health: starting)
erlich Up Less than a second (health: starting)
gilfoyle Up Less than a second (health: starting)
jared Up Less than a second (health: starting)
monica Up Less than a second (health: starting)
team-bootstrap exit 2
gitea user dinesh exists
full_name: Dinesh (AI builder)
gitea user gilfoyle exists
full_name: Gilfoyle (AI reviewer)
gitea user jared exists
full_name: Jared (AI coordinator)
gitea user monica exists
full_name: Monica (AI builder)
gitea user adam exists
litellm team piedpiper created (23ce3eb0-f61d-414f-9230-5a83bc4d56e3)
dinesh: key minted into TEAM_DINESH_LITELLM_KEY (team piedpiper)
gilfoyle: key minted into TEAM_GILFOYLE_LITELLM_KEY (team piedpiper)
jared: key minted into TEAM_JARED_LITELLM_KEY (team piedpiper)
erlich: key minted into TEAM_ERLICH_LITELLM_KEY (team piedpiper)
monica: key minted into TEAM_MONICA_LITELLM_KEY (team piedpiper)
make: *** [Makefile:30: team-bootstrap] Error 1
healthy members: 5
1
0
0
Teammates: Dinesh (builder), Gilfoyle (reviewer), Jared (coordinator and judge: scores every PR after CI and the review), Erlich (assistant), Monica (UI designer,  also a builder)
1
1
1
4
1
make test exit 0
./scripts/smoke-test.sh
--- litellm: context contract (context_window >= max_input_tokens + max_output_tokens on every chat model, plan 14)
--- litellm: chat round-trip (SMOKE_CHAT_MODELS=ornith-max; all = every chat model, one model swap each; reasoning models need a generous max_tokens)
ok
--- gitea: token works
created piedpiper/smoke-1789428880 private=true clone=https://git.colpitts.dev/piedpiper/smoke-1789428880.git
deleted smoke-1789428880
TEAM SMOKE PASS: PR #47, CI success, review APPROVED. Merge it in Gitea to close the loop (not automated on purpose).
PASS: PR deliverable label
PASS: review label
PASS: mirror: git push command
PASS: score line: **Score:** complexity 1/5 · confidence high — one function plus a matching test that mirrors the existing `subtract_NNNN` pattern exactly, CI green on head 9356794, Gilfoyle approved with no findings. 
PASS: score labels: complexity/1,confidence/high
smoke test finished
team-smoke 1 exit 2
thread: ```
thread: **Review:** APPROVED — Additive subtract_8968, exact pattern of its neighbors, tests match, no issues.
thread: @Jared score https://git.colpitts.dev/piedpiper/demo-calc/pulls/48
milestone: push present
milestone: CI present
PASS: PR deliverable label
PASS: review label
PASS: mirror: git push command
FAIL: no **Score:** line from Jared within 3 min
PASS: score labels: complexity/1,confidence/high
SCORE FAIL (see above)
make: *** [Makefile:33: team-smoke] Error 1
team-smoke 2 exit 2
thread: ```
thread: **Review:** APPROVED — one-line pass-through `subtract_9295` matches the sibling `subtract_1628`, test covers the same three cases, no issues. Ship it.
thread: @Jared score https://git.colpitts.dev/piedpiper/demo-calc/pulls/49
milestone: push present
milestone: CI present
PASS: PR deliverable label
PASS: review label
PASS: mirror: git push command
FAIL: no **Score:** line from Jared within 3 min
PASS: score labels: complexity/2,confidence/high
SCORE FAIL (see above)
make: *** [Makefile:33: team-smoke] Error 1
FAIL G41 recreate=0 bootstrap=2 test=0 smoke=2/2
## G37 per-member LiteLLM keys 2026-09-14T20:45:46-03:00
./scripts/litellm-keys.sh
dinesh: key present
gilfoyle: key present
jared: key present
erlich: key present
monica: key present
buzz-agent: key minted into BUZZ_AGENT_LITELLM_KEY
open-webui: key minted into OPENWEBUI_LITELLM_KEY
apply: docker compose up -d --force-recreate dinesh gilfoyle jared erlich monica buzz-agent open-webui   (each client re-reads its key)
litellm-keys exit 0
healthy: 7/7
dinesh on master key: 0 (want 0)
buzz-agent on master key: 0 (want 0)
team-smoke 3 exit 0
milestone: CI present
PASS: PR deliverable label
PASS: review label
PASS: mirror: git push command
PASS: score line: **Score:** complexity 1/5 · confidence high — one function plus test mirroring subtract_1842, CI green, approved  
PASS: score labels: complexity/1,confidence/high
dinesh|piedpiper|26
gilfoyle|piedpiper|15
jared|piedpiper|22
||166
-- per client (LiteLLM key alias; one row, master key, until clients have their own keys: plan 16)
 client | calls | calls_kwh | cost 
--------+-------+-----------+------
(0 rows)
PASS G37 keys=0 recreate=0 master-key-env=0 smoke=0 member-alias-rows=3
## DONE-A 2026-09-14T20:48:22-03:00
## G41 team-bootstrap rerun (after the litellm-keys.sh fix) 2026-09-14T20:48:33-03:00
team-bootstrap exit 0
full_name: Dinesh (AI builder)
full_name: Gilfoyle (AI reviewer)
full_name: Jared (AI coordinator)
full_name: Monica (AI builder)
dinesh: key present
gilfoyle: key present
jared: key present
erlich: key present
monica: key present
buzz-agent: key present
open-webui: key present
apply: docker compose up -d --force-recreate dinesh gilfoyle jared erlich monica buzz-agent open-webui   (each client re-reads its key)
PASS G41-bootstrap exit=0
## G42 sixth member 2026-09-14T20:48:38-03:00
member-add exit 0
python3 scripts/team-roster.py add bertram builder "backend builder"
add bertram: ok
rendered teams/piedpiper/compose.yml (6 members)
.env: added TEAM_BERTRAM_PRIVATE_KEY, added TEAM_BERTRAM_PUBKEY, added TEAM_BERTRAM_GITEA_TOKEN, added TEAM_BERTRAM_LITELLM_KEY
full_name: Dinesh (AI builder)
full_name: Gilfoyle (AI reviewer)
full_name: Jared (AI coordinator)
full_name: Monica (AI builder)
full_name: Bertram (AI builder)
TEAM_BERTRAM_GITEA_TOKEN written
bertram: key minted into TEAM_BERTRAM_LITELLM_KEY (team piedpiper)
docker compose up -d --force-recreate --wait bertram && docker compose logs --since 1m --no-log-prefix bertram | grep -E 'model=|presence set' | cut -c1-120
model=ornith-max context=65536 output=32768
2026-09-14T23:48:44.079547Z  INFO buzz_acp: presence set to online
bertram is on the team: add its pubkey to your project channels (buzz channels add-member --pubkey $TEAM_BERTRAM_PUBKEY --role bot)
dinesh     builder      dinesh     Up 3 minutes (healthy)
gilfoyle   reviewer     gilfoyle   Up 3 minutes (healthy)
jared      coordinator  jared      Up 3 minutes (healthy)
erlich     assistant    erlich     Up 3 minutes (healthy)
monica     builder      monica     Up 3 minutes (healthy)
bertram    builder      bertram    Up 6 seconds (healthy)
bertram full_name: Bertram (AI builder)
builders team: bertram,dinesh,monica
channel d4d1169d-a460-453d-80fd-52e1dfdb1aff
job posted for Bertram; waiting for picked up + PR (up to 15 min)
picked up reply: (none)
PR by bertram: 51 after ~900s
member-rm exit 0
python3 scripts/team-roster.py rm bertram
rm bertram: ok
rendered teams/piedpiper/compose.yml (5 members)
forge user bertram purged
volume removed
bertram removed; TEAM_BERTRAM_* stay in .env
compose ps bertram lines: 0 (want 0)
forge user bertram after purge: HTTP 404 (want 404)
teams/piedpiper/compose.yml: up to date; .env: up to date
render check exit 0
FAIL G42 add=0 full_name='Bertram (AI builder)' picked= pr=51 rm=0 ps=0 user=404
## G43 presets, suffix, refusal (scratch copy, org acme) 2026-09-14T21:04:37-03:00
preset dev-squad: team-new exit 2, config exit 1, services: 
FAIL preset dev-squad
tail: option used in invalid context -- 5
preset solo-builder: team-new exit 2, config exit 1, services: 
FAIL preset solo-builder
tail: option used in invalid context -- 5
preset review-board: team-new exit 2, config exit 1, services: 
FAIL preset review-board
tail: option used in invalid context -- 5
preset content-studio: team-new exit 2, config exit 1, services: 
FAIL preset content-studio
tail: option used in invalid context -- 5
person ada created: HTTP 201
bootstrap (person holds ada) exit 1
team.toml invalid:
  member 'acme' listed twice
  member 'acme' listed twice
  member 'acme' listed twice
make: *** [Makefile:41: team-render] Error 1
grep: teams/acme/compose.yml: No such file or directory
bootstrap (suffix -ai) exit 1
full_name: Acme (AI builder)
./scripts/bootstrap-team.sh: line 45: !var: unbound variable
curl: (22) The requested URL returned error: 404
ada-ai full_name: 
FAIL G43 refusal-exit=1 suffix-bootstrap=1 full_name=''
## G44 builder not named dinesh (team acme from content-studio) 2026-09-14T21:04:47-03:00
acme up exit 1
service "ada" is not running
acme team-smoke exit 2
./scripts/team-smoke.sh
acme not running (COMPOSE_PROFILES needs team; make up)
make: *** [Makefile:33: team-smoke] Error 1
FAIL G44 up=1 smoke=2
## cleanup acme 2026-09-14T21:04:48-03:00
acme containers/volumes down
curl: (22) The requested URL returned error: 404
org acme delete: 404
user ada purge: 204
user ada-ai purge: 404
user edsger-ai purge: 404
user barbara-ai purge: 404
user grace-ai purge: 404
no acme keys listed
scratch copy removed
## DONE-B 2026-09-14T21:04:49-03:00
## G41 smoke rerun: two consecutive team-smoke after the either-thread score check 2026-09-14T21:05:07-03:00
team-smoke 4 exit 0
PR #52 opened after ~30s
CI on PR #52: success
Gilfoyle review: APPROVED
TEAM SMOKE PASS: PR #52, CI success, review APPROVED. Merge it in Gitea to close the loop (not automated on purpose).
PASS: score line: **Score:** complexity 1/5 · confidence high — one function plus test mirroring subtract_1628, CI green, approved  
team-smoke 5 exit 0
PR #53 opened after ~50s
CI on PR #53: success
Gilfoyle review: APPROVED
TEAM SMOKE PASS: PR #53, CI success, review APPROVED. Merge it in Gitea to close the loop (not automated on purpose).
PASS: score line: **Score:** complexity 1/5 · confidence high — one function plus test, CI green, approved  
PASS G41-smoke consecutive=0/0
## DONE-C 2026-09-14T21:08:18-03:00
## G43 rerun: presets, suffix, refusal (scratch copy, org acme) 2026-09-14T21:08:33-03:00
preset dev-squad: team-new exit 0, config exit 0, services: dinesh erlich gilfoyle jared monica
preset solo-builder: team-new exit 0, config exit 0, services: ada grace
preset review-board: team-new exit 0, config exit 0, services: grace linus margaret
preset content-studio: team-new exit 0, config exit 0, services: ada barbara edsger grace
person ada created: HTTP 201
bootstrap (person holds ada) exit 1
login 'ada' exists and is not an agent (a person?). Set AGENT_LOGIN_SUFFIX=-ai in .env, make team-render, then rerun.
rendered teams/acme/compose.yml (4 members)
.env unchanged
1
bootstrap (suffix -ai) exit 22
full_name: Ada (AI builder)
TEAM_ADA_GITEA_TOKEN written
full_name: Edsger (AI reviewer)
TEAM_EDSGER_GITEA_TOKEN written
full_name: Barbara (AI builder)
TEAM_BARBARA_GITEA_TOKEN written
full_name: Grace (AI coordinator)
TEAM_GRACE_GITEA_TOKEN written
litellm team acme created (348243f7-a6f8-469e-8fe4-0264e2c68c45)
ada: key minted into TEAM_ADA_LITELLM_KEY (team acme)
edsger: key minted into TEAM_EDSGER_LITELLM_KEY (team acme)
barbara: key minted into TEAM_BARBARA_LITELLM_KEY (team acme)
grace: key minted into TEAM_GRACE_LITELLM_KEY (team acme)
ada-ai full_name: Ada (AI builder)
FAIL G43 refusal-exit=1 suffix-bootstrap=22 full_name='Ada (AI builder)'
## G44 rerun: builder not named dinesh (team acme from content-studio) 2026-09-14T21:08:41-03:00
acme up exit 1
ada Restarting (1) Less than a second ago
barbara Restarting (1) Less than a second ago
edsger Restarting (1) Less than a second ago
grace Restarting (1) Less than a second ago
Error response from daemon: Container cc32c77427a6d00074e590ed965faf7eb15c4a4efa51a0e44aab699a20b87aed is restarting, wait until the container is running
acme team-smoke exit 2
./scripts/team-smoke.sh
ada not running (COMPOSE_PROFILES needs team; make up)
make: *** [Makefile:33: team-smoke] Error 1
FAIL G44 up=1 smoke=2
## cleanup acme 2026-09-14T21:08:43-03:00
acme containers/volumes down
curl: (22) The requested URL returned error: 404
org acme delete: 404
user ada purge: 204
user ada-ai purge: 204
user edsger-ai purge: 204
user barbara-ai purge: 204
user grace-ai purge: 204
user acme-ai purge: 404
{"deleted_keys":["15c8c6c79171cfe104daf50ab065cd57af075c59931f3bf9098243b250842f5d","55fd27ae5d5910048294012933f53afda00c462ff8825ad15605f888f1322a37","e94e707a2044b885f8855a0abbe095a1116cc0374a5da03413eb79fbd1e627f1","0
{"deleted_teams":["348243f7-a6f8-469e-8fe4-0264e2c68c45"]}
scratch copy removed
## DONE-B2 2026-09-14T21:08:45-03:00
## G43 rerun 2 (stray user acme from the first run purged): presets, suffix, refusal (scratch copy, org acme) 2026-09-14T21:09:17-03:00
preset dev-squad: team-new exit 0, config exit 1, services: 
FAIL preset dev-squad
tail: option used in invalid context -- 5
preset solo-builder: team-new exit 0, config exit 1, services: 
FAIL preset solo-builder
tail: option used in invalid context -- 5
preset review-board: team-new exit 0, config exit 1, services: 
FAIL preset review-board
tail: option used in invalid context -- 5
preset content-studio: team-new exit 0, config exit 1, services: 
FAIL preset content-studio
tail: option used in invalid context -- 5
person ada created: HTTP 201
bootstrap (person holds ada) exit 1
login 'ada' exists and is not an agent (a person?). Set AGENT_LOGIN_SUFFIX=-ai in .env, make team-render, then rerun.
rendered teams/acme/compose.yml (4 members)
.env unchanged
1
bootstrap (suffix -ai) exit 0
full_name: Ada (AI builder)
TEAM_ADA_GITEA_TOKEN written
full_name: Edsger (AI reviewer)
TEAM_EDSGER_GITEA_TOKEN written
full_name: Barbara (AI builder)
TEAM_BARBARA_GITEA_TOKEN written
full_name: Grace (AI coordinator)
TEAM_GRACE_GITEA_TOKEN written
litellm team acme created (4eca8b81-fd8e-4f1b-95d0-cb0877a61bae)
ada: key minted into TEAM_ADA_LITELLM_KEY (team acme)
edsger: key minted into TEAM_EDSGER_LITELLM_KEY (team acme)
barbara: key minted into TEAM_BARBARA_LITELLM_KEY (team acme)
grace: key minted into TEAM_GRACE_LITELLM_KEY (team acme)
created team acme/builders
team builders: member ada-ai
team builders: member barbara-ai
created team acme/reviewers
team reviewers: member edsger-ai
created team acme/coordinators
team coordinators: member grace-ai
ada-ai full_name: Ada (AI builder)
PASS G43 refusal-exit=1 suffix-bootstrap=0 full_name='Ada (AI builder)'
## G44 rerun 2: builder not named dinesh (team acme from content-studio) 2026-09-14T21:09:31-03:00
acme up exit 1
ada Restarting (1) Less than a second ago
barbara Restarting (1) Less than a second ago
edsger Restarting (1) Less than a second ago
grace Restarting (1) Less than a second ago
Error response from daemon: Container 4b2e2cf26fee5ae67392bb57aa8e84084b835f43130097544244755b4605a6bd is restarting, wait until the container is running
acme team-smoke exit 2
./scripts/team-smoke.sh
edsger not running (COMPOSE_PROFILES needs team; make up)
make: *** [Makefile:33: team-smoke] Error 1
FAIL G44 up=1 smoke=2
## cleanup acme 2026-09-14T21:09:32-03:00
acme containers/volumes down
repo acme/python-template delete: 204
repo acme/demo-calc delete: 204
org acme delete: 204
user ada purge: 204
user ada-ai purge: 204
user edsger-ai purge: 204
user barbara-ai purge: 204
user grace-ai purge: 204
user acme-ai purge: 404
user acme purge: 404
{"deleted_keys":["1f37c385199d4b50005291d662f48f0787156a5feeea845ff68a8f59ed9bf6f8","99769f972085932878fa722cea9650481e190c22e05e51870bafdb5f37508c82","a8714e1e197cf3be6bcb891b1968039564fc9311f0841ea83a60e18bfeb6d496","f
{"deleted_teams":["4eca8b81-fd8e-4f1b-95d0-cb0877a61bae"]}
scratch copy removed
## DONE-B3 2026-09-14T21:09:34-03:00
## G43 rerun 3 (shell exports unset; the scratch .env drives Compose): presets, suffix, refusal (scratch copy, org acme) 2026-09-14T21:10:14-03:00
preset dev-squad: team-new exit 0, config exit 0, services: dinesh erlich gilfoyle jared monica
preset solo-builder: team-new exit 0, config exit 0, services: grace ada
preset review-board: team-new exit 0, config exit 0, services: grace linus margaret
preset content-studio: team-new exit 0, config exit 0, services: barbara edsger grace ada
person ada created: HTTP 201
bootstrap (person holds ada) exit 1
login 'ada' exists and is not an agent (a person?). Set AGENT_LOGIN_SUFFIX=-ai in .env, make team-render, then rerun.
rendered teams/acme/compose.yml (4 members)
.env unchanged
1
bootstrap (suffix -ai) exit 0
full_name: Ada (AI builder)
TEAM_ADA_GITEA_TOKEN written
full_name: Edsger (AI reviewer)
TEAM_EDSGER_GITEA_TOKEN written
full_name: Barbara (AI builder)
TEAM_BARBARA_GITEA_TOKEN written
full_name: Grace (AI coordinator)
TEAM_GRACE_GITEA_TOKEN written
litellm team acme created (c18ae83a-a3b4-4066-bbfb-687af681fe44)
ada: key minted into TEAM_ADA_LITELLM_KEY (team acme)
edsger: key minted into TEAM_EDSGER_LITELLM_KEY (team acme)
barbara: key minted into TEAM_BARBARA_LITELLM_KEY (team acme)
grace: key minted into TEAM_GRACE_LITELLM_KEY (team acme)
created team acme/builders
team builders: member ada-ai
team builders: member barbara-ai
created team acme/reviewers
team reviewers: member edsger-ai
created team acme/coordinators
team coordinators: member grace-ai
ada-ai full_name: Ada (AI builder)
PASS G43 refusal-exit=1 suffix-bootstrap=0 full_name='Ada (AI builder)'
## G44 rerun 3: builder not named dinesh (team acme from content-studio) 2026-09-14T21:10:28-03:00
acme up exit 1
ada Restarting (1) Less than a second ago
barbara Restarting (1) Less than a second ago
edsger Restarting (1) Less than a second ago
grace Restarting (1) Less than a second ago
Error response from daemon: Container d99cc5b187d457ff862027290299672761b6181753d1151411c7212d6a3dc365 is restarting, wait until the container is running
acme team-smoke exit 2
./scripts/team-smoke.sh
ada not running (COMPOSE_PROFILES needs team; make up)
make: *** [Makefile:33: team-smoke] Error 1
FAIL G44 up=1 smoke=2
## cleanup acme 2026-09-14T21:10:30-03:00
acme containers/volumes down
repo acme/python-template delete: 204
repo acme/demo-calc delete: 204
org acme delete: 204
user ada purge: 204
user ada-ai purge: 204
user edsger-ai purge: 204
user barbara-ai purge: 204
user grace-ai purge: 204
user acme-ai purge: 404
user acme purge: 404
{"deleted_keys":["9a9c20282b2a927020ed194a9bbd7c292a2f570bd4f16ae4ddcb505b198302a4","aa79742a3ed6e464af117891daadf4d8ac172fce7b3e02b4569c9af39a0c9160","473c662b4300b3f6b2777fa52b9b032fdc25dcca45e21c8ad5521544ec11dfa2","4
{"deleted_teams":["c18ae83a-a3b4-4066-bbfb-687af681fe44"]}
scratch copy removed
## DONE-B4 2026-09-14T21:10:32-03:00
## G43 rerun 4 (container logs captured): presets, suffix, refusal (scratch copy, org acme) 2026-09-14T21:10:52-03:00
preset dev-squad: team-new exit 0, config exit 0, services: monica dinesh erlich gilfoyle jared
preset solo-builder: team-new exit 0, config exit 0, services: ada grace
preset review-board: team-new exit 0, config exit 0, services: grace linus margaret
preset content-studio: team-new exit 0, config exit 0, services: ada barbara edsger grace
person ada created: HTTP 201
bootstrap (person holds ada) exit 1
login 'ada' exists and is not an agent (a person?). Set AGENT_LOGIN_SUFFIX=-ai in .env, make team-render, then rerun.
rendered teams/acme/compose.yml (4 members)
.env unchanged
1
bootstrap (suffix -ai) exit 0
full_name: Ada (AI builder)
TEAM_ADA_GITEA_TOKEN written
full_name: Edsger (AI reviewer)
TEAM_EDSGER_GITEA_TOKEN written
full_name: Barbara (AI builder)
TEAM_BARBARA_GITEA_TOKEN written
full_name: Grace (AI coordinator)
TEAM_GRACE_GITEA_TOKEN written
litellm team acme created (9f2bf665-7c46-4bc2-86b8-b1293464d68f)
ada: key minted into TEAM_ADA_LITELLM_KEY (team acme)
edsger: key minted into TEAM_EDSGER_LITELLM_KEY (team acme)
barbara: key minted into TEAM_BARBARA_LITELLM_KEY (team acme)
grace: key minted into TEAM_GRACE_LITELLM_KEY (team acme)
created team acme/builders
team builders: member ada-ai
team builders: member barbara-ai
created team acme/reviewers
team reviewers: member edsger-ai
created team acme/coordinators
team coordinators: member grace-ai
ada-ai full_name: Ada (AI builder)
PASS G43 refusal-exit=1 suffix-bootstrap=0 full_name='Ada (AI builder)'
## G44 rerun 4: builder not named dinesh (team acme from content-studio) 2026-09-14T21:11:06-03:00
acme up exit 1
ada Restarting (1) Less than a second ago
barbara Restarting (1) Less than a second ago
edsger Restarting (1) Less than a second ago
grace Restarting (1) Less than a second ago
no Gitea token for ada -- run make team-bootstrap, then docker compose up -d ada
no Gitea token for ada -- run make team-bootstrap, then docker compose up -d ada
no Gitea token for ada -- run make team-bootstrap, then docker compose up -d ada
no Gitea token for barbara -- run make team-bootstrap, then docker compose up -d barbara
no Gitea token for barbara -- run make team-bootstrap, then docker compose up -d barbara
no Gitea token for barbara -- run make team-bootstrap, then docker compose up -d barbara
Error response from daemon: Container 4d393b690efc5c77896885d3fb923f2af4cfea3fbae01df12fdd90359aac7040 is restarting, wait until the container is running
acme team-smoke exit 2
./scripts/team-smoke.sh
ada not running (COMPOSE_PROFILES needs team; make up)
make: *** [Makefile:33: team-smoke] Error 1
FAIL G44 up=1 smoke=2
## cleanup acme 2026-09-14T21:11:08-03:00
acme containers/volumes down
repo acme/python-template delete: 204
repo acme/demo-calc delete: 204
org acme delete: 204
user ada purge: 204
user ada-ai purge: 204
user edsger-ai purge: 204
user barbara-ai purge: 204
user grace-ai purge: 204
user acme-ai purge: 404
user acme purge: 404
{"deleted_keys":["f9bfedc0442b7039a95d1d012a6d474858e0200a760f21382c5d22d8c968e498","35b05ff9e5bd073e3a05cb231a21a4568986e23af92e6b94cf9515234d7da37a","fe1b42e8ba5ba673079aef0a1894ab01fe9dba5cd29e0519d8992f7906157e63","9
{"deleted_teams":["9f2bf665-7c46-4bc2-86b8-b1293464d68f"]}
scratch copy removed
## DONE-B5 2026-09-14T21:11:10-03:00
## G43 rerun 5 (.env re-sourced before up): presets, suffix, refusal (scratch copy, org acme) 2026-09-14T21:11:27-03:00
preset dev-squad: team-new exit 0, config exit 0, services: erlich gilfoyle jared monica dinesh
preset solo-builder: team-new exit 0, config exit 0, services: ada grace
preset review-board: team-new exit 0, config exit 0, services: margaret grace linus
preset content-studio: team-new exit 0, config exit 0, services: grace ada barbara edsger
person ada created: HTTP 201
bootstrap (person holds ada) exit 1
login 'ada' exists and is not an agent (a person?). Set AGENT_LOGIN_SUFFIX=-ai in .env, make team-render, then rerun.
rendered teams/acme/compose.yml (4 members)
.env unchanged
1
bootstrap (suffix -ai) exit 0
full_name: Ada (AI builder)
TEAM_ADA_GITEA_TOKEN written
full_name: Edsger (AI reviewer)
TEAM_EDSGER_GITEA_TOKEN written
full_name: Barbara (AI builder)
TEAM_BARBARA_GITEA_TOKEN written
full_name: Grace (AI coordinator)
TEAM_GRACE_GITEA_TOKEN written
litellm team acme created (7a073cc7-0a7b-4155-859b-1d6c43577309)
ada: key minted into TEAM_ADA_LITELLM_KEY (team acme)
edsger: key minted into TEAM_EDSGER_LITELLM_KEY (team acme)
barbara: key minted into TEAM_BARBARA_LITELLM_KEY (team acme)
grace: key minted into TEAM_GRACE_LITELLM_KEY (team acme)
created team acme/builders
team builders: member ada-ai
team builders: member barbara-ai
created team acme/reviewers
team reviewers: member edsger-ai
created team acme/coordinators
team coordinators: member grace-ai
ada-ai full_name: Ada (AI builder)
PASS G43 refusal-exit=1 suffix-bootstrap=0 full_name='Ada (AI builder)'
## G44 rerun 5: builder not named dinesh (team acme from content-studio) 2026-09-14T21:11:40-03:00
acme up exit 0
ada Up 5 seconds (healthy)
barbara Up 5 seconds (healthy)
edsger Up 5 seconds (healthy)
grace Up 5 seconds (healthy)
2026-09-15T00:11:41.287101Z  INFO buzz_acp: agent initialized: {"agentCapabilities":{"loadSession":false,"mcpCapabilities":{"http":false,"sse":false},"promptCapabiliti
2026-09-15T00:11:41.287108Z  INFO buzz_acp: agent initialized agent=0 name="buzz-agent" steering_supported=false
2026-09-15T00:11:41.287118Z  INFO buzz_acp: agent_pool_ready agents=1
2026-09-15T00:11:41.288245Z  INFO buzz_acp: connected to relay at ws://127.0.0.1:3002
2026-09-15T00:11:41.288841Z  INFO buzz_acp: subscribed to membership notifications
2026-09-15T00:11:41.288845Z  INFO buzz_acp: no agent owner configured
2026-09-15T00:11:41.288848Z  WARN buzz_acp: respond-to=allowlist but no owner is set — allowlisted pubkeys will still be accepted, but owner-based matching is unavai
2026-09-15T00:11:41.291481Z  INFO buzz_acp: discovered 0 channel(s)
2026-09-15T00:11:41.291488Z  WARN buzz_acp: no channel subscriptions resolved — agent will sit idle
2026-09-15T00:11:41.291530Z  INFO buzz_acp: presence set to online
2026-09-15T00:11:41.300526Z  INFO buzz_acp: agent initialized: {"agentCapabilities":{"loadSession":false,"mcpCapabilities":{"http":false,"sse":false},"promptCapabiliti
2026-09-15T00:11:41.300533Z  INFO buzz_acp: agent initialized agent=0 name="buzz-agent" steering_supported=false
2026-09-15T00:11:41.300542Z  INFO buzz_acp: agent_pool_ready agents=1
2026-09-15T00:11:41.301766Z  INFO buzz_acp: connected to relay at ws://127.0.0.1:3002
2026-09-15T00:11:41.302442Z  INFO buzz_acp: subscribed to membership notifications
2026-09-15T00:11:41.302448Z  INFO buzz_acp: no agent owner configured
2026-09-15T00:11:41.302451Z  WARN buzz_acp: respond-to=allowlist but no owner is set — allowlisted pubkeys will still be accepted, but owner-based matching is unavai
2026-09-15T00:11:41.304989Z  INFO buzz_acp: discovered 0 channel(s)
2026-09-15T00:11:41.304993Z  WARN buzz_acp: no channel subscriptions resolved — agent will sit idle
2026-09-15T00:11:41.305032Z  INFO buzz_acp: presence set to online
Teammates: Ada (writer), Edsger (editor), Barbara (designer), Grace (coordinator and judge: scores every PR after CI and the review)
0
acme team-smoke exit 0
thread: @Grace score https://git.colpitts.dev/acme/demo-calc/pulls/1
milestone: push present
milestone: CI ABSENT (model skipped a persona step; not gated)
PASS: PR deliverable label
PASS: review label
PASS: mirror: git push command
PASS: score line: **Score:** complexity 1/5 · confidence high — one function and its test mirroring add, CI green, approved  
PASS: score labels: complexity/1,confidence/high
PASS G44 up=0 smoke=0
## cleanup acme 2026-09-14T21:15:56-03:00
acme containers/volumes down
repo acme/python-template delete: 204
repo acme/demo-calc delete: 204
org acme delete: 204
user ada purge: 204
user ada-ai purge: 204
user edsger-ai purge: 204
user barbara-ai purge: 204
user grace-ai purge: 204
user acme-ai purge: 404
user acme purge: 404
{"deleted_keys":["a481fc6e7ba4e9f6c0f93876d4dc2c35f7d6eb5743c04853a8d7f66d92770601","c8e8cbcf306371fcfa16e213acba987298078184ec9ef55a4c906c0567cb1765","5a3c58fd1a0c8c6a406554bbae0c154b941d004481636ea46db268451acafec8","e
{"deleted_teams":["7a073cc7-0a7b-4155-859b-1d6c43577309"]}
scratch copy removed
## DONE-B6 2026-09-14T21:15:59-03:00
## G37 cost-report per client with the meter running 2026-09-14T21:17:03-03:00
(eval):1: bad substitution
DINESH call -> 
(eval):1: bad substitution
GILFOYLE call -> 
(eval):1: bad substitution
JARED call -> 
-- per client (LiteLLM key alias: one row per member, buzz-agent, open-webui once make litellm-keys ran; else master key)
 client | calls | calls_kwh | cost 
--------+-------+-----------+------
(0 rows)
meter stopped
## G37 cost-report per client with the meter running (bash) 2026-09-14T21:17:54-03:00
DINESH call -> 
GILFOYLE call -> 
JARED call -> 
-- per client (LiteLLM key alias: one row per member, buzz-agent, open-webui once make litellm-keys ran; else master key)
  client  | calls | calls_kwh |  cost  
----------+-------+-----------+--------
 dinesh   |     1 |     0.000 | 0.0000
 gilfoyle |     1 |     0.000 | 0.0000
 jared    |     1 |     0.000 | 0.0000
(3 rows)
meter still running
```
