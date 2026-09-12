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

- Consistency-sweep fixes:
- Gate results (G0–G10), with output:
- Clean-clone result:
- Anything not run, and why:
