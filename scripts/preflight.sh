#!/usr/bin/env bash
# G2: is LLM_BASE_URL reachable from INSIDE the litellm container?
set -euo pipefail
cd "$(dirname "$0")/.."
if ! docker compose ps --status running litellm 2>/dev/null | grep -q litellm; then
  echo "preflight: litellm is not running (profile off or not started) -- skipping"; exit 0
fi
docker compose exec -T litellm python3 - <<'PY'
import os, urllib.request, sys
base = os.environ["LLM_BASE_URL"].rstrip("/")
last = None
for path in ("/v1/models", "/api/tags"):
    try:
        urllib.request.urlopen(base + path, timeout=5)
        print(f"OK  backend reachable at {base}{path}")
        sys.exit(0)
    except Exception as e:
        last = e
print(f"FAIL {base} unreachable from inside the litellm container: {last}")
print("""
Which case are you in?
  1. Backend is a container      -> put it on the 'open-llm-stack' network and use http://<container>:<port>,
                                    or use the bundled profile: COMPOSE_PROFILES=...,ollama + LLM_BASE_URL=http://ollama:11434
  2. Host process bound to 0.0.0.0 -> http://host.docker.internal:<port> (extra_hosts is already set on litellm)
  3. Host process bound to 127.0.0.1 only -> host.docker.internal resolves to the Docker bridge gateway, never loopback,
     so this cannot be reached. Bind the backend to the docker0 bridge address (see `ip addr show docker0`)
     or use case 1. Do NOT bind an unauthenticated inference server to 0.0.0.0 on a LAN you do not trust.
""")
sys.exit(1)
PY
