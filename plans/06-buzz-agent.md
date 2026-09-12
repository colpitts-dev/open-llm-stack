# Plan 06 — Buzz agent container + "Buzz talks to LLMs through LiteLLM"

**Spec:** `docs/spec.md` §4.6, **§5.4**, §7 (G7). **Rules:** `AGENTS.md`.
**Sequence:** 6 of 7. Requires plans 01 (LiteLLM, `.env` with `BUZZ_AGENT_*` keys) and 03 (relay). Independent of 02/04/05.
**Execute with:** `/execute plans/06-buzz-agent.md`

---

## 1. Overview

Two deliverables:

1. **`buzz-agent` profile (off by default):** a container from `ghcr.io/block/buzz-sprig:sha-e17cdd9` running `buzz-acp` + `buzz-agent`, connected to the relay at `BUZZ_RELAY_URL` and to LiteLLM at `LITELLM_PUBLIC_URL`, answering any @mention with the model `BUZZ_AGENT_MODEL`. Runs on the **host network** (spec §4.6) so it uses the same URLs a human does and works against a bundled or an external relay/gateway.
2. **The LLM handoff for Buzz clients:** a documented, copy-pasteable env block (`BUZZ_AGENT_PROVIDER=openai`, `OPENAI_COMPAT_*`) that the Buzz desktop app's managed agents or any `buzz-acp` process use to reach LiteLLM.

Plus `scripts/buzz-smoke.sh` (G7): from a throwaway human identity, create a channel, add the agent, mention it, expect a reply.

**Success criteria:** G0 with `buzz-agent`; G7 prints `agent replied ... PONG`. Verified during planning exactly this way (reply in ~10 s).

---

## 2. Relevant files

| Path | Action |
|---|---|
| `docker-compose.yml` | add `buzz-agent` service |
| `scripts/buzz-smoke.sh` | create |
| `scripts/smoke-test.sh` | dispatch `buzz-smoke.sh` when the profile is on |
| `README.md` | add "Buzz + LLMs through LiteLLM" section |

## 3. Dependencies (spec §5.4, all verified 2026-09-12)

- `ghcr.io/block/buzz-sprig:sha-e17cdd9` (on host). Contains `buzz-acp`, `buzz-agent`, `buzz-dev-mcp`, `buzz` CLI, `bash`, `curl`. Entrypoint `/usr/local/bin/sprig-entrypoint` ends in `exec buzz-acp "$@"`.
- `.env` (plan 01): `BUZZ_AGENT_PRIVATE_KEY`, `BUZZ_AGENT_PUBKEY`, `BUZZ_AGENT_NAME`, `BUZZ_AGENT_MODEL`, `BUZZ_AGENT_MAX_CONTEXT_TOKENS`, `BUZZ_RELAY_URL`, `LITELLM_PUBLIC_URL`, `LITELLM_MASTER_KEY`.
- Relay in open mode (plan 03 default), so `BUZZ_ACP_RESPOND_TO=anyone` is what makes the agent answer non-owners.
- The agent's display name is a relay profile (`buzz users set-profile --name`), set by the container's entrypoint wrapper on every start (idempotent).

---

## 4. Tasks

### Task 1 — compose service

File: `docker-compose.yml` (modify). Append under `services:`:

```yaml
  # ---------------------------------------------------------------- profile: buzz-agent (host network)
  # An LLM agent living in the relay. Host network on purpose: the relay only accepts the exact host:port
  # in BUZZ_PUBLIC_HOST (spec §5.3), so the agent connects to the same public URLs a human uses and works
  # unchanged against an external relay or gateway. Nothing here depends_on another profile (spec §4.3).
  buzz-agent:
    image: ghcr.io/block/buzz-sprig:sha-e17cdd9   # same commit as the relay image
    profiles: [buzz-agent]
    restart: unless-stopped
    network_mode: host
    entrypoint:
      - /bin/bash
      - -ec
      - |
        url="$${BUZZ_RELAY_URL/#ws:/http:}"; url="$${url/#wss:/https:}"
        for i in $$(seq 1 60); do curl -fsS -o /dev/null "$$url/_liveness" && break; echo "waiting for relay at $$url"; sleep 2; done
        buzz users set-profile --name "$$BUZZ_ACP_DISPLAY_NAME" --about "open-llm-stack agent (LiteLLM: $$OPENAI_COMPAT_MODEL)" >/dev/null 2>&1 \
          && echo "profile name set: $$BUZZ_ACP_DISPLAY_NAME" || echo "could not set profile name (will retry on next restart)"
        exec /usr/local/bin/sprig-entrypoint
    environment:
      # identity + relay
      BUZZ_PRIVATE_KEY: ${BUZZ_AGENT_PRIVATE_KEY:?run make init}
      BUZZ_RELAY_URL: ${BUZZ_RELAY_URL:-ws://127.0.0.1:3002}
      BUZZ_ACP_DISPLAY_NAME: ${BUZZ_AGENT_NAME:-stack-agent}
      # harness: run buzz-agent (no Goose in this image), give it the dev-mcp tools, answer anyone (open relay)
      BUZZ_ACP_AGENT_COMMAND: buzz-agent
      BUZZ_ACP_AGENT_ARGS: ""
      BUZZ_ACP_MCP_COMMAND: buzz-dev-mcp
      BUZZ_ACP_RESPOND_TO: anyone
      # LLM through LiteLLM (OpenAI-compatible, Chat Completions)
      BUZZ_AGENT_PROVIDER: openai
      OPENAI_COMPAT_BASE_URL: ${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}/v1
      OPENAI_COMPAT_API_KEY: ${LITELLM_MASTER_KEY:?run make init}
      OPENAI_COMPAT_MODEL: ${BUZZ_AGENT_MODEL:-qwen3.6-max}
      OPENAI_COMPAT_API: chat
      BUZZ_AGENT_MAX_CONTEXT_TOKENS: ${BUZZ_AGENT_MAX_CONTEXT_TOKENS:-237568}   # = that model's max_input_tokens in proxy/config.yaml
      BUZZ_AGENT_MAX_OUTPUT_TOKENS: "16384"                                      # = max_output_tokens
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f buzz-acp >/dev/null"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 150s   # covers the relay-wait loop above
```

Notes for the executor: the `$$` are Compose escapes so the shell, not Compose, expands those variables. `pgrep` is BusyBox's in Alpine.

Acceptance: `COMPOSE_PROFILES=buzz-agent docker compose config` renders the entrypoint with single `$`; with `COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,buzz-agent` `make up` ends healthy; `docker compose logs buzz-agent` shows `profile name set: stack-agent`, `connected to relay at ws://127.0.0.1:3002`, `agent initialized ... name="buzz-agent"`, `presence set to online`, and the expected `WARN no channel subscriptions resolved — agent will sit idle` (it has no channels yet).

### Task 2 — `scripts/buzz-smoke.sh`

File: `scripts/buzz-smoke.sh` (create, `chmod +x`)

```bash
#!/usr/bin/env bash
# G7: from a throwaway human identity, create a channel, add the agent, mention it, expect a reply via LiteLLM.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9
RELAY_IMG=ghcr.io/block/buzz:sha-e17cdd9
URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
AGENT_PUB=${BUZZ_AGENT_PUBKEY:?run make init}
NAME=${BUZZ_AGENT_NAME:-stack-agent}
docker compose ps --status running buzz-agent | grep -q buzz-agent || { echo "buzz-agent is not running (add buzz-agent to COMPOSE_PROFILES and make up)" >&2; exit 1; }

HSEC=$(docker run --rm --entrypoint /usr/local/bin/buzz-admin "$RELAY_IMG" generate-key | awk '/Secret key:/{print $3}')
bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$HSEC" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@"; }
bz users set-profile --name smoke-human >/dev/null
ch=$(bz channels create --name "smoke-$(date +%s)" --type stream --visibility open --ttl 3600 | jq -r .channel_id)
[ -n "$ch" ] && [ "$ch" != "null" ] || { echo "channel creation failed" >&2; exit 1; }
echo "channel $ch"
bz channels add-member --channel "$ch" --pubkey "$AGENT_PUB" --role bot >/dev/null
sleep 3   # let the membership notification reach the harness
bz messages send --channel "$ch" --content "@${NAME} Reply with exactly the single word: PONG" --mention "$AGENT_PUB" >/dev/null
echo "mention sent; waiting for the agent (up to 240s)"
for i in $(seq 1 24); do
  sleep 10
  reply=$(bz messages get --channel "$ch" --limit 20 | jq -r --arg pk "$AGENT_PUB" '[.[] | select(.pubkey==$pk) | .content][0] // empty')
  if [ -n "$reply" ]; then echo "agent replied after ~$((i*10))s: $reply"; exit 0; fi
done
echo "FAIL: no reply within 240s. Inspect: docker compose logs buzz-agent" >&2
exit 1
```

Acceptance: `agent replied after ~10s: PONG` (the exact word can vary with sampling; any non-empty reply passes; a miss is possible with a weak model — re-run once before calling it a failure).

### Task 3 — dispatch from the smoke test

File: `scripts/smoke-test.sh` (modify). Add to the dispatcher, after `test_buzz`:

```bash
has_profile buzz-agent && ./scripts/buzz-smoke.sh
```

### Task 4 — README section

File: `README.md` (append)

```markdown
## Buzz + LLMs through LiteLLM

Every Buzz agent talks to a model through an OpenAI-compatible endpoint. LiteLLM is that endpoint. The relay itself never calls a model; agents do.

**Bundled agent (profile `buzz-agent`).** Add `buzz-agent` to `COMPOSE_PROFILES` and `make up`. An agent named `BUZZ_AGENT_NAME` (default `stack-agent`, pubkey `BUZZ_AGENT_PUBKEY` in `.env`) joins the relay and answers @mentions using `BUZZ_AGENT_MODEL` via LiteLLM. Invite it to a channel (desktop app → channel members → add by pubkey, or `buzz channels add-member --channel <uuid> --pubkey $BUZZ_AGENT_PUBKEY --role bot`), then mention it. Prove it with `./scripts/buzz-smoke.sh`.

**Your own agents (desktop app or `buzz-acp` anywhere on this machine).** Give them this environment, from `.env`:

    BUZZ_AGENT_PROVIDER=openai
    OPENAI_COMPAT_BASE_URL=http://127.0.0.1:3000/v1      # LITELLM_PUBLIC_URL + /v1
    OPENAI_COMPAT_API_KEY=<LITELLM_MASTER_KEY>
    OPENAI_COMPAT_MODEL=qwen3.6-max                       # any model_name from proxy/config.yaml
    OPENAI_COMPAT_API=chat
    BUZZ_AGENT_MAX_CONTEXT_TOKENS=237568                  # that model's max_input_tokens

In the Buzz desktop app these go in the agent's (or the global) configuration: provider `openai`, model `<model_name>`, and the `OPENAI_COMPAT_*` values as env vars. Any runtime other than `buzz-agent` (for example Goose) has its own OpenAI-compatible provider settings; point them at the same base URL and key.

Swap the model for every agent at once by editing `proxy/config.yaml` -- names stay stable, backends change.
```

---

## 5. Validation commands (G7)

```bash
for p in buzz-agent litellm,buzz,buzz-agent litellm,openwebui,buzz,gitea,buzz-agent; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: $p"; done
COMPOSE_PROFILES=buzz-agent docker compose config | grep -A6 'entrypoint:'     # single $ in the rendered script
sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,buzz-agent|' .env
make up && docker compose ps && docker compose logs buzz-agent | tail -20
./scripts/buzz-smoke.sh
make test                                              # full run incl. G7
# external-relay rendering check (no restart needed): the agent is the only consumer of BUZZ_RELAY_URL
BUZZ_RELAY_URL=wss://relay.example.test docker compose config | grep -E 'BUZZ_RELAY_URL'
```

## 6. Integration notes

- If the relay is down the agent waits up to 2 minutes, then `buzz-acp` exits and Docker restarts it; this is expected, not a bug.
- `BUZZ_AGENT_MAX_CONTEXT_TOKENS` and `BUZZ_AGENT_MAX_OUTPUT_TOKENS` mirror the registry entry for `BUZZ_AGENT_MODEL`; changing the model means changing these too (spec §6 numbers).
- Closed relay (`BUZZ_REQUIRE_RELAY_MEMBERSHIP=true`): also run `docker compose exec buzz buzz-admin add-member --pubkey $BUZZ_AGENT_PUBKEY` and consider `BUZZ_ACP_RESPOND_TO=owner-only` with `BUZZ_ACP_AGENT_OWNER=<your pubkey>`.

## 7. Execution report

Executed 2026-09-12 (15:13–15:21 ADT) on the reference host against the live stack, `COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,buzz-agent`. No file changed except the `COMPOSE_PROFILES` line in `.env` (this plan's step 2). Nothing committed. Stack left running with the `buzz-agent` profile on.

**G0 — compose valid per profile combination**

```
G0 ok: buzz-agent
G0 ok: litellm,buzz,buzz-agent
G0 ok: litellm,openwebui,buzz,gitea,buzz-agent
```
`docker compose config | grep -A6 entrypoint:` shows the script with `$$` (Compose's display escaping of a literal `$`); the container receives single `$`.

**Step 3 — `make up`** (relay already up, so the agent's wait loop exited on its first probe)

```
 Container open-llm-stack-buzz-1 Healthy
 Container open-llm-stack-open-webui-1 Healthy
 Container open-llm-stack-buzz-agent-1 Healthy
./scripts/preflight.sh
OK  backend reachable at http://host.docker.internal:11434/v1/models
make up  6.165 total
open-llm-stack-buzz-agent-1   ghcr.io/block/buzz-sprig:sha-e17cdd9   "/bin/bash -ec 'url=…"   buzz-agent   6 seconds ago   Up 5 seconds (healthy)
```
Time to healthy for buzz-agent: ~5 s after container creation (`pgrep -f buzz-acp` passes as soon as the entrypoint execs `buzz-acp`); all other eight services stayed healthy.

**Step 4 — agent logs** (`docker compose logs buzz-agent | tail -20`, trimmed)

```
profile name set: stack-agent
INFO buzz_acp: buzz-acp starting: relay=ws://127.0.0.1:3002 pubkey=e02c6e79… agent_cmd=buzz-agent mcp_cmd=buzz-dev-mcp … subscribe=Mentions … respond_to=anyone
INFO buzz_acp: agent initialized agent=0 name="buzz-agent" steering_supported=false
INFO buzz_acp: connected to relay at ws://127.0.0.1:3002
INFO buzz_acp: subscribed to membership notifications
INFO buzz_acp: discovered 0 channel(s)
WARN buzz_acp: no channel subscriptions resolved — agent will sit idle
INFO buzz_acp: presence set to online
```

**G7 — `./scripts/buzz-smoke.sh`** (three passes, one model-side miss; timed)

Attempt 1 (miss, 4:12.8 wall clock):
```
channel 9ce1d78a-ed46-41ad-b13f-fc3778f663c4
mention sent; waiting for the agent (up to 240s)
FAIL: no reply within 240s. Inspect: docker compose logs buzz-agent
```
Diagnosis: the membership notification arrived (`subscribing to new channel channel_id=9ce1d78a…`), `buzz-dev-mcp` initialised, LiteLLM logged `POST /v1/chat/completions 200 OK`, and the agent logged one `llm: call completed model="qwen3.6-max" duration_ms=1291 output_tokens=Some(36) stop=EndTurn` — no tool call, no message posted. A direct LiteLLM probe with the same prompt shows `qwen3.6-max` puts its output in `reasoning_content` with `content: ""` until thinking finishes, so a short `EndTurn` turn with empty content leaves nothing for the harness to post. This is the nondeterministic miss spec §5.4 already documents, not infrastructure: the relay, membership, LiteLLM and Ollama path all worked.

Attempt 2 (pass, 14.98 s wall clock):
```
channel e65a7a7e-eab6-4ec2-923e-83c3e40b4595
mention sent; waiting for the agent (up to 240s)
agent replied after ~10s: PONG
```
Agent log for this turn: `membership notification … e65a7a7e…` at 18:19:15; three LLM calls — `output_tokens=182 stop=ToolUse` (5.5 s), `output_tokens=208 stop=ToolUse` (1.3 s), `output_tokens=43 stop=EndTurn` (0.4 s); reply visible at ~10 s.

**Step 6 — `make test`** (51.5 s, exit 0; trimmed to the section headers and G7)

```
--- litellm: chat round-trip … qwen3.6-max -> OK  ornith-max -> OK  laguna-max -> OK  qwen3.8-max -> OK
--- litellm: embeddings  1024
--- open-webui: chat round-trip via qwen3.6-max  OK
--- buzz: readiness  readiness 200 / liveness on 127.0.0.1:3002: 200
--- buzz: community host == BUZZ_PUBLIC_HOST  community host: 127.0.0.1:3002
--- buzz: real client (buzz CLI from the sprig image, agent identity)  channels visible: 2
--- gitea: create + clone + delete a private repo  created … cloned (README.md ) deleted smoke-1789237218
channel d44e336c-12c9-4107-885a-3811aabefb7c
mention sent; waiting for the agent (up to 240s)
agent replied after ~10s: PONG
smoke test finished
```

**Step 7 — external relay rendering** (`BUZZ_RELAY_URL=wss://relay.example.test docker compose config | grep BUZZ_RELAY_URL`)

```
        url="$${BUZZ_RELAY_URL/#ws:/http:}"; url="$${url/#wss:/https:}"
      BUZZ_RELAY_URL: wss://relay.example.test
```
Command-line env overrides `.env`; the agent is the only consumer, no other service's rendering changed.

**Step 8 — restart durability**

```
 Container open-llm-stack-buzz-agent-1 Started        (restart: 0.21 s)
buzz-agent-1  | profile name set: stack-agent
buzz-agent-1  | 2026-09-12T18:20:42.555376Z  INFO buzz_acp: connected to relay at ws://127.0.0.1:3002
open-llm-stack-buzz-agent-1 … Up 30 seconds (healthy)
channel bc56098b-cfbc-434e-9f02-37aed00c6c9b
mention sent; waiting for the agent (up to 240s)
agent replied after ~10s: PONG        (14.93 s wall clock)
```
Reconnected ~0.1 s after the container started (relay was already live).

**G8 — loopback only** (`docker compose ps --format '{{.Name}} {{.Ports}}'`)

```
open-llm-stack-buzz-1 3000/tcp, 8080/tcp, 9102/tcp, 127.0.0.1:3002->3002/tcp
open-llm-stack-buzz-agent-1
open-llm-stack-buzz-db-1 5432/tcp
open-llm-stack-buzz-minio-1 9000/tcp
open-llm-stack-buzz-redis-1 6379/tcp
open-llm-stack-gitea-1 22/tcp, 127.0.0.1:3003->3000/tcp
open-llm-stack-litellm-1 127.0.0.1:3000->4000/tcp
open-llm-stack-litellm-db-1 5432/tcp
open-llm-stack-open-webui-1 127.0.0.1:3001->8080/tcp
```
buzz-agent publishes nothing (`network_mode: host`); every published mapping is `127.0.0.1:`.

**Smoke channels created** (all `--ttl 3600`, type stream, visibility open): `9ce1d78a-ed46-41ad-b13f-fc3778f663c4` (attempt 1, no reply), `e65a7a7e-eab6-4ec2-923e-83c3e40b4595` (PONG), `d44e336c-12c9-4107-885a-3811aabefb7c` (make test, PONG), `bc56098b-cfbc-434e-9f02-37aed00c6c9b` (post-restart, PONG).

**Fixes:** none. No image tag, `$$` escape, script or compose change was needed.

