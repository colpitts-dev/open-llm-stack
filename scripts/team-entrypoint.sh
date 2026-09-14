#!/usr/bin/env bash
# Shared entrypoint for the team agents. Runs as user `agent` inside the sprig image.
set -euo pipefail
: "${TEAM_ROLE:?}" "${BUZZ_RELAY_URL:?}"
# Checked here, not with :? in compose (that would break every `docker compose` call while the values are still blank).
[[ "${BUZZ_ACP_RESPOND_TO_ALLOWLIST:-}" != ,* ]] || { echo "TEAM_ALLOWLIST is blank in .env -- put your pubkey there, then docker compose up -d $TEAM_ROLE" >&2; exit 1; }
[ "$TEAM_ROLE" = erlich ] || [ -n "${GITEA_TOKEN:-}" ] || { echo "no Gitea token for $TEAM_ROLE -- run make team-bootstrap, then docker compose up -d $TEAM_ROLE" >&2; exit 1; }
url="${BUZZ_RELAY_URL/#ws:/http:}"; url="${url/#wss:/https:}"
for i in $(seq 1 60); do curl -fsS -o /dev/null "$url/_liveness" && break; echo "waiting for relay at $url"; sleep 2; done

# Workspace layout the base prompt expects (spec: docs/buzz-agents-primer.md §2)
# Private CA (GITEA_CA_FILE mounted at /opt/team/ca.crt; /dev/null when unset). Empty values would break curl/git, so set only when present.
if [ -s /opt/team/ca.crt ]; then
  export CURL_CA_BUNDLE=/opt/team/ca.crt GIT_SSL_CAINFO=/opt/team/ca.crt SSL_CERT_FILE=/opt/team/ca.crt   # for the harness itself
  # The agent's shell tool runs with a scrubbed environment (HOME and PATH only), so the CA must also be configured
  # where git and curl look without env vars: git's global config and ~/.curlrc (both under HOME, which survives).
  git config --global http.sslCAInfo /opt/team/ca.crt
  printf 'cacert = /opt/team/ca.crt\n' > "$HOME/.curlrc"
  echo "private CA loaded for $GITEA_URL"
else
  git config --global --unset http.sslCAInfo 2>/dev/null || true; rm -f "$HOME/.curlrc"   # a volume that was once external
fi

mkdir -p "$HOME"/{RESEARCH,PLANS,GUIDES,WORK_LOGS,OUTBOX,REPOS,.scratch}
# Clones from a different Gitea (the volume outlived an instance switch) must go: an agent would otherwise base new
# work on a stale checkout and push another instance's history and workflow labels (verified 2026-09-13). Bodies are
# disposable; anything that matters is in a PR on the instance it came from.
for d in "$HOME"/REPOS/*/; do
  [ -d "$d/.git" ] || continue
  origin=$(git -C "$d" remote get-url origin 2>/dev/null || true)
  case "$origin" in "${GITEA_URL}/"*) ;; *) echo "removing stale clone $(basename "$d") (origin $origin is not $GITEA_URL)"; rm -rf "$d" ;; esac
done

# Git identity + Gitea credentials (builder/reviewer/coordinator only). Token never appears in the prompt.
git config --global user.name "$BUZZ_ACP_DISPLAY_NAME"
git config --global user.email "${GITEA_USER:-$TEAM_ROLE}@localhost"
git config --global init.defaultBranch main
if [ -n "${GITEA_TOKEN:-}" ]; then
  git config --global credential.helper store
  scheme="${GITEA_URL%%://*}"; host="${GITEA_URL#*://}"   # keep the scheme: an https Gitea needs an https credential line
  printf '%s://%s:%s@%s\n' "$scheme" "$GITEA_USER" "$GITEA_TOKEN" "$host" > "$HOME/.git-credentials"
  chmod 600 "$HOME/.git-credentials"
  # The harness starts buzz-dev-mcp with a scrubbed environment (HOME and PATH only; verified 2026-09-13), so the
  # shell tool never sees GITEA_TOKEN. The personas source this file in the same command as each API call.
  printf 'export GITEA_URL=%s GITEA_OWNER=%s GITEA_USER=%s GITEA_TOKEN=%s\n' "$GITEA_URL" "$GITEA_OWNER" "$GITEA_USER" "$GITEA_TOKEN" > "$HOME/.gitea.env"
  chmod 600 "$HOME/.gitea.env"
fi

# Prompt = team norms + persona (base prompt is prepended by the harness itself)
{ cat /opt/team/agents/TEAM.md; echo; cat "/opt/team/agents/${TEAM_ROLE}.md"; } > "$HOME/.prompt.md"
sed -i "s|\$GITEA_URL|$GITEA_URL|g; s|\$GITEA_OWNER|$GITEA_OWNER|g; s|\$GITEA_ADMIN|${GITEA_ADMIN:-stackadmin}|g; s|\$GITEA_HUMAN|${GITEA_HUMAN:-richard}|g; s|\$TEAM_CI_LABEL|${TEAM_CI_LABEL:-python}|g; s|\$GILFOYLE_PUBKEY|${GILFOYLE_PUBKEY:-}|g; s|\$JARED_PUBKEY|${JARED_PUBKEY:-}|g" "$HOME/.prompt.md"   # non-secret values inlined for the same reason

# Context window from LiteLLM's registry, so TEAM_MODEL is the only switch (no jq in this image: sed/grep on the JSON).
# Verified 2026-09-13 against ornith-max (237568/16384) and qwen3.8-max (106496/16384).
info=$(curl -fsS -H "Authorization: Bearer $OPENAI_COMPAT_API_KEY" "$OPENAI_COMPAT_BASE_URL/model/info" | tr -d '\n ') || { echo "cannot read LiteLLM registry at $OPENAI_COMPAT_BASE_URL" >&2; exit 1; }
blk=$(sed "s/.*\"model_name\":\"$OPENAI_COMPAT_MODEL\"//" <<<"$info")
[ "$blk" != "$info" ] || { echo "model '$OPENAI_COMPAT_MODEL' is not in proxy/config.yaml -- fix TEAM_MODEL" >&2; exit 1; }
# bash regex, not grep|head: under pipefail `head -1` closing the pipe early gives grep SIGPIPE (exit 141) and kills the script
reg_in=""; [[ $blk =~ \"max_input_tokens\":([0-9]+) ]] && reg_in="${BASH_REMATCH[1]}"
reg_out=""; [[ $blk =~ \"max_output_tokens\":([0-9]+) ]] && reg_out="${BASH_REMATCH[1]}"
export BUZZ_AGENT_MAX_CONTEXT_TOKENS="${BUZZ_AGENT_MAX_CONTEXT_TOKENS:-${reg_in:-32768}}"
export BUZZ_AGENT_MAX_OUTPUT_TOKENS="${reg_out:-4096}"
echo "model=$OPENAI_COMPAT_MODEL context=$BUZZ_AGENT_MAX_CONTEXT_TOKENS output=$BUZZ_AGENT_MAX_OUTPUT_TOKENS"

buzz users set-profile --name "$BUZZ_ACP_DISPLAY_NAME" --about "open-llm-stack team agent (${TEAM_ROLE}), model ${OPENAI_COMPAT_MODEL}" >/dev/null 2>&1 \
  && echo "profile name set: $BUZZ_ACP_DISPLAY_NAME" || echo "could not set profile name (will retry on next restart)"
# Runtime (plan 12). goose: its own developer extension (shell + file edit) replaces buzz-dev-mcp; provider = LiteLLM;
# context limit from the same registry read; keyring off (no D-Bus in a container); auto mode = no permission prompts.
case "${TEAM_RUNTIME:-buzz-agent}" in
  goose)
    command -v goose >/dev/null || { echo "TEAM_RUNTIME=goose but this image has no goose binary (make goose-image; make dinesh-runtime R=goose)" >&2; exit 1; }
    export BUZZ_ACP_AGENT_COMMAND=goose BUZZ_ACP_AGENT_ARGS="acp,--with-builtin,developer" BUZZ_ACP_MCP_COMMAND=""
    export GOOSE_PROVIDER=openai GOOSE_MODEL="$OPENAI_COMPAT_MODEL" OPENAI_HOST="${OPENAI_COMPAT_BASE_URL%/v1}" OPENAI_API_KEY="$OPENAI_COMPAT_API_KEY"
    export GOOSE_MODE=auto GOOSE_DISABLE_KEYRING=1 GOOSE_CONTEXT_LIMIT="$BUZZ_AGENT_MAX_CONTEXT_TOKENS" GOOSE_MAX_TURNS=200
    echo "runtime=goose $(goose --version 2>/dev/null | tr -d ' ') context=$GOOSE_CONTEXT_LIMIT" ;;
  buzz-agent) ;;
  *) echo "unknown TEAM_RUNTIME '$TEAM_RUNTIME' (buzz-agent|goose)" >&2; exit 1 ;;
esac

# Progress mirror (plan 11), opt-in: the harness log goes through team-narrate.sh, which echoes it (docker logs unchanged)
# and posts commands/narration into the job thread. FIFO so the harness stays PID 1 via exec (healthcheck: pgrep -f buzz-acp).
# acp::wire at debug carries the shell command text the mirror needs (~10x log volume; rotated by compose).
case "${TEAM_NARRATE:-off}" in
  tools|both|stream)
    export RUST_LOG="${RUST_LOG:-info},acp::wire=debug"
    rm -f /tmp/acp.log; mkfifo /tmp/acp.log
    bash /opt/team/team-narrate.sh </tmp/acp.log &
    echo "progress mirror: $TEAM_NARRATE"
    exec /usr/local/bin/sprig-entrypoint >/tmp/acp.log 2>&1 ;;
esac
exec /usr/local/bin/sprig-entrypoint
