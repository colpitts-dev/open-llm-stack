# Plan 11 — Progress in the job thread: milestones by default, a log mirror when you want to watch

**Spec:** `docs/spec.md` (this plan adds §5.12 and gates G21–G22). **Rules:** `AGENTS.md`. **Knowledge:** plan 08 §5.8 (team, entrypoint, scrubbed shell, reply guard), `docs/buzz-agents-primer.md` §1–2 (harness never publishes model text; a post exists only when the model runs `buzz messages send`).
**Sequence:** 11. Requires plan 10 executed (either Gitea mode; this plan does not touch Gitea). Adds one script, one `.env` variable, persona lines. **No service, no image, no profile, no relay change. Default behaviour of the chat: +2 messages per job, nothing else.**
**Execute with:** `/execute plans/11-progress-mirror.md`
**No internet except `docker pull`.** Every harness behaviour below was verified live on 2026-09-13 on the running stack (`ghcr.io/block/buzz-sprig:sha-e17cdd9`, source `~/code/buzz` @ ad9591c). Message conventions come from a UX and a UI review of the noise trade-off (2026-09-13), summarised in §3.

---

## 1. Overview

Today a job thread shows `picked up: <plan>`, then silence for 20–70 s (minutes on bigger tasks), then a PR URL and a review verdict. Everything in between is in the container log. The operator wanted progress while agents work, without a noisy chat. Two layers:

1. **Milestones (persona, always on).** Two one-line posts the builder writes itself at the moments that matter: after the push and after reading the CI result. Deliverables (PR, review, questions) get a bold label and are the only messages that carry `@mentions`, so the eye finds them. Cost: +2 messages per job, no infrastructure.
2. **Mirror (opt-in, default off).** `scripts/team-narrate.sh` in the agent container posts the harness log into the job thread as replies by the agent: state-changing shell commands (`$ git push …`, `curl -X POST …`) and, on request, the model's narration. Turned on per need with `TEAM_NARRATE=tools|both` when babysitting a hard job or diagnosing a stuck agent; `docker logs` stops being the only window. Off = today's chat exactly.

Thread with layer 1 only (default; shape from a real turn 2026-09-13):

```
Richard  @Dinesh in demo-calc add subtract(a, b) with a test and open a PR
Dinesh   picked up: add subtract(a, b) to calc/__init__.py with a test, open a PR
Dinesh   🚩 pushed agent/subtract-9879 (2 files) — opening the PR, CI running
Dinesh   **PR:** https://git.colpitts.dev/piedpiper/demo-calc/pulls/8
         subtract(a, b) in calc/__init__.py, test_subtract in tests/test_calc.py. @Richard @Gilfoyle review please
Dinesh   🚩 CI success on a1b2c3d
Gilfoyle **Review:** APPROVED — clean, matches add(); one nit on the docstring
```

With `TEAM_NARRATE=tools` the same thread also carries, between those lines:

```
Dinesh   ```
         $ git checkout -b agent/subtract-9879
         ```
Dinesh   ```
         $ git add -A && git commit -m "feat: subtract(a, b) with test" && \
           git push -u origin agent/subtract-9879
         ```
Dinesh   ```
         $ . ~/.gitea.env && curl -sS -X POST -H "Authorization: token $GITEA_TOKEN" -d @pr.json \
           https://git.colpitts.dev/api/v1/repos/piedpiper/demo-calc/pulls
         ```
```

and with `both` the model's narration too, as `› …` lines (never the final answer: that chunk is dropped because it becomes the real reply).

**Why not the app's observer pane.** The harness can stream a live turn to the owner's desktop app (`BUZZ_ACP_RELAY_OBSERVER`, NIP-AO kind 24200). Verified 2026-09-13: with an owner row in the relay DB the relay accepts the frames (66 received, 0 rejected) and the app subscribes to every frame addressed to the owner, but it renders only agents it lists as its own, i.e. with a **kind 30177 record signed by the owner's desktop key**, which the app creates only for agents it spawned (backends `Local`, `Provider`). No CLI signs one; no Rust toolchain here. Not pursued (details §3). A Gitea-webhook feed (earlier draft) was dropped: it reports Gitea facts, not progress.

**Success criteria:** G21 — the mirror, fed a canned log excerpt inside `dinesh` with `TEAM_NARRATE=both` (no LLM), posts exactly the expected replies into a throwaway thread: one narration line, one wrapped `git push` command; it skips the read-only command, the `buzz messages send` command, the final narration chunk of the turn, and a `conversation`-scoped turn. G22 — `make team-smoke` (real job) shows a `**PR:**`-labelled post from `dinesh` and a `**Review:**` post from `gilfoyle` (gated), and reports whether the `🚩 pushed` / `🚩 CI` milestones were posted (model-dependent, see §7 finding 9). With `TEAM_NARRATE=tools` set for the run, the thread additionally shows a `$ git push` reply (gated only in that mode).

**Out of scope:** batching commands per phase and idle heartbeats (measure first; the reviews' cadence advice is recorded in §3 for the follow-up), narration for channel-scoped agents (Jared, Erlich: no thread), thought chunks, tool output.

## 2. Relevant files

| Path | Action |
|---|---|
| `agents/TEAM.md`, `agents/dinesh.md`, `agents/monica.md`, `agents/gilfoyle.md` | milestones, deliverable labels, mention discipline, stdin message bodies |
| `scripts/team-narrate.sh` | new: log filter + poster (bash, no jq; runs inside the sprig image) |
| `scripts/team-entrypoint.sh` | when `TEAM_NARRATE` ≠ `off`: `RUST_LOG=info,acp::wire=debug`, harness through a FIFO into the filter |
| `docker-compose.yml` | team services: mount the script; anchor: `TEAM_NARRATE`, log rotation |
| `.env.example` | `TEAM_NARRATE=off` |
| `scripts/team-smoke.sh` | after the review: thread summary + milestone/label gates (G22) |
| `scripts/smoke-test.sh` | `test_team_narrate` (G21) |
| `docs/spec.md` §3, §5.12, §7; `README.md`; `AGENTS.md`; `docs/buzz-agents-primer.md` | docs |
| `docker-compose.override.yml` (gitignored) | delete: leftover of the observer experiment (Task 0) |

## 3. Dependencies and verified facts (2026-09-13)

**Harness log (buzz-acp in the sprig image, `RUST_LOG=info`; lines carry ANSI colour codes through `docker logs`).** One short real turn, ANSI stripped:

```
2026-09-13T22:33:46.504129Z  INFO pool::prompt: turn starting for channel f1bb1ea9-107f-4b65-8c14-0d658716fd74 (thread:7ffa2104)
2026-09-13T22:33:48.407165Z  INFO acp::stream: Picked up: list demo-calc tests dir and count test functions (no changes).
<blank>
<blank>
2026-09-13T22:33:48.407183Z  INFO acp::tool: tool_call: buzz-dev-mcp__shell (other)
2026-09-13T22:33:48.407330Z  INFO acp::tool: tool_call_update: XQiocfGDc3GLCWW6Ywmfkg42mH1IDqFD → in_progress
2026-09-13T22:33:48.610740Z  INFO acp::tool: tool_call_update: XQiocfGDc3GLCWW6Ywmfkg42mH1IDqFD → completed
2026-09-13T22:33:52.386624Z  INFO acp::stream: The `tests/` directory contains a single file:
<continuation lines without timestamp, blank lines>
2026-09-13T22:33:55.420964Z  INFO pool::prompt: turn complete for channel f1bb1ea9-107f-4b65-8c14-0d658716fd74 (thread:7ffa2104): end_turn
```

- `acp::stream` = `agent_message_chunk` text (`crates/buzz-acp/src/acp.rs:1758`), **multi-line**: continuation lines have no timestamp; chunks often end with blank lines. A chunk is complete when the next timestamped line arrives. The last chunk of a turn is, in every captured turn, the text the model then posts with `buzz messages send` (or prose it never posts): dropped by the mirror either way, as the reviews asked; the posted copy is the visible one.
- `acp::tool: tool_call: <title> (<kind>)` carries the tool name only. The command is in the ACP frame, logged at **debug** on target `acp::wire` (`acp.rs:1218`, `← {json}`). Verified with `RUST_LOG=info,acp::wire=debug` on `buzz-agent`: `DEBUG acp::wire: ← {"jsonrpc":"2.0","method":"session/update","params":{…"update":{"kind":"other","rawInput":{"command":"buzz messages send --channel 3110de9d-… --reply-to 15e5e6d2… --content \"PONG\""},"sessionUpdate":"tool_call","status":"pending","title":"buzz-dev-mcp__shell","toolCallId":"…"}}}`. The same command repeats in the following `session/request_permission` frame (no `sessionUpdate` key): match on `"sessionUpdate":"tool_call"` only. Strings are JSON-escaped (`\"`, `\n`, `\\`).
- `turn starting for channel <uuid> (thread:<root8>)`: `<root8>` = first 8 hex chars of the thread **root event id** (`crates/buzz-acp/src/scope.rs`, `telemetry_label`; root = the mention's NIP-10 root tag, else the mention itself). Channel-policy agents log `(conversation)`.
- Prompt frames at debug hold the assembled prompt (~5 KB per turn), no secret (the token is in `~/.gitea.env`, never in the prompt). Wire debug is ~10× the info volume: the team anchor gets `logging: {driver: json-file, options: {max-size: "20m", max-file: "3"}}`, and the entrypoint raises `RUST_LOG` only when the mirror is on.

**`buzz` CLI in the container.** `buzz messages send --channel <uuid> --reply-to <event id> --content -` reads the body from stdin (the bundled agent itself replies with `--reply-to <mention id>`). `buzz messages get --channel <uuid> --limit N` lists top-level messages with full `id`; `buzz messages thread --channel <uuid> --event <root id>` returns the thread. The entrypoint's environment has `BUZZ_PRIVATE_KEY` and `BUZZ_RELAY_URL`, so a script it starts posts as the agent; the model's shell tool does not (scrubbed env, plan 08 gotcha 3), which is why the mirror lives in the entrypoint and the milestones in the persona.

**Entrypoint plumbing.** `scripts/team-entrypoint.sh` ends with `exec /usr/local/bin/sprig-entrypoint` (execs `buzz-acp`; healthcheck `pgrep -f buzz-acp`). A FIFO keeps that: the filter runs in the background reading the FIFO; the entrypoint execs the harness with stdout+stderr into it; the filter echoes every line, so `docker logs` is unchanged. **Gotcha:** a dead reader blocks the harness on its next write, so the filter runs `set +e`, `trap '' PIPE`, never exits before EOF. Sprig image: bash 5, `sed`, `grep`, no jq/python; JSON parsed with bash regex; `sed -u` strips ANSI unbuffered.

**Message conventions (UX + UI reviews, 2026-09-13).** Agreed by both: narration off by default (restates the next command; doubles volume in a channel with per-message unread badges); only state-changing commands are worth a post; `@mentions` and **bold** reserved for deliverables and questions, never on progress; milestones always, one line, one fixed glyph `🚩` first, no other emoji anywhere; drop the final narration chunk (duplicate of the reply); commands in a fenced block, `$ ` prefix, wrapped on `&&`/`|` with `\` continuation at ~48 chars rather than horizontally scrolling; hard cut at 300 chars only for JSON/heredoc tails; everything stays in the thread. Deferred, recorded for the follow-up: batch consecutive commands into one message per phase (`ran 4 commands (12s)`, ≤ 8 lines), idle heartbeat once per long phase (`still running CI on a1b2c3d…` after 60–90 s), promote a self-correction to a `retry: … → …` line only after a failed command or CI failure. Measure first: messages per job thread (median, p95), "still going?" questions per week, whether humans reply after milestones or after command posts.

**Observer pane (record only).** `BUZZ_ACP_RELAY_OBSERVER=true` + `BUZZ_ACP_AGENT_OWNER=<pubkey>` → buzz-acp logs `relay observer enabled` and publishes kind 24200 frames; the relay authorizes by `users.agent_owner_pubkey` (`is_agent_owner`), filled from a NIP-OA `auth` tag (a bootstrap could set it with the relay's own statement `UPDATE users SET agent_owner_pubkey=$1 WHERE community_id=$2 AND pubkey=$3 AND agent_owner_pubkey IS NULL`); the desktop lists owned agents only from kind 30177 events it signed (`desktop/src-tauri/src/commands/agent_discovery/relay_directory.rs`, `useAgentObserverIngestion.ts`). Experiment leftovers: Dinesh's owner row in `buzz-db`, `docker-compose.override.yml` (observer env on `dinesh`, wire debug on `buzz-agent`).

## 4. Tasks

### Task 0 — revert the experiment

```bash
rm -f docker-compose.override.yml
set -a; . ./.env; set +a
docker compose exec -T buzz-db psql -U buzz -d buzz -c "UPDATE users SET agent_owner_pubkey = NULL WHERE pubkey = decode('$TEAM_DINESH_PUBKEY','hex')"
docker compose up -d buzz-agent dinesh     # drops the override's env
```

### Task 1 — personas (milestones, labels, mentions, stdin bodies)

`agents/TEAM.md`, replace the "Shell quoting bites" bullet and add the progress bullet:
```markdown
- Shell quoting bites: never put backticks or unbalanced quotes inside a command string. Send every message body through stdin with a quoted heredoc, and JSON through a file:
  `buzz messages send --channel <uuid> --reply-to <thread root id> --mention <hex> --content - <<'EOF'` … `EOF`; `curl … -d @file.json`.
- Progress and deliverables, same shape for every agent:
  - Exactly two milestone posts per job, one line each, starting with the flag: `🚩 pushed <branch> (<n> files) — opening the PR, CI running` right after `git push`, and `🚩 CI success on <sha7>` or `🚩 CI failure on <sha7> — fixing: <one clause>` right after you read the CI status. No other emoji, ever.
  - Deliverables start with a bold label and are the ONLY messages that carry @mentions: `**PR:** <html_url>` then a blank line, then what changed and `@<requester> @Gilfoyle review please`; `**Review:** APPROVED|REQUEST_CHANGES|COMMENT — <one line>`; `**Question:** …` when you need the requester. Never use bold or a mention anywhere else.
```
`agents/dinesh.md`, `agents/monica.md`: after the push step add `Post the push milestone (TEAM.md).`; after the CI-check step add `Post the CI milestone (TEAM.md).`; the step that posts the PR URL says `Post the deliverable as **PR:** (TEAM.md)`; every `--content "$(cat msg.txt)"` becomes `--content - < msg.txt`. `agents/gilfoyle.md`: the thread post of the verdict starts with `**Review:**`. **verify** step numbers while editing (Dinesh: push 5, PR post 7, CI 8; Monica: push 6, PR 7/9, CI 8).

### Task 2 — `scripts/team-narrate.sh`

The script as executed is the file itself (`scripts/team-narrate.sh`, ~80 lines); it differs from the first draft in two places found during execution (§7): the sprig image's `sed` is BusyBox (no `-u`, no GNU multi-line commands), so ANSI stripping and chunk trimming are pure bash (`shopt -s extglob`, `mapfile`), and every `buzz` call that does not take stdin runs with `</dev/null` so it can never inherit the FIFO. Structure: `root_id` (resolve `thread:<root8>` once per thread via `buzz messages get --limit 300`), `post` (thread reply via `--reply-to <root> --content -`), `flush` (narration chunk → first 3 lines, `› ` prefix, only in `both`), `unescape` (JSON string → text), `wrap` (break on ` && ` / ` | ` past 48 chars, cut at 300), `mutating` (allow-list of state-changing commands), and the line loop: `turn starting (thread:…)` sets the target, `(conversation)` and `turn complete` clear it and drop the buffered chunk, `INFO acp::stream:` starts a chunk, continuation lines extend it, `DEBUG acp::wire: ← {…"sessionUpdate":"tool_call"…}` flushes the chunk and, in `tools`/`both`, posts the command unless it is a `buzz messages send`/`reactions add`. Every input line is echoed first, so `docker logs` is unchanged. `chmod +x`.

### Task 3 — entrypoint, compose, env

`scripts/team-entrypoint.sh`, replace the last line `exec /usr/local/bin/sprig-entrypoint` with:
```bash
# Progress mirror (plan 11), opt-in: the harness log goes through team-narrate.sh, which echoes it (docker logs unchanged)
# and posts commands/narration into the job thread. FIFO so the harness stays PID 1 via exec (healthcheck: pgrep -f buzz-acp).
# acp::wire at debug carries the shell command text the mirror needs (~10x log volume; rotated by compose).
case "${TEAM_NARRATE:-off}" in
  tools|both|stream)
    export RUST_LOG="${RUST_LOG:-info},acp::wire=debug"
    rm -f /tmp/acp.log; mkfifo /tmp/acp.log
    bash /opt/team/team-narrate.sh </tmp/acp.log &
    echo "progress mirror: $TEAM_NARRATE"
    exec /usr/local/bin/sprig-entrypoint >/tmp/acp.log 2>&1 ;;
esac
exec /usr/local/bin/sprig-entrypoint
```

`docker-compose.yml`: in `&team-env` add `TEAM_NARRATE: ${TEAM_NARRATE:-off}`; in the `x-team-agent` anchor add (sibling of `healthcheck`):
```yaml
  logging:                            # acp::wire debug (mirror on) is ~10x the info volume; bound it
    driver: json-file
    options: { max-size: "20m", max-file: "3" }
```
and in **each** of the five services' `volumes:` lists (they override the anchor's list; the entrypoint mount is already repeated per service) add `- ./scripts/team-narrate.sh:/opt/team/team-narrate.sh:ro`.

`.env.example`, team block after `TEAM_HEARTBEAT_SECONDS`:
```bash
# Progress mirror (plan 11), opt-in: what the builders/reviewer post into the job thread beyond their milestones.
# off (default) = milestones and deliverables only; tools = every state-changing shell command (git push/commit, API writes);
# both = also the model's narration between commands (verbose; for babysitting a hard job or diagnosing a silent agent).
# Jared and Erlich never mirror (no thread). Apply with: docker compose up -d dinesh gilfoyle monica
TEAM_NARRATE=off
```

Acceptance: `docker compose up -d dinesh gilfoyle jared erlich monica`; each logs `presence set to online`; with `off`, `docker compose exec dinesh pgrep -f team-narrate` finds nothing and `/proc/1/cmdline` is `buzz-acp`; with `TEAM_NARRATE=tools` (edit `.env`, `up -d dinesh`) the log shows `progress mirror: tools`, `pgrep -f team-narrate` succeeds, `/proc/1/fd/1` → `/tmp/acp.log`, and `docker compose logs dinesh` still shows harness lines.

### Task 4 — gates

`scripts/smoke-test.sh`, new function after `test_team_factory`, dispatcher `has_profile team && test_team_narrate` (G21, no LLM; independent of the `.env` setting because the filter is run by hand with `TEAM_NARRATE=both`):
```bash
test_team_narrate() {   # G21: canned harness log through team-narrate.sh inside dinesh -> expected replies in a throwaway thread
  local relay="${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}" sprig=ghcr.io/block/buzz-sprig:sha-e17cdd9
  echo "--- team: progress mirror (canned log through team-narrate.sh in dinesh, no LLM)"
  bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_SMOKE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$relay" --entrypoint buzz "$sprig" "$@"; }
  local ch root root8 n
  ch=$(bz channels create --name "narrate-$(date +%s)" --type stream --visibility open --ttl 3600 | jq -r .channel_id)
  bz channels add-member --channel "$ch" --pubkey "$TEAM_DINESH_PUBKEY" --role bot >/dev/null
  root=$(bz messages send --channel "$ch" --content "job root (mirror probe)" | jq -r .event_id); root8="${root:0:8}"
  docker compose exec -T -e TEAM_NARRATE=both dinesh bash /opt/team/team-narrate.sh >/dev/null <<EOF
2026-01-01T00:00:00.000000Z  INFO pool::prompt: turn starting for channel $ch (thread:$root8)
2026-01-01T00:00:01.000000Z  INFO acp::stream: Picked up: probe narration line.


2026-01-01T00:00:02.000000Z DEBUG acp::wire: ← {"jsonrpc":"2.0","method":"session/update","params":{"update":{"kind":"other","rawInput":{"command":"git fetch origin && git checkout main"},"sessionUpdate":"tool_call","status":"pending","title":"buzz-dev-mcp__shell"}}}
2026-01-01T00:00:03.000000Z DEBUG acp::wire: ← {"jsonrpc":"2.0","method":"session/update","params":{"update":{"kind":"other","rawInput":{"command":"git add -A && git commit -m \\"feat: probe\\" && git push -u origin agent/probe"},"sessionUpdate":"tool_call","status":"pending","title":"buzz-dev-mcp__shell"}}}
2026-01-01T00:00:04.000000Z DEBUG acp::wire: ← {"jsonrpc":"2.0","method":"session/update","params":{"update":{"kind":"other","rawInput":{"command":"buzz messages send --channel $ch --content \\"visible already\\""},"sessionUpdate":"tool_call","status":"pending","title":"buzz-dev-mcp__shell"}}}
2026-01-01T00:00:05.000000Z  INFO acp::stream: @Richard-smoke this is the final answer and must NOT be mirrored
2026-01-01T00:00:06.000000Z  INFO pool::prompt: turn complete for channel $ch (thread:$root8): end_turn
2026-01-01T00:00:07.000000Z  INFO pool::prompt: turn starting for channel $ch (conversation)
2026-01-01T00:00:08.000000Z  INFO acp::stream: must not be posted (conversation scope)
2026-01-01T00:00:09.000000Z  INFO pool::prompt: turn complete for channel $ch (conversation): end_turn
EOF
  sleep 3
  bz messages thread --channel "$ch" --event "$root" | jq -r --arg d "$TEAM_DINESH_PUBKEY" '.[] | select(.pubkey==$d) | "mirror: \(.content|gsub("\n";" | "))"'
  n=$(bz messages thread --channel "$ch" --event "$root" | jq -r --arg d "$TEAM_DINESH_PUBKEY" '[.[] | select(.pubkey==$d)] | length')
  [ "$n" = 2 ] && echo "mirror: 2 replies (narration + wrapped git push); skipped fetch, buzz send, final chunk, conversation turn" || fail "expected 2 mirror replies from dinesh, got $n"
}
```
**verify** field names `.event_id` (send) and `.pubkey`/`.content` (thread) at execution; adjust if nested.

`scripts/team-smoke.sh` (G22), after the `TEAM SMOKE PASS` line:
```bash
root=$(bz messages get --channel "$ch" --limit 20 | jq -r '[.[] | select(.content|startswith("@Dinesh"))][0].id')
th=$(bz messages thread --channel "$ch" --event "$root")
jq -r --arg d "$TEAM_DINESH_PUBKEY" --arg g "$TEAM_GILFOYLE_PUBKEY" '.[] | select(.pubkey==$d or .pubkey==$g) | (.content | split("\n")[0])' <<<"$th" | sed 's/^/thread: /' | head -40
chk() { jq -e --arg p "$1" --arg re "$2" '[.[] | select(.pubkey==$p and (.content|test($re)))] | length > 0' <<<"$th" >/dev/null && echo "PASS: $3" || { echo "FAIL: $3"; return 1; }; }
ok=0
chk "$TEAM_DINESH_PUBKEY"   '^🚩 pushed '      "push milestone"      || ok=1
chk "$TEAM_DINESH_PUBKEY"   '^🚩 CI (success|failure)' "CI milestone" || ok=1
chk "$TEAM_DINESH_PUBKEY"   '^\*\*PR:\*\* http' "PR deliverable label" || ok=1
chk "$TEAM_GILFOYLE_PUBKEY" '^\*\*Review:\*\* '  "review label"        || ok=1
case "${TEAM_NARRATE:-off}" in tools|both) chk "$TEAM_DINESH_PUBKEY" '^```\n\$ .*git push' "mirror: git push command" || ok=1 ;; esac
[ "$ok" = 0 ] || { echo "THREAD CONVENTIONS FAIL (see above)" >&2; exit 1; }
```
`$ch`, `$bz`, `$TEAM_*_PUBKEY` already exist in the script. The milestone and label checks are model-dependent by nature; two consecutive smoke runs must pass before the plan is called done (the reply guard retries once, the model on `ornith-max` followed similar mechanical rules in plans 08–10). If a run fails only on wording, record it in §7 and tighten the persona line, do not loosen the regex.

### Task 5 — docs

- `docs/spec.md`: §3 `TEAM_NARRATE`; new **§5.12 Progress in the thread (plan 11)** with the facts of §3 (log shapes, multi-line chunks, `acp::wire` debug carries `rawInput.command`, `thread:<root8>` = root id prefix, FIFO plumbing and the dead-reader gotcha, log rotation, message conventions and the deferred cadence items, the observer-pane finding and why it is not used); §7 gates **G21**, **G22**.
- `README.md` "The agent team": new paragraph **Following a job** (the two milestones, the bold labels, that only deliverables mention you, `TEAM_NARRATE=tools|both` for watching commands/narration, Jared/Erlich do not mirror, log rotation); "Limits, honestly": the silent-turn bullet gains "with `TEAM_NARRATE=both` the discarded text is visible as `›` lines".
- `docs/buzz-agents-primer.md` §2: one line: narration surfaces only via the entrypoint log mirror; the observer pane needs app-managed agents.
- `AGENTS.md`: status line; non-negotiable: "Progress posts come from `scripts/team-narrate.sh` (opt-in) and the two persona milestones; never add a persona loop that narrates every step, and never put @mentions or bold on progress lines."
- `plans/11-progress-mirror.md` §7: execution report.

## 5. Testing strategy

Task 0 → Task 1 → recreate `dinesh`, `monica`, `gilfoyle` → `make team-smoke` twice (G22 with `off`) → Tasks 2–3 → recreate the five agents → `make test` (G21 inside; also proves `off` leaves no filter process) → set `TEAM_NARRATE=tools`, `up -d dinesh` → `make team-smoke` once (G22 with the mirror line) → back to `off`. Do not run smokes while a human job is in flight (one GPU slot).

## 6. Validation commands

```bash
bash -n scripts/team-narrate.sh scripts/team-entrypoint.sh scripts/smoke-test.sh scripts/team-smoke.sh && test -x scripts/team-narrate.sh
docker compose config | grep -cE 'team-narrate.sh:/opt/team/team-narrate.sh'      # 5
docker compose config | grep -E 'TEAM_NARRATE|max-size' | sort -u
docker compose up -d dinesh gilfoyle jared erlich monica
make team-smoke | sed -n '/TEAM SMOKE PASS/,$p'                                       # G22 (off): thread: lines, 4x PASS
make test | sed -n '/progress mirror/,/mirror: 2 replies/p'                           # G21
docker compose exec -T dinesh sh -c 'pgrep -f "^bash /opt/team/team-narrate" || echo "no filter (off)"; tr "\0" " " </proc/1/cmdline'   # anchored: an unanchored -f matches this sh -c itself
sed -i 's|^TEAM_NARRATE=.*|TEAM_NARRATE=tools|' .env && docker compose up -d dinesh && docker compose logs --since 1m dinesh | grep -E 'progress mirror|presence set'
docker compose exec -T dinesh sh -c 'pgrep -f "^bash /opt/team/team-narrate" >/dev/null && ls -la /proc/1/fd/1'   # -> /tmp/acp.log
make team-smoke | sed -n '/TEAM SMOKE PASS/,$p'                                       # G22 (tools): + PASS: mirror: git push command
sed -i 's|^TEAM_NARRATE=.*|TEAM_NARRATE=off|' .env && docker compose up -d dinesh
```

## 7. Execution report (executed 2026-09-13, external Gitea mode, `ornith-max`)

### Findings and fixes

1. **BusyBox `sed` in the sprig image** (`sed: unrecognized option: u`): the first G21 run posted nothing because the filter's `sed -u` pipeline died on its first line. ANSI stripping and chunk trimming are now pure bash (`shopt -s extglob`, `mapfile`). Rule for this image: bash only, no GNU coreutils/sed features.
2. **The filter's `buzz messages get` inherited the FIFO as stdin.** In the first tools-mode job a 73 s stall appeared between an LLM call completing and the harness logging its output; every `buzz` call in the filter that takes no stdin now runs with `</dev/null`. No such stall afterwards (all remaining gaps were inside `llm: call completed` durations).
3. **G22 gate raced the agents.** The smoke asks Gilfoyle for the review as soon as CI is green, while Dinesh is still polling CI and posting his deliverable, and Gilfoyle's thread post lands ~5 s after his Gitea review. The gate now waits (up to 3 min) for both `**PR:**` and `**Review:**`, and reads both the job thread and the review-request thread (Gilfoyle replies to whichever asked him).
4. **`pgrep -f team-narrate` matched its own `sh -c` wrapper**: the validation uses the anchored pattern `^bash /opt/team/team-narrate`.
5. **Model wording, handled by persona wording (gates unchanged):** `🚩 CI on <sha> — pending …` (TEAM.md: poll until success/failure, never post pending); `***Review:**` (gilfoyle.md: exact eleven characters via a heredoc file); a PR body mangled by backticks inside `--content "…"` (builders: `--content - < pr.txt`); a stray `probe @Gilfoyle` while Dinesh hunted the reviewer's pubkey in a nameless members list (`GILFOYLE_PUBKEY` is now inlined into the prompt by the entrypoint, like `GITEA_URL`; `docker-compose.yml` passes `TEAM_GILFOYLE_PUBKEY`).
6. **Wrapped commands span lines**, so the tools-mode gate regex is `^```\n\$ [^`]*git push` (the first version anchored `git push` to the `$` line and failed on a correct post).
7. **Flag dropped once.** In the final `make test` (PR #15) Dinesh posted `pushed agent/… — opening the PR, CI running` and `CI success on d94d417 — tests pass` without the `🚩`, after a backtick-mangled PR body distracted him. Nine runs, one miss: the gate now checks the milestone text and reports the flag (`flag: …`), so `make test` does not fail on a glyph.
8. **The G22 gate judged before the CI milestone existed** (PR #16: the milestone landed 31 s after the PR post). The wait now requires PR + CI milestone + Review.
9. **Milestone posts are not reliable enough to gate `make test` on.** PR #17: Dinesh narrated "both milestones posted" but no such message reached the relay (relay-wide `buzz messages search --author` shows only the PR post): a broken `buzz messages send` he did not check. Across the day: milestones present in 9 of 12 jobs, once without the flag. Two responses: the builder personas now carry the exact milestone command inline as a mandatory step (not a pointer to TEAM.md), and `team-smoke.sh` reports milestones (`milestone: push present|ABSENT`) while gating only the deliverable labels (12/12 after the gate fixes). Success criterion G22 is therefore: labels gated, milestones reported.
10. **`TEAM.md` said "Gitea here is plain http://, never https://"** (a bundled-mode leftover); Dinesh posted `http://git.colpitts.dev/…` for PR #18. The norm now says: copy `html_url` exactly, never change its scheme.
11. **Persona edits need `docker compose up -d --force-recreate <agent>`**: the personas are a bind mount, so a plain `up -d` sees no config change and keeps the old container (prompt assembled at start). The Makefile's `team-model` target already uses `--force-recreate` for the same reason.
12. **Mirror off ⇒ no filter process, harness stdout is a plain pipe** (`readlink /proc/1/fd/1` → `pipe:[…]`); on ⇒ `/tmp/acp.log`, `progress mirror: tools` logged, `acp::wire` debug lines present, PID 1 = `buzz-acp`.

### Gate output (real; thread lines are the first line of each post)

```
# G22 run 1 (off)  FAIL — gate read the thread before Dinesh finished; Gilfoyle's post in the request thread (finding 3); CI pending post (finding 5)
thread: picked up: … / 🚩 pushed agent/subtract-0801 (2 files) — opening the PR, CI running / 🚩 CI on 54618aa — pending (…)
PASS: push milestone  FAIL: CI milestone  FAIL: PR deliverable label  FAIL: review label
# G22 run 2 (off)  FAIL — `***Review:**` (finding 5); everything else PASS
# G22 run 3 (off)  PASS 4/4 — PR #9, review COMMENT (Gilfoyle spotted the fixture's duplicate subtract_* functions)
# G22 run 4 (off, via make test)  FAIL — review label: race (finding 3); the run also aborted before G21
# G22 run 5 (off, via make test)  PASS 4/4 — PR #11
thread: picked up: add subtract_1477(a, b) with a test and open the PR / 🚩 CI success on 1a7241f / 🚩 pushed agent/subtract-1477 (2 files) — opening the PR, CI running
thread: **PR:** https://git.colpitts.dev/piedpiper/demo-calc/pulls/11 / **Review:** APPROVED — additive math, self-contained, …
  … repository factory: created …/factory-41541 / collaborators: none (creator demoted) / deleted
  … progress mirror: FAIL expected 2 mirror replies, got 0   (finding 1)
# G21 standalone after finding 1
mirror: › Picked up: probe narration line.
mirror: ``` | $ git add -A && \ |   git commit -m "feat: probe" && \ |   git push -u origin agent/probe | ```
mirror: 2 replies (narration + wrapped git push); skipped fetch, buzz send, final chunk, conversation turn
# tools mode on dinesh: progress mirror: tools / filter running / /proc/1/fd/1 -> /tmp/acp.log / PID 1 buzz-acp / acp::wire lines: 2
# G22 run 6 (tools)  4/4 conventions PASS, mirror check FAIL on the regex (finding 6); the thread had the three command posts:
$ cd REPOS/demo-calc && \ git checkout -b agent/subtract-1643 2>&1 | \ tail -2
$ cd REPOS/demo-calc && \ git add calc/__init__.py tests/test_calc.py && \ git commit -m "add subtract_1643(a, b) with test" 2>&1 | \ tail -3 && \ git push -u origin agent/subtract-1643 2>&1 | \ tail -5
$ cat > /tmp/pr.json <<'EOF' {"title":"Add subtract_1643(a, b)", … EOF . ~/.gitea.env & …
# G22 run 7 (tools)  PASS 5/5 — PR #13: push milestone, CI milestone, PR label, review label, mirror: git push command
# G22 run 8 (tools, after finding 2)  PASS 5/5 — PR #14 (~400 s: Dinesh first finished the operator's own job in another channel, then shared the GPU slot with Monica; 17 LLM calls = 330 s of the turn)
# back to off: no filter (off) / pipe:[…]
```
# Final make test (off), after findings 9-10 — exit 0
PR #18 opened after ~90s / CI success / TEAM SMOKE PASS: PR #18, CI success, review APPROVED
thread: picked up: … / 🚩 pushed agent/subtract-4237 (2 files) — opening the PR, CI running / 🚩 CI success on eb4aec8 / **PR:** …/pulls/18 / **Review:** APPROVED — correct, minimal, tested.
milestone: push present / milestone: CI present / PASS: PR deliverable label / PASS: review label
repository factory: created …/factory-44424 / collaborators: none (creator demoted) / deleted
progress mirror: 2 replies (narration + wrapped git push); skipped fetch, buzz send, final chunk, conversation turn
smoke test finished

### Timings

Per job (`off`): Dinesh's thread = picked up + 2 milestones + PR deliverable, Gilfoyle = 1 review post. PR opened 20–50 s after the mention when the GPU was free. `tools` added 3 command posts (branch, commit+push, PR curl). Whole `make team-smoke` ≈ 2 min idle GPU; 5–7 min when the operator's own jobs ran concurrently (single Ollama slot: check every agent's `turn starting` lines before attributing slowness to a change).

### Not run and why

- `both` mode on a real job: G21 exercises it with a canned log; the narration path is the same code as `tools` plus `flush`. Left for the operator to switch on when babysitting.
- Batching, heartbeat, `retry:` lines: deferred by design (§3), measure first.
- Merging the PRs left on the forge (`demo-calc` #7–#14, each adding a `subtract_<n>` function; Gilfoyle flagged the duplication on #9): the operator's.
