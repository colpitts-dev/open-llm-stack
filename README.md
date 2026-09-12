# Open LLM Stack

A local first, privacy focused, open weighted llm development stack. Bring your own LLMs (Ollama, llama.cpp, vLLM, etc)

## Batteries Included

- litellm - api gateway
- open web ui - basic chat
- buzz.xyz Relay - team collaboration
- gitea - version control

## Quick start

Requires Docker (Compose v2) and an OpenAI-compatible LLM backend you already run (Ollama, llama.cpp, vLLM, LM Studio). Bundled backends are optional, see docs/spec.md §5.6.

    make init     # .env + generated secrets + proxy/config.yaml
    make up       # starts every layer in COMPOSE_PROFILES, waits for healthy, checks your backend
    make test     # smoke-tests every running layer

| Service | URL |
|---|---|
| LiteLLM (OpenAI-compatible API) | http://127.0.0.1:3000/v1 -- key: `LITELLM_MASTER_KEY` from `.env` |
| Open WebUI | http://127.0.0.1:3001 |
| Buzz relay | ws://127.0.0.1:3002 |
| Gitea | http://127.0.0.1:3003 |

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
