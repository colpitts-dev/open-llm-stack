# Plan 20 — Chat command dispatcher: every console action, from Buzz chat

**Spec:** `docs/spec.md` (this plan adds §5.22 and gates G64–G67; plan 18 claims §5.20/G55–G59, plan 19 claims §5.21/G60–G63). **Rules:** `AGENTS.md`. **Knowledge:** plan 17 §5.19 (console, `ACTIONS`, the `p()`/regex validators, `console/audit.log`), plan 19 §5.21 (job-channel polling pattern, the docker-in-a-while-read stdin gotcha, `TEAM_ALLOWLIST`/`TEAM_SMOKE_PUBKEY` as the sender allowlist).
**Sequence:** 20 (after 17; independent of 19, but reuses its lessons — see §5). Requires plan 17 executed (`console/app.py`'s `ACTIONS`, `p()`, `Runner`, `console/audit.log`). Adds one script (`console/chatctl.py`), one make target (`chat-dispatch`), one persistent private Buzz channel (`sidekick`, created idempotently by the script itself, not by a separate bootstrap step), two gitignored state files. No new service, image, port, network, container, Python package, or `.env` variable.
**Execute with:** `/execute plans/20-chat-command-dispatcher.md`
**No internet at execution.** Every value below was verified live on the reference host on 2026-09-15, against the already-pinned `ghcr.io/block/buzz-sprig:sha-e17cdd9` image (same tag plans 17 and 19 already pin — this plan adds no new one) and the already-running `piedpiper` team.

---

## 1. Overview

Product requirement (verbatim): "console is god mode - all actions should be supported. chat is a requirement for any workflow actions human/agent interaction." Plan 19 solved one narrow case — a bare `approved` reaching the builder with no `@mention` — by hand-rolling a single-purpose bash matcher. This plan generalizes: every entry in the console's own `ACTIONS` allowlist (`init`, `up`, `down`, `test`, `member-add`, `team-model`, `restart`, `post-job`, `approve-job`, … all nineteen actions in `console/app.py`, unchanged) becomes invokable from Buzz chat, typed as a slash command, with the exact same validation, execution and audit trail as clicking the matching console button.

The key design decision, found by reading `console/app.py` in full: it is already import-safe. `ACTIONS`, `p()`, the regexes (`NAME`/`ROLE`/`SERVICE`/`UUID`/`HEX64`), the `Job`/`Runner` classes, `RUNNER` itself, `AUDIT`, and `read_env()` are all module-level objects; only `main()` (guarded by `if __name__ == "__main__"`) starts the HTTP server. A sibling script in the same directory can `import app as console` and get every one of these directly — the *same* allowlist object, not a second copy re-encoded in bash regex the way plan 19's watcher had to. This removes the biggest risk a chat surface would otherwise carry: two allowlists drifting apart. It also means `console/chatctl.py` doesn't need to hand-write the audit-log line the way plan 19's script did — submitting a `Job` to the imported `RUNNER` writes the exact same JSONL line `console/app.py` already writes for the web UI, for free.

Slash-command syntax was chosen over a bang prefix after checking what modern chat apps actually standardized on (Slack, Discord, Telegram all use `/command`); params reuse `ACTIONS`' own field names (`T`, `N`, `R`, `M`, `S`, `C`) so a chat command and a console form field are one vocabulary, not two — `/member-add T=piedpiper N=bertram R=builder` mirrors `make member-add T=piedpiper N=bertram R=builder` exactly. A destructive action's console-side "type the name back" becomes an inline `confirm=<action>` param in the same message (`/down confirm=down`) — one message, no second reply to land, which is the exact reliability problem this whole line of work exists to route around.

| | |
|---|---|
| New file | `console/chatctl.py`: imports `console/app.py`'s `ACTIONS`/`p`/`Job`/`RUNNER`/regexes/`AUDIT`/`read_env`; creates and polls a persistent `sidekick` channel (stack-wide commands) plus every `job-*` channel (job-scoped commands, same discovery as plan 19); parses `/action key=value ... [-- free text]`; dispatches through the imported `RUNNER`; replies in-thread with the command, exit code and last lines of output |
| New make target | `make chat-dispatch [I=<seconds>]` — foreground, same shape as `make power-meter` / `make approval-watch` |
| New channel | `sidekick` (private, permanent — no `--ttl`), created once by the script if missing; members: the console identity (owner) plus every pubkey in `TEAM_ALLOWLIST` and `TEAM_SMOKE_PUBKEY` (role `member`) |
| New state (gitignored, host-local) | `console/.chat-since` (poll low-water mark), `console/.chat-seen` (last 500 processed message ids, to survive a watermark-boundary re-scan without double-executing a command) |
| Untouched | `console/app.py`, `console/approve-job.sh`, `console/post-job.sh`, `console/approve-watch.sh` (plan 19), every agent's `BUZZ_ACP_*` config |

**Success:** any `ACTIONS` entry runs from a `/action key=value ...` message typed in `#sidekick` (stack-wide) or the relevant `job-*` thread (job-scoped), from an allowlisted human only; a destructive action refuses without `confirm=<name>` and runs with it; a non-allowlisted sender (including a teammate agent) or a malformed/unknown command never executes anything; the result — command, exit code, output tail — is replied in-thread and appears in the console's own Audit screen, actor `chat:<pubkey prefix>`.

**Out of scope:** a second confirmation UX (two-message handshake) — rejected, inline `confirm=` param chosen instead; changing any agent's `BUZZ_ACP_*` config; replacing plan 19's bare-`approved` watcher (both run side by side — see §5); a `/help` command or autocomplete (the console UI is still the discoverable surface; chat is for someone who already knows the action name).

## 2. Relevant files

| Path | Action |
|---|---|
| `console/chatctl.py` | new: the dispatcher |
| `Makefile` | new target `chat-dispatch` |
| `.gitignore` | `console/.chat-since`, `console/.chat-seen` |
| `scripts/validate-20.sh` | new: gates G64–G67 |
| `README.md` "Console" | one paragraph: the `sidekick` channel, the slash syntax, that it is the same `ACTIONS` allowlist as the web UI |
| `docs/spec.md` §5.22, §7 | new subsection; gates G64–G67 |
| `AGENTS.md` | status line |

## 3. Dependencies and verified facts (reference host, 2026-09-15)

- `console/app.py` (plan 17, read in full 2026-09-15): `ACTIONS` (line 92) is a module-level `dict[str, (argv_fn, destructive: bool)]`, 19 entries today (`init, up, down, test, reload, gitea-bootstrap, team-bootstrap, check-ports, preflight, stack-status, context-report, context-probe, model-fit, cost-report, team-model, team-status, team-smoke, member-add, member-rm, score-sync, score-report, restart, recreate, unload-model, post-job, approve-job`). `p(params, key, rx=NAME)` (line 87) raises `ValueError(f"bad {key}: {v!r}")` on a regex miss. `Job`/`Runner` (lines 122–154): `RUNNER.submit(Job(name, argv, actor))` queues one job at a time; `Runner.loop()` itself appends the audit line (`{"ts","actor","action","cmd","exit","seconds","job"}`) to `AUDIT` (`console/audit.log`) when the job finishes — the dispatcher never writes that file directly. Only `main()`, guarded by `if __name__ == "__main__":`, binds the HTTP port; every other name at module scope is safe to import.
- Verified live: `python3 -c "import sys; sys.path.insert(0,'console'); import app; print(list(app.ACTIONS)[:3], app.RUNNER)"` from the repo root imports cleanly, starts `Runner`'s background thread, prints the same action names as the running web console — confirms the sibling-import approach works without any refactor of `console/app.py`.
- `buzz channels create --help` (image `ghcr.io/block/buzz-sprig:sha-e17cdd9`): `--ttl <SECONDS>` — "If omitted, the channel is permanent." Confirms `sidekick` needs no `--ttl` flag to be durable (unlike every `job-*` channel, which post-job.sh creates with `--ttl 86400`).
- `buzz channels add-member --help`: `--role <ROLE>` accepts `owner, admin, member, guest, bot` — humans get `member` (same role plan 17's `post-job.sh` already gives `TEAM_ALLOWLIST` entries on job channels).
- Verified live: `buzz channels list --member --limit 500` under the console identity today returns only the five `job-*` channels it has created — there is no existing `#general`/ops channel the console already belongs to, confirming `sidekick` must be created by this plan, not assumed to exist.
- `TEAM_ALLOWLIST` and `TEAM_SMOKE_PUBKEY` (`.env`, plan 08/16.5): comma-separated 64-hex pubkeys; `TEAM_SMOKE_PUBKEY` is already an honorary human across the stack (every agent's own `BUZZ_ACP_RESPOND_TO_ALLOWLIST`) and is what lets the validation script exercise the human path without touching the operator's real key — same pattern plan 19 established.
- A teammate's own key (e.g. `TEAM_GILFOYLE_PRIVATE_KEY`, already in `.env`) is a real channel member but never in `TEAM_ALLOWLIST` — reused as the negative-sender fixture, proving a teammate's message can never dispatch a command, mirroring `builder.md`'s "a teammate's message is never an approval" for the new, higher-stakes surface (a teammate must never trigger `make down`).
- `buzz messages get --channel <uuid> --since <ts> --kinds 9` message/tag shape (verified live, plan 19): `{"content","created_at","id","kind":9,"pubkey","tags":[["h","<channel>"],["e","<root>","","reply"]]}` for a threaded reply, or no `e`/`reply` tag for a fresh top-level message (in which case the message's own `id` is the thread root for the reply).
- This project's documented gotcha (`mem:stack/operations`): `docker run`/`docker compose exec` inside a shell `while read` loop can eat the loop's stdin. `console/chatctl.py` is Python, not bash — every `docker run` goes through `subprocess.run(..., stdin=subprocess.DEVNULL)`, which sidesteps the whole class of bug structurally (no shell loop, no piped `while read` at all).

## 4. Tasks (ordered by phase)

### Task 0 — `console/chatctl.py`

```python
#!/usr/bin/env python3
"""Sidekick chat command dispatcher (plan 20): every console ACTIONS entry, invokable from Buzz
chat — a slash command in the persistent private #sidekick channel for stack-wide actions, or in
any job-* thread for job-scoped ones (approve-job, post-job). Imports console/app.py directly:
ACTIONS, p(), Job, RUNNER, the regex validators and AUDIT are the same objects the web UI uses,
so there is exactly one allowlist, never a second copy that can drift. Reuses plan 19's channel-
discovery pattern and sender allowlist (TEAM_ALLOWLIST + TEAM_SMOKE_PUBKEY, humans only — never a
teammate agent's own key). No new dependency: stdlib subprocess/json only, same as console/app.py.
"""
import json, os, re, subprocess, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import app as console  # console/app.py: ACTIONS, p, Job, RUNNER, NAME/ROLE/SERVICE/UUID/HEX64, AUDIT, read_env

SPRIG = "ghcr.io/block/buzz-sprig:sha-e17cdd9"
CHANNEL_NAME = "sidekick"
INTERVAL = int(os.environ.get("I", "15"))
SINCE_FILE = os.path.join("console", ".chat-since")
SEEN_FILE = os.path.join("console", ".chat-seen")
CMD_RE = re.compile(r"^/(?P<name>[a-z][a-z0-9-]*)(?P<kv>(?:\s+[A-Za-z_]+=\S*)*)(?:\s+--\s+(?P<text>.*))?\s*$", re.S)


def bz(private_key, *args):
    e = console.read_env()
    url = os.environ.get("BUZZ_RELAY_URL") or f"ws://{e.get('BUZZ_PUBLIC_HOST', '127.0.0.1:3002')}"
    cp = subprocess.run(
        ["docker", "run", "--rm", "--network", "host", "-e", f"BUZZ_PRIVATE_KEY={private_key}",
         "-e", f"BUZZ_RELAY_URL={url}", "--entrypoint", "buzz", SPRIG, *args],
        capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)
    return cp.returncode, cp.stdout


def bz_console(*args):
    e = console.read_env()
    return bz(e.get("CONSOLE_PRIVATE_KEY", ""), *args)


def allowlist(e):
    return set(filter(None, (e.get("TEAM_ALLOWLIST", "") + "," + e.get("TEAM_SMOKE_PUBKEY", "")).split(",")))


def ensure_channel(e):
    rc, out = bz_console("channels", "list", "--member", "--limit", "500")
    for c in json.loads(out or "[]"):
        if c.get("name") == CHANNEL_NAME:
            return c["channel_id"]
    rc, out = bz_console("channels", "create", "--name", CHANNEL_NAME, "--type", "stream", "--visibility", "private")
    ch = json.loads(out)["channel_id"]
    for pk in allowlist(e):
        bz_console("channels", "add-member", "--channel", ch, "--pubkey", pk, "--role", "member")
    print(f"created #{CHANNEL_NAME} ({ch}); members: {sorted(allowlist(e))}")
    return ch


def job_channels():
    rc, out = bz_console("channels", "list", "--member", "--limit", "500")
    return [c["channel_id"] for c in json.loads(out or "[]") if (c.get("name") or "").startswith("job-")]


def load_seen():
    if not os.path.exists(SEEN_FILE):
        return []
    return open(SEEN_FILE).read().split()


def mark_seen(mid):
    ids = (load_seen() + [mid])[-500:]
    with open(SEEN_FILE, "w") as f:
        f.write(" ".join(ids))


def reply(ch, root, text):
    bz_console("messages", "send", "--channel", ch, "--reply-to", root, "--content", text[:1800])


def parse(content):
    m = CMD_RE.match(content.strip())
    if not m:
        return None
    params = dict(kv.split("=", 1) for kv in m.group("kv").split())
    if m.group("text"):
        params.setdefault("text", m.group("text"))
        params.setdefault("note", m.group("text"))
    return m.group("name"), params


def run_and_reply(ch, root, name, argv, actor):
    job = console.RUNNER.submit(console.Job(name, argv, actor))
    job.done.wait(1200)
    tail = "\n".join(list(job.lines)[-15:])
    reply(ch, root, f"`{job.cmd()}` -> exit {job.rc}\n{tail}")


def dispatch(ch, root, pk, content):
    parsed = parse(content)
    if not parsed:
        return
    name, params = parsed
    spec = console.ACTIONS.get(name)
    if not spec:
        reply(ch, root, f"unknown action: {name}")
        return
    argv_fn, destructive = spec
    if destructive and params.get("confirm") != name:
        reply(ch, root, f"destructive: send `/{name} confirm={name}` to run it")
        return
    try:
        argv = argv_fn(params)
    except ValueError as ex:
        reply(ch, root, f"bad command: {ex}")
        return
    reply(ch, root, f"running: `{' '.join(argv)}`")
    threading.Thread(target=run_and_reply, args=(ch, root, name, argv, f"chat:{pk[:8]}"), daemon=True).start()


def poll_channel(ch, since, allow, seen):
    rc, out = bz_console("messages", "get", "--channel", ch, "--since", str(since), "--kinds", "9")
    try:
        events = json.loads(out or "[]")
    except json.JSONDecodeError:
        return
    for ev in events:
        mid = ev.get("id", "")
        if not mid or mid in seen:
            continue
        pk = ev.get("pubkey", "")
        if pk not in allow:
            continue
        root = next((t[1] for t in ev.get("tags", []) if t and t[0] == "e" and (t[3] if len(t) > 3 else "") == "reply"), mid)
        dispatch(ch, root, pk, ev.get("content", ""))
        mark_seen(mid)
        seen.add(mid)


def main():
    mine = os.getpid()
    others = subprocess.run(["pgrep", "-f", "[c]hatctl.py"], capture_output=True, text=True).stdout.split()
    if any(int(p) != mine for p in others):
        print(f"another chatctl.py is already running: {others}")
        sys.exit(1)

    e = console.read_env()
    sidekick = ensure_channel(e)
    since = int(open(SINCE_FILE).read()) if os.path.exists(SINCE_FILE) else int(time.time())
    seen = set(load_seen())
    print(f"chat dispatcher: #{CHANNEL_NAME} ({sidekick}) + job-* channels, poll every {INTERVAL}s (Ctrl-C to stop)")
    try:
        while True:
            allow = allowlist(e)
            for ch in [sidekick, *job_channels()]:
                poll_channel(ch, since, allow, seen)
            since = int(time.time())
            with open(SINCE_FILE, "w") as f:
                f.write(str(since))
            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
```

### Task 1 — `Makefile`

Append after the `approval-watch:` target added by plan 19 (or, if plan 19 has not been executed on this checkout, after the `console:` target):

Old:
```
console:         ## the console on BIND_HOST:CONSOLE_PORT (127.0.0.1:3004): a window onto the same files and scripts (plan 17)
	python3 console/app.py
```

New:
```
console:         ## the console on BIND_HOST:CONSOLE_PORT (127.0.0.1:3004): a window onto the same files and scripts (plan 17)
	python3 console/app.py

chat-dispatch:   ## every console action from Buzz chat: /action key=value in #sidekick (stack-wide) or a job-* thread (plan 20; foreground, Ctrl-C to stop): make chat-dispatch [I=<seconds>]
	@I=$(I) python3 console/chatctl.py
```

### Task 2 — `.gitignore`

Old:
```
console/audit.log
```

New:
```
console/audit.log
console/.chat-since
console/.chat-seen
```

### Task 3 — `scripts/validate-20.sh`

```bash
#!/usr/bin/env bash
# Validate plan 20 (chat command dispatcher): gates G64-G67. Usage: scripts/validate-20.sh
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
LOG=${VALIDATE_LOG:-/tmp/validate-20.log}
: > "$LOG"
log(){ echo "$@" | tee -a "$LOG"; }

mine=$$
others=$(pgrep -f '[v]alidate-20\.sh' | grep -v "^${mine}\$" || true)
if [ -n "$others" ]; then log "FAIL guard another validate-20.sh is already running: $others"; exit 1; fi

SPRIG=ghcr.io/block/buzz-sprig:sha-e17cdd9
URL=${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}
bz_console()  { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$CONSOLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }
bz_smoke()    { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_SMOKE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }
bz_gilfoyle() { docker run --rm --network host -e BUZZ_PRIVATE_KEY="$TEAM_GILFOYLE_PRIVATE_KEY" -e BUZZ_RELAY_URL="$URL" --entrypoint buzz "$SPRIG" "$@" </dev/null; }

setsid nohup env I=5 python3 console/chatctl.py > /tmp/validate-20-chat.log 2>&1 < /dev/null &
WPID=$!; sleep 3
PGID=$(ps -o pgid= "$WPID" 2>/dev/null | tr -d ' ')
log "dispatcher pid $WPID pgid $PGID"

# G64: the sidekick channel exists, is permanent, and carries the allowlisted humans as members
ch=$(bz_console channels list --member --limit 500 | jq -r '.[] | select(.name=="sidekick") | .channel_id')
if [ -n "$ch" ]; then
  members=$(bz_console channels members --channel "$ch" | jq -r '.[].pubkey' | sort)
  want=$(printf '%s\n%s\n' "$TEAM_ALLOWLIST" "$TEAM_SMOKE_PUBKEY" | tr ',' '\n' | sort -u)
  if comm -23 <(echo "$want") <(echo "$members") | grep -q .; then
    log "FAIL G64 sidekick channel $ch missing an allowlisted member: $(comm -23 <(echo "$want") <(echo "$members"))"
  else
    log "PASS G64 #sidekick exists ($ch), every allowlisted human is a member"
  fi
else
  log "FAIL G64 no channel named sidekick found after dispatcher startup"
fi

# G65: a valid slash command from an allowlisted human runs and is audited
before=$(grep -c '"actor":"chat:' console/audit.log 2>/dev/null || echo 0)
bz_smoke messages send --channel "$ch" --content "/stack-status" >/dev/null
for i in $(seq 1 30); do after=$(grep -c '"actor":"chat:' console/audit.log 2>/dev/null || echo 0); [ "$after" -gt "$before" ] && break; sleep 1; done
if [ "$after" -gt "$before" ]; then log "PASS G65 /stack-status ran and was audited (chat-actor lines $before -> $after)"
else log "FAIL G65 no chat-actor audit line appeared within 30s"; fi

# G66: a destructive action refuses without confirm=, runs with it
bz_smoke messages send --channel "$ch" --content "/unload-model M=nonexistent-model-xyz" >/dev/null
sleep 4
reply1=$(bz_console messages get --channel "$ch" --limit 5 | jq -r 'sort_by(.created_at) | .[-1].content')
if echo "$reply1" | grep -qi "confirm="; then log "PASS G66a destructive action without confirm= was refused: $reply1"
else log "FAIL G66a expected a confirm= refusal, got: $reply1"; fi
before2=$(grep -c '"actor":"chat:' console/audit.log 2>/dev/null || echo 0)
bz_smoke messages send --channel "$ch" --content "/unload-model M=nonexistent-model-xyz confirm=unload-model" >/dev/null
for i in $(seq 1 30); do after2=$(grep -c '"actor":"chat:' console/audit.log 2>/dev/null || echo 0); [ "$after2" -gt "$before2" ] && break; sleep 1; done
if [ "$after2" -gt "$before2" ]; then log "PASS G66b destructive action with confirm= ran (chat-actor lines $before2 -> $after2)"
else log "FAIL G66b confirmed destructive action never ran"; fi

# G67: a teammate's message and an unknown action are both refused/ignored, never audited
before3=$(grep -c '"actor":"chat:' console/audit.log 2>/dev/null || echo 0)
bz_gilfoyle messages send --channel "$ch" --content "/down confirm=down" >/dev/null
bz_smoke    messages send --channel "$ch" --content "/not-a-real-action" >/dev/null
sleep 8
after3=$(grep -c '"actor":"chat:' console/audit.log 2>/dev/null || echo 0)
if [ "$after3" -eq "$before3" ]; then log "PASS G67 teammate command and unknown action both produced no audit line (still $after3)"
else log "FAIL G67 audit count changed from $before3 to $after3 on a message that should not dispatch"; fi

[ -n "$PGID" ] && kill -TERM -- -"$PGID" 2>/dev/null
sleep 1
if pgrep -f '[c]hatctl\.py' >/dev/null; then log "FAIL guard dispatcher still running after SIGTERM"; else log "PASS guard dispatcher stopped cleanly on SIGTERM"; fi

log "## DONE"
```

### Task 4 — docs

- `docs/spec.md`: new subsection after §5.21, "5.22 Chat command dispatcher (plan 20)": the import-not-duplicate design (`console/chatctl.py` imports `console/app.py`'s `ACTIONS`/`p`/`Job`/`RUNNER` directly), the `sidekick` channel (permanent, private, console + `TEAM_ALLOWLIST` + `TEAM_SMOKE_PUBKEY`), the `/action key=value ... [-- free text]` syntax, the inline `confirm=<action>` rule for destructive actions, human-only sender gating; §7 gates G64–G67.
- `README.md`, in the "Console (port 3004)" section, immediately after the plan 19 approval-watcher paragraph (or after "The rule" bullet if plan 19 is not yet applied to this checkout), insert:

  ```
  - **Chat command dispatcher (plan 20).** `make chat-dispatch` runs every console action from Buzz chat, not only the web UI. It creates a permanent private channel, `#sidekick` (console plus every allowlisted human), and also listens in any open job-\* thread. Type `/action key=value ...` with the same field names the console forms use — `/member-add T=piedpiper N=bertram R=builder`, `/team-model M=qwen3.8-max` — and a destructive action needs an inline `confirm=<action>`, e.g. `/down confirm=down`. It imports `console/app.py`'s own action allowlist directly, so chat and the web UI can never drift apart; every run is audited exactly like a click.
  ```

- `AGENTS.md`: status line append: "; plan 20 (chat command dispatcher: `console/chatctl.py`, `make chat-dispatch`, `#sidekick` channel, gates G64–G67, spec §5.22) executed on `<execution date>`."

## 5. Considerations

- **Why import instead of a shared module.** `console/app.py` was already written import-safe by plan 17 (only `main()` is guarded); splitting `ACTIONS`/`Runner` into a separate `console/core.py` that both files import was considered and rejected as unnecessary churn on a working, tested file for no behavioral gain — the sibling-import (`sys.path.insert` + `import app`) gets the identical guarantee (one allowlist object) with a zero-line change to `console/app.py`.
- **Two RUNNER instances, one audit file.** `console/app.py` (the web server) and `console/chatctl.py` (this plan) are separate processes, each importing its own `Runner()` with its own in-memory queue — they do not share a job queue, so a slow chat-triggered job and a slow web-triggered job can run concurrently instead of one queueing behind the other (plan 17's "one privileged operation at a time" principle holds per-process, not stack-wide). Both append to the same on-disk `console/audit.log`; JSONL line-appends from two processes are safe (no interleaved partial lines at these message sizes). Deliberately deferred: a single shared queue across both processes (would need a lock file or a socket, real added complexity for a home-lab, single-operator deployment where two people are not clicking the console and typing chat commands at the same second).
- **Plan 19's watcher stays.** `console/approve-watch.sh` keeps handling the bare, no-slash `approved`/`#approved` case — that is intentionally *not* a slash command (matching `builder.md`'s own literal rule, "first word `approved`"), and stays the lightest-weight path for the single most common approval. This dispatcher adds the general surface; the two are independent, non-conflicting listeners on the same relay.
- **`sidekick` channel is not audience-isolated the way job channels are.** Every allowlisted human sees every stack-wide command any other allowlisted human runs there — acceptable for a single-operator deployment (`TEAM_ALLOWLIST` has one entry today); a multi-human deployment revisits this.
- **Reply-then-background-thread, not reply-and-block.** `dispatch()` posts an immediate `running: ...` acknowledgement and finishes the wait/reply in a daemon thread, so the poll loop is never blocked by a long job (`team-bootstrap`, `team-smoke`) the way a synchronous wait would block it. The underlying `RUNNER` still serializes actual execution one job at a time.
- **Deliberately deferred:** a `/help` command; per-command permission tiers (today it's binary — allowlisted or not, exactly like the console's own single `operator` actor); rate limiting (the same single-worker `Runner` queue already bounds how fast destructive actions can actually run); handling `/action` text that spans a `-- free text` tail for more than the two actions that need it today (`post-job`, `approve-job`) — a third free-text action would just add its key name to the same `setdefault` pattern in `parse()`.

## 6. Testing strategy

Everything is scriptable against the live relay; no LLM turn is required for any gate (`/stack-status`, `/unload-model` against a nonexistent model, and the negative cases all resolve without needing a builder to respond — `/unload-model` on a made-up model name still runs the actual `curl` against Ollama and gets a normal non-200, which is fine: the gate checks that the *command ran*, not that the model existed). Run in order: start the dispatcher (creates `#sidekick` if missing, G64), a successful non-destructive command (G65), the destructive confirm dance (G66, two sends), then the negative/security case (G67), then the process-guard stop last.

## 7. Validation commands

```bash
chmod +x scripts/validate-20.sh
./scripts/validate-20.sh
tail -n 60 /tmp/validate-20.log
```

Manual (cannot be scripted — needs the operator's own Buzz Desktop identity): with `make chat-dispatch` running, open `#sidekick` in Buzz Desktop and type `/team-status` — confirm a reply arrives with the same table `make team-status` prints in the terminal, and that `console/audit.log`'s tail shows `"actor":"chat:<your pubkey prefix>"`.

## 8. Execution report

_Fill in after running `scripts/validate-20.sh`:_

1. **Verdict table** — one row per gate (G64–G67): PASS/FAIL and the number(s) that prove it.
2. **Deviations** from this plan's exact text, each with its cause and where it was fixed (file and section).
3. **The log** — `/tmp/validate-20.log`, verbatim, trimmed only of repeated boilerplate.
