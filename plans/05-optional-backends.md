# Plan 05 — Optional LLM backends: `ollama` and `llamacpp` profiles

**Spec:** `docs/spec.md` §4, §5.6, §7 (G10). **Rules:** `AGENTS.md`.
**Sequence:** 5 of 7. Requires plan 01 (LiteLLM layer, preflight, smoke test). Independent of 02–04.
**Execute with:** `/execute plans/05-optional-backends.md`

---

## 1. Overview

The stack is bring-your-own-backend by default. This plan adds two **off-by-default** profiles so someone with no backend can still `make up`: `ollama` (Ollama server, models pulled on demand) and `llamacpp` (llama.cpp server, CPU build, you supply a GGUF in `./models/`). Neither publishes a host port; LiteLLM reaches them by service name.

**Success criteria:** G0 with each profile; G10: with `COMPOSE_PROFILES=litellm,ollama` and `LLM_BASE_URL=http://ollama:11434`, preflight passes and a chat completion through LiteLLM returns text from a model pulled into the bundled Ollama. Same for `llamacpp` if a GGUF can be obtained on the execution host (otherwise flag that gate "not run", with the reason).

---

## 2. Relevant files

| Path | Action |
|---|---|
| `docker-compose.yml` | add `ollama`, `llamacpp` services + `ollama-data` volume |
| `.gitignore` | already ignores `models/` and `*.gguf` (plan 01) — verify |
| `README.md` | add "Bring your own LLM backend" section incl. reachability cases and the two profiles |

## 3. Dependencies

- `ollama/ollama:0.34.0` — newest tag on Docker Hub (2026-09-09), verified; **not yet pulled on this host** (`0.33.3` is). Volume `/root/.ollama`.
- `ghcr.io/ggml-org/llama.cpp:server-b10920` — newest `server-b*` CPU tag, verified multi-arch; CUDA twin `server-cuda-b10920`. Not yet pulled. Flags: `-m <model>`, `--host`, `--port`, `-c <ctx>` (`0` = model default).
- Small test model for the ollama gate: `qwen3:0.6b` (Ollama library tag used by the reference project for the same test). Pulling it needs the ollama container to reach `registry.ollama.ai`; if that is blocked on the execution host, use any chat model the operator can provide and say so in the report.
- Small GGUF for the llamacpp gate: `stories260K.gguf` (~1.2 MB) from `https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K.gguf`, or any GGUF the operator drops into `./models/`.

---

## 4. Tasks

### Task 1 — compose services

File: `docker-compose.yml` (modify). Add `ollama-data:` to `volumes:`. Append under `services:`:

```yaml
  # ---------------------------------------------------------------- optional backends (no host ports)
  # Enable with COMPOSE_PROFILES=...,ollama  and  LLM_BASE_URL=http://ollama:11434
  ollama:
    image: ollama/ollama:0.34.0   # verified 2026-09-12
    profiles: [ollama]
    restart: unless-stopped
    volumes:
      - ollama-data:/root/.ollama
    # No ports: the Ollama API has no auth of its own; it is reachable only from this compose network.
    # NVIDIA GPU: uncomment (needs nvidia-container-toolkit on the host):
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: all
    #           capabilities: [gpu]

  # Enable with COMPOSE_PROFILES=...,llamacpp  LLM_BASE_URL=http://llamacpp:8080  LLAMACPP_MODEL_FILE=<file in ./models>
  llamacpp:
    image: ghcr.io/ggml-org/llama.cpp:server-b10920   # CPU build, verified 2026-09-12; GPU: server-cuda-b10920 (same build number)
    profiles: [llamacpp]
    restart: unless-stopped
    command: ["-m", "/models/${LLAMACPP_MODEL_FILE:-your-model.gguf}", "--host", "0.0.0.0", "--port", "8080", "-c", "${LLAMACPP_CTX_SIZE:-0}"]
    volumes:
      - ./models:/models:ro
    # --host 0.0.0.0 is safe here only because no ports: entry exists -- it binds inside the container only.
```

Acceptance: `COMPOSE_PROFILES=ollama docker compose config --services` → `ollama`; `COMPOSE_PROFILES=llamacpp ...` → `llamacpp`; `COMPOSE_PROFILES=litellm,openwebui,buzz,gitea docker compose config --services` lists neither.

### Task 2 — README section

File: `README.md` (append)

```markdown
## Bring your own LLM backend

`LLM_BASE_URL` in `.env` must be reachable **from inside the litellm container** -- not the same thing as reachable from your shell. `make up` runs `scripts/preflight.sh`, which tests exactly that and tells you which case you are in:

1. **Backend is a container** -- attach it to the `open-llm-stack` network (`docker network connect open-llm-stack <container>`) and use `http://<container>:<port>`.
2. **Host process bound to 0.0.0.0** (Ollama's default in Docker, LM Studio with "serve on network") -- `http://host.docker.internal:<port>`. Already wired: litellm has `extra_hosts: host.docker.internal:host-gateway`.
3. **Host process bound to 127.0.0.1 only** -- `host.docker.internal` resolves to the Docker bridge gateway, never loopback, so it cannot be reached. Bind the backend to the `docker0` address instead, or use case 1. Never bind an unauthenticated inference server to 0.0.0.0 on an untrusted LAN; put LiteLLM (master-key auth) in front.

### Or let the stack run one

    # Ollama -- models pulled on demand, stored in the ollama-data volume
    COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,ollama
    LLM_BASE_URL=http://ollama:11434
    make up && docker compose exec ollama ollama pull qwen3:0.6b      # any tag you want; then register it in proxy/config.yaml + make reload

    # llama.cpp -- you supply a GGUF in ./models/ (gitignored)
    COMPOSE_PROFILES=litellm,openwebui,buzz,gitea,llamacpp
    LLM_BASE_URL=http://llamacpp:8080
    LLAMACPP_MODEL_FILE=your-model.gguf          # LLAMACPP_CTX_SIZE caps the context; 0 = model default
    make up

Register the model in `proxy/config.yaml` (`ollama_chat/<tag>` for Ollama, `openai/<name>` with `api_base: http://llamacpp:8080/v1` for llama.cpp), then `make reload`. Neither backend publishes a host port. For an NVIDIA GPU uncomment the `deploy:` block on `ollama` or switch `llamacpp` to the `server-cuda-b10920` tag.
```

---

## 5. Validation commands (G10)

```bash
for p in ollama llamacpp litellm,ollama litellm,llamacpp; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: $p"; done

# --- ollama profile, end to end (temporarily; restore .env afterwards) ---
cp .env .env.bak
sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=litellm,ollama|; s|^LLM_BASE_URL=.*|LLM_BASE_URL=http://ollama:11434|' .env
make up                                   # preflight must print: OK backend reachable at http://ollama:11434/...
docker compose exec ollama ollama pull qwen3:0.6b
docker compose ps ollama --format '{{.Name}} {{.Ports}}'   # expect no host mapping
# register it temporarily and prove a completion through LiteLLM
cp proxy/config.yaml proxy/config.yaml.bak
python3 - <<'PY'
import re
p='proxy/config.yaml'; s=open(p).read()
entry='''  - model_name: qwen3-0.6b-test
    litellm_params:
      model: ollama_chat/qwen3:0.6b
      api_base: os.environ/LLM_BASE_URL
    model_info:
      mode: chat
      max_input_tokens: 24576
      max_output_tokens: 4096
      execution_locus: local
'''
open(p,'w').write(s.replace('model_list:\n','model_list:\n'+entry,1))
PY
make reload && sleep 20
set -a; . ./.env; set +a
curl -sS http://127.0.0.1:3000/v1/chat/completions -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-0.6b-test","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":256}' | jq -r '.choices[0].message.content // .error'
COMPOSE_PROFILES=litellm,ollama docker compose down     # stop the backend BEFORE restoring .env, or it is orphaned
mv proxy/config.yaml.bak proxy/config.yaml; mv .env.bak .env; make up   # restore

# --- llamacpp profile (only if a GGUF is obtainable) ---
mkdir -p models && curl -fL -o models/stories260K.gguf https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K.gguf || echo "no GGUF available -- flag G10-llamacpp not run"
cp .env .env.bak
sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=litellm,llamacpp|; s|^LLM_BASE_URL=.*|LLM_BASE_URL=http://llamacpp:8080|; s|^# LLAMACPP_MODEL_FILE=.*|LLAMACPP_MODEL_FILE=stories260K.gguf|' .env
make up                                   # preflight: OK backend reachable at http://llamacpp:8080/v1/models
docker compose exec -T litellm python3 -c "import urllib.request,json;b=json.dumps({'messages':[{'role':'user','content':'Once upon a time'}],'max_tokens':16}).encode();r=urllib.request.Request('http://llamacpp:8080/v1/chat/completions',data=b,headers={'Content-Type':'application/json'});print(json.load(urllib.request.urlopen(r,timeout=120))['choices'][0]['message']['content'][:80])"
COMPOSE_PROFILES=litellm,llamacpp docker compose down   # same: profile-scoped down first
mv .env.bak .env; rm -f models/stories260K.gguf; make up
```

## 6. Integration notes

- `.gitignore` from plan 01 already covers `models/` and `*.gguf`.
- Compose profiles are selective: with `ollama` on and the operator's own backend also present, LiteLLM uses whichever `LLM_BASE_URL` names; the other is untouched.
- The `deploy.resources` GPU block is commented, not profile-gated, because hosts without `nvidia-container-toolkit` fail hard on it.

## 7. Execution report

**Executed 2026-09-12** on the reference host (CPU only; host Ollama at 0.0.0.0:11434 outside the project). Stack state before: 8 default containers healthy (`COMPOSE_PROFILES=litellm,openwebui,buzz,gitea`, `LLM_BASE_URL=http://host.docker.internal:11434`). Baseline md5: `.env` `02b64f71d1a3a7341f27366bb5a3061b`, `proxy/config.yaml` `0b0931a54b8b551584f43cea15bb29e4`. Neither image was present on the host; both were pulled (`docker pull` of `ollama/ollama:0.34.0` + `ghcr.io/ggml-org/llama.cpp:server-b10920`: 6m08s total, ahead of `make up` -- Compose would otherwise have pulled them there).

### G0

```
$ for p in ollama llamacpp litellm,ollama litellm,llamacpp; do COMPOSE_PROFILES="$p" docker compose config --quiet && echo "G0 ok: $p"; done
G0 ok: ollama
G0 ok: llamacpp
G0 ok: litellm,ollama
G0 ok: litellm,llamacpp
```

### G10 -- ollama profile: PASS

```
$ cp .env .env.bak && sed -i '...' .env && grep -nE '^(COMPOSE_PROFILES|LLM_BASE_URL)=' .env
2:COMPOSE_PROFILES=litellm,ollama
11:LLM_BASE_URL=http://ollama:11434
$ make up                                        # 30.7 s
 Volume open-llm-stack_ollama-data Created
 Container open-llm-stack-ollama-1 Started
 Container open-llm-stack-litellm-1 Recreated ... Healthy
./scripts/preflight.sh
OK  backend reachable at http://ollama:11434/v1/models

$ docker compose exec ollama ollama pull qwen3:0.6b     # 45.5 s; registry.ollama.ai reachable from the container
pulling 7f4030143c1c: 100% 522 MB/522 MB   11 MB/s
verifying sha256 digest
writing manifest
success
$ docker compose exec ollama ollama list
NAME          ID              SIZE      MODIFIED
qwen3:0.6b    7df6b6e09427    522 MB    Less than a second ago

$ docker compose ps ollama --format '{{.Name}} {{.Ports}}'
open-llm-stack-ollama-1 11434/tcp                        # container port only, no host mapping

$ cp proxy/config.yaml proxy/config.yaml.bak && python3 - <<'PY' ... PY   # inserts qwen3-0.6b-test at top of model_list
$ make reload && sleep 20
$ curl -sS http://127.0.0.1:3000/v1/chat/completions -H "Authorization: Bearer $LITELLM_MASTER_KEY" ... -d '{"model":"qwen3-0.6b-test",...}' | jq -r '.choices[0].message.content // .error'
OK                                                        # 3.6 s, CPU inference
```

Restore: `mv proxy/config.yaml.bak proxy/config.yaml; mv .env.bak .env; make down && make up` (43.5 s). Preflight after restore: `OK  backend reachable at http://host.docker.internal:11434/v1/models`.

### G10 -- llamacpp profile: PASS

```
$ mkdir -p models && curl -fL -o models/stories260K.gguf https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K.gguf
100 1157k  100 1157k    0     0  1477k      0 --:--:-- --:--:-- --:--:-- 2352k    # 1,185,376 bytes, magic "GGUF"
$ cp .env .env.bak && sed -i '...' .env && grep -nE '^(COMPOSE_PROFILES|LLM_BASE_URL|LLAMACPP_MODEL_FILE)=' .env
2:COMPOSE_PROFILES=litellm,llamacpp
11:LLM_BASE_URL=http://llamacpp:8080
73:LLAMACPP_MODEL_FILE=stories260K.gguf
$ make up                                        # 33.8 s
 Container open-llm-stack-llamacpp-1 Started ... Healthy     # the image ships its own HEALTHCHECK
./scripts/preflight.sh
OK  backend reachable at http://llamacpp:8080/v1/models
$ docker compose ps llamacpp --format '{{.Name}} {{.Status}} {{.Ports}}'
open-llm-stack-llamacpp-1 Up 30 seconds (healthy)         # no host port
$ docker compose logs llamacpp | grep -E 'model loaded|listening'
llamacpp-1  | 0.00.018.641 I srv  llama_server: model loaded
llamacpp-1  | 0.00.018.645 I srv  llama_server: listening on http://0.0.0.0:8080

$ docker compose exec -T litellm python3 -c "...urlopen('http://llamacpp:8080/v1/chat/completions')...['choices'][0]['message']['content'][:80]"
"Sext," Joscries.                                        # 0.14 s; nonsense is expected from a 260K-param toy model
```

Restore: `COMPOSE_PROFILES=litellm,llamacpp docker compose down   # same: profile-scoped down first
mv .env.bak .env; rm -f models/stories260K.gguf; make up` (43.6 s), then `rmdir models`.

### Restore verification

```
$ md5sum .env proxy/config.yaml                  # identical before, after ollama phase, after llamacpp phase
02b64f71d1a3a7341f27366bb5a3061b  .env
0b0931a54b8b551584f43cea15bb29e4  proxy/config.yaml
$ grep -nE '^(COMPOSE_PROFILES|LLM_BASE_URL)=|LLAMACPP_MODEL_FILE' .env
2:COMPOSE_PROFILES=litellm,openwebui,buzz,gitea
11:LLM_BASE_URL=http://host.docker.internal:11434
73:# LLAMACPP_MODEL_FILE=your-model.gguf   # file inside ./models/, llamacpp profile only
$ docker compose ps    -> 8 containers, all (healthy): buzz, buzz-db, buzz-minio, buzz-redis, gitea, litellm, litellm-db, open-webui
$ docker ps -a --filter name=open-llm-stack | grep -E 'ollama|llamacpp'   -> none
$ ./scripts/preflight.sh
OK  backend reachable at http://host.docker.internal:11434/v1/models
$ ls .env.bak proxy/config.yaml.bak models   -> none exist
$ make test                                      # 44 s: litellm, open-webui, buzz, gitea all pass, "smoke test finished"
```

The `open-llm-stack_ollama-data` volume (522 MB, holds `qwen3:0.6b`) is left in place: `down` without `-v` keeps declared volumes, and the plan does not ask to remove it. `docker volume rm open-llm-stack_ollama-data` if unwanted.

### Timings

| step | time |
|---|---|
| pull both images | 6m08s |
| ollama: `make up` | 30.7 s |
| ollama: `ollama pull qwen3:0.6b` (522 MB) | 45.5 s |
| ollama: completion via LiteLLM (CPU) | 3.6 s |
| llamacpp: GGUF download (1.2 MB) | ~1 s |
| llamacpp: `make up` | 33.8 s |
| llamacpp: completion | 0.14 s |
| each restore `make down && make up` | ~43.5 s |

### Fix applied to the validation procedure (not to any project file)

The restore line as written (`mv .env.bak .env; make down && make up`) leaves the optional-backend container **running and orphaned**: once `.env` is back to the four default profiles, `docker compose down` no longer manages `ollama`/`llamacpp`, so it removes the eight default containers and prints `Network open-llm-stack Resource is still in use`. Observed after the ollama phase: `open-llm-stack-ollama-1 Up 2 minutes` still listed by `docker compose ps` next to the 8 restored containers. Cleaned up with `COMPOSE_PROFILES=ollama docker compose down` (removes only that container; the network warning is harmless). For the llamacpp phase the same profile-scoped `down` was run *before* restoring `.env`, after which `make down` removed the network cleanly. Anyone repeating §5 should run `COMPOSE_PROFILES=<backend> docker compose down` before `mv .env.bak .env`. No image tag, compose file, script, or env name was changed.
