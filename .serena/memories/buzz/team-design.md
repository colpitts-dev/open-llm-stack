## Proposed agent development team (input to plan 08; not built yet)

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
