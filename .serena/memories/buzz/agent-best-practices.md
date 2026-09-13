## Buzz agent best practices (docs + measurements 2026-09-12/13)

- One key per agent; N workers under one identity is fine, two agents is two keys. Separate identities per audience (private channel agent ≠ #general agent).
- Gate: team = `allowlist` of dev pubkeys; `anyone` only on a loopback demo relay (the agent has a shell). Local models: set `BUZZ_AGENT_REQUIRE_REPLY=1` AND keep an explicit publish sentence in the persona (`BUZZ_AGENT_INSTRUCTIONS` in this stack).
- Model: `ornith-max` publishes multi-step results; `qwen3.6-max` does not (measured 0/2 vs 3/3 on a build task). A stricter "never write prose" rule made things WORSE (0/3, posts to the wrong channel). Keep the rule short and mechanical; do not over-prompt.
- Busy multi-agent channels: even good local models drift to chat mode or post to a remembered channel. Keep task channels to one agent + humans; one thread per job with `BUZZ_ACP_SESSION_POLICY=thread`.
- Parallelism 1–2 per agent; single GPU slot serialises anyway; idle workers hold memory.
- `RUST_LOG=info` on server agents → `acp::tool` (tool calls) and `acp::stream` (model text) in logs; without it the container logs nothing useful.
- Workspace: mount a volume for the working dir (`REPOS/`, `WORK_LOGS/`, `OUTBOX/`); durable knowledge → `buzz mem`.
- Relay file store (Blossom) accepts media only: `.html`/archives rejected → code goes inline or to git.
- Mentions: app resolves `@Name` only for channel members; non-member mention has no `p` tag → never delivered. Add the agent (role bot) first.
- Silent-turn triage order: is the agent a member? did the mention carry a `p` tag? did the container start after the message? `llm: call completed ... stop=EndTurn` with no `tool_call` = prose-only turn (model), not infra. `transport error` = gateway/GPU (check `ollama ps` for `100% CPU`).
- Restart ordering: relay up → agent (entrypoint waits ≤2 min on `/_liveness`); app agents need manual restart to pick up global config.
