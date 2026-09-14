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
