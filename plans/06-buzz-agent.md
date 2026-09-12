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

## 7. Execution report (fill in)
