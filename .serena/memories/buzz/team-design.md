## Agent development team (built by plan 08, validated 2026-09-13; spec §5.8 has the full facts)

Pattern from the maintainers' own example pack (`examples/meadow-core`): orchestrator never builds; reviewers are READ ONLY; builders produce artifacts; team instructions carry shared norms.

| Agent | Runs | Gate | Sessions | Job |
|---|---|---|---|---|
| assistant | app or server | allowlist | channel | Q&A/summaries in #general |
| builder (per repo) | server, workspace volume | allowlist | thread | clone from Gitea → branch `agent/<thread>` → tests → push → PR via API → post URL, @mention requester |
| reviewer | server | allowlist | thread | read-only review of the PR diff, posts findings |
| triage (optional) | server, heartbeat | allowlist | channel | labels/points builders at issues |
| CI | Gitea Actions runner | — | — | the only verdict |

- Channels: `#general` (humans + assistant); one project channel per repo with exactly its builder + reviewer; jobs = threads; no agent in two project channels (audience isolation).
- Per server agent: own key (`buzz-admin generate-key`), `BUZZ_ACP_RESPOND_TO=allowlist` + team pubkeys, `BUZZ_ACP_SESSION_POLICY=thread`, `BUZZ_AGENT_REQUIRE_REPLY=1`, `BUZZ_ACP_AGENTS=1`, `BUZZ_ACP_SYSTEM_PROMPT_FILE=<persona.md>`, `RUST_LOG=info`, workspace volume, model `ornith-max`, `OPENAI_COMPAT_*` → LiteLLM public URL, `network_mode: host`. Builders: Gitea token in the git credential store, repo clone URL + test command in the persona.
- Stack additions needed: `gitea-runner` profile (`gitea/act_runner`, docker socket), workflow template per repo, branch protection requiring the check, personas dir, per-role compose services (same sprig image), `buzz-smoke` variant that submits a job thread and waits for a green PR.
- Known gaps: no NIP-OA attestation for server agents (standalone identities + closed relay `add-member`); reply guard is advisory; nothing enforces fleet policy except the compose file; multi-agent banter channels unreliable with 35B-class local models.
- Hardware: one resident model + `OLLAMA_NUM_PARALLEL=1` on the 5090; on a Strix Halo server use llama.cpp per model with `-np` slots (see `mem:stack/operations`).

## Built (plan 08) — invariants learned executing it

- Services `dinesh` (builder, thread sessions), `gilfoyle` (reviewer, read-only, thread), `jared` (coordinator, channel, heartbeat), `erlich` (assistant, channel, no Gitea token); `gitea-runner` = act_runner 3.4.2 on host network, jobs in `python:3.12-alpine`. Fixture repo `demo-calc` with `ci` workflow + branch protection (`ci / test (pull_request)` + 1 approval).
- `BUZZ_ACP_RESPOND_TO_ALLOWLIST` must contain the teammates' pubkeys too, or Dinesh→Gilfoyle / Jared→Dinesh / Erlich→Dinesh mentions are silently dropped.
- buzz-acp starts `buzz-dev-mcp` with a scrubbed env (HOME, PATH only; no passthrough flag) → non-secret `$GITEA_URL`/`$GITEA_OWNER` are inlined into the prompt by the entrypoint; the token lives in `~/.gitea.env` and every API call is `. ~/.gitea.env && curl …`. Git itself works via the file credential store.
- Gitea review API: event enum is `APPROVED|REQUEST_CHANGES|COMMENT` (not `APPROVE`); any other value is stored 200 OK as a PENDING draft only the reviewer sees; submit a draft with `POST …/pulls/{n}/reviews/{id}` (no `/submit` route).
- On `pull_request` events Gitea sets `GITHUB_REF_NAME` to the PR index; the workflow fetches `refs/pull/<n>/head` when `github.event.number` is set.
- Compose interpolates `${VAR:?}` for every service even with its profile off → bootstrap-filled vars use `${VAR:-}` + entrypoint guards. `grep … | head -1` under pipefail in the sprig image dies with SIGPIPE 141 → parse with bash regex.
- Sprig has no Python: builders cannot run pytest locally; CI is the verdict, Dinesh reads `…/commits/<sha>/status`.
- Measured (ornith-max): mention → "picked up" ≈ 6 s, PR opened ≈ 20 s, CI ≈ 25 s, review ≈ 30 s after mention; Erlich answers in ≈ 10 s. Local models mangle shell quoting (backticks, `--` in text) and self-correct; TEAM.md tells them to use heredoc files.
- Repos live in a Gitea org (`TEAM_GITEA_ORG`, default `piedpiper`), owned by the admin user; agents are on team `agents` (write on all repos, `can_create_org_repo`). Non-admins cannot create repos in another user's namespace, own-namespace creation needs `write:user`, org creation needs `write:organization` on the token → bootstrap re-mints under-scoped tokens (probe: `GET /user/orgs` 403). Team `write` suffices for branch protection on a repo the member created. Template `agents/ci-python.yaml` is copied by bootstrap and by Dinesh into new repos.
