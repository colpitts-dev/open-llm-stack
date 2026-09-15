# Plan 19 — Job approval watcher: a bare "approved" reply, no @mention, no extra LLM turns

**Spec:** `docs/spec.md` (this plan adds §5.21 and gates G60–G63; plan 18 already claims §5.20 and G55–G59). **Rules:** `AGENTS.md`. **Knowledge:** plan 16.5 §5.18 (job channel, thread root, the plan checkpoint, `TEAM_ALLOWLIST`), plan 17 §5.19 (console, `console/post-job.sh`, `console/approve-job.sh`, `console/audit.log` schema).
**Sequence:** 19 (after 17). Requires plan 17 executed (`console/approve-job.sh`, `console/post-job.sh`, `console/audit.log`); plan 16.5's checkpoint is what it approves. Adds one script (`console/approve-watch.sh`), one make target (`approval-watch`), two gitignored state files (`console/.watch-since`, `console/.watch-approved`). No new service, image, port, network, container, or `.env` variable.
**Execute with:** `/execute plans/19-job-approval-watcher.md`
**No internet at execution.** Every value below was verified live on the reference host on 2026-09-15, against the already-running `piedpiper` team and the already-pinned `ghcr.io/block/buzz-sprig:sha-e17cdd9` image (plan 17 pins the same tag; this plan adds no new one).

---

## 1. Overview

Buzz Desktop's `@mention` picker does not resolve server (`role: bot`) agents (verified live 2026-09-15: a channel-membership query showed Gilfoyle as a real `"role":"bot"` member while Desktop still offered to "invite" him) — typing `@Gilfoyle approved` in a job thread routinely fails to resolve. Separately, and independently, a bare `approved` reply with **no** mention never reaches the builder at all: `BUZZ_ACP_RESPOND_TO=allowlist` combined with the harness's default `--subscribe mentions` means the relay subscription itself filters out any event that does not `p`-tag the agent, before the model ever sees it. Verified live: a correctly spelled, correctly threaded `approved` reply from the allowlisted human sat in the job thread with zero pickup — no `turn starting` log line at all — until a mention-tagged event arrived.

The tempting fix, `BUZZ_ACP_SUBSCRIBE=all` on the builder, was considered and rejected: one job channel carries the *entire* job lifecycle in a single thread — the ask, the plan, the approval, the push/PR, the coordinator's routing message to the reviewer, the reviewer's verdict — so `all` would wake the builder on every later-stage message too, not only the approval it is waiting for. On this host that means extra, unaddressed LLM turns competing for the single resident model's one GPU slot, and a real (if small) risk of an unwanted reply, since the model's own base prompt already tells it "if a human asked you something, you MUST reply."

This plan instead adds a small watcher, entirely outside the agent runtime, that reads job-channel messages the same way `console/post-job.sh` and `console/approve-job.sh` already do (the `buzz` CLI over the relay), matches on content alone, and — on a match — calls the already-proven `console/approve-job.sh` exactly as a human clicking the console's Jobs-screen Approve button would. Zero LLM turns spent per poll; no `BUZZ_ACP_*` config touched on any agent.

| | |
|---|---|
| New file | `console/approve-watch.sh`: finds every `job-*` channel the console identity belongs to, polls each for a new reply matching the approval rule, calls `console/approve-job.sh` on a match, appends to `console/audit.log` |
| New make target | `make approval-watch [I=<seconds>]` — foreground, same shape as `make power-meter` |
| New state (gitignored, host-local) | `console/.watch-since` (one Unix timestamp: the poll low-water mark), `console/.watch-approved` (one already-approved thread-root id per line) |
| Untouched | every agent's `BUZZ_ACP_*` env var and compose service, `console/app.py`, `console/approve-job.sh`, `console/post-job.sh`, `agents/roles/builder.md` |

**Success:** a human's bare `approved` (any case) or `#approved`, posted as an ordinary threaded reply with **no** `@mention`, reaches the builder within one poll interval; a non-allowlisted sender (including a teammate agent) and non-matching text never trigger anything; replying `approved` twice to the same thread never double-fires.

**Out of scope:** changing any agent's `BUZZ_ACP_SUBSCRIBE`/`RESPOND_TO`; a UI for the watcher (it is an operator-started foreground terminal tool, like the power meter); revision-request handling (unchanged — any other human reply is still a change request per `builder.md`; this plan only ever adds the "approved" path); running the watcher unattended as a service (a later plan, like the console's own systemd-unit note).

## 2. Relevant files

| Path | Action |
|---|---|
| `console/approve-watch.sh` | new: the watcher |
| `Makefile` | new target `approval-watch` |
| `.gitignore` | `console/.watch-since`, `console/.watch-approved` |
| `scripts/validate-19.sh` | new: gates G60–G63 |
| `README.md` "Console" | one paragraph: what the watcher does, how to start/stop it, that it changes nothing about the agents |
| `docs/spec.md` §5.21, §7 | new subsection; gates G60–G63 |
| `AGENTS.md` | status line |

## 3. Dependencies and verified facts (reference host, 2026-09-15)

- `buzz-acp --help` (image `ghcr.io/block/buzz-sprig:sha-e17cdd9`, the tag plan 17 already pins): `--subscribe <SUBSCRIBE> [env: BUZZ_ACP_SUBSCRIBE=] [default: mentions] [possible values: mentions, all, config]`; `--no-mention-filter [env: BUZZ_ACP_NO_MENTION_FILTER=]`. Confirms the mention requirement is a subscription-level default, not a rule in `agents/roles/builder.md` itself, which only asks for "a reply whose first word is `approved` (any case)".
- `buzz channels list --member --limit 500` (run live, console identity) returns every channel the console created, each with a plain `name`, e.g. `{"channel_id":"5016943b-8ba8-4c26-b2ec-2a85ff4891b1","created_at":1789486524,"description":"","name":"job-1789486520"}`. `name` is always `job-<unix-ts>` (`console/post-job.sh`'s own `--name "job-$(date +%s)"`), so `select(.name // "" | startswith("job-"))` scopes the watcher to job channels only. The console is `"role":"owner"` on every channel it creates (verified: `buzz channels members --channel <uuid>`), so it can always list and read them.
- `buzz messages get --channel <uuid> --since <ts> --kinds 9` (verified live): each message is `{"content","created_at","id","kind":9,"pubkey","sig","tags":[["h","<channel>"],["e","<root>","","reply"]]}` for a threaded reply. The reply's own `e`/`reply` tag names the thread root directly — the watcher never needs a separate `buzz messages thread` lookup.
- Verified live 2026-09-15: a bare, unmentioned, correctly spelled `approved` reply (pubkey `b778d5aa0b71637945dde0b0ab9ea769c9f482617d7ace983e2644c3aa1291ce`, this deployment's sole `TEAM_ALLOWLIST` entry) produced zero activity in `docker compose logs gilfoyle` (no `turn starting` line) until `console/approve-job.sh <channel> <root>` ran — which sends the same word with an explicit `--mention <builder-pubkey>` and triggered a turn within seconds. This is the exact gap the watcher closes.
- `console/approve-job.sh <channel-uuid> <thread-root-id> [note]` (plan 17, unmodified by this plan): resolves the team's builder from `teams/<team>/team.toml`, sends `approved${note:+: $note}` with `--reply-to <root> --mention <builder-pubkey>`. The watcher's only job is deciding *when* to call this unmodified script.
- `console/audit.log` line schema (`console/app.py` lines 151–152, unmodified): one JSON object per line, `{"ts","actor","action","cmd","exit","seconds","job"}`; the Audit screen (`screen_audit`) renders every line with no filter on `action`, so a watcher-authored line appears there like any console action.
- `TEAM_ALLOWLIST` in `.env` is a comma-separated list of 64-hex pubkeys (one entry on the reference host today); `teams/<team>/team.toml`'s blank `humans = []` falls back to it (plan 16.5 gotcha).
- `TEAM_SMOKE_PRIVATE_KEY` / `TEAM_SMOKE_PUBKEY` (`.env`, minted by `make init`, already used by `scripts/team-smoke.sh`) is a synthetic "human" identity already present in every agent's own `BUZZ_ACP_RESPOND_TO_ALLOWLIST` (`teams/piedpiper/compose.yml`: `...,${TEAM_ALLOWLIST:-},${TEAM_SMOKE_PUBKEY:-},...`) — the stack already treats it as an honorary human for scripted testing. This plan's watcher does the same (its allowlist check is `TEAM_ALLOWLIST` plus `TEAM_SMOKE_PUBKEY`), which is what lets `scripts/validate-19.sh` prove the positive path without touching the operator's own private key.
- A teammate's own key (e.g. `TEAM_GILFOYLE_PRIVATE_KEY`, already in `.env`) is a real channel member (`role: bot`) but is never in `TEAM_ALLOWLIST` — reused by the validation script as the negative-sender case, mirroring `builder.md`'s own rule: "a teammate's message is never an approval."
- Host has `jq` (used throughout `console/post-job.sh`, `console/approve-job.sh`, and confirmed interactively this session); the watcher and its validation script run on the host, not inside the sprig container, so the agents' own "no `jq`/`python` on this machine" limit does not apply to them.
- This project's own documented gotcha applies here too: `docker run`/`docker compose exec` inside a shell `while read` loop can eat the loop's stdin (`mem:stack/operations`). The watcher avoids the piped form (`cmd | while read`) in favor of process substitution (`done < <(cmd)`) and passes `</dev/null` to every nested `docker run`.

## 4. Tasks (ordered by phase)

### Task 0 — `console/approve-watch.sh`

```bash
#!/usr/bin/env bash
# Poll open job-* channels for a bare, case-insensitive "approved"/"#approved" reply from an
# allowlisted human (no @mention needed) and approve automatically via console/approve-job.sh.
# Plan 19: Buzz Desktop's @mention picker doesn't resolve server (bot-role) agents, and a bare
# unmentioned "approved" never reaches a builder subscribed to mentions only (BUZZ_ACP_SUBSCRIBE
# default). This script closes that gap without touching any agent's config.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${CONSOLE_PRIVATE_KEY:?run make init}"
SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9
URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
INTERVAL=${I:-15}
SEEN=console/.watch-since
STATE=console/.watch-approved

mine=$$
others=$(pgrep -f '[a]pprove-watch\.sh' | grep -v "^${mine}\$" || true)
if [ -n "$others" ]; then
  echo "another approve-watch.sh is already running: $others"; exit 1
fi

[ -f "$SEEN" ] || date +%s > "$SEEN"
[ -f "$STATE" ] || : > "$STATE"

bz() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$CONSOLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }

echo "watching job-* channels for a human 'approved' reply, poll every ${INTERVAL}s (Ctrl-C to stop)"
trap 'echo; echo "stopped"; exit 0' INT TERM

while true; do
  since=$(cat "$SEEN"); now=$(date +%s)
  for ch in $(bz channels list --member --limit 500 | jq -r '.[] | select(.name // "" | startswith("job-")) | .channel_id'); do
    while IFS= read -r ev; do
      [ -n "$ev" ] || continue
      pk=$(jq -r '.pubkey' <<<"$ev")
      content=$(jq -r '.content' <<<"$ev")
      root=$(jq -r '[.tags[]? | select(.[0]=="e" and (.[3] // "")=="reply")][0][1] // empty' <<<"$ev")
      [ -n "$root" ] || continue
      case ",${TEAM_ALLOWLIST:-},${TEAM_SMOKE_PUBKEY:-}," in *",$pk,"*) : ;; *) continue ;; esac
      grep -qiE '^#?approved([[:space:]:]|$)' <<<"$content" || continue
      grep -qF "$root" "$STATE" && continue
      note=$(sed -E 's/^#?[Aa][Pp][Pp][Rr][Oo][Vv][Ee][Dd][:[:space:]]*//' <<<"$content")
      echo "approving $ch/$root (from $pk): ${content}"
      start=$(date +%s.%N)
      rc=0
      ./console/approve-job.sh "$ch" "$root" "$note" </dev/null || rc=$?
      dur=$(awk -v s="$start" -v e="$(date +%s.%N)" 'BEGIN{printf "%.1f", e-s}')
      echo "$root" >> "$STATE"
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      cmd="console/approve-job.sh $ch $root${note:+ $note}"
      jq -nc --arg ts "$ts" --arg cmd "$cmd" --argjson exit "$rc" --argjson seconds "$dur" \
        '{ts:$ts, actor:"watcher", action:"approve-job", cmd:$cmd, exit:$exit, seconds:$seconds, job:"watch"}' >> console/audit.log
    done < <(bz messages get --channel "$ch" --since "$since" --kinds 9 2>/dev/null | jq -c '.[]?')
  done
  echo "$now" > "$SEEN"
  sleep "$INTERVAL"
done
```

### Task 1 — `Makefile`

Append after the `console:` target (end of file):

Old (last two lines of the file):
```
console:         ## the console on BIND_HOST:CONSOLE_PORT (127.0.0.1:3004): a window onto the same files and scripts (plan 17)
	python3 console/app.py
```

New:
```
console:         ## the console on BIND_HOST:CONSOLE_PORT (127.0.0.1:3004): a window onto the same files and scripts (plan 17)
	python3 console/app.py

approval-watch:  ## poll job-* channels for a bare 'approved'/'#approved' reply, no @mention needed, and approve automatically (plan 19; foreground, Ctrl-C to stop): make approval-watch [I=<seconds>]
	@chmod +x console/approve-watch.sh
	@I=$(I) ./console/approve-watch.sh
```

### Task 2 — `.gitignore`

Old:
```
console/audit.log
```

New:
```
console/audit.log
console/.watch-since
console/.watch-approved
```

### Task 3 — `scripts/validate-19.sh`

```bash
#!/usr/bin/env bash
# Validate plan 19 (job approval watcher): gates G60-G63. Usage: scripts/validate-19.sh
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
LOG=${VALIDATE_LOG:-/tmp/validate-19.log}
: > "$LOG"
log(){ echo "$@" | tee -a "$LOG"; }

mine=$$
others=$(pgrep -f '[v]alidate-19\.sh' | grep -v "^${mine}\$" || true)
if [ -n "$others" ]; then log "FAIL guard another validate-19.sh is already running: $others"; exit 1; fi

SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9
URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
bz_console()   { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$CONSOLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }
bz_smoke()     { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_SMOKE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }
bz_gilfoyle()  { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_GILFOYLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }

ch=$(bz_console channels create --name "job-validate-$(date +%s)" --type stream --visibility private --ttl 3600 | jq -r .channel_id)
bz_console channels add-member --channel "$ch" --pubkey "$TEAM_SMOKE_PUBKEY" --role member >/dev/null
bz_console channels add-member --channel "$ch" --pubkey "$TEAM_GILFOYLE_PUBKEY" --role bot >/dev/null
bz_console messages send --channel "$ch" --content "validate-19 fixture root" >/dev/null
root=$(bz_console messages get --channel "$ch" --limit 5 | jq -r '[.[] | select(.content=="validate-19 fixture root")][0].id')
log "fixture channel $ch root $root"

audit_count(){ grep -c "\"cmd\":\"console/approve-job.sh $ch $root" console/audit.log 2>/dev/null || echo 0; }

setsid nohup env I=5 ./console/approve-watch.sh > /tmp/validate-19-watch.log 2>&1 < /dev/null &
WPID=$!
sleep 1
PGID=$(ps -o pgid= "$WPID" 2>/dev/null | tr -d ' ')
log "watcher pid $WPID pgid $PGID"

# G60: bare, unmentioned, case-varied "approved" from an allowlisted (smoke) human reaches approve-job.sh
bz_smoke messages send --channel "$ch" --reply-to "$root" --content "Approved" >/dev/null
for i in $(seq 1 20); do [ "$(audit_count)" -ge 1 ] && break; sleep 1; done
c=$(audit_count)
if [ "$c" -ge 1 ] && grep -qF "$root" console/.watch-approved; then
  log "PASS G60 bare mention-less 'Approved' reached approve-job.sh (audit_count=$c)"
else
  log "FAIL G60 no approve-job.sh call recorded for $root within 20s (audit_count=$c)"
fi

# G61: a teammate's reply and non-matching content are both ignored
bz_gilfoyle messages send --channel "$ch" --reply-to "$root" --content "approved" >/dev/null
bz_smoke    messages send --channel "$ch" --reply-to "$root" --content "not approved yet" >/dev/null
sleep 8
c2=$(audit_count)
if [ "$c2" -eq "$c" ]; then
  log "PASS G61 teammate reply and non-matching content ignored (audit_count still $c2)"
else
  log "FAIL G61 audit count changed from $c to $c2 on a non-approval"
fi

# G62: a second matching reply on the SAME root does not double-approve
bz_smoke messages send --channel "$ch" --reply-to "$root" --content "#APPROVED again" >/dev/null
sleep 8
c3=$(audit_count)
if [ "$c3" -eq "$c" ]; then
  log "PASS G62 duplicate approved reply did not re-fire (audit_count still $c3)"
else
  log "FAIL G62 duplicate approved reply fired again ($c -> $c3)"
fi

# G63: a second watcher instance refuses to start; the first stops cleanly on SIGTERM
if env I=5 ./console/approve-watch.sh > /tmp/validate-19-second.log 2>&1 </dev/null; then
  log "FAIL G63 a second approve-watch.sh instance was allowed to start"
else
  if grep -qi "already running" /tmp/validate-19-second.log; then
    log "PASS G63a second instance refused: $(cat /tmp/validate-19-second.log)"
  else
    log "FAIL G63a second instance exited nonzero for the wrong reason: $(cat /tmp/validate-19-second.log)"
  fi
fi
[ -n "$PGID" ] && kill -TERM -- -"$PGID" 2>/dev/null
sleep 1
if pgrep -f '[a]pprove-watch\.sh' >/dev/null; then
  log "FAIL G63b watcher still running after SIGTERM"
else
  log "PASS G63b watcher stopped cleanly on SIGTERM"
fi

log "## DONE"
```

### Task 4 — docs

- `docs/spec.md`: new subsection after §5.19 (renumber nothing — plan 18 already claims §5.20, so this is §5.21) titled "5.21 Job approval watcher (plan 19)": the problem (mention picker gap + `subscribe=mentions` default), the rejected `BUZZ_ACP_SUBSCRIBE=all` alternative and why (whole job lifecycle shares one thread; single-GPU one-slot host), the chosen design (poll job-\* channels, match first-word `approved`/`#approved` from `TEAM_ALLOWLIST` ∪ `TEAM_SMOKE_PUBKEY`, call `console/approve-job.sh`, dedup via `console/.watch-approved`), and §7 gates G60–G63.
- `README.md`, in the "Console (port 3004)" section, immediately before the "Loopback only, today with no login…" paragraph, insert:

  ```
  - **The approval watcher (plan 19).** Buzz Desktop's `@mention` picker does not recognize the team's server agents, so typing `@Gilfoyle approved` in a job thread often fails to resolve — and a plain `approved` with no mention never reaches the builder at all (it only subscribes to events that mention it). `make approval-watch` runs a small foreground poller (`console/approve-watch.sh`, Ctrl-C to stop) that watches open job threads for a bare, case-insensitive `approved` or `#approved` reply from an allowlisted human and approves the job the same way the console's own Approve button does. It changes nothing about any agent's configuration and spends no LLM turns.
  ```

- `AGENTS.md`: status line append: "; plan 19 (job approval watcher: `console/approve-watch.sh`, `make approval-watch`, gates G60–G63, spec §5.21) executed on `<execution date>`."

## 5. Considerations

- **Why the smoke identity is in the watcher's allowlist.** `TEAM_SMOKE_PUBKEY` is already treated as an honorary human everywhere in this stack (every agent's own `BUZZ_ACP_RESPOND_TO_ALLOWLIST`). Including it here is consistency, not a new trust boundary, and it is what makes G60–G62 scriptable without the operator's own key ever touching disk.
- **Global watermark, not per-channel.** `console/.watch-since` is one timestamp for every job channel, updated once per poll cycle. A message that lands in the same second as the previous cycle's mark could in principle be re-scanned; `console/.watch-approved` (keyed by thread-root id, not by message id) makes that harmless — the same root is never re-approved.
- **Why match on content, not on identity of the destination.** The watcher never inspects who the plan was *for* — it only checks that the reply is threaded (`e`/`reply` tag), the sender is allowlisted, and the first word is `approved`. If a job channel somehow has no open plan waiting, `console/approve-job.sh` still runs (it always resolves the current builder and sends `approved`), which is a harmless no-op in that case — the builder simply has nothing pending to act on. This mirrors `builder.md`'s own tolerance (it waits indefinitely; an early "approved" before a plan exists changes nothing).
- **Not a replacement for the console's Approve button** — both paths call the same unmodified `console/approve-job.sh`, so they can run side by side; whichever fires first wins, and `console/.watch-approved` only prevents the *watcher* from re-firing, not from a human also clicking Approve (which is idempotent in effect: both send `approved`, harmless if the plan was already accepted).
- **Deliberately deferred:** running this unattended as a systemd unit (mirroring the console's own README note); a config knob for the allowlist (it reads `.env` directly, same as every other console script); handling anything other than the approve path (a change-request reply still requires a human to write real feedback, which the builder already reads from thread context with no watcher involvement).

## 6. Testing strategy

Everything here is scriptable and needs the live relay only — no LLM turn is required for any gate (the fixture root is a plain console message, never a builder's `**Plan:**`, so all four gates are decoupled from model availability and GPU contention). Run in order: start the watcher against a disposable fixture channel (G60), then the two negative cases in the same channel (G61 depends on G60 having already produced one audit line to compare against), then the duplicate-suppression case (G62, same root again), then the process-guard case last (G63, since it stops the watcher).

## 7. Validation commands

```bash
chmod +x console/approve-watch.sh scripts/validate-19.sh
./scripts/validate-19.sh
tail -n 40 /tmp/validate-19.log
```

Manual (cannot be scripted — needs the operator's own Buzz Desktop identity, not `TEAM_SMOKE_PRIVATE_KEY`): with `make approval-watch` running, post a real job from the console Jobs screen, wait for the builder's `**Plan:**`, then reply in Buzz Desktop with a bare `approved` (no `@mention`) — confirm the builder starts a new turn within one poll interval, and that `console/audit.log`'s tail shows `"actor":"watcher","action":"approve-job"`.

## 8. Execution report

_Fill in after running `scripts/validate-19.sh`:_

1. **Verdict table** — one row per gate (G60–G63): PASS/FAIL and the number(s) that prove it (audit-line counts, timings).
2. **Deviations** from this plan's exact text, each with its cause and where it was fixed (file and section).
3. **The log** — `/tmp/validate-19.log`, verbatim, trimmed only of repeated boilerplate.
