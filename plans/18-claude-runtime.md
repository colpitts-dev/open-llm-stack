# Plan 18 — Claude Code as a team runtime: local models through the gateway, hosted models from an opt-in include

**Spec:** `docs/spec.md` (this plan adds §5.20 and gates G55–G60). **Rules:** `AGENTS.md` (the registry stays open weights and local; hosted entries, closed or open weights, live only in the opt-in include file this plan adds). **Knowledge:** plan 12 §5.13 (runtime switch, goose image, the measured comparison), plan 14 §5.15 (context contract), plan 15 (per-client virtual keys, cost ledger), plan 16 (`teams/<team>/team.toml`, `runtime` and `model` per member, the renderer's `IMAGES` map).
**Sequence:** 18 (after 16.5 and 17; the builder is whoever `team-roster.py role builder` names, Gilfoyle on the default team since plan 16.5). Requires plans 15 and 16 executed (17 is independent). Adds one image (`agents/claude/Dockerfile`, the second opt-in build after goose), one probe, one include file for the registry with a switch script, one entrypoint branch, four make targets, `.env` lines, docs. No new service, port or network.
**Execute with:** `/execute plans/18-claude-runtime.md`
**Network:** `docker pull` and the two pinned `npm install`s inside the image build; hosted models need egress to their provider. Everything else below was verified on the reference host on 2026-09-14 (Node 22.22 on the host for the scratch runs; the image pins Node 22).

---

## 1. Overview

**Intent.** Give the team a third runtime, the Claude Code harness (built-in tools, compaction, subagents), in two modes, each switched per member in `team.toml` and off by default. Both go through LiteLLM with the member's virtual key: one gateway, one ledger, budgets and attribution unchanged.

| Mode | Model | Where the model runs | Standing |
|---|---|---|---|
| **A** local | any entry in `proxy/config.yaml` (open weights, on this host) | the backend behind `LLM_BASE_URL` | unsupported by Anthropic ("doesn't support routing Claude Code to non-Claude models through any gateway"), documented by LiteLLM and by Fireworks' own `fireconnect` CLI; the binary is unmodified; the registry rule untouched |
| **B** hosted | an entry in `proxy/frontier.yaml`: `claude-sonnet-5` (default), `claude-haiku-4-5`, or hosted open weights such as Kimi and GLM on Fireworks, or any other provider LiteLLM speaks | the provider, with the deployment's own API key in `.env` | the provider's commercial terms, billed to the key owner; code leaves the host: explicit opt-in per member |

**Not in this plan: a person's Claude subscription.** Anthropic's terms ([Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance), fetched 2026-09-14) reserve subscription OAuth for "ordinary use of Claude Code and other native Anthropic applications", say developers building products "including those using the Agent SDK, should use API key authentication", and forbid tools that "collect, store, or intermediate Claude.ai credentials". The ACP adapter used here refuses subscriptions by design (`"This integration does not support using claude.ai subscriptions."` in its code). A subscription-driven agent would sit on a carve-out for "the unmodified Claude Code binary" and put the developer's own account at risk under "ordinary, individual usage". Decided 2026-09-14: not built, not shipped; mode B on a Console key with a budget is the cheap path (Sonnet 5 at $2 / $10 per MTok prices a small PR near $3). If that ever matters commercially, ask Anthropic in writing first (the legal page says contact sales for permitted authentication questions).

**Best practices applied.** Change one thing at a time and measure (plan 12's table, repeated per mode); one gateway, one ledger (LiteLLM prices Anthropic and Fireworks models from its built-in map, per-agent virtual keys attribute spend); hosted egress is an explicit per-member opt-in with a README warning and a switch that only turns on providers whose key is present; nothing downloaded at run time (both packages pinned in the image); `proxy/config.yaml` stays open weights and local, enforced by the smoke; feature flags default off so `make init && make up && make test` is unchanged.

**Design.**

| Piece | Where | What |
|---|---|---|
| image | `agents/claude/Dockerfile`, `make claude-image` → `open-llm-stack/claude-agent:2.1.270` | `node:22-bookworm-slim` by digest + `@anthropic-ai/claude-code@2.1.270` (unmodified, as published) + `@agentclientprotocol/claude-agent-acp@0.77.0` + the sprig binaries (`buzz`, `buzz-acp`, `buzz-dev-mcp`, git helpers) as in the goose image |
| member switch | `team.toml`: `runtime = "claude"`, `model = "<registry or frontier name>"`, `effort = "low\|medium\|high\|xhigh\|max"` (optional) | plan 16 renderer: `IMAGES["claude"]`, env `TEAM_RUNTIME=claude`, `TEAM_EFFORT`; `make member-claude N=<m> MODE=local\|hosted [M=<model>]` sets the keys, renders, recreates one container |
| entrypoint | `scripts/team-entrypoint.sh` branch `claude)` | `ANTHROPIC_BASE_URL=<LiteLLM root>`, `ANTHROPIC_AUTH_TOKEN=<member virtual key>`, `ANTHROPIC_MODEL=<model>`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `CLAUDE_CONFIG_DIR=/home/agent/.claude`, telemetry and auto-update off, persona written to `/home/agent/.claude/persona.md` and `CLAUDE.md` regenerated from persona + the agent's own `memory.md` (never overwriting it), agent command `claude-agent-acp`, `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` unset so nothing but the gateway credential is ever in play |
| probe | `agents/claude/acp-probe.py` (Python, stdlib) | initialize → session/new → one prompt, prints updates and the stop reason; the gate for the adapter in both modes |
| hosted registry | `proxy/frontier.yaml.example` (provider blocks: Anthropic, Fireworks, a commented OpenAI-compatible block), `proxy/frontier.yaml` (gitignored; `make init` writes `model_list: []`), `include: [frontier.yaml]` in `proxy/config.yaml.example`, compose mount `./proxy/frontier.yaml:/app/frontier.yaml:ro`, `scripts/frontier.sh on\|off\|status` behind `make frontier-on` / `make frontier-off` | `on` copies only the provider blocks whose key is set in `.env`, then reloads; LiteLLM `include` appends `model_list`; a missing file makes LiteLLM refuse to start, so `make init` always creates it |
| smoke rule | `scripts/smoke-test.sh` `test_litellm` | `proxy/config.yaml` on disk names no closed-weight model or router; every `/v1/models` entry with `execution_locus: cloud` is a `model_name` in `proxy/frontier.yaml` on disk; every closed-weight id in `/v1/models` has `execution_locus: cloud` |
| measurement | plan 12's table per mode and per model: time to PR, calls, input/output tokens, tool calls, persona misses, cost from LiteLLM spend | |

**Measured today (reference host).** Claude Code 2.1.270 on Node 22 answers through LiteLLM to `ornith-max`: `--output-format json` → `{"subtype":"success","stop_reason":"end_turn","num_turns":2,"duration_ms":6033,"total_cost_usd":0.01266,"usage":{"input":2377,"output":31},"session_id":"447e…","modelUsage":["ornith-max"]}`; through the adapter: `initialize` → `protocolVersion 1, authMethods []`, `session/new` → `configOptions [mode, model, effort, fast]`, modes `default, acceptEdits, plan, auto, bypassPermissions`, a prompt → `stopReason end_turn`, usage 28 827 input tokens (Claude Code's own system prompt and tool schemas: prefill per turn on a local hybrid model, cached by the per-agent slot from plan 14), the answer arrived as `agent_thought_chunk` only (the local reasoning model answered inside its thinking block: a persona-quality item for G56, lever in §5). Without any credential the adapter returns `{"code":-32000,"message":"Authentication required"}` on the prompt. LiteLLM's `/v1/messages` and `/v1/messages/count_tokens` answer for `ornith-max` (200) and map the model's reasoning to a `thinking` block ahead of the text.

**Success criteria.** G55 — `make claude-image` builds; `claude --version` prints `2.1.270 (Claude Code)`; `acp-probe.py` completes initialize, session/new and one prompt against the adapter in the image with the local model. G56 (mode A) — `make member-claude N=$(python3 scripts/team-roster.py role builder | awk 'NR==1') MODE=local`, two consecutive `make team-smoke` passes, the metrics row recorded, no `ANTHROPIC_API_KEY` in the container, spend rows under Dinesh's alias. G57 (mode B, Anthropic) — `ANTHROPIC_API_KEY` in `.env`, `make frontier-on` lists the Anthropic block as on, `make member-claude N=$(python3 scripts/team-roster.py role builder | awk 'NR==1') MODE=hosted` (Sonnet 5), two smoke passes, spend rows non-zero at Anthropic rates under Dinesh's alias, `make test` passes with the new rule. G58 (mode B, Fireworks) — `FIREWORKS_AI_API_KEY` in `.env`, `make frontier-on` adds the Fireworks block, `make member-claude N=$(python3 scripts/team-roster.py role builder | awk 'NR==1') MODE=hosted M=kimi-k2p7-code`, one smoke pass, spend rows non-zero under `fireworks_ai/…`; `make frontier-off` then `make test` unchanged. G59 (flags off) — every member on `buzz-agent`, `frontier.yaml` empty: `make test` output identical to plan 16's run; no team container carries an `ANTHROPIC_*` or `CLAUDE_*` variable. G60 (memory survives a restart) — a line written to `memory.md` inside the container is still there after `--force-recreate`, is present in the regenerated `CLAUDE.md`, and at least one session transcript exists under `projects/`.

**Out of scope.** Subscription credentials (decided above); an escalation cascade (per-member switch only); Bedrock, Agent Platform and Foundry (route them through LiteLLM as registry entries when needed); MCP servers passed to the adapter (buzz-dev-mcp stays off as with goose: Claude Code has its own tools, the `buzz` CLI is on `PATH`); Fireworks' `fireconnect` CLI (it configures Claude Code for Fireworks directly, bypassing the gateway and the ledger).

## 2. Relevant files

| Path | Action |
|---|---|
| `agents/claude/Dockerfile` | new: the runtime image |
| `agents/claude/acp-probe.py` | new: handshake and one-prompt probe |
| `proxy/frontier.yaml.example` | new: provider blocks (Anthropic, Fireworks, commented OpenAI-compatible) |
| `scripts/frontier.sh` | new: `on` (blocks with a key present), `off`, `status` |
| `proxy/config.yaml.example` | `include: [frontier.yaml]` at the top; header comment |
| `scripts/init.sh` | create `proxy/frontier.yaml` with `model_list: []` when missing |
| `scripts/team-entrypoint.sh` | `claude)` branch; persona/memory split (Task 5) |
| `teams/<team>/personas/<member>.md` | one line telling the agent to write durable notes to `~/.claude/memory.md`, not `CLAUDE.md` (Task 5) |
| `scripts/team-render.py` (plan 16) | `IMAGES["claude"]`, `effort` key, env line |
| `scripts/smoke-test.sh` | hosted-models rule; `test_team_runtime` accepts `claude` |
| `docker-compose.yml` | `litellm` mounts `./proxy/frontier.yaml:/app/frontier.yaml:ro` |
| `Makefile` | `claude-image`, `member-claude`, `frontier-on`, `frontier-off` |
| `.env.example`, `.gitignore` | `ANTHROPIC_API_KEY=`, `FIREWORKS_AI_API_KEY=`; `proxy/frontier.yaml` ignored |
| `docs/spec.md` §1 (image row), §3, §5.20, §7; `README.md`; `AGENTS.md` | docs, gates, status |

## 3. Dependencies and verified facts (reference host, 2026-09-14)

- **Packages.** `@anthropic-ai/claude-code@2.1.270`: `bin.claude`, `engines.node >=22.0.0`, 214 MB installed. `@agentclientprotocol/claude-agent-acp@0.77.0`: `bin.claude-agent-acp`, `engines.node >=22`, depends on `@anthropic-ai/claude-agent-sdk 0.3.270` (bundles its own copy of the CLI), `@agentclientprotocol/sdk 1.4.0`, `zod 4.6.5`; 271 MB with the SDK. Both installed on the host (`npm view` and a scratch `npm install`) and run on Node 22.22.
- **The pin stays at 2.1.270 for this execution.** Checked 2026-09-15: `npm view @anthropic-ai/claude-code version` → `2.1.272`, and the reference host's own CLI is `2.1.272 (Claude Code)`. Every measurement in this plan was taken against 2.1.270, so execute against 2.1.270 and keep the gate honest. Bump afterwards as its own change, per §5 Pin bumps.
- **Base image.** `node:22-bookworm-slim`, linux/amd64 digest `sha256:4d676821dff059fd00d277ee4261ef34ea712317fed0737c03941481b5760c96` (`docker manifest inspect`, 2026-09-14). Record it in spec §1 with the date.
- **Adapter behaviour** (from its `dist/*.js`): reads `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_CUSTOM_HEADERS`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_EXECUTABLE`, `CLAUDE_CODE_USE_BEDROCK`/`_VERTEX`; refuses subscriptions (`CLAUDE_SUBSCRIPTION_NOT_SUPPORTED_REASON = "claude_subscription_not_supported"`); config ids `mode` (`default`, `acceptEdits`, `plan`, `auto`, `bypassPermissions`), `model`, `effort`, `fast`; accepts client MCP servers on `session/new`.
- **buzz-acp** (`--help`): `--agent-command`/`BUZZ_ACP_AGENT_COMMAND`, `--agent-args`, `--mcp-command` (default `buzz-dev-mcp`, `""` disables), `--system-prompt-file` (`BUZZ_ACP_SYSTEM_PROMPT_FILE=/home/agent/.prompt.md`), `--permission-mode` (default `bypassPermissions`, "for agents that support `session/set_config_option` with `configId: "mode"` (e.g. `claude-agent-acp`)"), `--effort-level` (through `set_config_option` when advertised, non-fatal otherwise), `--session-title`. Its system prompt delivery is adapter-specific (goose: `_goose/unstable/session/system-prompt/set`); this plan delivers the persona through Claude Code's own `CLAUDE.md`, so it does not depend on buzz-acp support. **Verify at execution** that a probe prompt "what is your name" answers with the persona name.
- **CLI flags present in 2.1.270:** `-p`, `--output-format`, `--input-format stream-json`, `--verbose`, `--resume`, `--session-id`, `--permission-mode`, `--permission-prompts`, `--allowedTools`, `--append-system-prompt-file`, `--effort`, `--model`, `--settings`, `--mcp-config`, `--strict-mcp-config`, `--bare`.
- **ACP shapes** ([initialization](https://agentclientprotocol.com/protocol/initialization), [session setup](https://agentclientprotocol.com/protocol/session-setup), [prompt turn](https://agentclientprotocol.com/protocol/prompt-turn)): newline-delimited JSON-RPC 2.0 over stdio; `initialize` → `{protocolVersion: 1, agentCapabilities, authMethods: [], agentInfo}`; `session/new {cwd, mcpServers}` → `{sessionId}`; `session/prompt {sessionId, prompt: [{type: "text", text}]}` → `{stopReason}` in `end_turn | max_tokens | max_turn_requests | refusal | cancelled`; `session/update` variants `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`; `session/request_permission` answered with `{outcome: {outcome: "selected", optionId}}`.
- **Gateway rules Claude Code needs** ([compatibility guide](https://code.claude.com/docs/en/llm-gateway-protocol)): serve `/v1/messages` (and optionally `/v1/messages/count_tokens`), stream, forward `anthropic-version` and `anthropic-beta` verbatim and the body fields with them; `ANTHROPIC_AUTH_TOKEN` is sent as `Authorization: Bearer`; model names behind a custom base URL are passed through unchecked; `CLAUDE_CODE_ATTRIBUTION_HEADER=0` keeps the attribution block out of non-Anthropic upstreams. LiteLLM's tutorial ([Claude Code with non-Anthropic models](https://docs.litellm.ai/docs/tutorials/claude_non_anthropic_models)) uses exactly `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` and `/v1/messages`.
- **LiteLLM.** `POST /v1/messages` with `model: ornith-max` → `type message`, `stop_reason end_turn`, content `[thinking, text]`; with `max_tokens 32` the text was empty (thinking consumed the budget); `/v1/messages/count_tokens` → 200. `include` semantics (`/app/litellm/proxy/proxy_server.py:3509–3533`): each included file resolves against the config's directory, must exist (`FileNotFoundError`), list keys such as `model_list` are extended, other keys replaced; the registry is mounted at `/app/config.yaml` (`docker-compose.yml:107`), so the include mounts at `/app/frontier.yaml`. Fireworks in LiteLLM ([provider page](https://docs.litellm.ai/docs/providers/fireworks_ai)): `fireworks_ai/<slug>` (short slug expands to `accounts/fireworks/models/<slug>`), key `FIREWORKS_AI_API_KEY`, tool calling and streaming supported. LiteLLM prices `anthropic/claude-sonnet-5` and `fireworks_ai/…` from its built-in map; **verify at execution** that a hosted call's spend row is non-zero without any rate in `frontier.yaml`, and that a `fireworks_ai/` model answers on `/v1/messages` through the adapter (the translation path proven for Ollama today).
- **Fireworks slugs** ([fireworks.ai/kimi](https://fireworks.ai/kimi), [GLM 5.2 announcement](https://fireworks.ai/blog/glm-5p2), 2026-09-14): `kimi-k2p7-code` (262 144 context, $0.95 / $4 per MTok, serverless), `kimi-k2p6`, `kimi-k2-thinking`, `kimi-k3` (1 048 576 context, $3 / $15), `glm-5p2` (serverless; **verify** its context length on the model page at execution). Slugs change with releases: the example file names them with the date and `frontier.sh status` prints what the provider lists (`GET https://api.fireworks.ai/inference/v1/models`).
- **`frontier.sh` filter, dry run on the host** (2026-09-14): `bash -n` clean; with only `ANTHROPIC_API_KEY` set the filter keeps `claude-sonnet-5` and `claude-haiku-4-5`; with both keys set it keeps four entries; the kept/skipped loop prints `on: anthropic skipped: fireworks openai-compatible`; the generated file parses as YAML with the four `model_name`s.
- **Plan 16 hooks.** `IMAGES = {"buzz-agent": …, "goose": …}` in `scripts/team-render.py`; member keys `runtime`, `model`; the renderer validates `runtime` against `IMAGES`; `make member-runtime N= R=`; the entrypoint's `case "${TEAM_RUNTIME}"` with the `goose)` branch as the pattern (`scripts/team-entrypoint.sh:69–77` today).
- **Plan 15 hooks.** `OPENAI_COMPAT_API_KEY` is the member's virtual key with a master-key fallback; `OPENAI_COMPAT_BASE_URL` = LiteLLM root + `/v1`, so `ANTHROPIC_BASE_URL` = that value without `/v1`.
- **Pricing for mode B** (skill table, cached 2026-06-24; Fireworks page above): `claude-sonnet-5` $2 / $10 per MTok, `claude-haiku-4-5` $1 / $5, 1M context on Sonnet 5; effort `xhigh` recommended for coding on Sonnet 5; Kimi K2.7 Code $0.95 / $4.

## 4. Tasks

### Task 1 — `agents/claude/Dockerfile` and `make claude-image`

```dockerfile
# Claude Code runtime for a team member (plan 18, opt-in). Node 22 base by digest, the pinned unmodified Claude Code
# CLI, the pinned ACP adapter, and the sprig binaries (buzz CLI, harness, git helpers) as in the goose image.
# The CLI is installed as published by Anthropic and never patched (a condition of Anthropic's terms).
FROM node:22-bookworm-slim@sha256:4d676821dff059fd00d277ee4261ef34ea712317fed0737c03941481b5760c96
ARG CLAUDE_CODE_VERSION=2.1.270
ARG CLAUDE_ACP_VERSION=0.77.0
RUN apt-get update && apt-get install -y --no-install-recommends bash git curl ca-certificates procps python3 \
    && rm -rf /var/lib/apt/lists/* \
    && (useradd -m -u 1000 -d /home/agent -s /bin/bash agent || usermod -l agent -d /home/agent -m node)
RUN npm install -g --no-audit --no-fund "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@agentclientprotocol/claude-agent-acp@${CLAUDE_ACP_VERSION}" \
    && claude --version
COPY --from=ghcr.io/block/buzz-sprig:sha-e17cdd9 /usr/local/bin/sprig /usr/local/bin/sprig
COPY --from=ghcr.io/block/buzz-sprig:sha-e17cdd9 /usr/local/bin/sprig-entrypoint /usr/local/bin/sprig-entrypoint
RUN for b in buzz buzz-acp buzz-agent buzz-dev-mcp git-credential-nostr git-sign-nostr rg; do ln -s /usr/local/bin/sprig /usr/local/bin/$b; done
USER agent
WORKDIR /home/agent
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
```

`python3` is for the probe inside the image. The `node` image ships a `node` user with uid 1000; the `useradd || usermod` keeps uid 1000 as `agent` either way (**verify at execution**: `id agent` → `uid=1000`). `Makefile`:

```make
claude-image:    ## build open-llm-stack/claude-agent:2.1.270, the Claude Code runtime image (plan 18; npm install inside the build)
	docker build -t open-llm-stack/claude-agent:2.1.270 agents/claude
```

### Task 2 — `agents/claude/acp-probe.py`

```python
#!/usr/bin/env python3
"""ACP probe (plan 18): initialize -> session/new -> one prompt against any ACP agent on stdio; prints every update
and the stop reason; auto-answers permission requests with the first option.
Usage: acp-probe.py <cwd> "<prompt text>" -- <agent command...>"""
import json, queue, subprocess, sys, threading, time
cwd, text = sys.argv[1], sys.argv[2]; cmd = sys.argv[sys.argv.index("--") + 1:]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, text=True, bufsize=1)
q = queue.Queue()
threading.Thread(target=lambda: [q.put(l) for l in p.stdout], daemon=True).start()
def send(o): p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
def wait_id(i, timeout=120):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try: line = q.get(timeout=1)
        except queue.Empty: continue
        try: m = json.loads(line)
        except Exception: continue
        if m.get("method") == "session/update":
            u = m["params"]["update"]; c = u.get("content")
            print("update:", u.get("sessionUpdate"), (c.get("text", "")[:80] if isinstance(c, dict) else u.get("title", "")), flush=True)
        elif m.get("method") == "session/request_permission":
            opt = m["params"]["options"][0]["optionId"]; send({"jsonrpc": "2.0", "id": m["id"], "result": {"outcome": {"outcome": "selected", "optionId": opt}}}); print("permission auto:", opt)
        elif m.get("id") == i: return m
    raise SystemExit(f"timeout waiting for id {i}")
send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}}})
r0 = wait_id(0); print("initialize:", json.dumps({k: r0["result"].get(k) for k in ("protocolVersion", "authMethods")}))
send({"jsonrpc": "2.0", "id": 1, "method": "session/new", "params": {"cwd": cwd, "mcpServers": []}})
r1 = wait_id(1); sid = r1["result"]["sessionId"]; print("session:", sid[:8], "configOptions:", [o["id"] for o in r1["result"].get("configOptions", [])])
send({"jsonrpc": "2.0", "id": 2, "method": "session/prompt", "params": {"sessionId": sid, "prompt": [{"type": "text", "text": text}]}})
r2 = wait_id(2, 300); print("prompt result:", json.dumps(r2.get("result") or r2.get("error"))[:300])
p.stdin.close(); p.terminate()
```

Verified as written against the adapter (mode A: `end_turn`) and against the adapter with no credential (`Authentication required`).

### Task 3 — the hosted registry: `proxy/frontier.yaml.example`, `scripts/frontier.sh`, make targets

`proxy/frontier.yaml.example` (provider blocks delimited by `# provider:` markers that `frontier.sh` reads; a block is copied only when its key variable is set in `.env`):

```yaml
# Hosted models for the team, plan 18 mode B. INCLUDED by proxy/config.yaml; the only place a hosted model (closed or
# open weights) may appear: proxy/config.yaml stays open weights and local (AGENTS.md). Off = model_list: [] (what
# make init writes). On = make frontier-on: scripts/frontier.sh copies the blocks whose key is set in .env, then reloads.
# Spend is priced by LiteLLM's built-in map and attributed per member by their virtual key (plan 15). Code sent to
# these models leaves the host. Slugs and prices as listed by the providers on 2026-09-14; re-check before use.
model_list:
# provider: anthropic key: ANTHROPIC_API_KEY
  - model_name: claude-sonnet-5
    litellm_params:
      model: anthropic/claude-sonnet-5
      api_key: os.environ/ANTHROPIC_API_KEY
    model_info:
      mode: chat
      context_window: 1000000
      max_input_tokens: 717232          # 1000000 - 32768 - 250000 (plan 14 formula, margin = window / 4)
      max_output_tokens: 32768
      execution_locus: cloud
      model_revision: "anthropic:claude-sonnet-5:2026-09-14"
  - model_name: claude-haiku-4-5
    litellm_params:
      model: anthropic/claude-haiku-4-5
      api_key: os.environ/ANTHROPIC_API_KEY
    model_info:
      mode: chat
      context_window: 200000
      max_input_tokens: 117232          # 200000 - 32768 - 50000
      max_output_tokens: 32768
      execution_locus: cloud
      model_revision: "anthropic:claude-haiku-4-5:2026-09-14"
# provider: fireworks key: FIREWORKS_AI_API_KEY
  - model_name: kimi-k2p7-code                   # open weights, hosted; serverless on Fireworks, $0.95 / $4 per MTok
    litellm_params:
      model: fireworks_ai/kimi-k2p7-code
      api_key: os.environ/FIREWORKS_AI_API_KEY
    model_info:
      mode: chat
      context_window: 262144
      max_input_tokens: 163840          # 262144 - 32768 - 65536
      max_output_tokens: 32768
      execution_locus: cloud
      model_revision: "fireworks:kimi-k2p7-code:2026-09-14"
  - model_name: glm-5p2                          # open weights, hosted; verify the context length on the model page
    litellm_params:
      model: fireworks_ai/glm-5p2
      api_key: os.environ/FIREWORKS_AI_API_KEY
    model_info:
      mode: chat
      context_window: 131072
      max_input_tokens: 65536           # 131072 - 32768 - 32768
      max_output_tokens: 32768
      execution_locus: cloud
      model_revision: "fireworks:glm-5p2:2026-09-14"
# provider: openai-compatible key: HOSTED_API_KEY
#  - model_name: my-hosted-model                 # any OpenAI-compatible provider: set HOSTED_API_BASE and HOSTED_API_KEY in .env
#    litellm_params:
#      model: openai/<provider model id>
#      api_base: os.environ/HOSTED_API_BASE
#      api_key: os.environ/HOSTED_API_KEY
#    model_info:
#      mode: chat
#      context_window: 131072
#      max_input_tokens: 65536
#      max_output_tokens: 32768
#      execution_locus: cloud
```

`scripts/frontier.sh`:

```bash
#!/usr/bin/env bash
# Hosted-model switch (plan 18). on: write proxy/frontier.yaml from the example, keeping only the provider blocks whose
# key variable is set in .env, then reload LiteLLM. off: empty model_list, reload. status: what is on and what each
# provider currently lists. Blocks are delimited by "# provider: <name> key: <VAR>" lines in the example.
set -euo pipefail
cd "$(dirname "$0")/.."
# Export only the provider keys, rather than sourcing .env whole: one unquoted value with a space in it would
# otherwise run as a command and kill the script under `set -e`, before anything is written.
eval "$(grep -E '^(ANTHROPIC_API_KEY|FIREWORKS_AI_API_KEY|HOSTED_API_KEY|HOSTED_API_BASE)=' ./.env 2>/dev/null | sed 's/^/export /')"
EX=proxy/frontier.yaml.example; OUT=proxy/frontier.yaml
case "${1:-status}" in
  on)
    { echo "# generated by scripts/frontier.sh on $(date -u +%FT%TZ) from $EX; edit the example, not this file"; echo "model_list:"; } > "$OUT"
    kept=""; skipped=""
    awk '
      /^# provider: / { split($0, p, " "); var=p[5]; on = (ENVIRON[var] != ""); next }
      /^model_list:/ { next }
      { if (on) print }' "$EX" >> "$OUT"
    # A provider whose block is commented out in the example (openai-compatible) contributes only comment lines,
    # leaving a bare "model_list:" that YAML reads as null, not []. LiteLLM extends list keys from an include and
    # refuses to start on the result, taking the stack with it. Fall back to an explicit empty list.
    grep -qE '^[[:space:]]+- model_name:' "$OUT" || printf 'model_list: []\n' > "$OUT"
    for line in $(grep -E '^# provider: ' "$EX" | awk '{print $3":"$5}'); do name=${line%%:*}; var=${line##*:}; if [ -n "${!var:-}" ]; then kept="$kept $name"; else skipped="$skipped $name"; fi; done
    docker compose restart litellm >/dev/null && echo "hosted models on:${kept:- none}${skipped:+ (no key, skipped:$skipped)}; make test applies the hosted-models rule" ;;
  off)
    printf 'model_list: []\n' > "$OUT" && docker compose restart litellm >/dev/null && echo "hosted models off" ;;
  status)
    if grep -qE '^\s+- model_name:' "$OUT" 2>/dev/null; then echo "on: $(grep -E '^\s+- model_name:' "$OUT" | awk '{print $3}' | tr '\n' ' ')"; else echo "off"; fi
    [ -n "${FIREWORKS_AI_API_KEY:-}" ] && curl -fsS -H "Authorization: Bearer $FIREWORKS_AI_API_KEY" https://api.fireworks.ai/inference/v1/models | jq -r '.data[].id' | grep -iE 'kimi|glm' | head -20 || true ;;
  *) echo "usage: scripts/frontier.sh on|off|status"; exit 1 ;;
esac
```

(`bash -n` and a dry run of the filter on the example are part of G57.) `proxy/config.yaml.example`: first non-comment lines `include:\n  - frontier.yaml   # plan 18: hosted models live only there; make frontier-on|off`. `scripts/init.sh`: `[ -f proxy/frontier.yaml ] || printf 'model_list: []\n' > proxy/frontier.yaml`. `.gitignore`: `proxy/frontier.yaml`. `docker-compose.yml` `litellm` volumes: `- ./proxy/frontier.yaml:/app/frontier.yaml:ro   # plan 18; make init creates it (LiteLLM refuses to start on a missing include)`. `.env.example`, under the LLM backend section:

```
# Hosted models (plan 18 mode B, opt-in): keys for the provider blocks in proxy/frontier.yaml.example; make frontier-on keeps
# only the blocks whose key is set. Each key is the deployment's own; usage is billed to its owner. Never a person's subscription token.
ANTHROPIC_API_KEY=
FIREWORKS_AI_API_KEY=
```

`Makefile`:

```make
frontier-on:     ## hosted models on: proxy/frontier.yaml from the example, providers with a key in .env, reload (plan 18, mode B)
	./scripts/frontier.sh on
frontier-off:    ## hosted models off: empty model_list, reload (plan 18)
	./scripts/frontier.sh off
```

Smoke (`test_litellm`), replacing the closed-weight check:

```bash
  echo "--- litellm: proxy/config.yaml is open weights and local; hosted models only from the frontier include (plan 18)"
  if grep -iE 'claude|anthropic|gpt-|gemini|router|fireworks|execution_locus: cloud' proxy/config.yaml | grep -vE '^\s*#' | grep -q .; then fail "hosted or closed-weight entry in proxy/config.yaml (they belong in proxy/frontier.yaml)"; fi
  curl -fsS -H "$auth" "$base/v1/model/info" | jq -r '.data[] | "\(.model_name) \(.model_info.execution_locus // "local") \(.litellm_params.model)"' \
    | while read -r m locus lm; do
        case "$lm" in anthropic/*|openai/gpt-*|gemini/*|fireworks_ai/*) [ "$locus" = cloud ] || fail "$m ($lm) is hosted but not marked execution_locus: cloud" ;; esac
        if [ "$locus" = cloud ]; then grep -qE "^\s+- model_name: $m\b" proxy/frontier.yaml || fail "$m is marked cloud but is not in proxy/frontier.yaml"; echo "$m: hosted entry ($lm)"; fi
      done
```

### Task 4 — `team.toml` keys, renderer, `make member-claude`

`scripts/team-render.py` (plan 16): `IMAGES["claude"] = "open-llm-stack/claude-agent:2.1.270"`; optional member key `effort = "low|medium|high|xhigh|max"` (validated), rendered as `TEAM_EFFORT: <value or empty>`. `Makefile`:

```make
member-claude:   ## put one member on the Claude Code runtime: make member-claude N=$(python3 scripts/team-roster.py role builder | awk 'NR==1') MODE=local|hosted [M=<model>] (plan 18)
	@test -n "$(N)" && test -n "$(MODE)" || { echo "usage: make member-claude N=<member> MODE=local|hosted [M=<model>]"; exit 1; }
	@case "$(MODE)" in \
	  local)  python3 scripts/team-roster.py set $(N) runtime claude && python3 scripts/team-roster.py set $(N) model "$${M:-$$(python3 scripts/team-roster.py get model)}" ;; \
	  hosted) grep -qE '^\s+- model_name:' proxy/frontier.yaml || { echo "no hosted models on: make frontier-on first"; exit 1; }; \
	          python3 scripts/team-roster.py set $(N) runtime claude && python3 scripts/team-roster.py set $(N) model "$${M:-claude-sonnet-5}" ;; \
	  *) echo "MODE must be local or hosted"; exit 1 ;; esac
	$(MAKE) team-render && docker compose up -d --force-recreate --wait $(N) && docker compose logs --since 1m --no-log-prefix $(N) | grep -E 'runtime=|agent initialized|model=' | cut -c1-140
```

`member-runtime` (plan 16) accepts `claude` (validation string and usage line). A member switched to a hosted model that is later turned off with `make frontier-off` fails its registry read at start with plan 08's `model '<name>' is not in proxy/config.yaml` message: intended.

### Task 5 — the entrypoint branch

In `scripts/team-entrypoint.sh`, next to `goose)`:

```bash
  claude)
    command -v claude >/dev/null || { echo "TEAM_RUNTIME=claude but this image has no claude binary (make claude-image; make member-claude N=$TEAM_MEMBER MODE=…)" >&2; exit 1; }
    # Policy and memory are separate files with separate lifetimes. /home/agent is a persisted named volume
    # (plan 16 renderer: team-<member>:/home/agent), so anything written here survives --force-recreate.
    # persona.md is ours and is refreshed every boot; memory.md is the agent's and is created once, never
    # overwritten; CLAUDE.md is regenerated from the two so the session loads both.
    mkdir -p "$CLAUDE_CONFIG_DIR"
    cp /home/agent/.prompt.md "$CLAUDE_CONFIG_DIR/persona.md"
    [ -f "$CLAUDE_CONFIG_DIR/memory.md" ] || printf '# Memory\n\nDurable notes. This file is never overwritten by the entrypoint.\n\n' > "$CLAUDE_CONFIG_DIR/memory.md"
    cat "$CLAUDE_CONFIG_DIR/persona.md" "$CLAUDE_CONFIG_DIR/memory.md" > "$CLAUDE_CONFIG_DIR/CLAUDE.md"
    unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN   # only the gateway credential is ever in play
    export ANTHROPIC_BASE_URL="${OPENAI_COMPAT_BASE_URL%/v1}" ANTHROPIC_AUTH_TOKEN="$OPENAI_COMPAT_API_KEY" \
           ANTHROPIC_MODEL="$OPENAI_COMPAT_MODEL" ANTHROPIC_DEFAULT_HAIKU_MODEL="${TEAM_FAST_MODEL:-$OPENAI_COMPAT_MODEL}" \
           CLAUDE_CODE_ATTRIBUTION_HEADER=0 BUZZ_ACP_MCP_COMMAND="" BUZZ_ACP_PERMISSION_MODE=bypassPermissions \
           BUZZ_ACP_AGENT_COMMAND=claude-agent-acp BUZZ_ACP_AGENT_ARGS=""
    [ -n "${TEAM_EFFORT:-}" ] && export BUZZ_ACP_EFFORT_LEVEL="$TEAM_EFFORT"
    echo "runtime=claude model=$ANTHROPIC_MODEL via $ANTHROPIC_BASE_URL (claude $(claude --version | cut -d' ' -f1), adapter $(claude-agent-acp --version 2>/dev/null || echo 0.77.0))" ;;
```

`OPENAI_COMPAT_MODEL` is the member's `model` (plan 16 renders it): a `proxy/config.yaml` name in mode A, a `frontier.yaml` name in mode B; the entrypoint's registry read (plan 08) resolves caps for either since `/model/info` lists included entries (**verify at execution**). `TEAM_FAST_MODEL` (optional, renderer key `fast_model`) names the Haiku-class model for Claude Code's fast lane; default is the member's own model.

**The persona must tell the agent where to write.** `CLAUDE.md` is regenerated at every boot, so a note written there is lost. Add one line to the persona text in `teams/<team>/personas/<member>.md`: *"Record anything you need to remember between sessions in `~/.claude/memory.md`. Do not edit `CLAUDE.md`; it is regenerated at start-up."* Without that line the split above changes nothing — the agent still writes to the file that gets rebuilt.

**Verify at execution, before relying on the concatenation.** Check whether the pinned CLI resolves `@`-imports inside `CLAUDE.md` (a `CLAUDE.md` whose body is `@persona.md` and `@memory.md`). If it does, prefer imports: `CLAUDE.md` then stays agent-writable and the entrypoint only needs to create it when missing. If it does not, keep the `cat`. Decide during G55 and record which in §8; do not assume either way. `--append-system-prompt-file` exists in 2.1.270 (§3) but the agent command is `claude-agent-acp`, not `claude`, and `BUZZ_ACP_AGENT_ARGS` goes to the adapter rather than the CLI — do not plan on injecting the persona that way without first proving the adapter forwards it.

### Task 6 — docs

- `docs/spec.md`: §1 image row (`open-llm-stack/claude-agent:2.1.270` from `node:22-bookworm-slim@sha256:4d67…`, both npm packages pinned, verified 2026-09-14); §3 `ANTHROPIC_API_KEY`, `FIREWORKS_AI_API_KEY`; new §5.20 "Claude Code runtime and hosted models (plan 18)": the two modes, the subscription decision with the terms quoted, the include and the switch, the smoke rule, the measured numbers; §5.13 runtime matrix row updated from "design only"; §7 gates G55–G60. §5.20 also gets a short **"Memory: three layers, three owners"** subsection, so the next runtime added does not re-litigate it:

  | Layer | Scope | Who writes it | Lifetime | Where |
  |---|---|---|---|---|
  | Policy / persona | one member | we do, from `team.toml` | refreshed every boot | `.prompt.md` → `$CLAUDE_CONFIG_DIR/persona.md` |
  | Agent memory | one member | the agent | created once, never overwritten | `$CLAUDE_CONFIG_DIR/memory.md`, `projects/<slug>/memory/`, on the `team-<member>` volume |
  | Shared team memory | every member | we do, reviewed like code | git history | a committed `CLAUDE.md` in the repository the agents work in |

  With one rule stated plainly: **shared state between agents lives in the git repository, not in a shared agent-memory service.** It is diffable, revertable, and every member picks it up by opening the directory. `$CLAUDE_CONFIG_DIR` is per-member and must not be treated as shared.
- `README.md`: "Claude Code as a runtime" after the runtimes paragraph: what "runs Claude Code" means here (plain text, per Anthropic's branding rule), mode A ("unsupported by Anthropic, documented by LiteLLM"), mode B with `make frontier-on`, the provider keys, the egress warning, adding a provider block (copy a block, name the key variable in its marker line), and one sentence: subscription login is not offered by the stack, with the terms reference and the reason.
- `AGENTS.md`: replace the closed-weight-runtimes line with: "Claude Code is an opt-in runtime per member (`runtime = "claude"`, plan 18): local models through LiteLLM, or hosted models only from `proxy/frontier.yaml` (`make frontier-on`, provider keys in `.env`). `proxy/config.yaml` stays open weights and local; the smoke enforces it. No subscription credentials, ever (spec §5.20)."

## 5. Considerations

- **Prefill cost of the harness on a local model.** Claude Code sends ~29 k tokens of system prompt and tool schemas per turn. Plan 14's per-agent slot caches the prefix, so the cost is paid once per session, then only the tail; without the cache it is ~4 s of prefill per turn at 7.3 k tok/s. Mode A's metrics row will show it.
- **Local reasoning models answer inside thinking.** Through `/v1/messages` LiteLLM maps Ollama reasoning to a `thinking` block; the adapter probe saw only `agent_thought_chunk`. Claude Code's own budgets are large, so the smoke decides; the lever if personas misbehave is `merge_reasoning_content_in_choices` or turning thinking off for that registry entry. Recorded, not pre-applied.
- **Mode A is unsupported by Anthropic.** Features that need the Anthropic API silently degrade or 400 when the upstream is another model; LiteLLM translates most of it and `drop_params: true` drops the rest. Re-check after every Claude Code pin bump.
- **Hosted open weights are still egress.** Kimi and GLM on Fireworks are open weights, but the code leaves the host; that is why they live in the include, not in `proxy/config.yaml`, and why the smoke keys on `execution_locus: cloud`, not on weights.
- **Provider slugs drift.** The example names slugs with a date; `scripts/frontier.sh status` prints what the provider lists. Adding a provider is a block in the example with a `# provider: <name> key: <VAR>` marker and a key in `.env`; no code.
- **Budgets.** Per-member virtual keys (plan 15) take `max_budget`; set one on every member that runs a hosted model. Not gated here; documented.
- **Pin bumps.** Two pins (`CLAUDE_CODE_VERSION`, `CLAUDE_ACP_VERSION`) and one digest; the adapter's bundled SDK carries its own CLI copy, so the two versions need not match, but keep them close. A bump re-runs G55 and one smoke per mode in use. The CLI version string appears in **four** places and they must move together, or G55 fails: `agents/claude/Dockerfile` (`ARG CLAUDE_CODE_VERSION`), the `claude-image` target and tag in `Makefile`, `IMAGES["claude"]` in `scripts/team-render.py`, and the §1 image row in `docs/spec.md`. G55 asserting the version string is what makes a partial bump fail loudly; keep that assertion.
- **Session continuity.** The adapter calls `session/new` per connection, so every session starts with fresh context whatever is on disk. `--resume` and `--session-id` exist in 2.1.270 but the adapter does not drive them. Do not design as though the harness remembers across sessions: the repository is the memory, and the `CLAUDE.md` load at session start is how each new session reads it.
- **Sidekick's escalation cascade stays out of scope** (see §1). Reviewed 2026-09-15: the orchestrator's own metric is currently wrong in three places (`report.py:31` computes the local share over steps attempted rather than steps planned; `loop.py:31,92` label attempt 4+ as first-try once `max_retries > 2`; `loop.py:94-98` drop orchestrator-injected imports on the thrash path), its only end-to-end benchmark dictates the algorithm line by line against tests written in advance, and its API planner has never executed. This plan is the substrate and is worth landing on its own — mode A alone measures what the ~29 k-token harness prefill costs on a local model, a number that work needs either way. Revisit coupling once those defects are fixed, a generation benchmark passes, and one live escalation has been measured.
- **Cloud providers for Claude models.** Bedrock, Agent Platform and Foundry go through LiteLLM as `bedrock/…` or `vertex_ai/…` blocks in the include, keeping the one-ledger property; the adapter's own `CLAUDE_CODE_USE_*` path is not used.

## 6. Testing strategy

Image and probe first (G55, local model; decide the `@`-import question there and record it). Mode A on Dinesh (G56) with the metrics row against plan 12's table, then the restart check on the same member while it is still on the claude runtime (G60). Mode B only with real keys in `.env` (G57 Anthropic, G58 Fireworks), then `make frontier-off` and `make test`. Flags-off regression last (G59). Numbers into §8.

G60 is the one gate that fails against a naive entrypoint. If it passes on the first try, check that the marker line was actually written before the recreate — a green G60 with an empty `memory.md` means the test did not run, not that the design works.

## 7. Validation commands

```bash
# G55 image and probe
make claude-image && docker run --rm open-llm-stack/claude-agent:2.1.270 sh -c 'claude --version; id agent; which claude-agent-acp buzz buzz-acp python3'
docker run --rm --add-host host.docker.internal:host-gateway -e ANTHROPIC_BASE_URL=http://host.docker.internal:3000 -e ANTHROPIC_AUTH_TOKEN=$LITELLM_MASTER_KEY -e ANTHROPIC_MODEL=ornith-max \
  -v $PWD/agents/claude:/opt/probe:ro open-llm-stack/claude-agent:2.1.270 python3 /opt/probe/acp-probe.py /home/agent "Reply with exactly: OK" -- claude-agent-acp   # initialize, session, end_turn

# G56 mode A
make member-claude N=$(python3 scripts/team-roster.py role builder | awk 'NR==1') MODE=local && make team-smoke && make team-smoke
docker compose exec -T $(python3 scripts/team-roster.py role builder | awk 'NR==1') sh -c 'env | grep -cE "^ANTHROPIC_API_KEY="'   # 0
docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "select metadata->>'user_api_key_alias', model, count(*) from \"LiteLLM_SpendLogs\" where \"startTime\" > now()-interval '20 minutes' group by 1,2"

# G60 memory and sessions survive a container restart (run while the builder is on the claude runtime, after G56)
M=$(python3 scripts/team-roster.py role builder | awk 'NR==1')
docker compose exec -T $M sh -c 'echo "- restart marker $(date -u +%FT%TZ)" >> /home/agent/.claude/memory.md'
docker compose up -d --force-recreate --wait $M
docker compose exec -T $M sh -c 'grep -c "restart marker" /home/agent/.claude/memory.md'          # >= 1: the agent's file was not overwritten
docker compose exec -T $M sh -c 'grep -c "restart marker" /home/agent/.claude/CLAUDE.md'          # >= 1: the regenerated file carries it
docker compose exec -T $M sh -c 'ls /home/agent/.claude/projects/*/ | grep -c jsonl'              # >= 1: session transcripts persist
docker compose exec -T $M sh -c 'cmp -s /home/agent/.prompt.md /home/agent/.claude/persona.md && echo persona-refreshed'

# G57 mode B, Anthropic (ANTHROPIC_API_KEY in .env)
bash -n scripts/frontier.sh && make frontier-on && ./scripts/frontier.sh status && make member-claude N=$(python3 scripts/team-roster.py role builder | awk 'NR==1') MODE=hosted && make team-smoke && make team-smoke
docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "select model, round(sum(spend)::numeric,4), count(*) from \"LiteLLM_SpendLogs\" where model like 'anthropic/%' and \"startTime\" > now()-interval '20 minutes' group by 1"   # non-zero
make test | sed -n '/open weights and local/,/hosted entry/p'

# G58 mode B, Fireworks (FIREWORKS_AI_API_KEY in .env)
make frontier-on && make member-claude N=$(python3 scripts/team-roster.py role builder | awk 'NR==1') MODE=hosted M=kimi-k2p7-code && make team-smoke
docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "select model, round(sum(spend)::numeric,4), count(*) from \"LiteLLM_SpendLogs\" where model like 'fireworks_ai/%' and \"startTime\" > now()-interval '20 minutes' group by 1"
make member-runtime N=$(python3 scripts/team-roster.py role builder | awk 'NR==1') R=buzz-agent && make frontier-off && make test

# G59 flags off
make test   # identical sections to plan 16's run
for s in $(python3 scripts/team-roster.py members | cut -d' ' -f1); do docker compose exec -T $s sh -c 'env | grep -cE "^(ANTHROPIC|CLAUDE)_"'; done   # all 0
```

## 8. Execution report

(to be written at execution: image build output and `claude --version`, the probe transcript, the mode A and B metrics rows against plan 12's table, spend rows by alias and provider, `frontier.sh status` output, and any deviation with its reason)
