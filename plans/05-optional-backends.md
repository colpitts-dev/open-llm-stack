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
mv proxy/config.yaml.bak proxy/config.yaml; mv .env.bak .env; make down && make up   # restore

# --- llamacpp profile (only if a GGUF is obtainable) ---
mkdir -p models && curl -fL -o models/stories260K.gguf https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K.gguf || echo "no GGUF available -- flag G10-llamacpp not run"
cp .env .env.bak
sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=litellm,llamacpp|; s|^LLM_BASE_URL=.*|LLM_BASE_URL=http://llamacpp:8080|; s|^# LLAMACPP_MODEL_FILE=.*|LLAMACPP_MODEL_FILE=stories260K.gguf|' .env
make up                                   # preflight: OK backend reachable at http://llamacpp:8080/v1/models
docker compose exec -T litellm python3 -c "import urllib.request,json;b=json.dumps({'messages':[{'role':'user','content':'Once upon a time'}],'max_tokens':16}).encode();r=urllib.request.Request('http://llamacpp:8080/v1/chat/completions',data=b,headers={'Content-Type':'application/json'});print(json.load(urllib.request.urlopen(r,timeout=120))['choices'][0]['message']['content'][:80])"
mv .env.bak .env; rm -f models/stories260K.gguf; make down && make up
```

## 6. Integration notes

- `.gitignore` from plan 01 already covers `models/` and `*.gguf`.
- Compose profiles are selective: with `ollama` on and the operator's own backend also present, LiteLLM uses whichever `LLM_BASE_URL` names; the other is untouched.
- The `deploy.resources` GPU block is commented, not profile-gated, because hosts without `nvidia-container-toolkit` fail hard on it.

## 7. Execution report (fill in)
