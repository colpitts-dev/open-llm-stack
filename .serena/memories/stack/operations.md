## Stack operations (verified 2026-09-12/13)

- One compose file, one network `open-llm-stack`, profiles per layer: `litellm`, `openwebui`, `buzz`, `gitea` (default on), `ollama`, `llamacpp`, `buzz-agent` (off). `COMPOSE_PROFILES` in `.env`; never cross-profile `depends_on` (Compose rejects the whole project when the target profile is off).
- `make init` generates every secret incl. Nostr keys via `buzz-admin generate-key` (relay image). `make up` = check-ports → `compose up --wait` → preflight (LLM_BASE_URL reachable from inside litellm). `make test` = per-profile smoke sections.
- Relay binds ONE community to the exact host:port of `RELAY_URL` (`BUZZ_PUBLIC_HOST`); any other Host header → 404 "no community is configured for this host". `localhost:3002` ≠ `127.0.0.1:3002`. In-network `ws://buzz:3002` is rejected → agent runs `network_mode: host`.
- MinIO images pull from quay.io (Docker Hub denies anonymous `minio/*`).
- Open WebUI no-login API token: `POST /api/v1/auths/signin` with empty email/password. `ENABLE_PERSISTENT_CONFIG=false` keeps env authoritative.
- Switching optional backends: profile-scoped `docker compose down` BEFORE editing `COMPOSE_PROFILES`, else the container is orphaned.
- GPU: RTX 5090 32 GB; the operator's `-max` Ollama tags at 262K ctx use ~28 GB with one slot. Concurrent agent calls made Ollama spill to CPU (39 GB, 100% CPU) → host Ollama container recreated with `OLLAMA_NUM_PARALLEL=1` (standalone container outside compose: image ollama/ollama, volume `ollama`, 0.0.0.0:11434, --gpus all, KEEP_ALIVE 30m, MAX_LOADED 2, KV q8_0, flash attn).
- Agent LLM model: `ornith-max` (publishes results); `qwen3.6-max` ends long turns in discarded text even with an explicit rule. `laguna-max`, `qwen3.8-max` also publish. Keep `BUZZ_AGENT_MAX_CONTEXT_TOKENS` = registry `max_input_tokens`.
- Gitea bootstrap (`make gitea-bootstrap`) is idempotent; `--rotate` mints a new token; old tokens stay valid until deleted.
