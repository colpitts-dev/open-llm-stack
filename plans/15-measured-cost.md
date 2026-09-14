# Plan 15 — Measured cost: what the local models cost to run, from metered energy and your tariff

**Spec:** `docs/spec.md` (this plan adds §5.16 and gates G35–G36). **Rules:** `AGENTS.md`. **Knowledge:** plan 14 §5.15 (context contract, `context-report`, backend-agnostic rule).
**Sequence:** 15. Requires plan 14 executed. Adds two host scripts, three make targets, two stack-owned tables in the bundled `litellm-db`, four `.env` lines. No new service, image, port, build, network or Python package. Per-client keys, per-token rates and the status JSON were split out on 2026-09-14 (§3 "Deferred"): keys go to plan 16 (members are data there), status to plan 17 (the console owns its contract), rates to a later plan once a week of rows exists.
**Execute with:** `/execute plans/15-measured-cost.md`
**No internet.** Every mechanism below was verified on the reference host on 2026-09-14 (RTX 5090, driver 580.126.18, i9-10900K, Corsair PSU with USB telemetry, LiteLLM v1.89.7, Postgres 17, Python 3.12.3).

---

## 1. Overview

**The number this plan exists for:** kWh the local models burned, × `POWER_COST_PER_KWH` (cents per kWh; the report prints dollars). Everything else (per model, per client, busy vs idle) is that number cut finer. Two energy figures, never blended: `measured_kwh` (the hardware counter of the scope you attribute, `POWER_SCOPE`: the GPU on a discrete card, ±5%) and `host_kwh` = `measured + overhead × seconds`, where the overhead is measured per second (host-scope rows minus scope rows: a PSU or a plug) or typed (`POWER_HOST_OVERHEAD`); the report says which. Cost is `host_kwh × tariff`, printed in dollars to four decimals (a 30-minute window is a fraction of a cent). Good enough to tell a client "your agents used roughly N kWh this week"; not a billing instrument.

**Intent.** Local inference is not free: the GPU drew 470–570 W in prefill, 80 W with a model resident, 45 W empty, and LiteLLM's spend log says `$0.00` for all of it. The operator pays a utility tariff (18.13 cents per kWh on the reference site). This plan meters energy on the host, joins the seconds to LiteLLM's ledger, and prints the answer.

**Why LiteLLM is the ledger and not the meter.** LiteLLM has no GPU and the stack is backend-agnostic (plan 14): the meter runs where the hardware is, on the host, for any backend on that host. LiteLLM keeps the per-call record (`LiteLLM_SpendLogs`: `startTime`, `endTime`, tokens, model, key alias); the join happens in its database.

**Why polling a "current watts" value is not metering, and what is.** NVML exposes `nvmlDeviceGetTotalEnergyConsumption`: a counter in millijoules integrated inside the GPU since driver load. Two reads and a subtraction give the exact energy of the interval regardless of how spiky the load was between them. The meter reads it once per second and stores the delta: samples of an exact integral, not samples of a fluctuating value. Verified here through `ctypes` on `libnvidia-ml.so.1` with no package installed: a 5 s delta of 232.0 J gave 46.4 W against 47.7 W instantaneous. Calls in the ledger have millisecond boundaries, so attribution is time alignment of two exact records. Where a domain has no counter (a PSU's power rail, an old card) the meter stores `power × dt` and marks the row `exact = false`.

**Probes, domains, scopes.** The meter is a small probe registry with one interface: a domain either has a cumulative energy counter (exact) or a sampled power reading (`exact = false`). Every row names its domain and its scope:

| Probe (`POWER_PROBES`) | Reads | Domain | Default scope | Verified here |
|---|---|---|---|---|
| `nvml[:i,j]` | `libnvidia-ml.so.1` energy counter (mJ), power, memory, utilisation, per card | `nvml:0` | `gpu` | yes: RTX 5090 |
| `hwmon:<name>[:<attr>]` | any `/sys/class/hwmon` sensor by driver name: `energy*_input` (µJ counter) if present, else `power*_input` / `power*_average` (µW, sampled) | `hwmon:corsairpsu:power1` | `host` | yes: Corsair PSU total DC output at 1 Hz |

Scopes: `gpu` (the accelerator), `soc` (a package that is the whole inference engine: an APU), `host` (the machine at its PSU or plug). `POWER_SCOPE` (default `gpu`) is the scope `cost-report` attributes to calls; rows of the other scopes are kept for one thing: the measured overhead (`host − scope`, per second). Scopes are never summed together. `=gpu|soc|host` on a probe overrides its default (`hwmon:amdgpu:power1=soc` on an APU). A RAPL probe for APUs (`/sys/class/powercap`, `energy_uj`) is a ~15-line addition when that hardware exists; on the reference host the file is root-only (`0400`) and the CPU package is not the inference engine, so it is not built here.

**Why the overhead is additive, not a factor.** Measured 2026-09-14 on the reference host: PSU total output 158 W DC while the GPU drew 56 W; at 570 W prefill the box draws about 680 W. The non-GPU part is ≈ 100 W and flat: ratio 2.8 at idle, 1.18 in prefill, so no single factor fits both, and idle hours dominate a week. `POWER_HOST_OVERHEAD` (additive) fits both with one number the operator reads once at a PSU, UPS or plug. Where a host-scope probe runs, the overhead is measured per second and the knob is ignored. Either way it is a constant on the headline: it cancels in every comparison between models and clients, which is why the GPU counter alone is the right attribution meter.

**Line protocol.** The meter prints one JSON line per domain per second on stdout and reads no `.env`; `--ingest` reads those lines on stdin and `COPY`s them into `stack_energy` every 2 s. `make power-meter` pipes the two. A second inference host needs nothing installed: `ssh gpu2 python3 - --probes nvml < scripts/power-meter.py | make power-ingest` (standard library only, no database port exposed). The 2 s flush is what makes the console's "power now" tile (plan 17) current to a few seconds: one `docker compose exec psql` round trip is 0.10 s.

**Design.**

| Piece | Where | What |
|---|---|---|
| meter | `scripts/power-meter.py`, `make power-meter`, `make power-ingest` (host; README systemd user unit) | 1 Hz, every configured probe: counter delta (or `power × dt`, `exact = false`) → JSON lines → `stack_energy(host, domain, scope, ts, joules, watts_avg, mem_mib, util, exact)`, primary key `(host, domain, ts)` |
| report | `scripts/cost-report.sh`, `make cost-report [SINCE=…]` | TOTAL first (`measured_kwh`, `host_kwh` + measured/estimated, `cost`, `calls_kwh`, `idle_kwh`, `avg_w`), then per model, per client, per domain. Per call: joules of the attributed scope in overlapping seconds (every domain of that scope summed) pro rata, split equally among concurrent calls → `stack_call_energy(request_id, model, joules, seconds, shared)`, incremental. Idle = total − calls. 90-day retention |
| price | `.env`: `POWER_COST_PER_KWH`, `POWER_PROBES`, `POWER_SCOPE`, `POWER_HOST_OVERHEAD` | `cost = host_joules / 3.6e6 × cents / 100`, printed in dollars |

**Measured facts the numbers rest on** (2026-09-14): `power.draw.average` is a 1 s average ±5 W on Ampere+ (`watts_avg` column only); prefill 7 316 tok/s, decode 236 tok/s on `ornith-max`; one team job ≈ 3.7 M prompt tokens; 24 h on the reference host: 2 907 calls, 94.6 M prompt tokens, 1.52 M completion tokens, all at `$0.00`; PSU total 158 W DC at GPU 56 W, non-GPU overhead 74–144 W second by second, ≈ 100 W mean (§3).

**Success criteria.** G35 — ten minutes of meter rows with `POWER_PROBES=nvml,hwmon:corsairpsu`: 600 ± 2 rows per domain; the `nvml:0` sum of `joules` within 0.5% of the counter delta read directly at start and end; the PSU domain present with `exact = false`; the stdin form (`python3 - --probes nvml --host gpu2 < scripts/power-meter.py | make power-ingest`) writes rows under host `gpu2` (deleted afterwards). G36 — a team smoke with the meter on: `make cost-report SINCE="30 minutes"` prints TOTAL with `measured_kwh` > 0, `host_kwh_is` = `measured` (the PSU), `cost` > 0 at 18.13 cents/kWh (four decimals), `overhead_w` between 70 and 150, `calls_kwh + idle_kwh = measured_kwh`; every call in the window that overlaps metered seconds has a `stack_call_energy` row (calls during a metering gap have nothing to attribute); the per-model line for `ornith-max` is non-zero and its `wh_per_1k_tok` is within 2× of 0.021 (the value the reference constants predict); with `POWER_PROBES=nvml` alone and `POWER_HOST_OVERHEAD=100` the same report says `estimated` and `host_kwh = measured_kwh + 100 W × seconds`.

**Out of scope.** Per-client keys (plan 16), per-token rates in the registry (later plan), the status JSON (plan 17), a RAPL or amdgpu probe for APUs and a plug probe (`plug:<url>`; the row shape is ready), a macOS probe (IOReport; the meter is a host process for exactly that reason), per-call attribution to one card of several (needs a model-to-GPU map the ledger does not have; the report sums the scope's domains), a prefill/decode split from timestamps (`completionStartTime` equals `endTime` on non-streaming calls, verified), hardware amortisation, any allocation of idle energy to clients (idle is shown, not charged).

## 2. Relevant files

| Path | Action |
|---|---|
| `scripts/power-meter.py` | new: probes → JSON lines (meter mode); JSON lines → `stack_energy` (`--ingest`) |
| `scripts/cost-report.sh` | new: attribution by scope, overhead, pricing, report |
| `.env.example` | power block (four lines) |
| `Makefile` | `power-meter`, `power-ingest`, `cost-report` |
| `README.md`, `docs/spec.md` §3, §5.16, §7, `AGENTS.md` | docs, gates, status |

## 3. Dependencies and verified facts (reference host, 2026-09-14)

- **NVML through `ctypes`, no package.** `ctypes.CDLL("libnvidia-ml.so.1")`: `nvmlInit_v2` → 0; `nvmlDeviceGetHandleByIndex_v2(0, &h)` → 0; `nvmlDeviceGetTotalEnergyConsumption(h, &ull)` → 0, value `1552638683` mJ (431 Wh since driver load); `nvmlDeviceGetPowerUsage` → mW; `nvmlDeviceGetMemoryInfo` fills `{total, free, used}` as three `c_ulonglong` (used 3246 MiB of 32607 at test time); `nvmlDeviceGetUtilizationRates` fills `{gpu, memory}` as two `c_uint`; `nvmlDeviceGetName` → `NVIDIA GeForce RTX 5090`. `NVML_ERROR_NOT_SUPPORTED` is return code 3. `pynvml` is not installed and not needed.
- **Revisions (2026-09-14, operator decisions, before any row exists).** Key `(host, gpu smallint, ts)` → `(host, domain text, ts)` + `scope`; multiplicative `POWER_OVERHEAD_FACTOR` → additive `POWER_HOST_OVERHEAD`; probe registry; stdout line protocol with `--ingest`. Then a review against the goal ("an estimated cost for the local LLMs from power and tariff") removed: the idle policy (auto baseline, resident vs floor buckets, sharing resident idle into clients' `energy_used`), the reconciliation table, the opt-in write-back into `LiteLLM_SpendLogs`, `HOST_COST_PER_HOUR`, `POWER_METER_INTERVAL`, `POWER_METER_HOST`, the RAPL probe (its refusal was the only thing verified here), and moved keys, rates and status to their own plans. The primary key is a one-way door once rows exist; changing it now costs nothing.
- **Host power on the reference host, from a PSU.** `/sys/class/hwmon/hwmon5` is `corsairpsu` (USB HID `1B1C:1C07`): `power1_label` = `power total`, `power2..4` = `+12v`, `+5v`, `+3.3v`, all `power*_input` in µW, mode `444` (no root). Six reads one second apart: `158 150 116 122 120 120` W, so the PSU samples at 1 Hz; 20 reads took 36 ms (USB round trip, 1.8 ms each). GPU at the same moment: 56 W (`nvidia-smi`). This is the DC side; the wall figure is DC divided by the PSU's efficiency at that load (about 0.9 for an 80+ Gold unit): documented, not modelled. `hwmonN` numbering is not stable across boots: the probe addresses sensors by their `name` file.
- **RAPL, for the record.** `/sys/class/powercap/intel-rapl:0` (`package-0`): `energy_uj` mode `400` (root-only on stock kernels), `max_energy_range_uj` = `262143328850`. A probe for it is deferred to an APU host; the README notes the udev rule an operator would need (`SUBSYSTEM=="powercap", ACTION=="add", RUN+="/bin/chmod 444 /sys%p/energy_uj"`, unverified).
- **Prototype run of `power-meter.py`** (2026-09-14; the prototype also carried a RAPL probe, `--table` and `--interval`, removed in Task 2; nothing else differs). `--probes nvml,hwmon:corsairpsu` for 5 s: header lines `nvml:0 NVIDIA GeForce RTX 5090 scope=gpu hardware energy counter` and `hwmon:corsairpsu:power1 'power total' scope=host sampled power x dt (uW): exact false /sys/class/hwmon/hwmon5/power1_input`, then rows such as `{"host": "pop-os", "domain": "nvml:0", "scope": "gpu", "ts": "2026-09-14 19:05:24", "joules": 49.096, "watts_avg": 49.1, "mem_mib": 1802, "util": 2, "exact": true}` and `{"host": "pop-os", "domain": "hwmon:corsairpsu:power1", "scope": "host", "ts": "2026-09-14 19:05:24", "joules": 126.009, "watts_avg": 126.0, "mem_mib": null, "util": null, "exact": false}`. `--probes hwmon:amdgpu` → `AssertionError: no hwmon sensor named amdgpu (ls /sys/class/hwmon/*/name)`. Stdin form `timeout 3 python3 - --probes nvml --host gpu2 < scripts/power-meter.py` → rows with `"host": "gpu2"`. Piped into `--ingest` against a scratch table for 13 s: 13 rows per domain; `nvml:0` summed 624 J against a counter delta of 634 J read around the run (the seed read of the first second is outside the rows by design); PSU domain 1 648 J, avg 127 W, `exact = f`, `mem_mib` null on every row (`\N` in `COPY`); `sum(joules) filter (where scope='host') - sum(joules) filter (where scope='gpu')` per second gave 78.6, 73.6, 78.0, 144.3 J (the overhead, second by second). Scratch tables dropped. One `docker compose exec -T litellm-db psql -Atc 'select 1'` round trip: 0.10 s (three runs), so a 2 s flush is cheap.
- **Spend log shape.** `LiteLLM_SpendLogs` columns include `request_id text`, `api_key text` (a hash), `spend double precision`, `startTime`/`endTime`/`completionStartTime` as `timestamp without time zone` **in UTC** (`max(endTime)` 17:26:46 against `now()` 17:26:56+00), `model`, `prompt_tokens`, `completion_tokens`, `request_duration_ms`, `metadata` (JSON with `user_api_key_alias`, null under the master key), `session_id`. `completionStartTime` is set on every `ollama_chat` call (0 nulls of 3006) but equals `endTime` on non-streaming calls, so it cannot split prefill from decode.
- **Postgres from the host.** `docker compose exec -T litellm-db psql -U litellm -d litellm` works for DDL, `COPY … FROM STDIN` and CTE queries. The attribution query below ran on 202 real calls with a synthetic 300 W meter in a rolled-back transaction: 241 291 J attributed of 276 000 J metered, busy 1 069.2 s, average concurrency 1.45; the remainder is idle seconds. A fuller version of the report SQL (with `\gset` scalars, per model, per client) ran the same way on 307 calls: metered 553.6 Wh = attributed 91.9 + idle 461.7 (the 4.4 Wh of call-boundary seconds, 0.8%, now sit inside `idle_kwh` by construction). The scope filter and the overhead scalars are additions to that SQL: **verify at execution** (G36).
- **Deferred pieces, verified facts kept so nothing is re-researched.** *Per-client keys → plan 16:* `POST /key/generate {"key_alias":"plan15-test","metadata":{…}}` → `{"key":"sk-…","key_alias":"plan15-test","models":[],"max_budget":null}`; a call with that key wrote a spend row with `metadata->>'user_api_key_alias' = plan15-test`; the key reads `/v1/model/info` and `/v1/models` (200), which the entrypoint needs; `GET /key/list?key_alias=…&return_full_object=true` → `total_count 1`; `POST /key/delete {"keys":[…]}`; test keys deleted; Compose nested default `${TEAM_X_LITELLM_KEY:-${LITELLM_MASTER_KEY}}` rendered `mk` / `vk` correctly; on 4597 rows `metadata` carries `user_api_key_alias`, `user_api_key_team_alias`, `user_api_key_team_id` (all null under the master key) and the `team_id` column is `''`, so a team split groups by the metadata alias; today agents get the master key through `&team-env` (`docker-compose.yml:51`), Open WebUI at `:131`, the Buzz agent at `:347`. *Per-token rates → later plan:* `input_cost_per_token` / `output_cost_per_token` are `LiteLLM_Params` fields (`/app/litellm/router.py:8098`) and also read from `model_info` (`proxy_server.py:11504`, `router.py:9283`); a 3×3 normal-equation least squares in the standard library recovered `a = 0.0749, b = 2.303, c = 42.6` from 400 synthetic calls (true 0.075, 2.3, 40); seed rates at $0.1813/kWh (the variable now holds cents: 18.13) are `3.777e-09` / `1.158e-07` dollars per token (0.075 and 2.3 J per token); a YAML rewrite on a scratch registry added exactly eight lines. *Status JSON → plan 17:* `docker compose ps --format json` gives one object per line with `Service`, `State`, `Health`; LiteLLM `GET /health/readiness` → `{"status":"healthy","db":"connected"}` without calling any model (`/health` test-calls every registered model: never in status); the last meter row per domain is `select distinct on (host, domain) * from stack_energy where ts > now() - interval '2 minutes' order by host, domain, ts desc` (ran on the scratch table).
- **Not verified here, by design.** An APU (`soc` scope), a second NVIDIA card, an old card without the counter. Each is a documented operator line, to be verified on the hardware that has it; the probe interface does not change.

## 4. Tasks

### Task 1 — `.env`

`.env.example`, new block after the LLM backend section:

```
# --- Measured cost (plan 15). Blank tariff = energy accounting off. The meter runs on the host that holds the hardware: make power-meter.
POWER_COST_PER_KWH=            # your utility tariff in CENTS per kWh, e.g. 18.13; cost = host_kwh x this / 100, printed in dollars
POWER_PROBES=nvml              # what the meter reads, comma list: nvml[:0,1] | hwmon:<name>[:<attr>], each [=gpu|soc|host]; e.g. nvml,hwmon:corsairpsu (a PSU with telemetry = the whole host)
POWER_SCOPE=gpu                # the scope cost-report attributes to calls: gpu (discrete card), soc (APU package), host (PSU or plug only)
POWER_HOST_OVERHEAD=           # the rest of the box beside POWER_SCOPE, in watts, added per second (100 on the reference host); blank = 0; ignored while a host-scope probe runs
```

### Task 2 — `scripts/power-meter.py`, `make power-meter`, `make power-ingest`

```python
#!/usr/bin/env python3
"""Energy meter (plan 15). One file, two modes.

meter (default): read every configured probe once per second and print one JSON line per domain per second on stdout:
  {"host","domain","scope","ts","joules","watts_avg","mem_mib","util","exact"}
  joules is the delta of a hardware energy counter where the domain has one (NVML, hwmon energy*_input: exact true), else
  power x dt (hwmon power*_input / power*_average: exact false). Standard library only, reads no .env, so the same file runs
  unchanged on another host:  ssh gpu2 python3 - --probes nvml < scripts/power-meter.py | python3 scripts/power-meter.py --ingest
--ingest: read those lines on stdin, batch 2 s, COPY into stack_energy in the bundled litellm-db (creates the tables).

Probes (--probes a,b,c; each probe[:selector][=scope]):
  nvml[:i,j]              NVIDIA cards by index (default all); scope gpu; libnvidia-ml.so.1 through ctypes
  hwmon:<name>[:<attr>]   any /sys/class/hwmon sensor by driver name (corsairpsu, amdgpu, ...); attr energy1 / power1 (default: first
                          energy*_input, else first power*_input or power*_average); scope host
Scopes: gpu (the accelerator), soc (a package that is the whole inference engine: an APU), host (the machine at its PSU or plug).
cost-report attributes one scope (POWER_SCOPE) and never sums across scopes; host rows give the measured overhead.
Run: make power-meter (foreground; README shows the systemd user unit)."""
import argparse, ctypes, glob, json, os, signal, subprocess, sys, time
from datetime import datetime, timezone

ap = argparse.ArgumentParser()
ap.add_argument("--probes", default="nvml"); ap.add_argument("--host", default=""); ap.add_argument("--ingest", action="store_true")
a = ap.parse_args()
HOST = a.host or os.uname().nodename
INTERVAL, FLUSH = 1.0, 2.0
DEFAULT_SCOPE = {"nvml": "gpu", "hwmon": "host"}


def log(*s): print(*s, file=sys.stderr, flush=True)


class Domain:   # one metered thing: a card, a PSU rail
    def __init__(self, name, scope, exact): self.name, self.scope, self.exact, self.last = name, scope, exact, None
    def sample(self, dt):   # -> (joules, watts_avg, mem_mib, util)
        raise NotImplementedError
    def delta(self, counter, scale):   # exact energy: counter difference, scaled to joules; the first read seeds
        prev, self.last = self.last, counter
        return None if prev is None else max(0, counter - prev) * scale


class NvmlDomain(Domain):
    class Mem(ctypes.Structure): _fields_ = [("total", ctypes.c_ulonglong), ("free", ctypes.c_ulonglong), ("used", ctypes.c_ulonglong)]
    class Util(ctypes.Structure): _fields_ = [("gpu", ctypes.c_uint), ("memory", ctypes.c_uint)]
    lib = None
    def __init__(self, index, scope):
        n = self.lib; h = ctypes.c_void_p()
        assert n.nvmlDeviceGetHandleByIndex_v2(index, ctypes.byref(h)) == 0, f"no GPU {index}"
        name = ctypes.create_string_buffer(96); n.nvmlDeviceGetName(h, name, 96)
        e = ctypes.c_ulonglong(); ok = n.nvmlDeviceGetTotalEnergyConsumption(h, ctypes.byref(e)) == 0   # 3 = NVML_ERROR_NOT_SUPPORTED (pre-Volta, MIG)
        super().__init__(f"nvml:{index}", scope, ok); self.h = h
        log(f"nvml:{index} {name.value.decode()} scope={scope} {'hardware energy counter' if ok else 'power x dt (counter unsupported): exact false'}")
    def sample(self, dt):
        n = self.lib; w = ctypes.c_uint(); e = ctypes.c_ulonglong(); m = self.Mem(); u = self.Util()
        n.nvmlDeviceGetPowerUsage(self.h, ctypes.byref(w)); watts = w.value / 1000.0
        n.nvmlDeviceGetMemoryInfo(self.h, ctypes.byref(m)); n.nvmlDeviceGetUtilizationRates(self.h, ctypes.byref(u))
        if self.exact:
            n.nvmlDeviceGetTotalEnergyConsumption(self.h, ctypes.byref(e)); j = self.delta(e.value, 1e-3)
        else: j = watts * dt
        return j, watts, m.used // 2**20, u.gpu


class HwmonDomain(Domain):
    def __init__(self, name, attr, scope):
        dirs = [d for d in glob.glob("/sys/class/hwmon/hwmon*") if open(d + "/name").read().strip() == name]
        assert dirs, f"no hwmon sensor named {name} (ls /sys/class/hwmon/*/name)"
        d = dirs[0]; files = sorted(os.listdir(d))
        if not attr:
            attr = next((f[:-6] for f in files if f.startswith("energy") and f.endswith("_input")), None) \
                or next((f.rsplit("_", 1)[0] for f in files if f.startswith("power") and f.split("_")[-1] in ("input", "average")), None)
            assert attr, f"{name} exposes no energy*_input or power*_input/average"
        self.path = next(d + "/" + f for f in files if f.startswith(attr + "_") and f.split("_")[-1] in ("input", "average"))
        label = open(f"{d}/{attr}_label").read().strip() if os.path.exists(f"{d}/{attr}_label") else ""
        super().__init__(f"hwmon:{name}:{attr}", scope, attr.startswith("energy"))
        log(f"{self.name} {label!r} scope={scope} {'energy counter (uJ)' if self.exact else 'sampled power x dt (uW): exact false'} {self.path}")
    def sample(self, dt):
        v = int(open(self.path).read())
        return (self.delta(v, 1e-6), None, None, None) if self.exact else (v / 1e6 * dt, v / 1e6, None, None)


def build(spec):
    kind, _, rest = spec.partition(":"); rest, _, scope = rest.partition("="); scope = scope or DEFAULT_SCOPE.get(kind)
    assert scope in ("gpu", "soc", "host"), f"{spec}: scope must be gpu, soc or host"
    if kind == "nvml":
        if NvmlDomain.lib is None:
            NvmlDomain.lib = ctypes.CDLL("libnvidia-ml.so.1"); assert NvmlDomain.lib.nvmlInit_v2() == 0, "nvmlInit failed"
        c = ctypes.c_uint(); NvmlDomain.lib.nvmlDeviceGetCount_v2(ctypes.byref(c))
        return [NvmlDomain(int(i), scope) for i in (rest.split(",") if rest else range(c.value))]
    if kind == "hwmon":
        name, _, attr = rest.partition(":"); assert name, "hwmon needs a sensor name: hwmon:corsairpsu"
        return [HwmonDomain(name, attr, scope)]
    sys.exit(f"unknown probe {spec}; probes: nvml[:i,j], hwmon:<name>[:<attr>], each [=gpu|soc|host]")


stop = False
signal.signal(signal.SIGTERM, lambda *_: globals().__setitem__("stop", True))
signal.signal(signal.SIGINT, lambda *_: globals().__setitem__("stop", True))


def meter():
    doms = [d for spec in a.probes.split(",") if spec for d in build(spec)]
    last = time.monotonic(); minute = {}; n = 0
    for d in doms: d.sample(0)   # seed the counters
    while not stop:
        time.sleep(max(0.0, INTERVAL - ((time.monotonic() - last) % INTERVAL)))
        now = time.monotonic(); dt = now - last; last = now
        ts = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0).isoformat(sep=" ")   # UTC, whole seconds: the spend log's precision
        for d in doms:
            j, w, mem, util = d.sample(dt)
            if j is None: continue
            print(json.dumps({"host": HOST, "domain": d.name, "scope": d.scope, "ts": ts, "joules": round(j, 3),
                              "watts_avg": round(j / dt, 1) if dt else w, "mem_mib": mem, "util": util, "exact": d.exact}), flush=True)
            minute[d.name] = minute.get(d.name, 0.0) + j
        n += 1
        if n >= 60:
            log(ts[11:16] + "  " + "  ".join(f"{k} {v / n:.0f} W" for k, v in minute.items())); minute, n = {}, 0
    if NvmlDomain.lib: NvmlDomain.lib.nvmlShutdown()


def ingest():
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ddl = """create table if not exists stack_energy (
  host text not null default '', domain text not null, scope text not null, ts timestamp not null,
  joules double precision not null, watts_avg real, mem_mib integer, util smallint, exact boolean not null default true,
  primary key (host, domain, ts));
create table if not exists stack_call_energy (
  request_id text primary key, model text, joules double precision not null, seconds double precision not null,
  shared double precision not null, computed_at timestamp not null default now());"""
    def psql(sql, stdin=None):
        return subprocess.run(["docker", "compose", "exec", "-T", "litellm-db", "psql", "-U", "litellm", "-d", "litellm", "-v", "ON_ERROR_STOP=1", "-q", "-c", sql],
                              input=stdin, text=True, capture_output=True)
    r = psql(ddl)
    if r.returncode != 0: sys.exit("cannot reach litellm-db (bundled litellm profile required): " + r.stderr.strip())
    rows, flushed = [], time.monotonic()
    def nz(v): return "\\N" if v is None else v
    def flush():
        nonlocal rows, flushed
        flushed = time.monotonic()
        if not rows: return
        data = "".join("\t".join(str(x) for x in (r["host"], r["domain"], r["scope"], r["ts"], r["joules"], nz(r["watts_avg"]), nz(r["mem_mib"]), nz(r["util"]), "t" if r["exact"] else "f")) + "\n" for r in rows)
        out = psql("copy stack_energy(host, domain, scope, ts, joules, watts_avg, mem_mib, util, exact) from stdin", stdin=data)
        if out.returncode == 0: rows = []
        else:
            log("copy failed, keeping rows: " + out.stderr.strip().splitlines()[-1]); rows = rows[-36000:]   # an hour of a 10-domain host, drop the oldest
    for line in sys.stdin:
        try: rows.append(json.loads(line))
        except ValueError: log("skipped: " + line.strip()); continue
        if time.monotonic() - flushed >= FLUSH: flush()
    flush()


ingest() if a.ingest else meter()
```

The key is `(host, domain, ts)`: one row per domain per second per host. One meter process per host loops over every configured domain, so two cards, or a card and a PSU, never collide; a second meter process on the same host with the same probes still would, by design. The first second after start is a seed read and produces no row for counter domains: G35 reads the counter around the run, not inside it.

`Makefile` (the tariff guard lives here, so the meter file itself stays `.env`-free):

```make
power-meter:     ## meter energy into litellm-db, 1 row/s per domain (plan 15; foreground, Ctrl-C to stop): probes from POWER_PROBES
	@set -a; . ./.env; set +a; [ -n "$$POWER_COST_PER_KWH" ] || { echo "POWER_COST_PER_KWH is blank in .env: energy accounting off"; exit 0; }; \
	python3 scripts/power-meter.py --probes "$${POWER_PROBES:-nvml}" | python3 scripts/power-meter.py --ingest

power-ingest:    ## meter lines on stdin into litellm-db; a second host: ssh gpu2 python3 - --probes nvml < scripts/power-meter.py | make power-ingest (plan 15)
	@python3 scripts/power-meter.py --ingest
```

README systemd user unit (documented, operator opt-in):

```
# ~/.config/systemd/user/stack-power-meter.service
[Unit]
Description=open-llm-stack energy meter
After=docker.service
[Service]
ExecStart=/usr/bin/make -C /home/adam/code/open-llm-stack power-meter
Restart=on-failure
[Install]
WantedBy=default.target
# systemctl --user enable --now stack-power-meter
```

### Task 3 — `scripts/cost-report.sh` and `make cost-report`

Order of the output is the order of the questions: how many kWh (and what did that cost), on which models, for which clients, per probe.

```bash
#!/usr/bin/env bash
# What the local models cost to run (plan 15): metered energy of one scope (POWER_SCOPE) x your tariff (cents/kWh, printed as dollars), then per model,
# per client, per domain. Per call: joules of the seconds a call ran, pro rata, split equally among concurrent calls
# (stack_call_energy, incremental). Idle = everything the scope burned outside calls (includes the ~1% of call-boundary
# seconds). Host = the whole machine: measured when a host-scope probe runs, else scope + POWER_HOST_OVERHEAD x seconds.
# Usage: make cost-report [SINCE="7 days"]
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
SINCE=${SINCE:-7 days}
[ -n "${POWER_COST_PER_KWH:-}" ] || { echo "POWER_COST_PER_KWH is blank: energy accounting off"; exit 0; }
docker compose ps -q litellm-db 2>/dev/null | grep -q . || { echo "no litellm-db container: nothing to report"; exit 0; }
docker compose exec -T litellm-db psql -U litellm -d litellm -v ON_ERROR_STOP=1 -q \
  -v since="$SINCE" -v rate="$POWER_COST_PER_KWH" -v scope="${POWER_SCOPE:-gpu}" -v overhead_w="${POWER_HOST_OVERHEAD:-0}" <<'EOF'
\set win 'now() - :''since''::interval'
\set kwh '(1.0 / 3600000.0)'
-- joules -> dollars: the tariff is cents per kWh. No trailing comments on \set lines: psql appends them to the value
\set usd '(:kwh * :rate / 100.0)'
-- one row per second for the attributed scope (every domain of that scope summed: LiteLLM does not know which card served a call)
-- and one for the host scope when a PSU or plug probe runs; scopes are never summed together
create temp view energy_s as select ts, sum(joules) as joules from stack_energy where scope = :'scope' group by ts;
create temp view host_s as select ts, sum(joules) as joules from stack_energy where scope = 'host' group by ts;
-- 1. attribute new calls: joules of overlapping seconds, pro rata by overlap, divided by the calls sharing each second
with calls as (
  select request_id, model, "startTime" s, "endTime" e from "LiteLLM_SpendLogs"
  where "endTime" > :win and "endTime" >= (select min(ts) from stack_energy) and request_id not in (select request_id from stack_call_energy)
), ov as (
  select c.request_id, c.model, x.ts, x.joules,
         greatest(0, extract(epoch from (least(c.e, x.ts + interval '1 second') - greatest(c.s, x.ts)))) as frac
  from calls c join energy_s x on x.ts < c.e and x.ts + interval '1 second' > c.s
), conc as (
  select x.ts, sum(greatest(0, extract(epoch from (least(l."endTime", x.ts + interval '1 second') - greatest(l."startTime", x.ts))))) as busy
  from energy_s x join "LiteLLM_SpendLogs" l on x.ts < l."endTime" and x.ts + interval '1 second' > l."startTime"
  where x.ts > :win - interval '1 hour' group by x.ts
)
insert into stack_call_energy (request_id, model, joules, seconds, shared)
select o.request_id, o.model, sum(o.joules * o.frac / greatest(1, c.busy)), sum(o.frac), avg(c.busy)
from ov o join conc c on c.ts = o.ts group by o.request_id, o.model;
-- 2. the window's numbers: scope total, overhead (measured host - scope when host rows exist, else POWER_HOST_OVERHEAD), host total, calls
select coalesce(sum(joules), 0) as scope_j, count(*) as scope_s from energy_s where ts > :win \gset
select case when :'scope' = 'host' then 0 else coalesce((select avg(h.joules - x.joules) from host_s h join energy_s x using (ts) where h.ts > :win), :overhead_w) end as ovh_w \gset
select case when :'scope' <> 'host' and exists (select 1 from host_s where ts > :win) then 'measured' else 'estimated' end as host_src \gset
-- host = scope + seconds x overhead in both cases (with full host-row coverage this equals the host rows' sum; with partial coverage it stays consistent)
select :scope_j + :scope_s * :ovh_w as host_j \gset
create temp view attributed as select e.request_id, e.joules, e.seconds, e.shared, l.model, l.prompt_tokens, l.completion_tokens,
       coalesce(nullif(l.metadata->>'user_api_key_alias', ''), 'master key') as client
  from stack_call_energy e join "LiteLLM_SpendLogs" l using (request_id) where l."endTime" > :win;
select coalesce(sum(joules), 0) as calls_j from attributed \gset
-- a group of calls at the host: its joules plus its share of seconds x overhead
\set host_cost '((sum(joules) + sum(seconds / greatest(1, shared)) * :ovh_w) * :usd)'
\echo energy, last :since   (scope :scope, tariff :rate cents per kWh, cost in dollars, host figure :host_src, overhead :ovh_w W)
\echo
\echo == TOTAL: measured = the scope counters; host = the whole machine; cost = host x tariff; idle = measured - calls
select round((:scope_j * :kwh)::numeric, 3) as measured_kwh, round((:host_j * :kwh)::numeric, 3) as host_kwh, :'host_src' as host_kwh_is,
       round((:host_j * :usd)::numeric, 4) as cost, round((:calls_j * :kwh)::numeric, 3) as calls_kwh,
       round(((:scope_j - :calls_j) * :kwh)::numeric, 3) as idle_kwh, round((:scope_j / greatest(1, :scope_s))::numeric, 0) as avg_w, :scope_s as seconds;
\echo
\echo -- per model (calls only; wh_per_1k_tok is the sizing number)
select model, count(*) as calls, sum(prompt_tokens) as prompt_tok, sum(completion_tokens) as completion_tok,
       round((sum(joules) * :kwh)::numeric, 3) as calls_kwh, round(:host_cost::numeric, 4) as cost,
       round((sum(joules) / 3600.0 * 1000 / greatest(1, sum(prompt_tokens) + sum(completion_tokens)))::numeric, 3) as wh_per_1k_tok
from attributed group by model order by calls_kwh desc;
\echo
\echo -- per client (LiteLLM key alias; one row, master key, until clients have their own keys: plan 16)
select client, count(*) as calls, round((sum(joules) * :kwh)::numeric, 3) as calls_kwh, round(:host_cost::numeric, 4) as cost
from attributed group by client order by calls_kwh desc;
\echo
\echo -- per domain (every probe row; scope :scope is attributed, host rows give the measured overhead)
select host, domain, scope, count(*) as rows, round((sum(joules) * :kwh)::numeric, 3) as kwh, round(avg(watts_avg)::numeric, 1) as avg_w, bool_and(exact) as exact
from stack_energy where ts > :win group by host, domain, scope order by host, scope, domain;
delete from stack_energy where ts < now() - interval '90 days';
EOF
```

**Verify at execution**: the `\gset` scalars and `:host_cost` are psql variables interpolated into later statements (`\set` expands `:name` at definition time, so `host_cost` is set after `ovh_w`); the dry run in §3 proved the mechanism. With an empty window every scalar is `0` through `coalesce` and the report prints zeros rather than failing.

`Makefile`:

```make
cost-report:     ## kWh the local models burned and what it cost, then per model, client, domain (plan 15): make cost-report [SINCE="24 hours"]
	./scripts/cost-report.sh
```

Add the three targets to `.PHONY`.

### Task 4 — docs

- `docs/spec.md`: §3 env rows; new §5.16 "Measured cost (plan 15)": the counter-not-sample argument, probes / domains / scopes and the rule that scopes are never summed, the two tables and their columns, the attribution rule (pro rata, equal split), idle shown not charged, the two energy figures and why they are never blended (`measured_kwh` at the scope's counters ±5%, `host_kwh` measured at a host probe or `measured + POWER_HOST_OVERHEAD × seconds` and labelled), why the overhead is additive (the 158 W / 56 W measurement), the price formula (`cost = host_kwh × cents / 100`, tariff stored in cents per kWh, cost printed in dollars), the line protocol and the remote-host form; §7 gates G35–G36 (G37–G39 are taken by plans 16 and 17: keys, rates, status).
- `README.md`: "What local inference costs" after "GPU budget": tariff in `.env` (cents per kWh), `make power-meter` and the systemd unit, the probe table (NVIDIA card; a PSU with hwmon telemetry as the whole host; an APU as `soc`, later), a second inference host by `ssh … | make power-ingest` (NTP on both), `make cost-report` sample output with the TOTAL line first and the wording to give a client ("measured at the GPU's energy counter; the whole-machine figure is measured at the PSU / an estimate"). Make-targets table rows.
- `AGENTS.md`: status line + one non-negotiable: "The stack's energy is measured on the host by `make power-meter` (probes `nvml`, `hwmon`; each row carries a domain and a scope `gpu|soc|host`; scopes are never summed), reported in kWh first (`make cost-report`: total, then model, client, domain), attributed to LiteLLM's ledger for one scope (`POWER_SCOPE`) and priced from `.env`; `measured_kwh` and `host_kwh` are never blended and the report says whether the host figure is measured or estimated (`POWER_HOST_OVERHEAD`, additive, never a factor); idle is shown, never charged to a client (spec §5.16)."

## 5. Considerations

- **Scopes, not vendors.** The meter's interface is "a domain with a counter, or a domain with a sampled power reading". NVML and hwmon are two readers of that interface; RAPL for APUs, a plug (`plug:<url>`) and IOReport on macOS are three more of 15–30 lines each, verified when the hardware exists. Nothing above the probe layer knows a vendor: the report groups by scope, the console reads rows. What stays OS-bound: the sysfs paths and the `.so` name inside the probes, and the systemd unit in the README.
- **Why additive overhead.** Non-accelerator draw on a workstation is mostly constant (CPU idle, board, storage, fans): measured 74–144 W second by second here, ≈ 100 W mean, whether the GPU drew 56 W or 570 W. A multiplicative factor over-charges busy seconds and under-charges idle ones; an additive watt figure is right in both. Where a host probe runs, the overhead is measured per second and the knob is ignored, which is how the operator finds the number to type on a host without one.
- **Idle is shown, not charged.** A model kept warm between calls and the display floor are the stack's cost, printed as `idle_kwh` beside `calls_kwh`. Allocating idle to clients is a policy question (by call seconds? by tokens? nobody?); the report gives both numbers and leaves the policy to whoever reads it. If a client figure that includes idle is wanted later, it is one more column, not a new mechanism.
- **Unified-memory SoCs.** Strix Halo, Apple Silicon: there is no separable GPU domain; the package is the inference engine, so the whole-SoC counter is the number to attribute and the residual overhead (fans, SSD, NIC) is small. Linux APU: a RAPL probe (`energy_uj`, root-only on stock kernels: udev rule) or `hwmon:amdgpu:power1=soc` where the driver exposes socket power, `POWER_SCOPE=soc`. Apple Silicon is a macOS host: containers run in a VM that cannot see the hardware, which is why the meter is a host process with a line protocol and not a service. Verified on that hardware, not here.
- **Concurrency.** Equal split per second among overlapping calls. With three slots that is rarely more than 1.5 (measured 1.45 on today's log). Token-weighted split later, if the numbers show it matters. The overhead is shared the same way (`seconds / shared`).
- **Two or more cards.** One row per domain per second; the report sums the scope's domains per second before attributing, so totals and idle are exact whether a model sits on one card or is split across two. Approximate: two different models answering at the same time on two different cards (call A carries part of card B's joules; the equal split softens it). A per-card split needs a model-to-GPU map the ledger does not have; v2, only if the per-domain lines show both cards busy at once often. MIG instances: the counter is unsupported per instance; the probe falls back to `power × dt`, `exact = false`.
- **Several hosts.** The line protocol makes a second inference host one ssh pipe with nothing installed there; its rows carry its `host`. The attribution is a time join, so both clocks must agree (NTP). The report treats every host's rows of the attributed scope as one pool per second, which is right while one LiteLLM ledger fronts them all.
- **Sampled domains.** A PSU's `power1_input` is a spot reading once a second, not an average: a 1 s interval keeps the error small (the PSU updates at 1 Hz here) but not zero, and it is the DC side (wall = DC / efficiency). Such rows are marked `exact = false`. The attributed scope on the reference host stays the NVML counter.
- **Old cards.** No energy counter before Volta: the NVML probe falls back to `power × dt` and prints it; the ±5 W reading and 1 s interval keep the error small but not zero.

## 6. Testing strategy

Meter first (G35, no LLM involved: two probes, the counter read around the run, the stdin form), then a team smoke with the meter on and the report (G36, once with the PSU probe so the overhead is measured, once with `nvml` alone so it is estimated). Numbers into §8.

## 7. Validation commands

```bash
# G35 meter accuracy: 10 minutes with two probes, the NVML counter read directly at both ends
sed -i 's|^POWER_PROBES=.*|POWER_PROBES=nvml,hwmon:corsairpsu|' .env
E0=$(python3 -c 'import ctypes;n=ctypes.CDLL("libnvidia-ml.so.1");n.nvmlInit_v2();h=ctypes.c_void_p();n.nvmlDeviceGetHandleByIndex_v2(0,ctypes.byref(h));e=ctypes.c_ulonglong();n.nvmlDeviceGetTotalEnergyConsumption(h,ctypes.byref(e));print(e.value)')
T0=$(date -u +'%F %T'); timeout 600 make power-meter; T1=$(date -u +'%F %T')
E1=$(python3 -c '…same one-liner…'); echo "counter delta J: $(( (E1 - E0) / 1000 ))"
docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "select host, domain, scope, count(*), round(sum(joules)), bool_and(exact) from stack_energy where ts between '$T0' and '$T1' group by 1,2,3"
#   nvml:0 gpu ~600 rows, sum within 0.5% of the counter delta (the seed second is outside the rows); hwmon:corsairpsu:power1 host ~600 rows, exact f
docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "select round(avg(h.joules - g.joules)), round(min(h.joules - g.joules)), round(max(h.joules - g.joules)) from (select ts, sum(joules) joules from stack_energy where scope='host' group by ts) h join (select ts, sum(joules) joules from stack_energy where scope='gpu' group by ts) g using (ts) where ts between '$T0' and '$T1'"   # the measured overhead: ~100 W, 70–150
# the remote form, locally: the script on stdin, nothing read from the repo, rows under another host name
timeout 5 python3 - --probes nvml --host gpu2 < scripts/power-meter.py | make power-ingest
docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "select host, count(*) from stack_energy where host='gpu2' group by 1; delete from stack_energy where host='gpu2'"   # 4 rows, then removed

# G36 the report on a real job, overhead measured at the PSU
setsid make power-meter > /tmp/meter.log 2>&1 & MPID=$!; sleep 3; PG=$(ps -o pgid= $MPID | tr -d ' ')   # a process group: `kill %1` would stop make and leave the two python processes running (verified); Ctrl-C and systemd are unaffected
make team-smoke; sleep 15; make cost-report SINCE="30 minutes"      # TOTAL: host_kwh_is measured, overhead_w 70–150, calls_kwh + idle_kwh = measured_kwh; ornith-max wh_per_1k_tok ~0.02
docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "select count(*) from \"LiteLLM_SpendLogs\" l where l.\"endTime\" > now()-interval '30 minutes' and not exists (select 1 from stack_call_energy e where e.request_id=l.request_id) and exists (select 1 from stack_energy x where x.scope='gpu' and x.ts < l.\"endTime\" and x.ts + interval '1 second' > l.\"startTime\")"   # 0: every metered call has a row
# the estimated form: nvml alone and the typed overhead; host_kwh_is estimated, host_kwh = measured_kwh + 100 W x seconds
kill -TERM -- -$PG; sed -i 's|^POWER_PROBES=.*|POWER_PROBES=nvml|; s|^POWER_HOST_OVERHEAD=.*|POWER_HOST_OVERHEAD=100|' .env
docker compose exec -T litellm-db psql -U litellm -d litellm -Atc "delete from stack_energy where scope='host'"   # so the window has no host rows
make cost-report SINCE="30 minutes" > /tmp/report.txt; head -6 /tmp/report.txt   # not `| head`: the closed pipe makes make report Error 255
```

## 8. Execution report (2026-09-14, reference host)

**Files.** `scripts/power-meter.py`, `scripts/cost-report.sh` (copied from Task 2 and Task 3 by extracting the code blocks, then the two fixes below applied to both the files and this plan); `Makefile` targets `power-meter`, `power-ingest`, `cost-report` + `.PHONY`; `.env.example` block after `LLM_API_KEY`; `docs/spec.md` §3 block, §5.16, §7 G35–G36; `README.md` "What local inference costs" + three make-target rows; `AGENTS.md` status line, non-negotiable, layout, commands. `.env` on the reference host: `POWER_COST_PER_KWH=18.13`, `POWER_PROBES=nvml,hwmon:corsairpsu`, `POWER_SCOPE=gpu`, `POWER_HOST_OVERHEAD=100`. `docker compose config --quiet` passes with the new lines.

**G35 (10 min, two probes).** `T0=2026-09-14 22:27:54 E0=2589668561`, `T1=2026-09-14 22:37:54 E1=2624399978`, `counter delta J: 34731`. Rows in `[T0, T1]`:

```
pop-os|hwmon:corsairpsu:power1|host|600|91221|f
pop-os|nvml:0|gpu|600|34727|t
```

600 rows per domain; `nvml:0` 34 727 J against the counter's 34 731 J (0.01%, the seed second excluded by design); PSU rows `exact = f`. Measured overhead (host − gpu, per second) over the run: `avg 94 W, min 46, max 203`. The meter's minute lines: `nvml:0 54–64 W, hwmon:corsairpsu:power1 143–162 W` (idle box, no model resident). Stdin form: `timeout 5 python3 - --probes nvml --host gpu2 < scripts/power-meter.py | make power-ingest` → `gpu2|5` rows (five, not four: a 5 s timeout yields five one-second rows after the seed), then `DELETE 5`. `timeout 600 make power-meter` ends the whole pipeline cleanly (verified on a 4 s trial: no python process left, 4 rows per domain).

**G36 (team smoke with the meter on, PSU probe).** `make team-smoke` → `PASS: score labels: complexity/1,confidence/high`. `make cost-report SINCE="30 minutes"`:

```
energy, last 30 minutes (scope gpu, tariff 18.13 cents per kWh, cost in dollars, host figure measured, overhead 110.40099224806204 W)
== TOTAL: measured = the scope counters; host = the whole machine; cost = host x tariff; idle = measured - calls
 measured_kwh | host_kwh | host_kwh_is |  cost  | calls_kwh | idle_kwh | avg_w | seconds
        0.033 |    0.065 | measured    | 0.0118 |     0.018 |    0.015 |   115 |    1036
-- per model
 ollama_chat/ornith-max |   111 |    1397635 |          24987 |     0.018 | 0.0043 |         0.012
-- per client
 master key |   111 |     0.018 | 0.0043
-- per domain
 pop-os | nvml:0                  | gpu   | 1036 | 0.033 | 114.9 | t
 pop-os | hwmon:corsairpsu:power1 | host  |  258 | 0.021 | 286.3 | f
```

`calls_kwh + idle_kwh = 0.018 + 0.015 = 0.033 = measured_kwh`; overhead 110 W (70–150); `ornith-max` `wh_per_1k_tok` 0.012 (within 2× of 0.021); cost `$0.0118` for the window. Every call overlapping metered seconds has a `stack_call_energy` row: `unattributed 36 | unattributed_but_metered 0 | calls 149` (the 36 ran 22:41–22:43, a gap with no meter rows between a first G36 attempt and its rerun: nothing to attribute, by design). Estimated form (`POWER_PROBES=nvml`, `POWER_HOST_OVERHEAD=100`, host rows deleted):

```
energy, last 30 minutes (scope gpu, tariff 18.13 cents per kWh, cost in dollars, host figure estimated, overhead 100 W)
        0.033 |    0.062 | estimated   | 0.0112 |     0.018 |    0.015 |   115 |    1037
```

`0.033 + 100 W × 1037 s / 3.6e6 = 0.062` ✓.

**Deviations from the plan as written (each fixed in the plan text above and in the files).**
1. Trailing `-- comments` on `\set` lines: psql appends every further argument to the variable, so `:usd` carried `--joules->dollars…` and commented out the rest of the SQL line (`syntax error at or near "round"`), and an apostrophe in `\echo … the scope's …` and in a `\set` comment gave `unterminated quoted string`. Comments moved to their own `--` lines; apostrophes removed from `\echo` text. The §3 dry run had covered `\gset`, not `\set` with comments.
2. Host figure: with partial host-row coverage (the stray meter of the first attempt), summing host rows undercounted the window (`host_kwh 0.004` against `measured 0.020`). Rule changed to `host = scope + seconds × overhead` in both cases (identical to the host rows' sum under full coverage); plan 17's status SQL mirrored. `host_kwh_is` now says whether the overhead was measured.
3. `cost` printed to four decimals: a 30-minute window is a fraction of a cent and rounded to `0.00`.
4. `kill %1` / `kill $MPID` on a backgrounded `make power-meter` stops make and leaves both python processes running (seen: two meter pairs alive). The gate uses `setsid` + `kill -- -PGID`; Ctrl-C (foreground group) and the systemd unit (cgroup) stop everything, as documented.
5. `make cost-report | head` makes make print `Error 255` (SIGPIPE when head closes the pipe); the gate writes to a file first.
6. G36 "every call has a row" refined to calls that overlap metered seconds.
7. The meter is not enabled as a service here (operator opt-in, README); `stack_energy` keeps the rows of this run.

**Clean rerun (same evening, one meter, §7 as one script).** G35: `T0 22:55:06 E0 2767243552`, `T1 23:05:12 E1 2799592620`, delta 32 349 J; 603 rows per domain in 603 s (the script clocks T0 three seconds before the first row), `nvml:0` 32 193 J (0.48 %, under the 0.5 % bound; the seed second is the difference), PSU `exact = f`, overhead avg 89 W (51–184); stdin form `gpu2|5`, deleted. G36 measured, `SINCE="3 minutes"` so the window lies inside the metered span: `measured 0.008 | host 0.013 measured | cost 0.0024 | calls 0.006 | idle 0.002 | avg_w 174 | 170 s`, overhead 101.6 W, `ornith-max` 41 calls `wh_per_1k_tok 0.012`, **0 calls without a `stack_call_energy` row**. Estimated form: `0.008 | 0.013 estimated | 0.0023 | 169 s`, `make cost-report` exit 0 (report to a file, `head` on the file). `.env` left as `POWER_PROBES=nvml,hwmon:corsairpsu`, `POWER_HOST_OVERHEAD=` blank (PSU measures the overhead); host rows of earlier windows deleted by the estimated-form step.
