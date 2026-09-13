#!/usr/bin/env bash
# G1: refuse to start when one of our ports is held by something that is not this stack.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a
has_profile() { [[ ",${COMPOSE_PROFILES:-}," == *",$1,"* ]]; }
# Only the ports of layers that will actually run: with the gitea profile off, 3003 may legitimately belong to something else.
ports=()
has_profile litellm   && ports+=("${LITELLM_PORT:-3000}")
has_profile openwebui && ports+=("${OPENWEBUI_PORT:-3001}")
has_profile buzz      && ports+=("${BUZZ_PORT:-3002}")
has_profile gitea     && ports+=("${GITEA_PORT:-3003}")
[ ${#ports[@]} -gt 0 ] || { echo "ports ok (no port-publishing profile enabled)"; exit 0; }
ours=$(docker ps --filter label=com.docker.compose.project=open-llm-stack --format '{{.Ports}}' 2>/dev/null || true)
rc=0
for p in "${ports[@]}"; do
  if ss -Htln | awk '{print $4}' | grep -qE "[:.]${p}$"; then
    if grep -qE ":${p}->" <<<"$ours"; then
      echo "port ${p}: in use by this stack (ok)"
    else
      echo "port ${p}: BUSY -- $(ss -Htlnp 2>/dev/null | grep -E "[:.]${p} " | head -1)"; rc=1
    fi
  fi
done
[ $rc -eq 0 ] || { echo "Free the ports above (or change *_PORT in .env) and re-run make up." >&2; exit 1; }
echo "ports ok"
