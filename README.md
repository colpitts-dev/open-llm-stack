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
