# Plan 07 — Assembly, README, full gate suite

**Spec:** `docs/spec.md` (all). **Rules:** `AGENTS.md`.
**Sequence:** 7 of 7. Requires plans 01–06 executed and individually validated.
**Execute with:** `/execute plans/07-assembly-and-readme.md`

---

## 1. Overview

Turn six individually validated layers into one product: reconcile `docker-compose.yml`, `.env.example` and `scripts/` against the spec, prove every profile combination and every gate G0–G10 against the fully assembled stack on this host, prove a **clean clone** works with `make init && make up && make test`, and write the final `README.md` and `AGENTS.md`.

**Success criteria:** the validation section below runs top to bottom with real output; the README lets a new developer go from clone to all four services (and the agent) with no other document.

---

## 2. Relevant files

| Path | Action |
|---|---|
| `docker-compose.yml`, `.env.example`, `scripts/*` | review/correct only |
| `README.md` | rewrite (structure below) |
| `AGENTS.md` | update status + commands |
| `plans/07-assembly-and-readme.md` | append execution report |

---

## 3. Tasks

### Task 1 — consistency sweep (expect to find at least one gap)

1. Every `${VAR` in `docker-compose.yml` exists in `.env.example`:
   ```bash
   diff <(grep -oE '(^|[^$])\$\{[A-Z0-9_]+' docker-compose.yml | grep -oE '[A-Z0-9_]+$' | sort -u) \
        <(grep -oE '^#? ?[A-Z0-9_]+=' .env.example | tr -d '#= ' | sort -u)
   ```
   Lines only on the right are fine (documented but unused, e.g. `GITEA_ADMIN_TOKEN`); lines only on the left are defects. (`$${VAR}` container-side references such as `REDIS_PASSWORD` are excluded by the `[^$]` guard.)
2. Every variable in spec §3 is in `.env.example` (same grep against `docs/spec.md`).
3. Every image tag in `docker-compose.yml` matches spec §1 exactly (`grep -E 'image:' docker-compose.yml`).
4. Every `ports:` entry starts with `${BIND_HOST:-127.0.0.1}`.
5. No `depends_on` names a service in a different profile (read the file; spec §4.3).
6. `scripts/smoke-test.sh` dispatcher covers `litellm`, `openwebui`, `buzz`, `gitea`, `buzz-agent`.

Fix what you find; record each fix in §6.

### Task 2 — full gate suite on the assembled stack

```bash
# G0 -- every profile alone, the default set, and everything
for p in "" litellm openwebui buzz gitea buzz-agent ollama llamacpp litellm,openwebui,buzz,gitea litellm,openwebui,buzz,gitea,buzz-agent,ollama,llamacpp; do
  COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: '$p'" || { echo "G0 FAIL: '$p'"; exit 1; }
done
COMPOSE_PROFILES=litellm,openwebui,buzz,gitea docker compose config --services | sort

# G1, G2, G3–G7 on the default set + agent
sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,buzz-agent|' .env
make down; make up; docker compose ps
make gitea-bootstrap
make test

# G8 -- loopback only, no stray ports
docker compose ps --format '{{.Name}} {{.Ports}}' | tee /dev/stderr | grep -vE '127\.0\.0\.1:|^[^ ]+ *$' | grep -qE '0\.0\.0\.0|:::' && echo "G8 FAIL" || echo "G8 ok"

# G9 -- external gateway swap: Open WebUI pointed at "some gateway on this machine" (LiteLLM's own published
#       port through host.docker.internal). Needs BIND_HOST=0.0.0.0 for the duration because host-gateway
#       cannot reach a 127.0.0.1-bound port (reachability case 3). Shell env overrides .env.
make down
BIND_HOST=0.0.0.0 LITELLM_URL=http://host.docker.internal:3000 COMPOSE_PROFILES=litellm,openwebui docker compose up -d --wait
BIND_HOST=0.0.0.0 docker compose exec -T open-webui sh -c 'env | grep OPENAI_API_BASE_URL'     # http://host.docker.internal:3000/v1
make test                                   # openwebui section must still list the registry models
make down; make up                          # back to loopback defaults

# G10 -- plan 05 already proved the ollama profile; re-run its G0 lines above only.

# Clean-clone proof (the real "new developer" path)
make down
tmp=$(mktemp -d) && git clone -q . "$tmp/open-llm-stack" && cd "$tmp/open-llm-stack"
make init && make up && make gitea-bootstrap && make test
make down && cd - && rm -rf "$tmp"
make up
```

### Task 3 — `README.md` (rewrite)

Keep it operator-facing and dense (calibrate on `examples/open-llm-runner/README.md` in this checkout for tone, but shorter). Required sections, in order:

1. **Title + one paragraph**: local-first, open-weights dev stack; four batteries; bring your own LLM.
2. **Quick start** (from plan 01, corrected): prerequisites, `make init && make up && make test`, the four URLs, where the master key and admin password live (`.env`).
3. **What runs** — the table from spec §1 (service, port, profile, image tag).
4. **Turning layers on/off and pointing at external services** — `COMPOSE_PROFILES` + the `*_URL` variables, one example per layer (external gateway, external relay, external Gitea, no Open WebUI). State the no-cross-profile-`depends_on` rule in one sentence so people editing the compose file keep it.
5. **Bring your own LLM backend** (plan 05 section) + **Registering models** (edit `proxy/config.yaml`, `make reload`, prefixes, reserve formula table).
6. **Open WebUI** (plan 02 section).
7. **Buzz relay** (plan 03 section) and **Buzz + LLMs through LiteLLM** (plan 06 section).
8. **Gitea** (plan 04 section).
9. **Security notes**: loopback-only default and what `BIND_HOST=0.0.0.0` exposes; the open relay is open (anyone with the URL joins) — closed mode one-liner; LiteLLM supply-chain note (PyPI 1.82.7/1.82.8 were malicious; this stack pins the official image tag `v1.89.7`); Open WebUI no-login mode is for a single trusted machine.
10. **Troubleshooting**: `relay: no community is configured for this host` (use `BUZZ_PUBLIC_HOST` literally); `port BUSY` from `make up`; preflight cases; Open WebUI shows no models (`LITELLM_URL`/`LITELLM_MASTER_KEY`, `ENABLE_PERSISTENT_CONFIG` already false); agent silent (add it to the channel; `docker compose logs buzz-agent`).
11. **Data & backups**: named volumes list; `.env` holds the relay key — back it up; `docker compose down -v` destroys everything.
12. **Make targets** and **Layout** (spec §2 tree).
13. **Credits / upstream**: LiteLLM, Open WebUI, Buzz (block/buzz, Apache-2.0), Gitea, Ollama, llama.cpp.

Remove the temporary sections the earlier plans appended once their content is folded in.

Acceptance: a reader can find every `.env` variable's purpose either in the README or by following its pointer to `docs/spec.md §3`; no section references a file that does not exist.

### Task 4 — `AGENTS.md`

Update the status line to "all seven plans executed on <date>", keep the rules, and make sure the "Development commands" block matches the Makefile exactly.

---

## 4. Testing strategy

The gates are the tests. Paste real output for each gate into §6 below, and mark any gate you could not run with the reason (do not fake it).

## 5. Integration notes

- Leave the stack **up** at the end with `COMPOSE_PROFILES=litellm,openwebui,buzz,gitea` (agent profile off) unless the operator says otherwise.
- Do not delete `examples/` (gitignored reference material) or `plans/`.

## 6. Execution report (fill in)

Executed 2026-09-12 on the reference host (Compose v5.1.3, external Ollama at 0.0.0.0:11434). Tasks 1 and 2 of this plan; Tasks 3–4 (README.md, AGENTS.md) were done by a parallel agent and are not covered here. Nothing committed.

### Consistency sweep (Task 1)

| # | Check | Finding | Fix |
|---|---|---|---|
| 1 | `${VAR}` in `docker-compose.yml` vs `.env.example` | Only right-side lines: `BUZZ_AGENT_PUBKEY`, `COMPOSE_PROFILES`, `GITEA_ADMIN_PASSWORD`, `GITEA_ADMIN_TOKEN`, `GITEA_ADMIN_USER` (documented, used by scripts/Compose itself, not by the compose file). No left-side lines. | none |
| 2 | spec §3 block vs `.env.example` | `diff` exit 0 — identical variable sets (including the commented `RELAY_OWNER_PUBKEY`, `LLAMACPP_*`). | none |
| 3 | image tags vs spec §1 | 11 distinct tags in compose, 11 in spec §1, identical set (`postgres:17.11-alpine` used twice). | none |
| 4 | `ports:` entries | 4 entries (litellm, open-webui, buzz, gitea), all `"${BIND_HOST:-127.0.0.1}:…"`. ollama/llamacpp/buzz-agent publish nothing. | none |
| 5 | `depends_on` across profiles | `litellm→litellm-db` (both `[litellm]`); `buzz→buzz-db/buzz-redis/buzz-minio/buzz-minio-init` and `buzz-minio-init→buzz-minio` (all `[buzz]`). open-webui, gitea, buzz-agent, ollama, llamacpp have no `depends_on`. | none |
| 6 | smoke-test dispatcher | Lines 98–102 dispatch `litellm`, `openwebui`, `buzz`, `gitea`, `buzz-agent`. The comment above them was stale: `# --- dispatcher (later plans add: openwebui, buzz, gitea) ---`. | `scripts/smoke-test.sh` line 97 → `# --- dispatcher: one section per profile in COMPOSE_PROFILES ---` (comment only) |

Net code change from the sweep: one comment line in `scripts/smoke-test.sh`. The "expected gap" in the plan turned out to be documentation drift, not a functional defect.

### Gate results (Task 2)

**G0 — every profile combination** (10 runs):
```
G0 ok: ''
G0 ok: 'litellm'
G0 ok: 'openwebui'
G0 ok: 'buzz'
G0 ok: 'gitea'
G0 ok: 'buzz-agent'
G0 ok: 'ollama'
G0 ok: 'llamacpp'
G0 ok: 'litellm,openwebui,buzz,gitea'
G0 ok: 'litellm,openwebui,buzz,gitea,buzz-agent,ollama,llamacpp'
$ COMPOSE_PROFILES=litellm,openwebui,buzz,gitea docker compose config --services | sort
buzz buzz-db buzz-minio buzz-minio-init buzz-redis gitea litellm litellm-db open-webui   (9 services, as spec §4.2)
```

**G1/G2 — `make down; make up` with `COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,buzz-agent`** (down 5.8 s removed all 9 + network; up 37.3 s):
```
 Container open-llm-stack-buzz-agent-1 Healthy
 Container open-llm-stack-buzz-1 Healthy
 Container open-llm-stack-open-webui-1 Healthy
 Container open-llm-stack-litellm-1 Healthy
./scripts/preflight.sh
OK  backend reachable at http://host.docker.internal:11434/v1/models
$ docker compose ps  -> 9 containers, all (healthy); ports 127.0.0.1:3000->4000, :3001->8080, :3002->3002, :3003->3000
$ make gitea-bootstrap
admin user stackadmin already exists
GITEA_ADMIN_TOKEN already set in .env (pass --rotate to mint a new one)
```

**G3–G7 — `make test` (51.7 s), all five sections, first attempt:**
```
--- litellm: registry            embed laguna-max ornith-max qwen3.6-max qwen3.8-max (max_input 237568/237568/237568/106496, locus local)
--- litellm: chat round-trip     qwen3.6-max -> OK  ornith-max -> OK  laguna-max -> OK  qwen3.8-max -> OK
--- litellm: embeddings          1024
--- litellm: no closed-weight model or router registered   ok
--- open-webui: health           healthy / version 0.11.3  auth=false
--- open-webui: models via LiteLLM   embed laguna-max ornith-max qwen3.6-max qwen3.8-max
--- open-webui: chat round-trip via qwen3.6-max   OK
--- buzz: readiness 200 / liveness on 127.0.0.1:3002: 200
--- buzz: NIP-11                 Buzz Relay 0.2.1 nips=14 self=938eb3301c0c6c13...
--- buzz: community host == BUZZ_PUBLIC_HOST   community host: 127.0.0.1:3002
--- buzz: browser UI             web UI served at http://127.0.0.1:3002/
--- buzz: real client            channels visible: 6
--- gitea: healthz: pass / version 1.27.3 / user stackadmin admin=true
--- gitea: create + clone + delete   created stackadmin/smoke-1789240962 private=true ... cloned (README.md ) ... deleted smoke-1789240962
channel 2c8ddc74-3b54-4099-8368-2142f2d0cdb7
mention sent; waiting for the agent (up to 240s)
agent replied after ~10s: PONG
smoke test finished
```

**G8 — loopback only** (9 containers up, agent on host network shows no ports):
```
open-llm-stack-buzz-1 3000/tcp, 8080/tcp, 9102/tcp, 127.0.0.1:3002->3002/tcp
open-llm-stack-buzz-agent-1
open-llm-stack-gitea-1 22/tcp, 127.0.0.1:3003->3000/tcp
open-llm-stack-litellm-1 127.0.0.1:3000->4000/tcp
open-llm-stack-open-webui-1 127.0.0.1:3001->8080/tcp
(+ buzz-db 5432/tcp, buzz-minio 9000/tcp, buzz-redis 6379/tcp, litellm-db 5432/tcp — container-side only)
G8 ok
```

**G9 — external gateway swap** (`make down` 5.9 s; up 42.1 s):
```
$ BIND_HOST=0.0.0.0 LITELLM_URL=http://host.docker.internal:3000 COMPOSE_PROFILES=litellm,openwebui docker compose up -d --wait
 Container open-llm-stack-litellm-db-1 Healthy / open-webui-1 Healthy / litellm-1 Healthy
$ ... docker compose exec -T open-webui sh -c 'env | grep OPENAI_API_BASE_URL'
OPENAI_API_BASE_URL=http://host.docker.internal:3000/v1
$ docker compose ps -> litellm 0.0.0.0:3000->4000/tcp, open-webui 0.0.0.0:3001->8080/tcp (expected for the duration of G9)
$ tok=$(curl -fsS -X POST http://127.0.0.1:3001/api/v1/auths/signin -d '{"email":"","password":""}' | jq -r .token)   # length 247
$ curl -fsS -H "Authorization: Bearer $tok" http://127.0.0.1:3001/api/models | jq -r '.data[].id' | grep -v '^arena-model$' | sort
embed
laguna-max
ornith-max
qwen3.6-max
qwen3.8-max
$ BIND_HOST=0.0.0.0 LITELLM_URL=... COMPOSE_PROFILES=litellm,openwebui docker compose down   -> network removed, 0 project containers left
$ make up (37.8 s) -> preflight OK; docker compose ps --format '{{.Name}} {{.Ports}}' shows only 127.0.0.1: bindings again (9 containers)
```
Deviation from the plan text: `make test` was **not** run in the G9 state — `.env` still carried `COMPOSE_PROFILES=…,buzz,gitea,buzz-agent`, so the script would have tried the buzz/gitea/agent sections against containers that were deliberately not running. The openwebui section's exact check (empty-credential sign-in → `/api/models`) was run by hand instead, shown above.

**G10 — optional backends:** not re-run here; proven in `plans/05-optional-backends.md` §7 ("G10 -- ollama profile: PASS", "G10 -- llamacpp profile: PASS", 2026-09-12). Re-verified in this plan only via the G0 lines for `ollama`, `llamacpp` and the all-profiles combination above. (`open-llm-stack_ollama-data` volume still present from plan 05.)

### Clean-clone result

Deviation from the plan text and why: `docker-compose.yml` pins `name: open-llm-stack`, so a clone on the same host would attach to the live project's named volumes (`open-llm-stack_litellm-db-data` etc., already initialised with the operator's passwords) while its fresh `.env` generates new ones — Postgres would refuse the new credentials. The clone was therefore run under `COMPOSE_PROJECT_NAME=open-llm-stack-clone` (CLI env outranks the file's `name:`), which gives it its own containers, volumes and project label. Side effect: `scripts/check-ports.sh` filters on the `open-llm-stack` label, so it only reports `ports ok`; harmless here because the main stack was down and 3000–3003 were free.

```
$ make down                      -> Network open-llm-stack Removed; networks: 0; containers (label project=open-llm-stack): 0
$ tmp=$(mktemp -d) && git clone -q /home/adam/code/open-llm-stack "$tmp/open-llm-stack"   # HEAD d396aea, no .env, no proxy/config.yaml
$ export COMPOSE_PROJECT_NAME=open-llm-stack-clone
$ make init   (0.8 s)
created .env from .env.example
created proxy/config.yaml from proxy/config.yaml.example
generated LITELLM_MASTER_KEY / LITELLM_DB_PASSWORD / WEBUI_SECRET_KEY / BUZZ_GIT_HOOK_HMAC_SECRET / BUZZ_DB_PASSWORD
generated BUZZ_REDIS_PASSWORD / BUZZ_S3_ACCESS_KEY / BUZZ_S3_SECRET_KEY / GITEA_ADMIN_PASSWORD
generated BUZZ_RELAY_PRIVATE_KEY / BUZZ_AGENT_PRIVATE_KEY / BUZZ_AGENT_PUBKEY          (12 values)
init complete. Next: check LLM_BASE_URL in .env and the models in proxy/config.yaml, then: make up
$ make up     (1:32 — fresh volumes, first-boot migrations)
 Container open-llm-stack-clone-{litellm-db,buzz-db,buzz-minio,buzz-redis,buzz,gitea,litellm,open-webui}-1 Healthy; buzz-minio-init Exited
./scripts/preflight.sh
OK  backend reachable at http://host.docker.internal:11434/v1/models
$ docker compose ps -> 8 containers (healthy), 127.0.0.1:3000/3001/3002/3003
$ make gitea-bootstrap
created admin user stackadmin
GITEA_ADMIN_TOKEN written to .env
$ make test   (36.1 s) -> litellm: 5 models, 4 chat OK, embeddings 1024, no closed-weight ok
                          open-webui: healthy 0.11.3, 5 models, chat OK
                          buzz: readiness/liveness 200, NIP-11 self=8339940dd5e08a58... (distinct relay key), community host 127.0.0.1:3002, web UI served, channels visible: 0
                          gitea: healthz pass, 1.27.3, stackadmin admin=true, created/cloned/deleted smoke-1789241249
                          smoke test finished
$ COMPOSE_PROJECT_NAME=open-llm-stack-clone docker compose down -v
 Volume open-llm-stack-clone_{gitea-data,litellm-db-data,buzz-redis-data,buzz-db-data,buzz-minio-data,open-webui-data,buzz-git-data} Removed; Network open-llm-stack Removed
clone volumes left: 0 ; main volumes intact: 8 (open-llm-stack_{buzz-db,buzz-git,buzz-minio,buzz-redis,gitea,litellm-db,ollama,open-webui}-data)
$ rm -rf "$tmp"; unset COMPOSE_PROJECT_NAME
$ make up     (38.0 s) -> 9 containers healthy (agent profile still in the main .env at this point), preflight OK
```
Result: PASS. A new developer's path (`make init && make up && make gitea-bootstrap && make test`) works with zero edits on this host.

### Final state (plan §5)

```
$ COMPOSE_PROFILES=buzz-agent docker compose down      -> Container open-llm-stack-buzz-agent-1 Removed   (run first, so it is not orphaned)
$ sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=litellm,openwebui,buzz,gitea|' .env
$ make up     (2.0 s, containers already running) -> preflight OK
$ docker compose ps -> 8 containers, 8 healthy, all published ports 127.0.0.1:*;  docker ps -a | grep buzz-agent -> (empty)
$ ./scripts/preflight.sh
OK  backend reachable at http://host.docker.internal:11434/v1/models
$ make test   (31.5 s) -> litellm / open-webui / buzz (channels visible: 7) / gitea (smoke-1789241349) all pass; "smoke test finished"
```
The stack is left up with `COMPOSE_PROFILES=litellm,openwebui,buzz,gitea`, `.env` valid, agent profile off.

### Timings

| Step | Wall time |
|---|---|
| `make down` (9 containers) | 5.8 s |
| `make up` (9, warm volumes) | 37.3 s |
| `make test` (5 sections incl. agent) | 51.7 s (agent reply ~10 s) |
| G9 `up -d --wait` (litellm+openwebui, BIND_HOST=0.0.0.0) | 42.1 s |
| clone `make init` / `make up` / `make test` | 0.8 s / 1:32 / 36.1 s |
| final `make up` (no-op) / `make test` (4 sections) | 2.0 s / 31.5 s |

### Anything not run, and why

- **G10 live** — not re-run; plan 05's report is the proof, per this plan's own instruction ("re-run its G0 lines above only").
- **`make test` in the G9 configuration** — replaced by the direct Open WebUI check (see G9), because `.env`'s `COMPOSE_PROFILES` would have dispatched sections for layers intentionally absent in that state.
- **Clean clone with the literal plan commands** (`git clone .` + no project override) — replaced by the `COMPOSE_PROJECT_NAME=open-llm-stack-clone` variant for the volume-collision reason above; `down -v` was never run against the main project.
- Buzz-agent single-miss retry (`./scripts/buzz-smoke.sh` second run) — not needed; the agent answered on the first attempt.
- Unrelated working-tree changes observed but not made by this task: `README.md`, `AGENTS.md`, `plans/01-foundation-and-litellm.md`, `proxy/config.yaml.example` (parallel README/AGENTS agent).
