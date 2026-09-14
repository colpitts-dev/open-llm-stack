#!/usr/bin/env bash
# Progress mirror (plan 11), opt-in. Reads the harness log on stdin, echoes every line to stdout (docker logs stay intact)
# and posts, as this agent's identity, thread replies for: state-changing shell commands the model runs (acp::wire tool_call
# frames, "$ ..." in a fenced block) and, in mode both, the model's narration (acp::stream, "› ...") except the last chunk
# of a turn (it is the reply the model posts itself). Thread-scoped turns only. Never @mentions, never bold (TEAM.md keeps
# those for deliverables). Sprig image: bash, sed, grep; no jq. Must never exit before EOF: the harness writes into this pipe.
set +e; trap '' PIPE; shopt -s extglob   # busybox sed here: no -u, no GNU multi-line tricks -> pure bash below
mode="${TEAM_NARRATE:-off}"          # off | tools | both   (stream = narration only, for debugging the mirror itself)
want_stream=0; want_tools=0
case "$mode" in both) want_stream=1; want_tools=1 ;; stream) want_stream=1 ;; tools) want_tools=1 ;; esac
declare -A ROOT                      # "<channel>:<root8>" -> full root event id (looked up once per thread)
channel=""; root8=""; buf=""
ts='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z '   # a timestamped line starts a new log record

root_id() {   # full root id for the current turn, "" when unknown
  local key="$channel:$root8" out
  [ -n "${ROOT[$key]:-}" ] && { printf '%s' "${ROOT[$key]}"; return; }
  out=$(buzz messages get --channel "$channel" --limit 300 2>/dev/null </dev/null)   # never let buzz inherit the FIFO as stdin
  if [[ $out =~ \"id\":\"($root8[0-9a-f]{56})\" ]]; then ROOT[$key]="${BASH_REMATCH[1]}"; printf '%s' "${BASH_REMATCH[1]}"; fi
}
post() {      # post <text>: one thread reply; silent when the turn has no thread or the root cannot be found
  [ -n "$channel" ] && [ -n "$root8" ] || return 0
  local root; root=$(root_id); [ -n "$root" ] || return 0
  printf '%s\n' "$1" | buzz messages send --channel "$channel" --reply-to "$root" --content - >/dev/null 2>&1 \
    || echo "narrate: post failed (channel $channel thread $root8)" >&2
}
flush() {     # the buffered narration chunk: trim blank edges, keep the first 3 lines; skipped when empty
  local text="$buf" lines; buf=""
  text="${text##*([[:space:]])}"; text="${text%%*([[:space:]])}"
  [ -n "$text" ] || return 0
  mapfile -t lines <<<"$text"; text=$(printf '%s\n' "${lines[@]:0:3}"); text="${text%%*([[:space:]])}"
  [ "$want_stream" = 1 ] && post "› $text"
}
unescape() {  # JSON string body -> text (enough for shell commands: \" \\ \n \t)
  local s="$1"; s="${s//\\\"/\"}"; s="${s//\\n/ }"; s="${s//\\t/ }"; s="${s//\\\\/\\}"; printf '%s' "$s"
}
wrap() {      # break a long command on && and | with a trailing \ and two-space indent (phone-safe, no horizontal scroll)
  local s="$1"; [ ${#s} -gt 300 ] && s="${s:0:300} …"
  [ ${#s} -le 48 ] && { printf '%s' "$s"; return; }
  s="${s// && /$' && \\\n  '}"; s="${s// | /$' | \\\n  '}"; printf '%s' "$s"
}
mutating() {  # only commands that change state are worth a post (UX review): writes to git, the forge, the factory
  case "$1" in
    *"git push"*|*"git commit"*|*"git merge"*|*"git rebase"*|*"git reset"*|*"git checkout -b"*|*"git switch -c"*) return 0 ;;
    *"curl "*"-X POST"*|*"curl "*"-X PATCH"*|*"curl "*"-X PUT"*|*"curl "*"-X DELETE"*|*"curl "*"-d @"*) return 0 ;;
    *"new-repo "*|*"rm -rf"*) return 0 ;;
  esac; return 1
}

# Matching is glob/substring based on purpose: bash =~ (glibc regex) with `.*` on a 100 KB wire frame spins for minutes
# (seen 2026-09-14: the filter pegged a CPU on a goose `write` frame and the harness blocked on the FIFO).
while IFS= read -r line; do
  printf '%s\n' "$line"
  [ "$mode" = off ] && continue
  # ANSI codes sit only in the record prefix (timestamp, level, target). A global strip over a 25 KB wire frame is quadratic
  # in bash and pegged a CPU (2026-09-14); strip the first 60 bytes only, classify with globs on the raw line.
  pre="${line:0:60}"; pre="${pre//$'\e'\[*([0-9;])m/}"
  if [[ ${pre:0:40} =~ $ts ]]; then
    head="${line:0:400}"
    if [[ $head == *"turn complete for channel "* ]]; then
      buf=""; channel=""; root8=""                                # last chunk of the turn = the reply itself: dropped
    elif [[ $head == *"turn starting for channel "*"(thread:"* ]] && [[ $head =~ channel\ ([0-9a-f-]{36})\ \(thread:([0-9a-f]{8})\) ]]; then
      buf=""; channel="${BASH_REMATCH[1]}"; root8="${BASH_REMATCH[2]}"
    elif [[ $head == *"turn starting for channel "*"(conversation)"* ]]; then
      buf=""; channel=""; root8=""                                # channel-scoped agent: nothing to reply to
    elif [[ $head == *"acp::stream"* ]]; then
      # consecutive narration records join (goose streams token-sized chunks; buzz-agent paragraph chunks): one post per run
      chunk="${line#*acp::stream$'\e'\[0m$'\e'\[2m:$'\e'\[0m }"                # coloured prefix form
      [ "$chunk" = "$line" ] && chunk="${line#*acp::stream: }"           # plain form
      [ -n "$buf" ] && buf+="$chunk" || buf="$chunk"
    elif [[ $head == *"acp::wire"*"← "* ]] && [[ $line == *'"sessionUpdate":"tool_call"'* ]]; then
      [ -n "$buf" ] && flush                                       # a chunk followed by a tool call is narration, not the reply
      rest="${line#*\"command\":\"}"                              # from the command's first byte; bounded before any regex
      if [ "$want_tools" = 1 ] && [ "$rest" != "$line" ] && [[ ${rest:0:4000} =~ ^((\\.|[^\"\\])*)\" ]]; then
        cmd=$(unescape "${BASH_REMATCH[1]}")
        case "$cmd" in *"buzz messages send"*|*"buzz reactions add"*) ;;   # already visible as the agent's own post
          *) mutating "$cmd" && post "$(printf '```\n$ %s\n```' "$(wrap "$cmd")")" ;;
        esac
      fi
    else
      [ -n "$buf" ] && flush                                       # any other record ends a chunk (llm call completed, …)
    fi
  else
    [ -n "$buf" ] && buf+=$'\n'"$line"                            # continuation of a multi-line narration chunk
  fi
done
