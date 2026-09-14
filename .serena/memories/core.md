## Project

open-llm-stack — local-first, open-weights dev stack in one docker compose: LiteLLM (3000), Open WebUI (3001), Buzz relay (3002), Gitea (3003); optional profiles `ollama`, `llamacpp`, `buzz-agent`. Binding spec: `docs/spec.md`. Rules: `AGENTS.md` (auto-loaded via CLAUDE.md — do not duplicate here). Plans 01–07 executed and validated 2026-09-12, plan 08 (agent team + Gitea Actions: profiles `gitea-runner`, `team`) 2026-09-13, plans 09–14 by 2026-09-14 (external Gitea, repo factory, progress mirror, goose runtime, PR scoring with Jared as judge, context contract + GPU budget); execution reports at the end of each `plans/NN-*.md`. Remote: github.com/colpitts-dev/open-llm-stack.

Quick LLM priming for Buzz agent work: `docs/buzz-agents-primer.md` (flat, dense; the memories below are the graph form of the same research).

## Memory graph

- `mem:stack/operations` — how the running stack behaves: profiles, env matrix, verified gotchas (relay community host, MinIO on quay, no cross-profile depends_on), GPU/Ollama single-slot rule, smoke tests.
- `mem:buzz/agent-architecture` — how a Buzz agent is built (key, harness, ACP agent, MCP tools), prompt layers, the publish rule and reply guard, sessions, author gate, NIP-OA ownership, disposable bodies. Read before touching any agent config.
- `mem:buzz/agent-best-practices` — measured + documented practices: model choice, gates, parallelism, logging, workspace, channel topology, silent-turn causes.
- `mem:buzz/desktop-app-agents` — Buzz Desktop specifics: where provider/model/prompt actually resolve from (persona vs instance vs global file), reserved env vars, parallelism field, permission prompts.
- `mem:buzz/git-and-gitea` — relay-hosted git vs Gitea: CLI surface (`buzz repos/pr/issues/projects`), app clone-URL restriction, forge feature status, the recommended split.
- `mem:buzz/team-design` — the agent development team as built by plan 08 (roles, channels, per-role env), the gotchas found executing it, and the open gaps.
