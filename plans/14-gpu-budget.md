# Plan 14 — GPU budget: a backend-agnostic context contract, one slot per agent, no silent truncation, no idle burn

**Spec:** `docs/spec.md` (this plan adds §5.15 and gates G29–G34). **Rules:** `AGENTS.md`. **Knowledge:** plan 08 §5.8 (team, one-variable model switch), plan 12 §5.13 (goose reads `GOOSE_CONTEXT_LIMIT`), plan 13 §5.14 (Jared is coordinator and judge; his heartbeat).
**Sequence:** 14. Requires plan 13 executed. Adds three host scripts, three make targets, one registry field (`model_info.context_window`) on every chat model, backend knobs on the Ollama entries only, an env block on the bundled `ollama` profile, two `.env` variables, one default change (`TEAM_HEARTBEAT_SECONDS`). No new service, image, port, build or network.
**Execute with:** `/execute plans/14-gpu-budget.md`
**No internet.** Every number below was measured on the reference host on 2026-09-14 (RTX 5090 32 GB, driver 580.126.18, host Ollama 0.33.3, LiteLLM v1.89.7).

---

## 1. Overview

**Intent.** The stack is backend-agnostic: LiteLLM fronts whatever `LLM_BASE_URL` serves (Ollama, llama.cpp, vLLM, anything OpenAI-compatible), and nothing above the gateway may depend on which one. On one 32 GB GPU three properties must hold for every backend: a response is never truncated (neither its prompt nor its output), the model never spills off the GPU or fails to load, and the GPU draws nothing beyond its display floor when no job runs. Adding a model must keep those properties without hand arithmetic.

**The contract, in one paragraph.** The registry (`proxy/config.yaml`) is the single declaration: every chat model states its physical window per slot (`model_info.context_window`), its output budget (`max_output_tokens`) and its input cap (`max_input_tokens`, derived by one formula). The backend is configured to honour that window (Ollama: `num_ctx` mirrored in `litellm_params`, which LiteLLM forwards; llama.cpp: `-c`/`-np`; vLLM: `--max-model-len`/`--max-num-seqs`). The declaration is **verified through the gateway, black-box**: `make context-probe` sends prompts at the caps and past them and checks that the backend accepted each one whole. Backend-specific helpers exist only below that line: `make model-fit` finds the window for an Ollama backend; a llama.cpp or vLLM operator sets the flags and runs the same probe.

**What was found (2026-09-14, evidence in §3).**

| # | Issue | Evidence |
|---|---|---|
| 1 | Prompts silently truncated | 34 generations on `qwen3.8-max` stopped at `n_tokens = 131071, truncated = 1`: the agent's own token estimate stayed under its 106496 cap while the real prompt reached the 131072 window. llama.cpp cannot shift a hybrid-attention context (`KV cache shifting is not supported for this context`), so Ollama cut the prompt and the model generated into a wall. The 8192 scaffolding margin in the registry formula is smaller than the estimate error (≥ 23%). |
| 2 | Outputs truncated | 7 completions hit `max_output_tokens` 16384 exactly (5 on `ornith-max`, 2 on `qwen3.6-max`). Reasoning tokens count as output. |
| 3 | Every call re-prefills everything | All four registry models are hybrid attention (`full_attention_interval=4`). One server slot (`OLLAMA_NUM_PARALLEL=1`), three agents alternating on it: each turn evicts the others' checkpoints (`selected slot by LCP similarity, f_sim_best = 0.412`, then `forcing full prompt re-processing`). One team job = ~3.7 M prompt tokens at 7.3 k tok/s ≈ 8 min at 470–570 W. |
| 4 | Window oversized for the work | 262144 per slot. Real use over 3794 calls: 72% under 32 k, p95 93 k, max 205 k. |
| 5 | The only OOM guard is the backend's estimator | `OLLAMA_MAX_LOADED_MODELS=2` with 25–28 GB models; `qwen3.6-max` was predicted at 30.5 of 31.4 GiB; `make test` swaps four such models per run for one 15-token call each. |
| 6 | The model never leaves VRAM | `OLLAMA_KEEP_ALIVE=30m` is refreshed by Jared's heartbeat every 1800 s (up to 12 shell commands ≈ 13 full-prefill calls). Resident model = 80 W idle; empty GPU = 45 W. |
| 7 | No burst cap | Power limit 600 W, bursts 570 W; the card's minimum limit is 400 W. |
| 8 | Nothing verifies the declared window | The spec says the physical window "is an operator declaration; the stack never queries the backend". True, and nothing checked it either: issue 1 lived for a day unseen. |

**Best practices applied** (llama.cpp, Ollama and vLLM server guidance; agent-runtime context management; nothing invented here):

- Declare the contract in one place, implement it per backend, verify it black-box through the interface every backend shares. Backend-specific knobs stay inside the provider mapping (`litellm_params`) and the backend's own config.
- One server slot per concurrently talking client; window per slot sized to the p95 of real prompts plus the output budget, never to the model's architectural maximum.
- When the client counts tokens by estimate, compact at 50–60% of the physical window; the backend's truncation is never the guard.
- Output budget ≥ 32 k for reasoning models.
- Short residency on a shared GPU; no LLM polling on a timer. Residency is the backend's business (Ollama `keep_alive`; llama.cpp and vLLM stay resident by design).
- The VRAM budget is written down and re-measured: weights + KV × slots + checkpoints + compute + display + headroom. A model is registered only after it loaded at its declared window and stayed on the GPU.
- The default test exercises the model in use, not the whole registry.
- Optional power cap on an inference box, persisted by the operator (typical cost 5–10% throughput).

**Design.**

| Piece | Where | Backend-specific? |
|---|---|---|
| window per slot | `model_info.context_window` on every chat model | no: a declaration |
| caps | `model_info`: `max_output_tokens: 32768`, `max_input_tokens = context_window − max_output_tokens − margin`, margin = max(context_window/4, 8192) | no; agents read both from the registry (plan 08), goose via `GOOSE_CONTEXT_LIMIT` (plan 12) |
| the backend honours the window | Ollama entries: `litellm_params.num_ctx: <context_window>` (forwarded as `options.num_ctx`, verified in LiteLLM 1.89.7 `OllamaChatConfig`); llama.cpp: `-c context_window × slots -np slots`; vLLM: `--max-model-len context_window --max-num-seqs slots` | yes, and only here |
| residency | Ollama entries: `litellm_params.keep_alive: "5m"`; bundled profile env `OLLAMA_KEEP_ALIVE`; other backends: none needed | yes, and only here |
| slots | bundled `ollama` profile: `OLLAMA_NUM_PARALLEL` from `.env`; host Ollama: same variable on that container; llama.cpp `-np`; vLLM `--max-num-seqs` | yes: backend config |
| verification | `scripts/context-probe.sh` (`make context-probe [M=…] [FULL=1]`): through LiteLLM, prompts at 50%, 100% of `max_input_tokens` and at `max_input_tokens + max_output_tokens − 128`; each must come back whole (`usage.prompt_tokens` within 16 of what was sent, HTTP 200) | no: black-box through the gateway |
| sizing (Ollama) | `scripts/model-fit.sh` (`make model-fit M=<tag>`): loads the model at candidate windows on the live Ollama, keeps the largest that stays fully on the GPU within the budget, prints the registry block | yes: an Ollama helper; other backends set the flags and run the probe |
| real use | `scripts/context-report.sh` (`make context-report`): per model from LiteLLM's spend log | no (needs the bundled `litellm-db`) |
| idle | `TEAM_HEARTBEAT_SECONDS=0` default | no |
| test cost | `scripts/smoke-test.sh`: registry arithmetic on `context_window`; chat round-trip on `TEAM_MODEL` only (`SMOKE_CHAT_MODELS=all` for the registry) | no |
| power cap | README, operator opt-in: `nvidia-smi -pl 450` + a systemd oneshot unit | host |

VRAM budget for `ornith-max` on the reference host (measured, MiB): weights 19903, mmproj + CUDA context ≈ 2200, KV 10.9 per 1 k tokens (hybrid: 10 of 41 layers hold KV, q8_0), context checkpoints 62.8 each × 8 per slot, compute 820–1318, display 1176.

| Configuration | KV | checkpoints | runner total | GPU total | headroom of 32106 |
|---|---|---|---|---|---|
| before: 1 slot × 262144 | 2782 | 503 | 25 254 (reported 24 908 + compute) | 26 430 | 5 676 |
| 1 slot × 131072 (measured today) | 1391 | 503 | 23 079 reported | 24 666 | 7 440 |
| after: 3 slots × 131072 (projected) | 4173 | 1507 | ≈ 28 300 | ≈ 29 500 | ≈ 2 600 |

The projection is verified by `make model-fit` and G29 before the registry value is kept. If the 3-slot load lands above 29 500 MiB, the fallback is `context_window: 98304` (`max_input_tokens: 40960`) rather than fewer slots.

**Success criteria.** G29 — registry arithmetic holds for every chat model (`context_window ≥ max_input_tokens + max_output_tokens`; Ollama entries carry `num_ctx == context_window`) and, on the reference host, the runner runs `-c 393216 -np 3` fully on the GPU with `memory.used` ≤ 29 500 MiB through a team smoke. G30 — `make context-probe` passes for every registered chat model (every probe accepted whole), and two consecutive team smokes show zero `truncated = 1` lines in the backend log with `make context-report` at `over_in 0`, `at_out 0`. G31 — prefilled tokens per team smoke drop by at least half against the baseline measured before the change, and agent turns log `f_sim_best` ≥ 0.9. G32 — six minutes after a smoke: no model resident, power ≤ 50 W, no chat completion in LiteLLM's log for 30 min. G33 — `make model-fit M=ornith-max` reproduces the registry's window; `make model-fit M=qwen3.8-max` yields its numbers, recorded; the probe on a deliberately wrong entry (`max_input_tokens` = `context_window`) **fails** (the probe is only worth having if it can fail). G34 (opt-in, measured once) — decode tok/s at 450 W within 10% of 600 W.

**Out of scope.** Replacing the heartbeat's LLM poll with a shell diff (§5); llama.cpp or vLLM as the team backend (§5 says when); recreating the `*-max` tags with a smaller `PARAMETER num_ctx` (operator step, documented); the 45 W display floor (three connected displays pin the memory clock at 14001 MHz).

## 2. Relevant files

| Path | Action |
|---|---|
| `proxy/config.yaml.example`, `proxy/config.yaml` | `context_window` + new caps on every chat model; `num_ctx` + `keep_alive` on Ollama entries; header formula |
| `scripts/context-probe.sh` | new: black-box window verification through the gateway |
| `scripts/model-fit.sh` | new: Ollama sizing helper, prints the registry block |
| `scripts/context-report.sh` | new: real context use vs caps from the spend log |
| `scripts/smoke-test.sh` | registry arithmetic check; round-trip on `TEAM_MODEL` by default |
| `docker-compose.yml` | `ollama` profile env block; `TEAM_HEARTBEAT_SECONDS` default 0 |
| `.env.example` | `OLLAMA_NUM_PARALLEL`, `OLLAMA_KEEP_ALIVE`; heartbeat comment |
| `Makefile` | `context-probe`, `model-fit`, `context-report` |
| `README.md` | "GPU budget" section with per-backend subsections; registering-models formula; make targets; team paragraph |
| `docs/spec.md` §3, §5.7, §5.15, §6, §7; `AGENTS.md` | docs, gates, status |

## 3. Dependencies and verified facts (reference host, 2026-09-14)

- **Ollama honours a per-request `num_ctx` and reloads the runner for it.** `POST /api/generate {"model":"ornith-max","options":{"num_ctx":131072},"keep_alive":"2m"}` → the runner restarted with `-c 131072 -np 1`; `/api/ps` reported `size_vram 23079283587, context_length 131072` (24 908 MB at 262144). `nvidia-smi memory.used` 24 666 MiB (26 430 before). Reload took ~10 s.
- **Ollama multiplies the window by `OLLAMA_NUM_PARALLEL`** (`-c num_ctx × parallel -np parallel`) and, when the variable is set explicitly, does not lower it to fit: an oversized request loads partially on the CPU instead (`size_vram < size` in `/api/ps`). `make model-fit` detects that case. **Verify at execution** from the llama-server cmdline (`docker exec ollama sh -c 'tr "\0" " " < /proc/$(pgrep -f llama-server | head -1)/cmdline'`) before any registry value is kept.
- **LiteLLM forwards `num_ctx` and `keep_alive` for `ollama_chat/`.** `OllamaChatConfig` (v1.89.7) lists `num_ctx` among its option fields (`/app/litellm/llms/ollama/chat/transformation.py:95`) and pops `keep_alive` into the request body (`:255`, `:323–324`). Extra keys under `litellm_params` reach the provider as optional params; `drop_params: true` drops only unknown OpenAI-style client params. For `openai/` entries (llama.cpp, vLLM) neither key applies: the window is a server flag. **Verify at execution**: after `make reload`, one chat completion, then `/api/ps` shows `context_length 131072` and `expires_at` ≈ now + 5 min.
- **Custom `model_info` fields pass through `/v1/model/info`** (`execution_locus`, `model_revision` since plan 01), so `context_window` will too. Whether `/v1/model/info` also exposes custom `litellm_params` keys (`num_ctx`) is **verified at execution**; today it shows `api_base`, `model` and LiteLLM's own flags.
- **`usage.prompt_tokens` through LiteLLM is the backend's own count** (Ollama `prompt_eval_count`, llama.cpp `prompt_n`, vLLM its tokenizer), so a silently truncated prompt shows up as fewer tokens than sent (spend log: `qwen3.8-max` max `prompt_tokens` 131071 = window − 1 exactly). A repeated fixed line tokenizes linearly (`tokens = c + k × repeats`), which is what the probe relies on to know how many tokens it sent: verified through LiteLLM on `ornith-max` with the probe's line, 200 / 400 / 800 repeats → `prompt_tokens` 2218 / 4418 / 8818 (11 tokens per line, 18 fixed, exact).
- **Measured VRAM breakdown** (llama-server `memory breakdown [MiB]`, `model + context + compute`): `ornith-max` at 262144: `19902 + 2782 + 820`; `laguna-max` at 262144: `20428 + 2908 + 820`; `qwen3.8-max` at 131072: `15339 + 5100 + 720` (dense 27B, 16 of 65 layers hold KV: ≈ 39 MiB per 1 k tokens). Context checkpoints (hybrid models): `size = 62.813 MiB`, up to 8 per slot (`--ctx-checkpoints` default, spacing 8192). The analytic check for `ornith-max` agrees: 10 attention layers × 2 KV heads × (256 + 256) × 1.0625 B (q8_0) = 10.9 kB per token.
- **Throughput.** Prefill 7 316 tok/s mean over 104 prompts > 5 k tokens; decode 236 tok/s. Power: 45 W empty (SM ≈ 360 MHz, memory clock pinned 14001 MHz by the displays), ≈ 80 W with a model resident and no calls, 470–570 W in prefill at 80–99% utilisation.
- **Truncation evidence.** llama-server log: 34 × `stop processing: n_tokens = 131071, truncated = 1` (all `qwen3.8-max`); 141 × `KV cache shifting is not supported for this context, disabling KV cache shifting`. Spend log: `ornith-max` max 205 155, p95 93 027, 5 completions ≥ 16 000; `qwen3.6-max` 2 completions at 18 128.
- **Host Ollama container** (outside the repo): `ollama/ollama` 0.33.3, env `OLLAMA_HOST=0.0.0.0:11434 OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=2 OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_KEEP_ALIVE=30m`, `restart=unless-stopped`. The operator changes its env; this plan documents the values and gates the result. The Ollama image has no curl; the LiteLLM image has python3 and no curl; the host has `jq`, `nvidia-smi`.
- **Agent side.** The entrypoint (plan 08) reads `max_input_tokens`/`max_output_tokens` for `TEAM_MODEL` from `/v1/model/info` into `BUZZ_AGENT_MAX_CONTEXT_TOKENS`/`BUZZ_AGENT_MAX_OUTPUT_TOKENS` (`GOOSE_CONTEXT_LIMIT` for goose). buzz-agent counts context by estimate; the base prompt already tells agents "after compaction or session restart, resume silently". Jared's heartbeat: `BUZZ_ACP_HEARTBEAT_INTERVAL` (`0 = disabled`), prompt `agents/jared-heartbeat.md` ("at most 12 shell commands").
- **Smoke test today** round-trips every `mode: chat` model with a 15-token prompt; each call on a different 25–28 GB model evicts the previous one (`sched.go: … predicted to exceed available memory, evicting`).
- **Power limit.** `nvidia-smi -q -d POWER`: current 600 W, min 400 W, max 600 W. `nvidia-persistenced` active; `nvidia-powerd` inactive. `-pl` does not survive a reboot.

## 4. Tasks

### Task 1 — registry: the contract on every chat model, backend knobs on the Ollama entries

`proxy/config.yaml.example` header, replace the formula lines with:

```yaml
# The context contract (plan 14), the same for every backend:
#   context_window     physical window PER SLOT the backend is configured for (model_info; a declaration, verified by make context-probe)
#   max_output_tokens  output budget (32768 for reasoning models: thinking counts)
#   max_input_tokens = context_window - max_output_tokens - margin,   margin = max(context_window / 4, 8192)
# The 25% margin covers the agents' token estimate (measured 23% under the real count) plus template/tool scaffolding.
# The backend must honour context_window: Ollama entries mirror it as litellm_params.num_ctx (forwarded per request) and
# carry keep_alive ("5m": idle GPU between jobs); llama.cpp is -c <window x slots> -np <slots>; vLLM --max-model-len.
# Ollama: `make model-fit M=<tag>` measures the window on the live backend and prints this block. Any backend:
# `make context-probe` proves the declaration through the gateway; `make context-report` shows real use against the caps.
```

Every chat entry gains `context_window`; Ollama entries also `num_ctx` and `keep_alive`. Sample for `ornith-max` (the value `131072` is the measured one; the others are set by `make model-fit` at execution and recorded in §8):

```yaml
  - model_name: ornith-max
    litellm_params:
      model: ollama_chat/ornith-max
      api_base: os.environ/LLM_BASE_URL
      num_ctx: 131072                 # = context_window (Ollama honours it per request); make model-fit 2026-09-14
      keep_alive: "5m"
    model_info:
      mode: chat
      context_window: 131072          # per slot; 3 slots x 131072 measured on the GPU, see plan 14
      max_input_tokens: 65536         # 131072 - 32768 - 32768
      max_output_tokens: 32768
      model_revision: "ollama:ornith-max:2026-09-14"
      execution_locus: local
```

`qwen3.6-max` (same architecture and size): same numbers. `laguna-max` (20.4 GB weights, 11.4 MiB per 1 k tokens): expected `131072`, verify. `qwen3.8-max` (dense, 39 MiB per 1 k tokens, 15.3 GB weights): expected `65536` with `max_output_tokens: 16384` and `max_input_tokens: 32768` (16384 margin); verify, and if `model-fit` returns less than `65536` register it with `# not for the team on this host`. The commented llama.cpp example becomes:

```yaml
  # --- llama.cpp / vLLM / LM Studio (OpenAI-compatible) example: the window is a SERVER flag, declared here and probed ---
  # - model_name: my-gguf-model
  #   litellm_params:
  #     model: openai/my-gguf-model
  #     api_base: http://llamacpp:8080/v1     # bundled profile; or http://host.docker.internal:8080/v1
  #     api_key: sk-unused                     # the client requires *a* key; an unauthenticated server ignores it.
  #                                            # Server with auth: api_key: os.environ/LLM_API_KEY (set LLM_API_KEY in .env)
  #   model_info:
  #     mode: chat
  #     context_window: 32768                 # llama.cpp: -c 98304 -np 3 gives 32768 per slot (LLAMACPP_CTX_SIZE = window x slots)
  #     max_input_tokens: 20480               # 32768 - 4096 - 8192
  #     max_output_tokens: 4096
  #     execution_locus: local
```

The `embed` entry is unchanged. Copy the result to `proxy/config.yaml` (gitignored; the example is the shipped sample) and `make reload`.

### Task 2 — backend slots and residency (Ollama layer)

`docker-compose.yml`, `ollama` service, add after `restart:`:

```yaml
    environment:
      OLLAMA_NUM_PARALLEL: ${OLLAMA_NUM_PARALLEL:-3}   # one slot per concurrently talking agent: the slot keeps that agent's prompt cache (plan 14)
      OLLAMA_KEEP_ALIVE: ${OLLAMA_KEEP_ALIVE:-5m}      # backstop for callers that bypass LiteLLM; the registry's keep_alive rules the rest
      OLLAMA_MAX_LOADED_MODELS: "2"                    # the chat model and the embedding model; a second chat model evicts the first
      OLLAMA_FLASH_ATTENTION: "1"
      OLLAMA_KV_CACHE_TYPE: q8_0                       # halves the KV cost of the window; the registry's windows assume it
```

`.env.example`, under `# --- Optional backends`:

```
# Ollama tuning (bundled `ollama` profile). A host Ollama needs the same variables on its own container: README "GPU budget".
# OLLAMA_NUM_PARALLEL=3     # slots: Dinesh, Gilfoyle and Jared talk concurrently during a job; the rest queue
# OLLAMA_KEEP_ALIVE=5m      # unload 5 min after the last call; the registry's keep_alive does the same for calls through LiteLLM
# llama.cpp profile: LLAMACPP_CTX_SIZE = context_window x slots, and add -np <slots> --no-context-shift to its command (README)
```

`.env.example`, under `# --- LLM backend`:

```
# Key for an OpenAI-compatible server that requires one (intranet vLLM, LM Studio with auth). Blank for Ollama and open servers;
# registry entries reference it as api_key: os.environ/LLM_API_KEY
LLM_API_KEY=
```

Host Ollama (reference host, operator step, documented in README): recreate the `ollama` container with `OLLAMA_NUM_PARALLEL=3` and `OLLAMA_KEEP_ALIVE=5m`, the other three variables as they are. Gate G29 reads the resulting llama-server cmdline.

### Task 3 — `scripts/context-probe.sh` and `make context-probe` (any backend)

```bash
#!/usr/bin/env bash
# Black-box verification of the context contract through the gateway (plan 14), for ANY backend LiteLLM fronts.
# For each registered chat model: send prompts of 50% and 100% of max_input_tokens, and one of
# max_input_tokens + max_output_tokens - 128 (the window must hold both); each must come back whole:
# HTTP 200 and usage.prompt_tokens within 16 of what was sent. A backend that truncates silently (Ollama past
# num_ctx) returns fewer tokens; one that rejects (llama.cpp, vLLM) returns an error. Either fails the probe.
# FULL=1 also generates max_output_tokens once per model (slow: ~2 min per 32k tokens at 236 tok/s).
# Usage: make context-probe [M=<model_name>] [FULL=1]        Exit 1 on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
base="${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}"; auth="Authorization: Bearer ${LITELLM_MASTER_KEY}"
info=$(curl -fsS -H "$auth" "$base/v1/model/info")
models=${M:-$(jq -r '.data[] | select(.model_info.mode=="chat") | .model_name' <<<"$info")}
LINE="alpha beta gamma delta epsilon zeta eta theta iota kappa"   # a fixed line tokenizes the same on every repeat: tokens = c + k * repeats
body() { yes "$LINE" | head -n "$1" | tr '\n' ' '; }
ask() {   # ask <model> <repeats> <max_tokens> -> "<prompt_tokens> <finish_reason>" or "ERROR <message>"
  jq -cn --arg m "$1" --arg p "$(body "$2")" --argjson t "$3" \
     '{model:$m, messages:[{role:"user",content:("Reply with the single word ok.\n\n"+$p)}], max_tokens:$t, temperature:0}' \
  | curl -sS "$base/v1/chat/completions" -H "$auth" -H 'Content-Type: application/json' -d @- \
  | jq -r 'if .error then "ERROR " + (.error.message|tostring|.[0:160]) else "\(.usage.prompt_tokens) \(.choices[0].finish_reason)" end'
}
rc=0
for m in $models; do
  read -r win cap_in cap_out <<<"$(jq -r --arg m "$m" '.data[] | select(.model_name==$m) | "\(.model_info.context_window // 0) \(.model_info.max_input_tokens) \(.model_info.max_output_tokens)"' <<<"$info")"
  [ "${win:-0}" -gt 0 ] || { echo "$m: no context_window in model_info"; rc=1; continue; }
  # calibrate this model's tokenizer on the line: two sizes give the exact slope k and offset c
  read -r t1 _ <<<"$(ask "$m" 200 4)"; read -r t2 _ <<<"$(ask "$m" 400 4)"
  [[ $t1 =~ ^[0-9]+$ && $t2 =~ ^[0-9]+$ ]] || { echo "$m: calibration failed: $t1 / $t2"; rc=1; continue; }
  k=$(( (t2 - t1) )); c=$(( t1 * 2 - t2 ))      # k = tokens per 200 repeats, c = fixed overhead (system/template/instruction)
  echo "$m: context_window=$win max_input=$cap_in max_output=$cap_out; $((k/200)) tokens per line, $c fixed"
  for label in "50% of max_input:$(( cap_in / 2 ))" "100% of max_input:$cap_in" "max_input + max_output - 128:$(( cap_in + cap_out - 128 ))"; do
    target=${label##*:}; name=${label%%:*}
    reps=$(( (target - c) * 200 / k )); sent=$(( c + reps * k / 200 ))
    read -r got fin <<<"$(ask "$m" "$reps" 4)"
    if [[ $got =~ ^[0-9]+$ ]] && [ "$got" -ge $(( sent - 16 )) ]; then
      echo "  ok   $name: sent ~$sent tokens, backend counted $got"
    else
      echo "  FAIL $name: sent ~$sent tokens, got '$got $fin' (silent truncation or rejection: lower max_input_tokens or raise context_window)"; rc=1
    fi
  done
  if [ "${FULL:-0}" = 1 ]; then
    out=$(jq -cn --arg m "$m" --argjson t "$cap_out" '{model:$m, messages:[{role:"user",content:"Write a very long essay about the history of roads. Do not stop before 40000 words."}], max_tokens:$t}' \
      | curl -sS "$base/v1/chat/completions" -H "$auth" -H 'Content-Type: application/json' -d @- \
      | jq -r 'if .error then "ERROR " + (.error.message|tostring) else "\(.usage.completion_tokens) \(.choices[0].finish_reason)" end')
    echo "  output budget: completion_tokens / finish_reason = $out   (length at $cap_out = the cap held end to end)"
  fi
done
[ $rc = 0 ] && echo "context probe: every registered window holds" || echo "context probe: FAILED" >&2
exit $rc
```

`Makefile`:

```make
context-probe:   ## prove every chat model's declared window through the gateway (any backend): make context-probe [M=<model>] [FULL=1] (plan 14)
	./scripts/context-probe.sh
```

Add `context-probe model-fit context-report` to `.PHONY`.

### Task 4 — `scripts/model-fit.sh` and `make model-fit` (Ollama helper)

```bash
#!/usr/bin/env bash
# Size a model for this GPU on an OLLAMA backend (plan 14). Loads it at candidate windows on the LIVE backend, keeps
# the largest window that stays fully on the GPU within the budget, and prints the proxy/config.yaml block.
# The backend's OLLAMA_NUM_PARALLEL is already folded into what it reports (it loads -c num_ctx x parallel), so the
# measurement is exact for the server as configured. Re-run after changing slots, the KV cache type, the model, or
# the GPU. Other backends: set the server's window flags, declare context_window, run `make context-probe`.
# Usage: make model-fit M=<ollama tag> [OUT=32768] [HEADROOM_MB=2048]
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
M=${M:-${1:-}}; [ -n "$M" ] || { echo "usage: make model-fit M=<ollama tag>  [OUT=<max_output_tokens>] [HEADROOM_MB=<free VRAM to keep>]"; exit 1; }
OUT=${OUT:-32768}
HEADROOM_MB=${HEADROOM_MB:-2048}             # kept free for compute-buffer growth under load and the embedding model
CANDIDATES=${CANDIDATES:-262144 196608 131072 98304 65536 49152 32768 16384}
GPU_INDEX=${GPU_INDEX:-0}

# Backend calls run inside litellm (python3, no curl there) so LLM_BASE_URL resolves as the stack sees it;
# without a litellm container (external gateway) they go to OLLAMA_URL from the host.
api() {   # api <path> [json body]
  if docker compose ps -q litellm 2>/dev/null | grep -q .; then
    docker compose exec -T litellm python3 -c '
import sys, urllib.request
base, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(base + path, data=body.encode() if body else None, headers={"Content-Type": "application/json"})
sys.stdout.write(urllib.request.urlopen(req, timeout=900).read().decode())' "$LLM_BASE_URL" "$1" "${2:-}"
  else
    curl -fsS "${OLLAMA_URL:-http://127.0.0.1:11434}$1" ${2:+-d "$2"}
  fi
}
api /api/tags >/dev/null 2>&1 || { echo "$LLM_BASE_URL is not an Ollama backend (no /api/tags): set the window on your server, declare context_window, run make context-probe"; exit 1; }
unload_all() { for m in $(api /api/ps | jq -r '.models[].name'); do api /api/generate "{\"model\":\"$m\",\"keep_alive\":0}" >/dev/null; done; sleep 3; }

api /api/show "{\"model\":\"$M\"}" | jq -e .details >/dev/null || { echo "$M is not a model on $LLM_BASE_URL"; exit 1; }
arch=$(api /api/show "{\"model\":\"$M\"}" | jq -r '.details.family + " " + .details.parameter_size + " " + .details.quantization_level')

if command -v nvidia-smi >/dev/null; then
  total=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=memory.total --format=csv,noheader,nounits | tr -d ' ')
  unload_all
  other=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' ')   # display server etc.
else
  [ -n "${VRAM_MB:-}" ] || { echo "no nvidia-smi: set VRAM_MB=<total> and OTHER_MB=<used by the display server>"; exit 1; }
  total=$VRAM_MB; other=${OTHER_MB:-0}; unload_all
fi
budget=$(( total - other - HEADROOM_MB ))
echo "model $M ($arch); GPU $total MiB, other $other MiB, headroom $HEADROOM_MB MiB -> budget for the runner: $budget MiB"
printf '%-8s %-10s %-10s %s\n' window size_MiB vram_MiB verdict

pick=""; pick_vram=""
for ctx in $CANDIDATES; do
  api /api/generate "{\"model\":\"$M\",\"prompt\":\"\",\"options\":{\"num_ctx\":$ctx},\"keep_alive\":\"1m\",\"stream\":false}" >/dev/null 2>&1 || { printf '%-8s %-10s %-10s %s\n' "$ctx" - - "load failed"; continue; }
  read -r size vram <<<"$(api /api/ps | jq -r --arg m "$M" '.models[] | select(.name==$m or .name==($m+":latest")) | "\(.size/1048576|floor) \(.size_vram/1048576|floor)"')"
  [ -n "${size:-}" ] || { printf '%-8s %-10s %-10s %s\n' "$ctx" - - "not loaded"; continue; }
  if [ "$vram" -lt "$size" ]; then verdict="spills to CPU"
  elif [ "$vram" -gt "$budget" ]; then verdict="over budget"
  else verdict="fits"; fi
  printf '%-8s %-10s %-10s %s\n' "$ctx" "$size" "$vram" "$verdict"
  if [ "$verdict" = fits ]; then pick=$ctx; pick_vram=$vram; break; fi
done
unload_all
[ -n "$pick" ] || { echo "no candidate fits: fewer slots (OLLAMA_NUM_PARALLEL), a smaller quantisation, or a smaller model"; exit 2; }

margin=$(( pick / 4 )); [ "$margin" -lt 8192 ] && margin=8192
in=$(( pick - OUT - margin ))
[ "$in" -ge 16384 ] || echo "WARNING: max_input_tokens $in is small: lower OUT, or give the model fewer slots"
name=${M%:latest}
cat <<EOF

# paste into proxy/config.yaml, then: make reload && make context-probe M=$name && make test
  - model_name: $name
    litellm_params:
      model: ollama_chat/$M
      api_base: os.environ/LLM_BASE_URL
      num_ctx: $pick                 # = context_window; make model-fit $(date +%F): $pick_vram MiB on the GPU with OLLAMA_NUM_PARALLEL as set
      keep_alive: "5m"
    model_info:
      mode: chat
      context_window: $pick
      max_input_tokens: $in         # $pick - $OUT - $margin
      max_output_tokens: $OUT
      model_revision: "ollama:$name:$(date +%F)"
      execution_locus: local
EOF
```

`Makefile`:

```make
model-fit:       ## Ollama: measure a model's window on the live backend, print its registry block: make model-fit M=<tag> [OUT=32768] (plan 14)
	@test -n "$(M)" || { echo "usage: make model-fit M=<ollama tag> [OUT=<max_output_tokens>] [HEADROOM_MB=2048]"; exit 1; }
	M=$(M) ./scripts/model-fit.sh
```

### Task 5 — `scripts/context-report.sh` and `make context-report`

```bash
#!/usr/bin/env bash
# Real context use per model from LiteLLM's spend log against the registry caps (plan 14): the input to sizing,
# and the check that no call sat on a truncation edge. Any backend; needs the bundled litellm-db.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
SINCE=${SINCE:-7 days}
base="${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}"; auth="Authorization: Bearer ${LITELLM_MASTER_KEY}"
docker compose ps -q litellm-db 2>/dev/null | grep -q . || { echo "no litellm-db container (external gateway): nothing to report"; exit 0; }
echo "context use per model, last $SINCE   (over_in: prompts above max_input_tokens = compaction came late; at_out: completions at max_output_tokens = truncated)"
printf '%-14s %6s %8s %8s %8s %8s %7s %6s\n' model calls p50_in p95_in max_in max_out over_in at_out
curl -fsS -H "$auth" "$base/v1/model/info" \
  | jq -r '.data[] | select(.model_info.mode=="chat") | "\(.model_name) \(.litellm_params.model) \(.model_info.max_input_tokens) \(.model_info.max_output_tokens)"' \
  | while read -r name lm cap_in cap_out; do
      docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "select count(*), coalesce(percentile_cont(0.5) within group (order by prompt_tokens)::int,0), coalesce(percentile_cont(0.95) within group (order by prompt_tokens)::int,0), coalesce(max(prompt_tokens),0), coalesce(max(completion_tokens),0), count(*) filter (where prompt_tokens > $cap_in), count(*) filter (where completion_tokens >= $cap_out) from \"LiteLLM_SpendLogs\" where model='$lm' and \"startTime\" > now() - interval '$SINCE'" \
        | { IFS='|' read -r calls p50 p95 maxin maxout over atout; printf '%-14s %6s %8s %8s %8s %8s %7s %6s\n' "$name" "$calls" "$p50" "$p95" "$maxin" "$maxout" "$over" "$atout"; }
    done
```

`Makefile`:

```make
context-report:  ## real prompt/completion sizes per model vs the registry caps, from LiteLLM's spend log (plan 14)
	./scripts/context-report.sh
```

### Task 6 — idle: heartbeat off by default

- `docker-compose.yml`: `BUZZ_ACP_HEARTBEAT_INTERVAL: ${TEAM_HEARTBEAT_SECONDS:-0}`.
- `.env.example` and spec §3: `TEAM_HEARTBEAT_SECONDS=0    # Jared's proactive triage tick (plan 08). 0 = off (default since plan 14: a tick is ~13 LLM calls at full prefill every interval and keeps the model in VRAM). 7200 when you want it.`
- `agents/jared-heartbeat.md`: unchanged.

### Task 7 — smoke test: registry arithmetic, one model by default

In `test_litellm`, after the registry listing:

```bash
  echo "--- litellm: context contract (context_window >= max_input_tokens + max_output_tokens on every chat model, plan 14)"
  curl -fsS -H "$auth" "$base/v1/model/info" | jq -r '.data[] | select(.model_info.mode=="chat") | "\(.model_name) \(.model_info.context_window // 0) \(.model_info.max_input_tokens) \(.model_info.max_output_tokens) \(.litellm_params.model) \(.litellm_params.num_ctx // 0)"' \
    | while read -r m win in out lm ctx; do
        [ "$win" -gt 0 ] || fail "$m: no context_window in model_info (Ollama: make model-fit M=<tag>; others: declare your server's window)"
        [ $(( in + out )) -le "$win" ] || fail "$m: max_input_tokens + max_output_tokens ($in + $out) exceeds context_window $win"
        case "$lm" in ollama_chat/*) [ "$ctx" = "$win" ] || fail "$m: litellm_params.num_ctx ($ctx) must equal context_window ($win)" ;; esac
        echo "$m: window $win >= $in + $out"
      done
```

**Verify at execution** that `/v1/model/info` exposes `litellm_params.num_ctx`; if LiteLLM strips custom `litellm_params` keys, drop the `case` line and check `num_ctx == context_window` in `proxy/config.yaml` with `awk` instead (record which path was needed).

Replace the round-trip loop's model list: `SMOKE_CHAT_MODELS` (default `${TEAM_MODEL:-}`, else the first chat model; `all` = every chat model), and note it in the echo line: `chat round-trip (SMOKE_CHAT_MODELS=${SMOKE_CHAT_MODELS:-$TEAM_MODEL}; all = every chat model, one model swap each)`.

### Task 8 — power cap (documentation, opt-in)

README "GPU budget" section (Task 9) carries:

```bash
sudo nvidia-smi -pl 450          # bursts capped at 450 W (this card: min 400, max 600); lost at reboot
# persist: /etc/systemd/system/nvidia-power-limit.service
# [Unit]\nDescription=GPU power limit\nAfter=nvidia-persistenced.service\n[Service]\nType=oneshot\nExecStart=/usr/bin/nvidia-smi -pl 450\n[Install]\nWantedBy=multi-user.target
```

G34 measures decode tok/s at 450 W once (one long generation through LiteLLM, `usage.completion_tokens` over wall time) and records it; the cap stays off unless the operator enables it.

### Task 9 — docs

- `docs/spec.md`: §3 (`OLLAMA_NUM_PARALLEL`, `OLLAMA_KEEP_ALIVE`, heartbeat default); §5.7 host Ollama env as measured; new §5.15 "Context contract and GPU budget (plan 14)": the contract paragraph, the issues table, the budget table, the formula, per-backend implementation table (Ollama / llama.cpp / vLLM / external), `context-probe`, `model-fit`, `context-report`, heartbeat default, power cap; §6 registry sample with `context_window`; §7 gates G29–G34. Replace "the stack never queries the backend for it" with "the stack declares it and proves it through the gateway (`make context-probe`)".
- `README.md`: "Registering models" — the contract, the formula, `make context-probe` after every registry edit, `make model-fit` for Ollama, `make context-report`; new "GPU budget" section after "Bring your own LLM backend" with subsections **Any backend** (budget method, probe), **Ollama** (host container variables, `model-fit`), **llama.cpp** (`-c` = window × slots, `-np`, `--no-context-shift` so an overflow is a 400 not a cut, `-ctk/-ctv q8_0`, `-fa on`, no idle unload: stop the container), **vLLM** (`--max-model-len`, `--max-num-seqs`, `--gpu-memory-utilization`), **power cap**; a recipe **Same repo, another backend** (develop against a local Ollama, deploy against an intranet OpenAI-compatible server): the `.env` diff (`LLM_BASE_URL`, `LLM_API_KEY`), the registry diff (`ollama_chat/<tag>` → `openai/<name>` + `api_base: <server>/v1` + `api_key: os.environ/LLM_API_KEY`, same `model_name`, `context_window` from the server's flags, the embedding entry as `openai/<name>` with `mode: embedding`), then `make reload && make context-probe && make team-model M=<name> && make test`; team paragraph: three slots, heartbeat off by default; make-targets table rows.
- `AGENTS.md`: status line + one non-negotiable: "Every chat model declares `context_window`; `max_input_tokens = context_window − max_output_tokens − max(context_window/4, 8192)`; Ollama entries mirror it as `num_ctx` and carry `keep_alive`; `make context-probe` must pass after any registry edit; the smoke fails on the arithmetic (spec §5.15). Never raise a window by hand: `make model-fit` (Ollama) or the server's flags plus the probe."

## 5. Considerations and future requirements

- **Backend-agnostic by construction.** Above the gateway nothing changes between backends: the registry fields, the probe, the report, the agents' caps. Switching the team backend to llama.cpp or vLLM is: run the server with the window flags, register `openai/<name>` with `context_window`, `make context-probe`, `make team-smoke`. The known trade-offs (2026-09-14): llama.cpp gives `--no-context-shift` (an overflow is an HTTP 400, never a silent cut), per-model slots, `--slot-save-path`, `--cache-reuse`, exact flags, but one model per process and no idle unload (80 W resident until the container stops; `llama-swap` adds a TTL at the cost of one more service); vLLM gives paged attention and real batching, heavier than "light". Ollama gives multi-model, per-request window, idle unload, maintained qwen3.5-family parsers, and silent truncation as its failure mode, which the probe and the margin cover. Ollama stays the default because idle unload matters here; write plan 15 when `context-report` shows `over_in > 0` under the new caps, or when per-model slots are needed.
- **Deployment path.** A developer runs the repo against a local Ollama; the same repo deploys against an intranet server (vLLM, llama.cpp, LM Studio, any OpenAI-compatible API) by `.env` and registry alone: `LLM_BASE_URL`, `LLM_API_KEY`, `openai/<name>` entries with `context_window` from that server's flags, same `model_name`s so personas and `TEAM_MODEL` do not change. Not hot for the team: LiteLLM restarts (~30 s) and the agents read their caps at container start (`make team-model` recreates them). The probe proves the window on the new server; `make team-smoke` is the behavioural acceptance test there (tool-call and thinking parsers differ per server; expect persona misses of the kind plan 12 §7 recorded, and fix them in the server's template flags, never in personas).
- **Adding a model, from now on:** Ollama: `ollama pull <tag>`, `make model-fit M=<tag>`, paste, `make reload`, `make context-probe M=<name>`, `make test`. Any other backend: set the server's window, declare `context_window` and the caps by the formula, `make reload`, `make context-probe`, `make test`. Re-run sizing whenever slots, KV type, quantisation or GPU change; `make test` catches arithmetic drift, the probe catches a window the backend no longer honours, neither catches a window that no longer fits in VRAM (Ollama: `model-fit`; others: the backend's own log). Watch `make context-report` for a week: `over_in` > 0 means the margin is too small for that model's tokenizer, `at_out` > 0 means the output budget is.
- **Hybrid re-prefill is architectural.** With per-agent slots a turn re-prefills only the tail past the last checkpoint (spacing 8192, ≈ 1 s at 7.3 k tok/s), but any prompt that is not append-only (compaction, session rotation, a different agent on the slot) costs a full prefill. Fewer calls and shorter prompts are the only further lever; persona budgets (plan 13: 12 commands per heartbeat) are that lever.
- **Slots are server-wide in Ollama.** Three slots fit `ornith-max` at 131072; a dense model like `qwen3.8-max` gets a smaller window under the same three slots. Per-model slot counts need one llama.cpp server per model or vLLM. Two concurrent jobs = six talking agents = six slots at ~65536, or a second GPU.
- **Direct callers.** Anything that calls the backend without LiteLLM gets the backend's default window (Ollama Modelfile: 262144) and, on Ollama, forces a runner reload each way. The operator can recreate the `*-max` tags with `PARAMETER num_ctx 131072` (`ollama create`); not gated here.
- **Token counting stays an estimate** in buzz-agent; the 25% margin is the guard, the probe proves the window, `context-report` shows whether the margin was enough. If a future buzz-agent exposes a compaction threshold or calls LiteLLM's `/utils/token_counter`, the margin can shrink to 8192.
- **The OOM guard** is the backend's (Ollama estimator + `MAX_LOADED_MODELS=2`; llama.cpp fails to start; vLLM `--gpu-memory-utilization`). `model-fit` verifies reality for Ollama; a model that fits alone but not next to `embed` shows as `sched.go … evicting` on every Open WebUI RAG call.
- **Heartbeat without an LLM.** The right shape is a shell script that polls Gitea and prompts Jared only when the summary changed; buzz-acp's heartbeat has no pre-check hook today, so the default is off. A later plan can add `scripts/team-heartbeat.sh` posting to the `triage` channel with the smoke identity, or a Gitea webhook into Buzz.
- **Output budget 32768.** Reasoning tokens count. If `at_out` rises with a new model, that model loops in thought: lower `temperature` or disable thinking for it before raising the cap.
- **Host change (announced): 9950X3D, 32 GB DDR5.** The GPU and driver stay, so nothing in this plan moves. A 25 GB GGUF is mmap'd; with 32 GB RAM the page cache holds one model, every swap re-reads from NVMe (seconds), and CPU offload is no longer an option: a "spills to CPU" verdict becomes a hard fail. Never `--no-mmap`/`--mlock` a 25 GB model on that host. Re-run `make model-fit` once after the move to confirm.
- **Power.** 45 W is the display floor; the cap at 450 W is a host setting persisted by the unit above. Multi-GPU: `GPU_INDEX` for `model-fit`.

## 6. Testing strategy

Baseline first, on the unchanged stack: one `make team-smoke` with the Ollama log marked (`docker logs --since` from a timestamp), summing `prompt eval time = … / N tokens` over the run and counting `truncated = 1`; then `make context-probe` on the **old** registry with a temporary entry where `max_input_tokens = context_window = 131072` on `qwen3.8-max`, which must **fail** (G33's negative case, proving the probe detects the exact failure of issue 1). Then tasks 1–7, host Ollama recreated, `make reload`, `docker compose up -d --force-recreate dinesh gilfoyle jared erlich monica`, and the gates in order: arithmetic, cmdline and probe (G29, G30 part 1), two smokes (G30, G31 against the baseline), idle (G32), `model-fit` on two models (G33), the power measurement (G34). Every number goes into §8.

## 7. Validation commands

```bash
# baseline (before any change)
T0=$(date -u +%FT%TZ); make team-smoke
docker logs --since "$T0" ollama 2>&1 | grep -oE 'prompt eval time = +[0-9.]+ ms / +[0-9]+ tokens' | awk '{s+=$(NF-1)} END{print "prefilled tokens:", s}'
docker logs --since "$T0" ollama 2>&1 | grep -c 'truncated = 1'
# negative probe: a wrong declaration must fail (temporary entry, removed afterwards)
make context-probe M=qwen3.8-max      # with context_window: 131072, max_input_tokens: 131072 -> FAIL at "100% of max_input"

# G29 contract + slots
make reload && make test 2>&1 | sed -n '/context contract/,/chat round-trip/p'
docker exec ollama sh -c 'tr "\0" " " < /proc/$(pgrep -f llama-server | head -1)/cmdline' | grep -oE '\-c [0-9]+ -np [0-9]+'      # -c 393216 -np 3
docker exec ollama ollama ps                                                                                                  # 100% GPU
nvidia-smi --query-gpu=memory.used --format=csv,noheader                                                                      # <= 29500 MiB during a smoke

# G30 no truncation: probe every model, then two team passes
make context-probe                                                                                                            # every registered window holds
T1=$(date -u +%FT%TZ); make team-smoke && make team-smoke
docker logs --since "$T1" ollama 2>&1 | grep -c 'truncated = 1'                                                               # 0
make context-report                                                                                                           # over_in 0, at_out 0 for ornith-max

# G31 cache reuse
docker logs --since "$T1" ollama 2>&1 | grep -oE 'prompt eval time = +[0-9.]+ ms / +[0-9]+ tokens' | awk '{s+=$(NF-1)} END{print "prefilled tokens (2 smokes):", s}'   # <= half the baseline per smoke
docker logs --since "$T1" ollama 2>&1 | grep -oE 'f_sim_best = [0-9.]+' | sort | uniq -c | sort -rn | head                  # mass at >= 0.9

# G32 idle
sleep 360; curl -s localhost:11434/api/ps | jq '.models|length'                                                               # 0
nvidia-smi --query-gpu=power.draw,pstate --format=csv,noheader                                                                # <= 50 W
docker logs --since 30m open-llm-stack-litellm-1 2>&1 | grep -c 'chat/completions'                                            # 0 (heartbeat off)

# G33 sizing
make model-fit M=ornith-max            # table + block with context_window 131072
make model-fit M=qwen3.8-max OUT=16384 # record its numbers into the registry, then make context-probe M=qwen3.8-max

# G34 power cap (measured once, then reset)
sudo nvidia-smi -pl 450; FULL=1 make context-probe M=ornith-max   # completion_tokens over wall time
sudo nvidia-smi -pl 600; FULL=1 make context-probe M=ornith-max   # both tok/s into §8
```

## 8. Execution report (executed 2026-09-14, external Gitea mode, `ornith-max`, Dinesh on `buzz-agent`, host Ollama 0.33.3, RTX 5090, driver 580.126.18)

### Findings and deviations

1. **`jq --arg` cannot carry a 100 k-token prompt** (`/usr/bin/jq: Argument list too long`, the kernel's per-argument limit; the first negative probe reported `model=None` because the request never left the shell). `context-probe.sh` passes the body with `--rawfile p <(body N)`. Same shape everywhere a script builds a large JSON body.
2. **Ollama 0.33.3 gives the qwen3.5 family one slot whatever `OLLAMA_NUM_PARALLEL` says**: `sched.go:509 msg="model architecture does not currently support parallel requests" architecture=qwen35moe` (ornith-max, qwen3.6-max, laguna-max) and `architecture=qwen35` (qwen3.8-max). Every registry model therefore runs `-c <num_ctx> -np 1`; the plan's 3 × 131072 budget row and the per-agent prompt cache (G31) are not reachable on this backend for these models. `OLLAMA_NUM_PARALLEL=3` is kept on the container and in the compose default (harmless here, right for architectures that support it) and the limitation is written into §5.15 and the README. A dense architecture that does support it (first `qwen3.8-max` attempt before Ollama classified it) got `-c 786432 -np 3` and `common_params_fit_impl: cannot meet free memory target … need to reduce device memory by 9761 MiB`, which confirms fact 2 of §3: Ollama does not shrink an explicit oversized window.
3. **`model-fit` needs a cap.** With one slot the architectural maximum "fits": ornith-max 262144 → 23754 MiB fits, qwen3.6-max 21672, qwen3.8-max 17683 (laguna-max spills at 262144 and 196608: `size_vram < size`, its MTP draft model). The largest-that-fits rule then contradicts the plan's own sizing principle (p95 of real prompts + output budget). Added `MAX_WINDOW` (default 131072, candidates ≤ it) to `scripts/model-fit.sh` and `make model-fit`; the registry values below come from the capped run.
4. **The negative probe fails at Ollama's layer, not llama-server's.** `context_window = max_input_tokens = 131072` on `qwen3.8-max` (temporary entry): `50%` ok at 65534, `100%` `FAIL … got '65538 length'`, third case the same: Ollama 0.33.3 cut the 131 k prompt to half the window before the runner saw it, so no `truncated = 1` line appeared (the plan's evidence came from `n_tokens = 131071` cuts inside llama-server on an older path). Both are silent; the probe catches both because it compares `usage.prompt_tokens` with what was sent.
5. **`context-report.sh` printed one row**: `docker compose exec -T` inside the `while read` loop consumed the remaining model lines from the loop's stdin. Fixed with `</dev/null` on the exec.
6. **The probe's own prompts count as `over_in`**: its third case is `max_input + max_output − 128` by design, so after a probe each model shows `over_in ≥ 1` in `make context-report` for the window that includes it. The gate reads the report over the smokes' own interval (`SINCE="<seconds since T1> seconds"`); documented in §5.15 and the README.
7. **Not in the task list but required by the contract:** the bundled `buzz-agent` had `BUZZ_AGENT_MAX_CONTEXT_TOKENS=237568` (compose default, `.env.example`, `.env`, spec §3) and `BUZZ_AGENT_MAX_OUTPUT_TOKENS=16384` hard-coded; both now follow the new window (65536 / 32768), and the live `.env` got `TEAM_HEARTBEAT_SECONDS=0` (the plan changed the example only; the default is meaningless while the operator's file still said 1800). `buzz-agent` and the five team agents were recreated.
8. **`sudo` on the reference host needs a password**, so G34 (`nvidia-smi -pl 450`) was not run from this session; the commands are in the README and §7 for the operator.
9. `/v1/model/info` exposes both custom `litellm_params` keys (`num_ctx`) and custom `model_info` keys (`context_window`), so the smoke's `num_ctx == context_window` check works from the gateway; no `awk` fallback needed.
10. Host Ollama recreated (operator step, same image id `ollama/ollama:0.33.3` = `sha256:32931b46…`): `docker run -d --name ollama --restart unless-stopped --gpus all -p 0.0.0.0:11434:11434 -v ollama:/root/.ollama -e OLLAMA_HOST=0.0.0.0:11434 -e OLLAMA_NUM_PARALLEL=3 -e OLLAMA_MAX_LOADED_MODELS=2 -e OLLAMA_FLASH_ATTENTION=1 -e OLLAMA_KV_CACHE_TYPE=q8_0 -e OLLAMA_KEEP_ALIVE=5m ollama/ollama:0.33.3`.

### Baseline (before any change; one slot × 262144, heartbeat 1800 s)

```
T0=2026-09-14T16:36Z; make team-smoke -> TEAM SMOKE PASS: PR #37 (score line + labels PASS)
prefilled tokens: 210895 over 34 prompts (47 prompt evals; min 138, median 1373, max 22681 tokens)
truncated lines: 0 (the smoke's prompts stay far under the window; the 34 historical cuts were qwen3.8-max jobs)
f_sim_best >= 0.9: 17 / < 0.9: 31; "forcing full prompt re-processing": 18
```

### model-fit (host Ollama with OLLAMA_NUM_PARALLEL=3; every model got -np 1, finding 2)

```
uncapped (MAX_WINDOW unset, first pass):        capped (MAX_WINDOW=131072, the registry):
ornith-max   262144  23754 MiB  fits              ornith-max   131072  22010 MiB  fits   -> 65536 / 32768
qwen3.6-max  262144  21672 MiB  fits              qwen3.6-max  131072  21288 MiB  fits
laguna-max   262144  12996/23179 spills to CPU    laguna-max   131072  21114 MiB  fits
             196608  17040/22283 spills to CPU
             131072  21114 MiB  fits
qwen3.8-max  262144  17683 MiB  fits              qwen3.8-max  131072  17043 MiB  fits
budget line: GPU 32607 MiB, other 1239-1243 MiB (display), headroom 2048 -> 29316-29320 MiB for the runner
```

### Gate output (real)

```
# negative probe (old registry + temporary qwen3.8-max entry context_window=131072, max_input_tokens=131072, num_ctx=131072):
#   qwen3.8-max: context_window=131072 max_input=131072 max_output=16384; 11 tokens per line, 18 fixed
#   ok   50% of max_input: sent ~65534 tokens, backend counted 65534
#   FAIL 100% of max_input: sent ~131072 tokens, got '65538 length'
#   FAIL max_input + max_output - 128: sent ~147319 tokens, got '65538 length'
#   context probe: FAILED (exit 1)                                                     -> G33 negative case
# /v1/model/info for that entry: litellm_params.num_ctx=131072, model_info.context_window=131072 (finding 9)
# after make reload with the new registry: one completion, then /api/ps: context_length 131072, expires_at = now + 5 min; runner: -c 131072 -np 1; memory.used 24731 MiB
# agents recreated: jared/dinesh log model=ornith-max context=65536 output=32768; jared BUZZ_ACP_HEARTBEAT_INTERVAL=0
# G29 (smoke section): qwen3.6-max / ornith-max / laguna-max / qwen3.8-max: window 131072 >= 65536 + 32768
# G30 make context-probe (7 min 44 s, four models, one swap each): every model ok at 32765 / 65534 / 98171 tokens (backend counted exactly what was sent) -> "context probe: every registered window holds"
# G29/G30/G31 two smokes, T1=2026-09-14T17:10:59Z: TEAM SMOKE PASS PR #39 and PR #40 (7/7 each, score lines + labels)
#   ollama ps during smoke 1: ornith-max 23 GB 100% GPU 131072; runner -c 131072 -np 1
#   nvidia-smi sampled every 5 s: peak memory.used 24887 MiB (<= 29500), median 24761; peak power 597 W
#   truncated = 1 lines: 0
#   make context-report SINCE=209 seconds (the two smokes only): ornith-max calls 95, p50_in 12173, p95_in 16896, max_in 18656, max_out 503, over_in 0, at_out 0
#   G31: prefilled tokens 437978 over 74 prompts for two smokes (~219 k per smoke vs 211 k baseline; NOT halved); f_sim_best >= 0.9: 17 / < 0.9: 57 -> G31 NOT MET (finding 2: one slot, three agents alternate on it)
# make test (full, exit 0): context contract 4/4, round-trip ornith-max only, every layer section, TEAM SMOKE PASS PR #41 (score 2/5 high), factory, mirror, runtime, PR scoring (canned rubric inside jared)
# G32 idle, T3=17:17:41Z (last completion of make test): /api/ps empty at 17:22:46 (305 s after T3); power 65.2 W at +30 s, 52.4 W at +60 s, 57.5-57.7 W at +30 min, P0, memory.used 1254 MiB (three displays)
#   LiteLLM log 17:18-17:48: zero completions from the stack; Jared made no heartbeat call (interval 0). One host-side request at 17:26:46 (POST /key/generate then a bodiless POST /v1/chat/completions -> 500 "Router.acompletion() missing 'messages'") came from another session on this machine, not from any agent (no agent log line at that time)
#   -> G32: unload and "no LLM polling" hold; power sits at 52-58 W, above the plan's 50 W line and the 45 W floor measured earlier today with the same displays (P0 state persisted after the unload; not chased further)
# make context-report (7 days, current caps): ornith-max 4025 calls p50 15236 p95 90892 max 205155 over_in 454 (history above the new cap); qwen3.8-max 185 calls max_in 131071 over_in 118 (the old cuts); at_out 0 everywhere
```

### Reading the numbers

- Gate status: G29 pass, G30 pass, G31 **not met** (one slot), G32 pass on unload and idle calls with power at 52–58 W (plan said ≤ 50 W), G33 pass, G34 not run (operator's sudo).
- The contract holds end to end on this backend: every declared window is honoured (probe), the smokes ran with no truncation and no prompt near the cap (`max_in 18656` of 65536), the model unloads five minutes after the last call and the heartbeat no longer keeps it warm.
- Prefill did not drop because there is still one slot: three agents alternate on it and each turn evicts the others' checkpoints (`f_sim_best < 0.9` on 57 of 74 prompts). Per-agent prompt caches need a backend that gives this architecture more than one sequence (llama.cpp per model with `-np`, or vLLM) — the next plan's first question when a job's prefill time matters more than idle unload.
- `over_in` and `at_out` are the numbers to watch under real work; both were 0 for the gated smokes. The historical rows (`over_in 454` on ornith-max) are prompts from before this plan measured against the new cap: the compaction that buzz-agent does at its estimate of 65536 will now fire far earlier than the 131072 window.

### Addendum 2026-09-14 (late): host Ollama upgraded to 0.34.0, G31 rechecked

`docker rm -f ollama` and the same `docker run` line with `ollama/ollama:0.34.0` (image pulled earlier; models kept in the `ollama` volume). Loaded `ornith-max` and `qwen3.8-max` once each:

```
{"version":"0.34.0"}
time=2026-09-15T00:54:57.041Z level=WARN source=sched.go:509 msg="model architecture does not currently support parallel requests" architecture=qwen35moe
time=2026-09-15T00:56:22.124Z level=WARN source=sched.go:509 msg="model architecture does not currently support parallel requests" architecture=qwen35
```

Same limitation as 0.33.3 for both architectures, so G31 stays not reachable on Ollama; release notes 0.33.0–0.34.1-rc1 do not mention parallel support for qwen3.5. `make context-probe` after the upgrade: every registered window holds (ornith-max, laguna-max, qwen3.8-max at 50%, 100%, max_input + max_output − 128). Stack healthy. Next levers unchanged: a later Ollama release, llama.cpp `-np 3` with a GGUF, or a dense architecture that supports slots.

### Addendum 2026-09-14 (late): G34 measured

Operator set the cap (`sudo nvidia-smi -pl 450`, then `-pl 600` to reset); both runs on Ollama 0.34.0, `ornith-max`, through LiteLLM.

| Cap | `FULL=1 make context-probe M=ornith-max` | Timed generation, 4,096 completion tokens, 30 prompt tokens |
|---|---|---|
| 450 W | passes; output budget 27,550 tokens `stop`; 139 s wall for the four calls | 16.15 s wall, **253.6 tok/s** |
| 600 W | passes; output budget 12,708 tokens `stop`; 66 s wall | 16.36 s wall, **250.3 tok/s** |

Decode draw stayed at 349–362 W under both caps, so 450 W never throttles decode on this model; the difference is noise (1%). The cap only trims prefill bursts (470–570 W uncapped). G34 met (within 10%). The cap stays off; the systemd oneshot in the README is the opt-in.

```
450.00 W
  output budget: completion_tokens / finish_reason = 27550 stop   (length at 32768 = the cap held end to end)
context probe: every registered window holds
450W: {"c":4096,"p":30,"f":"length"} wall=16.147081574s decode=253.6 tok/s
600.00 W
  output budget: completion_tokens / finish_reason = 12708 stop   (length at 32768 = the cap held end to end)
context probe: every registered window holds
600W: {"c":4096,"p":30,"f":"length"} wall=16.362015066s decode=250.3 tok/s
```
