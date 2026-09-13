# Buzz agents primer (LLM context priming)

Purpose: load this file to work on Buzz agents in this stack without re-reading the Buzz repo. Dense facts only. Sources: `github.com/block/buzz` @ ad9591c (2026-09-09) docs + source, images `ghcr.io/block/buzz:sha-e17cdd9` and `buzz-sprig:sha-e17cdd9`, and live measurements on this stack 2026-09-12/13. Graph form of the same content: `.serena/memories/buzz/*`.

## 1. Model of an agent

- Identity = Nostr keypair. Durable on the relay: profile, messages, `core` memory, reputation. Process = disposable body; files in the body die with it.
- Body = `buzz-acp` (harness) ⇄ ACP/stdio ⇄ agent runtime (`buzz-agent` default here; goose/codex/claude adapters possible) ⇄ MCP/stdio ⇄ `buzz-dev-mcp` (`shell`, `read_file`, `str_replace`, `todo`, `view_image`). The `buzz` CLI is used through `shell`.
- Launchers are interchangeable: Buzz Desktop, a compose service, a script exporting `BUZZ_PRIVATE_KEY` + `BUZZ_RELAY_URL` and exec'ing `buzz-acp`.
- THE rule: the harness never publishes model text. A reply exists only if the model runs `buzz messages send` (or `reactions add`). Model prose is logged (`acp::stream`) and shown in the owner's observer pane, then discarded.
- Reply guard: `BUZZ_AGENT_REQUIRE_REPLY=1` (buzz-agent) → up to 2 reminders when a turn ends with no send; budget `BUZZ_AGENT_STOP_MAX_REJECTIONS` (3). Advisory. Present in both pinned images. Desktop enables it only for mesh agents by default → set it explicitly.

## 2. Prompt, sessions, gating

- Prompt per message: `[Base]` (compiled-in; CLI table, publish rules, threading, memory, engineering discipline) → `[System]` persona (`BUZZ_ACP_SYSTEM_PROMPT`/`_FILE`) → team instructions → `<context>` (channel uuid, reply destination, project fields) → last 12 messages (`BUZZ_ACP_CONTEXT_MESSAGE_LIMIT`) → event. Don't repeat base content in personas. `BUZZ_ACP_NO_BASE_PROMPT` / `BUZZ_ACP_BASE_PROMPT_FILE` exist.
- Sessions: `BUZZ_ACP_SESSION_POLICY=channel|thread`. One prompt in flight per channel. `BUZZ_ACP_AGENTS` 1–32 workers, one identity. `BUZZ_ACP_MULTIPLE_EVENT_HANDLING=steer` default.
- Delivery: only member channels + DMs; mentions need a `p` tag (app resolves `@Name` only for members); no replay of pre-connect mentions; membership notification auto-subscribes.
- Gate `BUZZ_ACP_RESPOND_TO`: owner-only (default; owner from NIP-OA `BUZZ_AUTH_TAG` or `BUZZ_ACP_AGENT_OWNER`) | allowlist (+`BUZZ_ACP_RESPOND_TO_ALLOWLIST`) | anyone | nobody. Owner commands: `!cancel` `!rotate` `!shutdown`.
- Ownership: NIP-OA auth tag (owner-signed) → NIP-AA relay admission via owner membership → relay-git push rights inherited from owner. Desktop mints it; no CLI found for standalone keys → server agents = standalone identities, `buzz-admin add-member` on a closed relay.
- Memory: `core` engram injected each turn (keep <10 KB); cold `buzz mem set/get/ls/patch/rm`. Heartbeat: `BUZZ_ACP_HEARTBEAT_INTERVAL` + prompt. Hooks: `_Stop`/`_PostCompact` via `MCP_HOOK_SERVERS` (off).
- Security today: one process serves all its channels with full ambient authority (shell, key). Broker/audience isolation is a proposal. → one identity per audience.

## 3. Measured on this stack (ornith-max / qwen3.6-max via LiteLLM → Ollama, RTX 5090)

| Situation | Result |
|---|---|
| Short mention, quiet channel, explicit publish rule | ornith-max & qwen3.6-max reply ~10 s |
| Multi-step build task, explicit rule | ornith-max 3/3 published (~20 s); qwen3.6-max 0/2 (prose, discarded) |
| Stricter "no prose" rule | worse: 0/3, posts to wrong channel |
| Busy multi-agent channel | even ornith-max sometimes ends in prose or wrong channel |
| Concurrent calls, `OLLAMA_NUM_PARALLEL` unset | Ollama spilled the model to CPU (39 GB) → minutes/turn, transport timeouts |
| `buzz upload file` of .html | rejected (Blossom = media only) |

Decisions: default agent model `ornith-max`; `OLLAMA_NUM_PARALLEL=1` on the host Ollama; `BUZZ_AGENT_INSTRUCTIONS` short publish rule; `RUST_LOG=info`; one agent per task channel.

## 4. Desktop app specifics (0.5.32)

- Data: `~/.local/share/xyz.block.buzz.app/agents/{managed-agents.json,global-agent-config.json,logs/,agent-pids/,teams.json}`. Global file `{env_vars, provider, model, preferred_runtime}` applies to agents with unset provider/model; agents restart to pick it up.
- Linked agents (persona_id set) take prompt/provider/model from the PERSONA definition; instance fields ignored. Team instructions apply to all members.
- LiteLLM wiring: provider `openai`, model = registry name, `OPENAI_COMPAT_BASE_URL=http://127.0.0.1:3000/v1`, `OPENAI_COMPAT_API=chat`, key field "OpenAI Runtime API Key" = LITELLM_MASTER_KEY. Unset provider/model = "setup mode" nudge messages.
- Parallelism: Edit Agent → Advanced (instance `parallelism` → `BUZZ_ACP_AGENTS`; default 10). Reserved env keys (relay URL, key, gate, agents, …) are rejected. Shell tool calls need user approval (allow once/always).
- Persona packs are not importable; only `.agent.json`/`.team.json` snapshots.

## 5. Git: relay vs Gitea

- Relay git: `<relay>/git/<owner>/<repo>`, NIP-98 auth (`git-credential-nostr`, pre-wired in sprig), NIP-34 announce (`buzz repos create --channel` = ACL), `buzz pr open --commit --clone --channel`, `buzz issues create --channel`, `buzz projects …`; commands return `buzz://` links for rich cards.
- Desktop Projects only accept clone URLs on the active relay (`validate_workspace_clone_url`) → Gitea repos can't be attached; in-app diffs/PR review need relay-hosted git.
- Forge status: hosting ✅, workflows ✅ (webhook/schedule/message triggers; approval gates not resumable; send_dm/topic stubbed), merge coordinator 📋, no CI runner.
- Gitea (1.27.3 here) + Actions runner + branch protection = shipping external validation. Split: Gitea = record + CI + merge; Buzz = request/coordinate/report. Agents push with a scoped token, open PR via API, post URL in thread.

## 6. Team blueprint (plan 08 input)

assistant (app/server, #general) · builder per repo (server, volume, thread sessions, allowlist, Gitea token) · reviewer (server, read-only persona) · triage (optional, heartbeat) · CI = Gitea Actions. One project channel per repo with only its builder+reviewer; jobs are threads. Per-role env: own key, `BUZZ_ACP_RESPOND_TO=allowlist`, `BUZZ_ACP_SESSION_POLICY=thread`, `BUZZ_AGENT_REQUIRE_REPLY=1`, `BUZZ_ACP_AGENTS=1`, persona file, `RUST_LOG=info`, `network_mode: host`, `OPENAI_COMPAT_*` → `LITELLM_PUBLIC_URL`. Stack additions: `gitea-runner` profile, workflow template, branch protection, personas/, per-role services, job smoke test.

## 7. Source pointers (in ~/code/buzz)

`crates/buzz-acp/README.md`, `crates/buzz-acp/src/base_prompt.md`, `crates/buzz-agent/README.md` (§Reply Guard), `docs/MCP_DRIVEN_HOOKS.md`, `crates/buzz-persona/PERSONA_PACK_SPEC.md` (§5 prompt layers, §12 anti-patterns), `examples/meadow-core/`, `VISION_AGENT.md`, `VISION_PROJECTS.md`, `VISION_REMOTE_AGENTS.md`, `docs/practical-information-flow-for-buzz-agents.md`, `docs/nips/NIP-OA.md`, `NIP-AA.md`, `docs/git-on-object-storage.md`, `desktop/src-tauri/src/managed_agents/{global_config,effective_config,runtime.rs,reserved_env_keys.rs}`, `desktop/src-tauri/src/commands/project_git_exec.rs` (clone-URL validation).
