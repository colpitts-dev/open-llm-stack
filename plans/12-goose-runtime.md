# Plan 12 — goose as an alternative agent runtime: one builder, measured against buzz-agent

**Spec:** `docs/spec.md` (this plan adds §5.13 and gates G23–G25). **Rules:** `AGENTS.md`. **Knowledge:** plan 08 §5.8 (team, entrypoint, scrubbed shell, reply guard), plan 11 §5.12 (thread conventions, mirror), `docs/buzz-agents-primer.md` §1 (harness → ACP → runtime → MCP).
**Sequence:** 12. Requires plan 11 executed. Adds one Dockerfile (the stack's first and only build step, **opt-in**, one image), one `.env` variable, one make target, a runtime branch in the entrypoint. No new service, profile, port or relay change.
**Execute with:** `/execute plans/12-goose-runtime.md`
**Internet:** `docker pull` and `docker build` only (the build downloads one pinned goose release; the digest and the sha256 below were verified on 2026-09-14). Everything else was verified live on 2026-09-13/14 on the running stack.

---

## 1. Overview

The team runs on `buzz-agent`, the minimal runtime inside the sprig image. Plan 11 measured its rough edges with a 35B-class local model: persona steps skipped (milestones 9/12), shell quoting mangled (`--content "…"` with backticks), a send narrated but never executed, no local tests. The harness (`buzz-acp`) speaks ACP to any runtime; **goose** is the one that keeps the stack's principles (open weights via LiteLLM, local, no API key leaving the LAN) while bringing a real developer toolset (its own shell + file editing extension, tool-call recovery, context management). This plan runs **Dinesh on goose**, everything else unchanged, and measures.

Also decided: the switch is a per-agent runtime variable, so a third runtime can be added later without touching the team layout. `claude-agent-acp` (Anthropic API key or Claude Code subscription) is that future column — a "grid" opt-in outside the open-weights default; designed in §3, not built here.

| | `buzz-agent` (today) | `goose` (this plan) | `claude-agent-acp` (future, design only) |
|---|---|---|---|
| Image | sprig (Alpine, 14 MB binary) | `open-llm-stack/goose-agent:1.50.0`, built locally (Debian slim + goose 1.50.0 + the sprig binaries), 864 MB | sprig-like base + Node 20 + `npm install -g @agentclientprotocol/claude-agent-acp` (build) |
| Model | LiteLLM, open weights | LiteLLM, open weights (`GOOSE_PROVIDER=openai`, `OPENAI_HOST=<LiteLLM>`) | Anthropic only; `ANTHROPIC_API_KEY` or subscription login persisted under `/home/agent` |
| Tools | `buzz-dev-mcp` (shell, scrubbed env) | goose `developer` extension (shell + file edit, **container env, not scrubbed**); `buzz-dev-mcp` optional | Claude Code's own tools |
| Reply guard | `BUZZ_AGENT_REQUIRE_REPLY` | none (measure silent turns) | none |
| Persona | `BUZZ_ACP_SYSTEM_PROMPT_FILE` | same file; harness sets it with `_goose/unstable/session/system-prompt/set` | same file via ACP |
| Steering (new mention mid-turn) | cancel + re-prompt | `_goose/unstable/session/steer` (harness supports; goose 1.50 advertised `steering_supported=false` at init — **verify** behaviour) | ACP steering |

**Success criteria:** G23 — the image builds reproducibly from pinned inputs and `dinesh` boots on it (`agent initialized name="goose"`, `presence set to online`, thread conventions prompt loaded). G24 — two consecutive `make team-smoke` passes with Dinesh on goose (same G22 gate: labels gated, milestones reported), plus a metrics table against the buzz-agent baseline: time to PR, LLM calls per job, input tokens of the first and last call, tool calls, persona misses. G25 — `TEAM_DINESH_RUNTIME=buzz-agent` restores the sprig image and one smoke passes. The decision (keep goose for builders, or not) is taken from the numbers, in the report; the default stays `buzz-agent` until then.

**Out of scope:** goose for Gilfoyle/Monica/Jared/Erlich (one variable each later if the numbers say so), `claude-agent-acp` (plan 13 if wanted), goose recipes/skills/subagents, `GOOSE_TOOLSHIM` (tool-call shim for models without native tool calling — `ornith-max` has it).

## 2. Relevant files

| Path | Action |
|---|---|
| `agents/goose/Dockerfile` | new: pinned Debian digest + pinned goose release (sha256) + sprig binaries copied from the pinned sprig image |
| `Makefile` | `goose-image` target (build); `team-model` unchanged |
| `.env.example` | `TEAM_DINESH_RUNTIME=buzz-agent` |
| `docker-compose.yml` | `dinesh.image` from `TEAM_DINESH_RUNTIME`; `TEAM_RUNTIME` env in the anchor (per service) |
| `scripts/team-entrypoint.sh` | runtime branch: goose env, no MCP, `GOOSE_CONTEXT_LIMIT` from the registry |
| `scripts/team-narrate.sh` | coalesce consecutive narration records (goose streams token-sized chunks) |
| `scripts/smoke-test.sh` | `test_team_runtime` (G23) |
| `docs/spec.md` §1, §3, §5.13, §7; `README.md`; `AGENTS.md` | docs; principle 1 gets its explicit exception |

## 3. Dependencies and verified facts (2026-09-13/14)

**goose.**
- `~/.local/bin/goose` on this host is **1.50.0**, glibc-linked (`libstdc++.so.6`, `libgcc_s`), byte-identical (sha256 `ec04bdea…`) to the release artifact `https://github.com/block/goose/releases/download/v1.50.0/goose-x86_64-unknown-linux-gnu.tar.bz2` (87 435 937 bytes, sha256 `8b5dfae07d16e352fbabe3122339a9270ea30e3b29246c81d6a227ed5f35e904`, tar member `./goose`). `goose acp [--with-builtin <names>]` = ACP agent server on stdio.
- Env-only provider config works, no `config.yaml` needed: `GOOSE_PROVIDER=openai GOOSE_MODEL=ornith-max OPENAI_HOST=http://127.0.0.1:3000 OPENAI_API_KEY=<LITELLM_MASTER_KEY> GOOSE_MODE=auto goose run --no-session -t "Reply with exactly the word OK"` → `OK` through LiteLLM. goose writes config/sessions/logs under `$HOME` (`.config/goose/config.yaml`, `.local/share/goose/sessions/sessions.db`, `.local/state/goose/logs/llm_request.N.jsonl` — the request log carries `usage.input_tokens` / `output_tokens` per call: the metrics source). Knobs present in the binary: `GOOSE_CONTEXT_LIMIT`, `GOOSE_MAX_TURNS`, `GOOSE_MODE`, `GOOSE_SYSTEM_PROMPT_FILE_PATH`, `GOOSE_DISABLE_KEYRING`, `GOOSE_TOOLSHIM`, `OPENAI_HOST`, `OPENAI_BASE_PATH`, `OPENAI_TIMEOUT`.
- **End to end through the harness, verified:** `buzz-acp` with `BUZZ_ACP_AGENT_COMMAND=goose BUZZ_ACP_AGENT_ARGS=acp,--with-builtin,developer BUZZ_ACP_MCP_COMMAND=buzz-dev-mcp` in the Debian goose image (host network, bundled-agent key) logged `agent initialized agent=0 name="goose" steering_supported=false`, `presence set to online`; a mention got `PONG` back in ~4 s; goose used **its own** `shell` tool (log title `tool_call: shell · buzz messages send --channel …` — the command text is in the INFO title, truncated with `…`), not `buzz-dev-mcp`; first LLM call 8 198 input tokens (buzz-agent: 7 510 on a comparable turn). Narration arrives as **token-sized `acp::stream` records** (`P`, `ONG`, ` sent`, `.`), each its own log line: the plan 11 mirror must coalesce consecutive records (Task 3).
- The harness sets the persona with `_goose/unstable/session/system-prompt/set` (`crates/buzz-acp/src/acp.rs:706`) and knows `_goose/unstable/session/steer` (`acp.rs:364`) keyed on goose's `activeRunId`. `BUZZ_ACP_MCP_COMMAND` may be empty (`lib.rs:5878`).

**Image.**
- The sprig multicall binary is musl static-PIE: `ldd` names `/lib/ld-musl-x86_64.so.1`, but it runs unchanged on Debian (verified: `buzz-acp --help`, `buzz` usage inside `debian:bookworm-slim`-based images without any musl loader). So one Debian image can hold goose **and** the harness/CLI without a Rust build.
- `debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171` (pulled 2026-09-14) ships `libstdc++.so.6` and `libgcc_s.so.1`, so the goose binary runs; it lacks `git`, `curl`, `ca-certificates`, `bzip2`, `procps` (`pgrep` for the healthcheck) → `apt-get` in the Dockerfile.
- Built and tested 2026-09-14 as `open-llm-stack/goose-agent:1.50.0` (image id `23dfb2f1…`, 864 MB): `id -u` = 1000 (`agent`), `goose --version` 1.50.0, `buzz-acp --help`, `git 2.39.5`, `curl 7.88.1`, `pgrep 4.0.2`, nine `sprig` symlinks. `docker build` needs the goose download (ADD from the release URL, sha256-checked) and `apt-get` (Debian mirrors): the build is the only step in this repository that needs the internet beyond `docker pull`, and it is opt-in.

**Team plumbing (plan 08/11).** `scripts/team-entrypoint.sh` already computes `BUZZ_AGENT_MAX_CONTEXT_TOKENS` from LiteLLM's registry (`max_input_tokens`), assembles the prompt file, writes `~/.gitea.env` and the git credential store, then runs the mirror FIFO and `exec sprig-entrypoint`. goose's `developer` shell runs with the **container environment** (not the scrubbed `buzz-dev-mcp` env): `GITEA_TOKEN`, `BUZZ_PRIVATE_KEY`, `OPENAI_API_KEY` are visible to the model's shell. Same trust boundary as the container, but the persona's `. ~/.gitea.env` dance is no longer what protects the token; record it in §5.13 and README.

**Baseline to compare against (buzz-agent, 2026-09-13, `ornith-max`, plan 11 §7):** PR opened 20–50 s after the mention with an idle GPU (100–400 s when the operator's jobs shared the slot); 17 LLM calls in one job; first call 7.5k input tokens, later calls 9–13k; ~7 shell calls per job; milestones present in 9 of 12 jobs; labels 12/12; one mangled PR body per ~3 jobs.

## 4. Tasks

### Task 0 — `agents/goose/Dockerfile` and `make goose-image`

```dockerfile
# goose runtime for a team agent (plan 12, opt-in). Debian base + the pinned goose release + the sprig binaries
# (musl static-PIE; verified to run on glibc). The only image this repository builds.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171
ARG GOOSE_VERSION=1.50.0
ARG GOOSE_SHA256=8b5dfae07d16e352fbabe3122339a9270ea30e3b29246c81d6a227ed5f35e904
RUN apt-get update && apt-get install -y --no-install-recommends bash git curl ca-certificates bzip2 procps \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -d /home/agent -s /bin/bash agent
ADD https://github.com/block/goose/releases/download/v${GOOSE_VERSION}/goose-x86_64-unknown-linux-gnu.tar.bz2 /tmp/goose.tar.bz2
RUN echo "${GOOSE_SHA256}  /tmp/goose.tar.bz2" | sha256sum -c - \
    && tar -xjf /tmp/goose.tar.bz2 -C /usr/local/bin ./goose && rm /tmp/goose.tar.bz2 && chmod 0755 /usr/local/bin/goose
COPY --from=ghcr.io/block/buzz-sprig:sha-e17cdd9 /usr/local/bin/sprig /usr/local/bin/sprig
COPY --from=ghcr.io/block/buzz-sprig:sha-e17cdd9 /usr/local/bin/sprig-entrypoint /usr/local/bin/sprig-entrypoint
RUN for b in buzz buzz-acp buzz-agent buzz-dev-mcp git-credential-nostr git-sign-nostr rg; do ln -s /usr/local/bin/sprig /usr/local/bin/$b; done
USER agent
WORKDIR /home/agent
```
(`rg` is a sprig applet name; the goose image also has no `jq`/`python3`, like sprig: the personas' "no jq" rule still holds.)

`Makefile`:
```make
goose-image:     ## build open-llm-stack/goose-agent (plan 12; needs the goose release download + apt)
	docker build -t open-llm-stack/goose-agent:1.50.0 agents/goose
```
Acceptance: `make goose-image` twice (second from cache); `docker run --rm open-llm-stack/goose-agent:1.50.0 sh -c 'id -u; goose --version; buzz-acp --help | head -1; pgrep --version'`.

### Task 1 — env, compose

`.env.example`, team block after `TEAM_NARRATE`:
```bash
# Runtime behind Dinesh (plan 12): buzz-agent (sprig image, default) or goose (open-llm-stack/goose-agent, make goose-image first).
# Same persona, same LiteLLM model; goose brings its own shell/file tools (container env, not scrubbed) and no reply guard.
TEAM_DINESH_RUNTIME=buzz-agent
```
`docker-compose.yml`: in `&team-env` add `TEAM_RUNTIME: buzz-agent`; in the `dinesh` service:
```yaml
  dinesh:
    <<: *team-agent
    image: ${TEAM_DINESH_IMAGE:-ghcr.io/block/buzz-sprig:sha-e17cdd9}   # plan 12: open-llm-stack/goose-agent:1.50.0 when TEAM_DINESH_RUNTIME=goose
    …
    environment:
      <<: *team-env
      TEAM_RUNTIME: ${TEAM_DINESH_RUNTIME:-buzz-agent}
```
Compose cannot map one variable to an image name, so `make` does it: a small target `team-runtime` (or a line in `make up`) that sets `TEAM_DINESH_IMAGE` in `.env` from `TEAM_DINESH_RUNTIME` — **verify** the cheapest form at execution; the plan's default is a Makefile helper `dinesh-runtime R=goose|buzz-agent` that rewrites both lines in `.env` and runs `docker compose up -d --force-recreate dinesh`. Document that editing `TEAM_DINESH_RUNTIME` alone is not enough.

### Task 2 — entrypoint runtime branch

In `scripts/team-entrypoint.sh`, after the context-window block and before the mirror block:
```bash
# Runtime (plan 12). goose: its own developer extension (shell + file edit) replaces buzz-dev-mcp; provider = LiteLLM;
# context limit from the same registry read; keyring off (no D-Bus in a container); auto mode = no permission prompts.
case "${TEAM_RUNTIME:-buzz-agent}" in
  goose)
    command -v goose >/dev/null || { echo "TEAM_RUNTIME=goose but this image has no goose binary (make goose-image; set TEAM_DINESH_IMAGE)" >&2; exit 1; }
    export BUZZ_ACP_AGENT_COMMAND=goose BUZZ_ACP_AGENT_ARGS="acp,--with-builtin,developer" BUZZ_ACP_MCP_COMMAND=""
    export GOOSE_PROVIDER=openai GOOSE_MODEL="$OPENAI_COMPAT_MODEL" OPENAI_HOST="${OPENAI_COMPAT_BASE_URL%/v1}" OPENAI_API_KEY="$OPENAI_COMPAT_API_KEY"
    export GOOSE_MODE=auto GOOSE_DISABLE_KEYRING=1 GOOSE_CONTEXT_LIMIT="$BUZZ_AGENT_MAX_CONTEXT_TOKENS" GOOSE_MAX_TURNS=200
    echo "runtime=goose $(goose --version 2>/dev/null | tr -d ' ') context=$GOOSE_CONTEXT_LIMIT" ;;
  buzz-agent) ;;
  *) echo "unknown TEAM_RUNTIME '$TEAM_RUNTIME' (buzz-agent|goose)" >&2; exit 1 ;;
esac
```
**verify** at execution: `OPENAI_HOST` wants the host without `/v1` (the manual test used `http://127.0.0.1:3000`); `GOOSE_DISABLE_KEYRING=1` is accepted (the container test ran without it: keep it only if goose logs a keyring warning otherwise); `GOOSE_CONTEXT_LIMIT` is honoured (goose logs it, or `goose info -v` inside the container shows it); `--with-builtin developer` is needed with a fresh `$HOME` (the `run` test enabled `developer` and `todo` by default — check `goose acp` does the same without the flag; keep the flag if unsure). Team norms in `agents/TEAM.md` say "your shell starts with an EMPTY environment": add "(buzz-agent runtime; on goose the shell sees the container environment)".

### Task 3 — mirror: coalesce narration records

`scripts/team-narrate.sh`, stream branch: a new `INFO acp::stream:` record **appends** to the buffer (with a newline) instead of flushing the previous one; flushes still happen on a tool-call frame, on any other record, and are dropped at `turn complete`. goose's `P`/`ONG`/` sent` records then post as one `› PONG sent.` line; for buzz-agent nothing visible changes except adjacent chunks joining. Tools mode is unchanged (`rawInput.command` in the wire frame — **verify** goose's `tool_call` frames carry `rawInput.command`; the INFO title `shell · <cmd>…` is the fallback source, truncated).

### Task 4 — gates

`scripts/smoke-test.sh`, `test_team_runtime` (G23), dispatcher after `test_team_narrate`:
```bash
test_team_runtime() {   # G23: dinesh runs the runtime .env asks for; goose image present when asked
  echo "--- team: dinesh runtime = ${TEAM_DINESH_RUNTIME:-buzz-agent}"
  docker compose exec -T dinesh sh -c 'tr "\0" " " </proc/1/cmdline | cut -c1-40; echo'
  docker compose logs --since 24h --no-log-prefix dinesh 2>/dev/null | grep -oE 'agent initialized agent=0 name="[a-z-]+"' | tail -1
  case "${TEAM_DINESH_RUNTIME:-buzz-agent}" in
    goose) docker compose exec -T dinesh sh -c 'goose --version && pgrep -fa "goose acp" >/dev/null && echo "goose acp running"' || fail "goose runtime requested but not running" ;;
    *) docker compose exec -T dinesh sh -c 'pgrep -f buzz-agent >/dev/null && echo "buzz-agent running"' || fail "buzz-agent not running" ;;
  esac
}
```
G24 = `make team-smoke` twice with `TEAM_DINESH_RUNTIME=goose`; after each, collect from the container: `ls /home/agent/.local/state/goose/logs/llm_request*.jsonl` → number of calls and `usage.input_tokens` of first/last call (no jq in the image: copy the file out with `docker compose cp dinesh:/home/agent/.local/state/goose/logs/ .` and use host `jq`), `docker compose logs dinesh | grep -c 'tool_call:'`, time to PR from the smoke output, milestone/label lines. Same for one buzz-agent run the same hour (GPU state comparable). Table in §7.
G25 = `make dinesh-runtime R=buzz-agent` (or the manual two-line `.env` edit + `--force-recreate`), `make team-smoke` once.

### Task 5 — docs

- `docs/spec.md`: §1 table row "Optional: goose runtime for Dinesh — `open-llm-stack/goose-agent:1.50.0`, built locally by `make goose-image` from `debian:bookworm-slim@sha256:88200866…` + goose v1.50.0 (sha256 `8b5dfae0…`) + the sprig binaries"; principle 1 gets "(exception: the goose image, opt-in, one Dockerfile)"; §3 `TEAM_DINESH_RUNTIME`, `TEAM_DINESH_IMAGE`; new **§5.13 goose runtime** with the facts of §3 (env-only provider, sprig-on-glibc, token-sized stream records, own shell with container env, no reply guard, steering flag, metrics sources) and the runtime matrix including the `claude-agent-acp` design; §7 G23–G25.
- `README.md` "The agent team": **Runtimes** paragraph (default, how to switch Dinesh to goose, what changes for the operator, the env-exposure note, the build being the only internet-needing step); Make targets table.
- `AGENTS.md`: principle "Light" gets the exception sentence; status line; non-negotiable: "runtimes are switched per agent by `TEAM_<AGENT>_RUNTIME`; the goose image is the only thing this repository builds; closed-weight runtimes (claude-agent-acp) are never a default and need their own opt-in plan".
- `plans/12-goose-runtime.md` §7: execution report with the metrics table and the keep/drop decision.

## 5. Testing strategy

Task 0 → G23 build checks → Tasks 1–3 → `make dinesh-runtime R=goose` → G23 (`make test`, includes G21 mirror canned test on the goose image: same script, verifies the coalescing) → G24 two smokes + one buzz-agent smoke for the baseline row (GPU idle: no operator jobs in flight, check other agents' `turn starting`) → G25 switch back + one smoke. Leave the stack on `buzz-agent`.

## 6. Validation commands

```bash
make goose-image && make goose-image                      # second run cached
docker run --rm open-llm-stack/goose-agent:1.50.0 sh -c 'id -u; goose --version; buzz-acp --help | head -1; git --version; pgrep --version | head -1'
bash -n scripts/team-entrypoint.sh scripts/team-narrate.sh scripts/smoke-test.sh && docker compose config | grep -E 'TEAM_RUNTIME|goose-agent|buzz-sprig' | sort | uniq -c
make dinesh-runtime R=goose                               # rewrites TEAM_DINESH_RUNTIME + TEAM_DINESH_IMAGE, force-recreates dinesh
docker compose logs --since 2m dinesh | grep -E 'runtime=goose|agent initialized|presence set'
make test | sed -n '/dinesh runtime/,/running/p; /progress mirror/,/mirror: 2 replies/p'   # G23 + G21 on the goose image
make team-smoke | tail -12                                 # G24 run 1
docker compose cp dinesh:/home/agent/.local/state/goose/logs/ ./.scratch-goose-logs/ && jq -r '.usage | "\(.input_tokens) \(.output_tokens)"' ./.scratch-goose-logs/llm_request.*.jsonl | head; rm -rf ./.scratch-goose-logs
make team-smoke | tail -12                                 # G24 run 2
make dinesh-runtime R=buzz-agent && make team-smoke | tail -8   # G25
```

## 7. Execution report (executed 2026-09-14, external Gitea mode, `ornith-max`, `TEAM_NARRATE=tools` as found in `.env`)

### Findings and fixes

1. **The Dockerfile's tar member is `./goose`, not `goose`** (`tar: goose: Not found in archive`); fixed in the file. Image built twice (`sha256:23dfb2f1…`, second build from cache), 864 MB.
2. **`sed -i` on a bind-mounted script leaves the container on the old inode** (sed writes a new file; the bind mount keeps the old one). The canned mirror test failed with a fresh script until `docker compose up -d --force-recreate dinesh`. Rule: edit mounted scripts in place (Python `open(p,'w')`, `>` redirection) or recreate the container after `sed -i`.
3. **The plan 11 filter pegged a CPU on goose** (`ps`: `RN 90%`): bash's global `${line//pattern/}` ANSI strip and `=~ .*…*` on 25 KB wire frames (goose sends the full prompt and `write` frames with file content) are quadratic. Rewritten: ANSI stripped from the first 60 bytes only, classification with globs on the raw line, the `command` regex bounded to 4 000 bytes. Filter now idles at 1–5 % during a job. Symptom before the fix: mirror posts landed ~60 s after the milestones (docker logs lagged the same way), so runs 1–3 failed only the `mirror: git push` check while the posts existed.
4. **goose's `tool_call` frames carry `rawInput.command`** like buzz-agent's, plus `_meta.goose.toolCall.extensionName=developer`; the INFO title is `shell · <command>…` (truncated). `write` frames carry `rawInput.path` + content (large).
5. **goose narration is token-sized** (`P`, `ONG`, ` sent`, `.` as separate records): the filter now joins consecutive `acp::stream` records into one post (G21 on the goose image: 2 replies, same as on sprig).
6. **`docker compose logs` lag is a mirror symptom**: with a slow filter the harness log (which goes through the FIFO) arrives late; a "silent" agent with `narrate` at high CPU is the filter, not the model. Fixed by 3; recorded in §5.12/§5.13.
7. **G23's grep missed the ANSI-coloured `agent initialized` line**; the smoke strips ANSI before matching.
8. **`make dinesh-runtime`** works as designed (`.env` rewrite + `--force-recreate --wait`; prints `runtime=goose 1.50.0 context=237568`, `agent initialized`, `presence set to online`).

### Gate output (real; thread lines are the first line of each post)

```
# G23 — image: id -u 1000 / goose 1.50.0 / buzz-acp --help ok / git 2.39.5 / pgrep procps-ng 4.0.2; second build cached
# make dinesh-runtime R=goose: runtime=goose 1.50.0 context=237568 / agent initialized agent=0 name="goose" / presence set to online
# test_team_runtime: PID 1 buzz-acp / agent initialized … name="goose" / goose acp running
# G21 on the goose image: mirror: 2 replies (narration + wrapped git push); skipped fetch, buzz send, final chunk, conversation turn
# G24 run 1 (goose)  PR #20 after ~20s, job 58 s: milestones present, PR/Review PASS, mirror check FAIL (finding 3: posts landed late)
# G24 run 2 (goose)  PR #21 after ~20s, job 57 s: push milestone ABSENT, CI present, labels PASS, mirror FAIL (finding 3)
# G24 run 3 (goose)  PR #22 after ~50s, job 88 s: milestones present, labels PASS, mirror FAIL (finding 3); the $ posts arrived ~60 s later
# — filter rewritten, dinesh recreated, G21 again: 2 replies —
# G24 run 4 (goose)  PR #23 after ~40s, job 78 s: milestone push/CI present, PR label PASS, review label PASS, mirror: git push PASS, exit 0
# G24 run 5 (goose)  PR #24 after ~20s, job 57 s: same, 5/5 PASS, exit 0                         ← two consecutive passes
# G25 — make dinesh-runtime R=buzz-agent: TEAM_DINESH_RUNTIME=buzz-agent, TEAM_DINESH_IMAGE=ghcr.io/block/buzz-sprig:sha-e17cdd9, presence set to online
#       team smoke (buzz-agent): PR #25 after ~20s, job 58 s, 5/5 PASS, exit 0
# final make test (buzz-agent, TEAM_NARRATE=tools): every layer section / TEAM SMOKE PASS PR #26 (review REQUEST_CHANGES: the fixture's duplicate subtract_* functions) /
#   push milestone present, CI milestone ABSENT (reported) / PR + Review labels PASS / mirror git push PASS / factory: collaborators none /
#   progress mirror: 2 replies / dinesh runtime = buzz-agent, agent initialized name="buzz-agent", buzz-agent running / smoke test finished / exit 0
```

### Metrics (same hour, GPU otherwise idle, `ornith-max` through LiteLLM; one job = the `subtract_<n>` smoke)

| | buzz-agent (G25 run, PR #25) | goose run 5 (PR #24) | goose run 4 (PR #23) | goose run 1 (PR #20) |
|---|---|---|---|---|
| Dinesh turn wall-clock | 61 s | 45 s | 58 s | ~60 s |
| Time to PR (smoke) | 20 s | 20 s | 40 s | 20 s |
| LLM calls | 17 | ~15–18 (10 `llm_request` files in the window; goose reports usage once per turn) | ~20 | — |
| Input tokens, whole job | 226 620 | 230 641 | 327 668 | 250 786 |
| First call input | 8 050 | ~11.5k | — | 8 198 (PONG probe) |
| Output tokens | 4 395 | 3 353 | — | 5 402 |
| Tool calls | 22 (shell only) | 17 (15 shell, 2 write) | 24 (18 shell) | 10 seen before the log lagged |
| Context used at turn end | n/a | 18 630 | ~16k | 22 233 |
| Persona: milestones / labels | both / both | both / both | both / both | both / both (run 2: push milestone missing) |
| Silent or failed sends | 0 | 0 | 0 | 0 |

Reading: at this task size goose and buzz-agent cost the same tokens (±10 %, one goose run +45 %) and finish in the same wall-clock; goose used its `write` tool instead of heredocs, its own shell instead of `buzz-dev-mcp`, and made no quoting mistakes in five jobs (buzz-agent's day: one mangled PR body per ~3 jobs). Persona adherence was equal (goose skipped a milestone once in five, buzz-agent 3 in 12). No silent turns on goose without the reply guard.

### Decision

**Default stays `buzz-agent`**; goose is kept as the verified alternative (`make dinesh-runtime R=goose`) with equal cost and cleaner shell behaviour, no clear win on the fixture task. Revisit with a multi-file task (Monica's UI work is the candidate) where goose's file-editing tool and context management should matter; the switch is one command per agent.

### Not run and why

- goose for Monica/Gilfoyle: out of scope by design; `TEAM_<AGENT>_RUNTIME` for them is the same three lines in compose/entrypoint.
- `GOOSE_TOOLSHIM`, recipes, subagents: not needed for `ornith-max`.
- A `both`-mode job on goose: G21 covers the coalescing; not exercised with the model.
- The five goose PRs (#20–#24) and the baseline #25 stay open on the forge for the operator, like plan 11's.
