# Open LLM Stack

A local first, privacy focused, open weighted llm development stack. Bring your own LLMs (Ollama, llama.cpp, vLLM, etc)

## Batteries Included

- litellm - api gateway
- open web ui - basic chat
- buzz.xyz Relay - team collaboration
- gitea - local version control + web ui

## Quick start

Requires Docker (Compose v2) and an OpenAI-compatible LLM backend you already run (Ollama, llama.cpp, vLLM, LM Studio). Bundled backends are optional, see docs/spec.md §5.6.

    make init     # .env + generated secrets + proxy/config.yaml
    make up       # starts every layer in COMPOSE_PROFILES, waits for healthy, checks your backend
    make test     # smoke-tests every running layer

| Service                         | URL                                                               |
| ------------------------------- | ----------------------------------------------------------------- |
| LiteLLM (OpenAI-compatible API) | http://127.0.0.1:3000/v1 -- key: `LITELLM_MASTER_KEY` from `.env` |
| Open WebUI                      | http://127.0.0.1:3001                                             |
| Buzz relay                      | ws://127.0.0.1:3002                                               |
| Gitea                           | http://127.0.0.1:3003                                             |

Full documentation: `docs/spec.md` (architecture, every env var, verified facts). Plans in `plans/` build the layers one at a time.

## Open WebUI (port 3001)

Open http://127.0.0.1:3001. With the default `WEBUI_AUTH=false` there is no login; every model in `proxy/config.yaml` is in the picker because Open WebUI talks only to LiteLLM (`LITELLM_URL`). Set `WEBUI_AUTH=true` in `.env` and `docker compose up -d open-webui` to get normal signup/login (the first account becomes admin).

Using an external gateway instead of the bundled LiteLLM: remove `litellm` from `COMPOSE_PROFILES`, set `LITELLM_URL` to that gateway (reachable from inside Docker -- for a gateway on this machine use `http://host.docker.internal:<port>`) and `LITELLM_MASTER_KEY` to its key, then `docker compose up -d`.

## Buzz relay (port 3002)

The relay is up at `ws://127.0.0.1:3002` (open mode: anyone with the URL can join; fine on a laptop, see below for closed mode). Chat clients:

- **Buzz desktop app** (packaged builds: https://github.com/block/buzz/releases): launch with `BUZZ_RELAY_URL=ws://127.0.0.1:3002`, or switch relay inside the app.
- **`buzz` CLI** without installing anything: `docker run --rm --network host -e BUZZ_PRIVATE_KEY=<64-hex secret> -e BUZZ_RELAY_URL=ws://127.0.0.1:3002 --entrypoint buzz ghcr.io/block/buzz-sprig:sha-e17cdd9 channels list`. Mint a key with `docker compose exec buzz buzz-admin generate-key`.
- Browser: http://127.0.0.1:3002/ serves the repo browser and invite pages (not a chat client).

**Use exactly `127.0.0.1:3002`.** The relay creates one community keyed on `BUZZ_PUBLIC_HOST` and answers HTTP 404 to any other host name, so `localhost:3002` is a different (non-existent) community. To expose the relay on your LAN set `BIND_HOST=0.0.0.0` and `BUZZ_PUBLIC_HOST=<your-ip>:3002` (and `BUZZ_RELAY_URL` to match), then `docker compose up -d buzz`.

Closed relay (members only): set `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true` and `RELAY_OWNER_PUBKEY=<your 64-hex pubkey>` in `.env`, `docker compose up -d buzz`, then add members with `docker compose exec buzz buzz-admin add-member --pubkey <hex-or-npub>`.

External relay: remove `buzz` from `COMPOSE_PROFILES` and set `BUZZ_RELAY_URL=wss://your-relay.example` -- only the optional `buzz-agent` profile reads it.

Data lives in the `buzz-db-data`, `buzz-redis-data`, `buzz-minio-data` and `buzz-git-data` volumes; back up `.env` too (the relay key and HMAC secret must stay stable).

## Gitea (port 3003)

http://127.0.0.1:3003 -- SQLite, HTTP only, install already locked. Create the admin account and an API token once:

    make gitea-bootstrap        # uses GITEA_ADMIN_USER / GITEA_ADMIN_PASSWORD from .env, writes GITEA_ADMIN_TOKEN

Log in with those credentials, or use the token: `curl -H "Authorization: token $GITEA_ADMIN_TOKEN" http://127.0.0.1:3003/api/v1/user`. Push over HTTP with the token (`git -c http.extraHeader="Authorization: token ..." push`) or with the user's password.

External Gitea/GitHub: remove `gitea` from `COMPOSE_PROFILES`; nothing else in this stack depends on it. `GITEA_PUBLIC_URL` only controls the bundled instance's `ROOT_URL` (what its clone URLs show), so change it together with `GITEA_PORT` or `BIND_HOST`.

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
