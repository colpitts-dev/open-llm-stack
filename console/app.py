#!/usr/bin/env python3
"""open-llm-stack console (plan 17): a host-side window onto the stack's files and scripts.
Standard library only. Files and scripts are the truth: every screen reads them, every action runs a make target or a
script, shows the exact command, streams its output and appends to console/audit.log. Read-only until you act; writes
show a diff first; destructive actions need their name typed back. Binds BIND_HOST:CONSOLE_PORT (127.0.0.1:3004)."""
import difflib, hmac, html, http.server, json, os, re, secrets, shlex, socket, subprocess, sys, threading, time, tomllib, urllib.request
from collections import deque
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
STATIC = os.path.join(ROOT, "console", "static")
AUDIT = os.path.join(ROOT, "console", "audit.log")
SECRET_RE = re.compile(r"KEY|TOKEN|SECRET|PASSWORD|PRIVATE", re.I)

# ---------------------------------------------------------------- configuration and helpers
def read_env():
    env = {}
    if os.path.exists(".env"):
        for line in open(".env"):
            s = line.strip()
            if s and not s.startswith("#") and "=" in s:
                k, v = s.split("=", 1); env[k] = v.split(" #", 1)[0].strip()
    return env

def mask(k, v):
    return v if not v or not SECRET_RE.search(k) else "••••" + v[-4:]

def sh(argv, timeout=60):
    """run a command, return (rc, text). Used for reads; actions go through the runner so they stream and are audited."""
    try:
        p = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except Exception as ex:  # noqa: BLE001
        return 1, str(ex)

def esc(s): return html.escape(str(s if s is not None else ""), quote=True)

def strip_ansi(s): return re.sub(r"\x1b\[[0-9;]*m", "", s)

_cache = {}
def cached(key, ttl, fn):
    now = time.time(); hit = _cache.get(key)
    if hit and now - hit[0] < ttl: return hit[1]
    val = fn(); _cache[key] = (now, val); return val

def stack_status():
    def load():
        rc, out = sh(["make", "-s", "stack-status"], timeout=20)
        try: return json.loads(out[out.index("{"):])
        except Exception: return {"error": out.strip()[-400:]}
    return cached("status", 10, load)

def gateway_json(path, env):
    try:
        req = urllib.request.Request(f"{env.get('LITELLM_PUBLIC_URL', 'http://127.0.0.1:3000')}{path}",
                                     headers={"Authorization": f"Bearer {env.get('LITELLM_MASTER_KEY', '')}"})
        return json.loads(urllib.request.urlopen(req, timeout=3).read())
    except Exception: return None

def gitea_json(path, env, token_var="TEAM_JARED_GITEA_TOKEN"):
    base = env.get("GITEA_PUBLIC_URL", "http://127.0.0.1:3003").rstrip("/") + "/api/v1"
    try:
        req = urllib.request.Request(base + path, headers={"Authorization": f"token {env.get(token_var, '')}"})
        return json.loads(urllib.request.urlopen(req, timeout=5).read())
    except Exception: return None

def backend_is_ollama(env):
    url = env.get("LLM_BASE_URL", "").replace("host.docker.internal", "127.0.0.1")
    def probe():
        try: return urllib.request.urlopen(url + "/api/tags", timeout=2).status == 200
        except Exception: return False
    return cached("ollama", 60, probe) if url.startswith("http://127.0.0.1") else False

def team_file():
    for t in sorted(os.listdir("teams")) if os.path.isdir("teams") else []:
        p = os.path.join("teams", t, "team.toml")
        if not t.startswith("_") and os.path.exists(p):
            with open(p, "rb") as f: return t, tomllib.load(f), p
    return None, {}, None

# ---------------------------------------------------------------- actions: an allowlist of named commands, never a shell string built from input
NAME = re.compile(r"^[a-z][a-z0-9._-]{0,63}$")
ROLE = re.compile(r"^(builder|reviewer|coordinator|assistant)$")
SERVICE = re.compile(r"^[a-z][a-z0-9-]{0,40}$")
UUID = re.compile(r"^[0-9a-f-]{36}$"); HEX64 = re.compile(r"^[0-9a-f]{64}$")   # a Buzz channel id and an event id (plan 16.5 approve-job)
HINT = {NAME: "lowercase letters/digits/._- , must start with a letter", ROLE: "one of builder, reviewer, coordinator, assistant",
        SERVICE: "lowercase letters/digits/- , must start with a letter", UUID: "a UUID, e.g. from the post-job output", HEX64: "64 hex chars, the thread root event id"}
def p(params, key, rx=NAME, label=None):
    v = params.get(key, "")
    if not rx.match(v): raise ValueError(f"bad {label or key}: {v!r} — {HINT.get(rx, 'does not match the expected format')}")
    return v

ACTIONS = {   # name -> (argv builder, destructive?)
    "init": (lambda q: ["make", "init"], False),
    "up": (lambda q: ["make", "up"], False),
    "down": (lambda q: ["make", "down"], True),
    "test": (lambda q: ["make", "test"], False),
    "reload": (lambda q: ["make", "reload"], False),
    "gitea-bootstrap": (lambda q: ["make", "gitea-bootstrap"], False),
    "team-bootstrap": (lambda q: ["make", "team-bootstrap"], False),
    "check-ports": (lambda q: ["./scripts/check-ports.sh"], False),
    "preflight": (lambda q: ["./scripts/preflight.sh"], False),
    "stack-status": (lambda q: ["make", "-s", "stack-status"], False),
    "context-report": (lambda q: ["make", "-s", "context-report"], False),   # -s: make's own recipe echo would break G51's byte-for-byte diff
    "context-probe": (lambda q: ["make", "context-probe"] + ([f"M={p(q, 'M')}"] if q.get("M") else []), False),
    "model-fit": (lambda q: ["make", "model-fit", f"M={p(q, 'M')}"], False),
    "cost-report": (lambda q: ["make", "cost-report"], False),
    "team-model": (lambda q: ["make", "team-model", f"M={p(q, 'M')}"], False),
    "team-status": (lambda q: ["make", "team-status"], False),
    "team-smoke": (lambda q: ["make", "team-smoke"], False),
    "member-add": (lambda q: ["make", "member-add", f"T={p(q, 'T', label='team')}", f"N={p(q, 'N', label='name')}", f"R={p(q, 'R', ROLE, label='role')}"], False),
    "member-rm": (lambda q: ["make", "member-rm", f"T={p(q, 'T', label='team')}", f"N={p(q, 'N', label='name')}"], True),
    "score-sync": (lambda q: ["make", "score-sync"], False),
    "score-report": (lambda q: ["make", "score-report"], False),
    "restart": (lambda q: ["docker", "compose", "restart", p(q, "S", SERVICE)], False),
    "recreate": (lambda q: ["docker", "compose", "up", "-d", "--force-recreate", p(q, "S", SERVICE, label="service")], False),
    "unload-model": (lambda q: ["bash", "-c", "curl -s localhost:11434/api/generate -d '{\"model\":\"" + p(q, "M") + "\",\"keep_alive\":0}'"], True),
    "post-job": (lambda q: ["./console/post-job.sh", p(q, "T", label="team"), q.get("text", "")[:2000]], False),
    "approve-job": (lambda q: ["./console/approve-job.sh", p(q, "C", UUID, label="channel id"), p(q, "R", HEX64, label="thread root id"), q.get("note", "")[:200]], False),   # plan 16.5 checkpoint: the human says `approved`
}

# ---------------------------------------------------------------- runner: one job at a time, streamed, audited
class Job:
    def __init__(self, name, argv, actor):
        self.id = secrets.token_hex(6); self.name = name; self.argv = argv; self.actor = actor
        self.lines = deque(); self.done = threading.Event(); self.rc = None; self.started = None; self.ended = None
        self.cond = threading.Condition()
    def cmd(self): return " ".join(shlex.quote(a) for a in self.argv)

class Runner:
    def __init__(self):
        self.queue = deque(); self.jobs = {}; self.current = None; self.lock = threading.Lock()
        threading.Thread(target=self.loop, daemon=True).start()
    def submit(self, job):
        with self.lock: self.jobs[job.id] = job; self.queue.append(job)
        return job
    def loop(self):
        while True:
            with self.lock: job = self.queue.popleft() if self.queue else None
            if job is None: time.sleep(0.2); continue
            self.current = job; job.started = time.time()
            try:
                proc = subprocess.Popen(job.argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
                for line in proc.stdout:
                    with job.cond: job.lines.append(strip_ansi(line.rstrip("\n"))); job.cond.notify_all()
                job.rc = proc.wait()
            except OSError as ex:   # a missing script or binary must end the job, never the worker
                with job.cond: job.lines.append(f"cannot run: {ex}"); job.cond.notify_all()
                job.rc = 127
            job.ended = time.time(); self.current = None
            with open(AUDIT, "a") as f:
                f.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(job.started)), "actor": job.actor, "action": job.name,
                                    "cmd": job.cmd(), "exit": job.rc, "seconds": round(job.ended - job.started, 1), "job": job.id}) + "\n")
            with job.cond: job.done.set(); job.cond.notify_all()
RUNNER = Runner()

# ---------------------------------------------------------------- writes: read, diff, confirm, replace atomically
EDITABLE = {"env": ".env", "registry": "proxy/config.yaml"}
def editable_path(kind, name=None):
    if kind in EDITABLE: return EDITABLE[kind]
    team, _, path = team_file()
    if kind == "team" and path: return path
    if kind == "persona" and team and name and NAME.match(name): return os.path.join("teams", team, "personas", f"{name}.md")
    raise ValueError("not editable")

def mask_env_text(text):
    """secrets never render, not even as diff context: KEY=value lines with a secret-looking key are masked for display."""
    return "".join((f"{m.group(1)}={mask(m.group(1), m.group(2))}\n" if (m := re.match(r"^([A-Z0-9_]+)=(.*)$", line.rstrip("\n"))) else line) for line in text.splitlines(True))

def diff_for(path, new):
    old = open(path).read() if os.path.exists(path) else ""
    if path == ".env": old, new = mask_env_text(old), mask_env_text(new)   # display only; apply uses the real content behind the signature
    return "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True), f"a/{path}", f"b/{path}"))

def env_merge(form):
    """the .env editor posts only the keys it changed; masked values never come back, so unchanged secrets are untouched."""
    lines = open(".env").read().splitlines(True) if os.path.exists(".env") else []
    seen = set()
    for i, line in enumerate(lines):
        m = re.match(r"^([A-Z0-9_]+)=(.*)$", line)
        if m and m.group(1) in form:
            seen.add(m.group(1)); lines[i] = f"{m.group(1)}={form[m.group(1)]}\n"
    for k, v in form.items():
        if k not in seen and re.match(r"^[A-Z0-9_]+$", k): lines.append(f"{k}={v}\n")
    return "".join(lines)

def write_atomic(path, content):
    tmp = path + ".console.tmp"
    with open(tmp, "w") as f: f.write(content)
    os.replace(tmp, path)

# ---------------------------------------------------------------- security: Host allowlist, per-process token, Origin / Sec-Fetch-Site, auth hook
TOKEN = secrets.token_urlsafe(24)
def actor_of(handler):
    """authentication hook. Today: loopback = the operator. A later plan replaces this with Gitea OIDC behind TLS."""
    return "operator"

def host_ok(handler, allowed):
    return handler.headers.get("Host", "").lower() in allowed

def mutation_ok(handler, allowed_origins):
    if handler.headers.get("X-Console-Token", "") != TOKEN: return False
    origin = handler.headers.get("Origin"); site = handler.headers.get("Sec-Fetch-Site", "")
    if origin and origin.lower() not in allowed_origins: return False
    if site and site not in ("same-origin", "none"): return False
    return True

# ---------------------------------------------------------------- html
NAV = [("overview", "Overview"), ("jobs", "Jobs"), ("teams", "Teams"), ("models", "Models"), ("runs", "Runs & logs"), ("setup", "Setup"), ("audit", "Audit")]
def page(active, title, body, env, last):
    nav = "".join(f'<a href="/{k}"{" aria-current=page" if k == active else ""}>{esc(v)}</a>' + ('<div class="sep"></div>' if k == "runs" else "") for k, v in NAV)
    lastrow = (f'<span>Last action</span><span class="cmd">$ {esc(last["cmd"])}</span><span class="{"exit" if last["exit"] == 0 else "fail"}">exit {last["exit"]} · {last["seconds"]} s</span>'
               if last else '<span>No action yet. Everything on screen is read-only until you act.</span>')
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)} · Stack Console</title><meta name="console-token" content="{TOKEN}"><link rel="stylesheet" href="/static/console.css"></head><body>
<header><div><h1>Stack Console</h1><div class="host">open-llm-stack · {esc(socket.gethostname())} · BIND_HOST {esc(env.get("BIND_HOST", "127.0.0.1"))} · backend {esc(env.get("LLM_BASE_URL", "?"))}</div></div>
<div class="mono host">console/app.py · read-only until you act</div></header>
<div class="shell"><nav aria-label="Console sections">{nav}</nav><main>{body}</main></div>
<div class="drawer"><div class="row" id="drawer">{lastrow}</div><pre id="stream" hidden></pre></div>
<script src="/static/console.js"></script></body></html>"""

def pill(text, kind="neutral"): return f'<span class="pill {kind}">{esc(text)}</span>'
def dot(kind): return f'<span class="dot {kind}"></span>'
def btn(action, label, params=None, kind="", destructive=False):
    q = esc(json.dumps(params or {}))
    return f'<button class="btn {kind}" data-action="{esc(action)}" data-params=\'{q}\'{" data-destructive=1" if destructive else ""}>{esc(label)}</button>'
def table(headers, rows, numeric=()):
    th = "".join(f'<th class="{"n" if i in numeric else ""}">{esc(h)}</th>' for i, h in enumerate(headers))
    tr = "".join("<tr>" + "".join(f'<td class="{"n" if i in numeric else ""}">{c}</td>' for i, c in enumerate(r)) + "</tr>" for r in rows)
    return f'<div class="tablewrap"><table><thead><tr>{th}</tr></thead><tbody>{tr or "<tr><td colspan=99 class=note>nothing yet</td></tr>"}</tbody></table></div>'
def panel(title, inner, right=""): return f'<div class="panel"><h3>{esc(title)}<span class="right">{right}</span></h3>{inner}</div>'
def last_action():
    try:
        with open(AUDIT) as f: lines = f.read().splitlines()
        return json.loads(lines[-1]) if lines else None
    except Exception: return None

# ---------------------------------------------------------------- screens
def screen_overview(env):
    st = stack_status(); team, tf, _ = team_file()
    if "error" in st: return f'<h2>Overview</h2><p class="sub">stack-status failed:</p><pre>{esc(st["error"])}</pre>'
    svc = st.get("services", []); up = sum(1 for s in svc if s.get("state") == "running"); en = st.get("energy_24h") or {}; scope = en.get("scope", "gpu"); pw = st.get("power") or []; attributed = [p for p in pw if p.get("scope") == scope]; hostp = [p for p in pw if p.get("scope") == "host"]; l24 = st.get("last_24h") or {}
    tiles = f"""<div class="tiles">
<div class="tile"><div class="l">Stack</div><div class="v">{dot("good" if up == len(svc) else "warn")}{up} / {len(svc)} up</div><div class="d">{esc(", ".join(s["service"] for s in svc if s.get("state") != "running") or "all services running")}</div></div>
<div class="tile energy"><div class="l">Energy · 24 h</div><div class="v">{esc(en.get("measured_kwh", "—"))}<small>kWh</small></div><div class="d">{("measured at " + str(en.get("scope")) + " · whole machine " + str(en.get("host_kwh")) + " kWh (" + str(en.get("host_kwh_is")) + ") · $" + str(en.get("cost")) + " at " + str(en.get("tariff_cents")) + " cents/kWh") if en else "no tariff in .env: energy accounting off"}</div></div>
<div class="tile"><div class="l">Power now</div><div class="v">{esc(round(sum(p.get("watts") or 0 for p in attributed)) if attributed else "—")} W</div><div class="d">{esc(", ".join(p["domain"] + (" · " + str(p["mem_mib"]) + " MiB" if p.get("mem_mib") is not None else "") for p in attributed) or "meter not running")}{(" · host " + str(round(sum(p.get("watts") or 0 for p in hostp))) + " W") if hostp else ""}</div></div>
<div class="tile"><div class="l">Last 24 h</div><div class="v">{esc(l24.get("calls", 0))} calls</div><div class="d">{esc(l24.get("prompt_tokens", 0))} prompt · {esc(l24.get("completion_tokens", 0))} completion · ${esc(l24.get("litellm_spend", 0))} at the gateway's rates</div></div>
<div class="tile"><div class="l">Open PRs by agents</div><div class="v">{len(st.get("open_prs", []))}</div><div class="d">{esc(", ".join("#" + str(x["number"]) for x in st.get("open_prs", [])[:6]))}</div></div></div>"""
    alerts = "".join(f'<li>{pill("cap", "warn")}<span><b>{esc(a["model"])}</b>: {a["over_in"]} prompts over max_input_tokens, {a["at_out"]} completions at max_output_tokens (7 d)</span></li>' for a in st.get("alerts", []))
    alerts = f'<ul class="list">{alerts or "<li><span class=note>nothing needs attention</span></li>"}</ul>'
    members = [(esc(m["name"].title()), esc(m["role"]), f'<span class="mono">{esc(m.get("runtime", "buzz-agent"))}</span>',
                dot("good" if any(s["service"] == m["name"] and s.get("state") == "running" for s in svc) else "crit") + ("up" if any(s["service"] == m["name"] and s.get("state") == "running" for s in svc) else "down"))
               for m in tf.get("members", [])]
    prs = [(f'<span class="mono">{x["number"]}</span>', f'<a href="{esc(x["url"])}">{esc(x["title"])}</a>', esc(x["by"]),
            " ".join(pill(l.split("/", 1)[1], "good" if l.endswith("high") else "neutral") for l in x.get("labels", []) if l.startswith(("complexity/", "confidence/"))), esc(x["opened"][:16]))
           for x in st.get("open_prs", [])]
    return (f'<h2>Overview</h2><p class="sub">Is it healthy, what is it doing, what does it cost. Generated {esc(st.get("generated", ""))}.</p>{tiles}'
            f'<div class="grid2">{panel("Needs attention", alerts, btn("context-report", "make context-report"))}'
            f'{panel(f"Team {team or "(none)"}", table(["Agent", "Role", "Runtime", "State"], members), pill(tf.get("model", ""), "neutral"))}</div>'
            f'{panel("Open pull requests by agents", table(["#", "Title", "By", "Score", "Opened"], prs), btn("score-sync", "make score-sync"))}')

def screen_models(env):
    info = gateway_json("/v1/model/info", env) or {"data": []}; ollama = backend_is_ollama(env)
    rows = []
    for m in info["data"]:
        mi = m.get("model_info", {}); lp = m.get("litellm_params", {})
        rows.append((f'<span class="mono">{esc(m["model_name"])}</span>', f'<span class="mono">{esc(lp.get("model", "").split("/")[0])}</span>', esc(mi.get("context_window", "—")),
                     esc(mi.get("max_input_tokens", "—")), esc(mi.get("max_output_tokens", "—")),
                     btn("context-probe", "probe", {"M": m["model_name"]}) + (btn("model-fit", "fit", {"M": lp.get("model", "").split("/", 1)[-1]}) if ollama and lp.get("model", "").startswith("ollama_chat/") else "")
                     + btn("team-model", "use for team", {"M": m["model_name"]})))
    rc, rep = sh(["make", "-s", "context-report"], timeout=30)
    return (f'<h2>Models</h2><p class="sub">The registry is the contract; declared windows are proved through the gateway.</p>'
            f'{panel("Registry · proxy/config.yaml", table(["Model", "Backend", "Window", "Input cap", "Output cap", ""], rows, numeric=(2, 3, 4)), btn("context-probe", "make context-probe") + btn("reload", "make reload"))}'
            f'<div class="grid2">{panel("Backend", f"<dl class=kv><dt>Endpoint</dt><dd class=mono>{esc(env.get("LLM_BASE_URL", ""))}</dd><dt>Type</dt><dd>{"Ollama (answers /api/tags)" if ollama else "OpenAI-compatible"}</dd></dl>")}'
            f'{panel("Real use vs caps (7 d)", f"<pre>{esc(rep.strip())}</pre>", btn("context-report", "refresh"))}</div>'
            f'{panel("Edit the registry", editor("registry", "proxy/config.yaml"))}')

def editor(kind, path, name=None):
    content = open(path).read() if os.path.exists(path) else ""
    return (f'<form class="mock" data-write="{esc(kind)}" data-name="{esc(name or "")}"><textarea id="ed-{esc(kind)}-{esc(name or "x")}" name="content" rows="14" class="mono">{esc(content)}</textarea>'
            f'<div><button class="btn" type="submit">Show diff</button> <span class="example">nothing is written until you confirm the diff</span></div></form>')

def screen_setup(env):
    st = stack_status(); have_env = os.path.exists(".env"); svc = st.get("services", []) if isinstance(st, dict) else []
    steps = [("Prerequisites: Docker, Compose, ports 3000–3003 free", "check-ports", bool(svc)),
             ("Backend reachable from inside the gateway", "preflight", bool(svc)),
             ("Configuration: layers, bind host, backend, forge", None, have_env),
             ("Secrets minted, registry copied", "init", have_env and bool(env.get("LITELLM_MASTER_KEY"))),
             ("Stack up and healthy", "up", bool(svc) and all(s.get("health") in ("healthy", "") for s in svc)),
             ("Forge admin and token", "gitea-bootstrap", bool(env.get("GITEA_ADMIN_TOKEN"))),
             ("Team accounts, tokens, fixture repository", "team-bootstrap", bool(env.get("TEAM_DINESH_GITEA_TOKEN"))),
             ("Every gate green", "test", False)]
    first_open = next((i for i, s in enumerate(steps) if not s[2]), len(steps))
    items = "".join(f'<li><span class="n {"done" if done else ("now" if i == first_open else "")}">{i + 1}</span><span>{esc(label)}</span>'
                    f'<span>{btn(action, "make " + action if action not in ("check-ports", "preflight") else action, kind="primary" if i == first_open else "") if action else ""}</span></li>'
                    for i, (label, action, done) in enumerate(steps))
    keys = ["COMPOSE_PROFILES", "BIND_HOST", "LLM_BASE_URL", "LLM_API_KEY", "LITELLM_PUBLIC_URL", "GITEA_PUBLIC_URL", "GITEA_ADMIN_USER", "TEAM_GITEA_ORG", "TEAM_MODEL", "POWER_COST_PER_KWH", "POWER_PROBES", "POWER_SCOPE", "POWER_HOST_OVERHEAD"]
    fields = "".join(f'<label>{esc(k)}<input id="env-{esc(k)}" name="{esc(k)}" value="{esc(mask(k, env.get(k, "")))}" data-masked="{1 if SECRET_RE.search(k) else 0}"></label>' for k in keys)
    form = f'<form class="mock" data-write="env"><input type="hidden" name="content" value="">{fields}<div><button class="btn primary" type="submit">Show diff of .env</button> <span class="example">masked values are never sent back; leave them as they are</span></div></form>'
    return f'<h2>Setup</h2><p class="sub">Get it running on this machine. Each step shows the command it runs.</p>{panel("Steps", f"<ol class=steps>{items}</ol>")}{panel("Configuration", form)}'

def screen_teams(env):
    team, tf, path = team_file()
    if not team: return '<h2>Teams</h2><p class="sub">No teams/<team>/team.toml yet (plan 16). Run make team-new from the terminal.</p>'
    rc, status = sh(["make", "-s", "team-status", f"T={team}"], timeout=30)
    members = [(esc(m["name"].title()), esc(m["role"]), f'<span class="mono">{esc(m["name"])}</span>', f'<span class="mono">{esc(m.get("runtime", "buzz-agent"))}</span>',
                btn("recreate", "restart", {"S": m["name"]}) + f' <a class="btn" href="/teams?persona={esc(m["name"])}">persona</a> ' + btn("member-rm", "remove", {"T": team, "N": m["name"]}, destructive=True))
               for m in tf.get("members", [])]
    add = (f'<form class="mock" data-run="member-add"><input type="hidden" name="T" value="{esc(team)}"><label>Name <input id="m-name" name="N" value="" placeholder="e.g. bertram" pattern="[a-z][a-z0-9._-]{{0,63}}" title="lowercase letters/digits/._- , must start with a letter"></label>'
           f'<label>Role <select id="m-role" name="R"><option>builder</option><option>reviewer</option><option>coordinator</option><option>assistant</option></select></label>'
           f'<div><button class="btn primary" type="submit">Add member</button> <span class="example">runs make member-add T={esc(team)} N=&lt;name&gt; R=&lt;role&gt;: keys, render, forge user, container; then write the persona</span></div></form>')
    kv = f'<dl class="kv"><dt>Organisation</dt><dd class="mono">{esc(tf.get("org", ""))}</dd><dt>Model</dt><dd class="mono">{esc(tf.get("model", ""))}</dd><dt>CI label</dt><dd class="mono">{esc(tf.get("ci_label", ""))}</dd><dt>Humans</dt><dd class="mono">{esc(", ".join(h[:8] + "…" for h in tf.get("humans", [])))}</dd></dl>'
    return (f'<h2>Teams</h2><p class="sub">One team per deployment. Members are a few lines in <code>{esc(path)}</code> plus a persona.</p>'
            f'<div class="grid2">{panel(team, kv, btn("team-status", "make team-status"))}{panel("Add member", add)}</div>'
            f'{panel("Members", table(["Member", "Role", "Login", "Runtime", ""], members))}{panel("team-status", f"<pre>{esc(status.strip())}</pre>")}'
            f'{panel("team.toml", editor("team", path))}')

def screen_persona(env, name):
    team, tf, _ = team_file()
    if not team or not NAME.match(name): return "<h2>Persona</h2><p class=sub>unknown member</p>"
    path = editable_path("persona", name)
    return (f'<h2>Persona · {esc(name.title())}</h2><p class="sub">Applying writes <code>{esc(path)}</code> and force-recreates <code>{esc(name)}</code> only.</p>'
            f'{panel(path, editor("persona", path, name))}')

def screen_jobs(env):
    team, tf, _ = team_file(); org = tf.get("org") or env.get("TEAM_GITEA_ORG", "piedpiper")
    repos = gitea_json(f"/orgs/{org}/repos?limit=50", env) or []
    rows = []
    for r in repos:
        for pr in gitea_json(f"/repos/{org}/{r['name']}/pulls?state=all&limit=10", env) or []:
            labels = [l["name"] for l in pr.get("labels", [])]
            score = " ".join(pill(l.split("/", 1)[1], "good" if l.endswith("high") else ("warn" if l.endswith("medium") else ("crit" if l.endswith("low") else "neutral"))) for l in labels if l.startswith(("complexity/", "confidence/"))) or pill("not scored")
            out = next((l.split("/", 1)[1] for l in labels if l.startswith("outcome/")), "open" if pr["state"] == "open" else "unsynced")
            rows.append((f'<span class="mono">{r["name"]}#{pr["number"]}</span>', f'<a href="{esc(pr["html_url"])}">{esc(pr["title"])}</a>', esc(pr["user"]["login"]), score,
                         pill(out, "good" if out == "merged-as-is" else ("neutral" if out == "open" else "warn")), esc(pr["created_at"][:16])))
    rows.sort(key=lambda x: x[5], reverse=True)
    rc, rep = sh(["make", "-s", "score-report"], timeout=30)
    ask = (f'<form class="mock" data-run="post-job"><input type="hidden" name="T" value="{esc(team or "")}"><label>Ask <textarea id="job-text" name="text" rows="4"></textarea></label>'
           f'<div><button class="btn primary" type="submit">Post job thread</button> <span class="example">posts as the console identity into a new private job channel with the builder, the reviewer, the coordinator and the humans as members; the builder answers with a plan</span></div></form>'
           f'<form class="mock" data-run="approve-job"><label>Channel <input name="C" placeholder="job channel uuid (from the post-job output)"></label><label>Thread root <input name="R" placeholder="thread root event id"></label><label>Note <input name="note" placeholder="optional"></label>'
           f'<div><button class="btn" type="submit">Approve plan</button> <span class="example">replies `approved` as the console identity (plan 16.5); nothing is built before this</span></div></form>')
    return (f'<h2>Jobs</h2><p class="sub">Ask the team, then see what shipped and how good it was.</p><div class="grid2">{panel("New job and approval", ask)}{panel("Reliability", f"<pre>{esc(rep.strip())}</pre>", btn("score-report", "make score-report") + btn("score-sync", "make score-sync"))}</div>'
            f'{panel("Pull requests", table(["PR", "Title", "By", "Score", "Outcome", "Opened"], rows[:40]))}')

FILTER = re.compile(r"turn starting|turn complete|🚩|\*\*(PR|Review|Score|Question):\*\*|tool_call_update|^\s*\$ ")
def screen_runs(env):
    team, tf, _ = team_file(); names = [m["name"] for m in tf.get("members", [])] or ["dinesh", "gilfoyle", "jared", "erlich", "monica"]
    panels = ""
    for n in names:
        rc, log = sh(["docker", "compose", "logs", "--since", "2h", "--no-log-prefix", n], timeout=20)
        lines = [l for l in strip_ansi(log).splitlines() if FILTER.search(l)][-25:]
        panels += panel(f"{n} · last 2 h", f'<pre>{esc(chr(10).join(lines) or "quiet")}</pre>', btn("restart", "restart", {"S": n}))
    smokes = [(esc(a["ts"][:16]), pill("PASS" if a["exit"] == 0 else "FAIL", "good" if a["exit"] == 0 else "crit"), f'{a["seconds"]} s') for a in read_audit() if a.get("action") == "team-smoke"][-8:]
    return (f'<h2>Runs &amp; logs</h2><p class="sub">Why is an agent quiet. Milestones and deliverables filtered from the logs.</p>'
            f'{panel("Team smoke", table(["When", "Result", "Duration"], smokes), btn("team-smoke", "make team-smoke", kind="primary"))}{panels}')

def read_audit():
    try:
        with open(AUDIT) as f: return [json.loads(l) for l in f if l.strip()]
    except FileNotFoundError: return []

def screen_audit(env):
    rows = [(esc(a["ts"]), esc(a["actor"]), f'<span class="mono">{esc(a["cmd"])}</span>', pill(f'exit {a["exit"]}', "good" if a["exit"] == 0 else "crit"), f'{a["seconds"]} s') for a in reversed(read_audit()[-200:])]
    return f'<h2>Audit</h2><p class="sub">Every action the console ran, with its command and exit code. Append-only: <code>console/audit.log</code>.</p>{panel("Actions", table(["When (UTC)", "Actor", "Command", "Exit", "Took"], rows))}'

SCREENS = {"overview": ("Overview", screen_overview), "models": ("Models", screen_models), "setup": ("Setup", screen_setup),
           "teams": ("Teams", screen_teams), "jobs": ("Jobs", screen_jobs), "runs": ("Runs & logs", screen_runs), "audit": ("Audit", screen_audit)}

# ---------------------------------------------------------------- http
class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "StackConsole/1"
    def log_message(self, fmt, *args): pass
    def send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Frame-Options", "DENY"); self.send_header("Referrer-Policy", "no-referrer"); self.end_headers(); self.wfile.write(data)
    def chunk(self, data):
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n"); self.wfile.flush()
    def do_GET(self):
        if not host_ok(self, self.server.hosts): return self.send(400, "bad Host", "text/plain")
        env = read_env(); u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/": self.send_response(302); self.send_header("Location", "/overview"); self.end_headers(); return
        if u.path.startswith("/static/"):
            f = os.path.join(STATIC, os.path.basename(u.path))
            if not os.path.exists(f): return self.send(404, "not found", "text/plain")
            return self.send(200, open(f, "rb").read(), "text/css" if f.endswith(".css") else "application/javascript")
        if u.path.startswith("/api/jobs/") and u.path.endswith("/stream"):
            job = RUNNER.jobs.get(u.path.split("/")[3])
            if not job: return self.send(404, "no such job", "text/plain")
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            self.chunk(f"event: cmd\ndata: {json.dumps(job.cmd())}\n\n".encode()); i = 0
            while True:
                with job.cond:
                    while i >= len(job.lines) and not job.done.is_set(): job.cond.wait(1)
                    lines = list(job.lines)[i:]; i = len(job.lines); done = job.done.is_set()
                for l in lines: self.chunk(f"data: {json.dumps(l)}\n\n".encode())
                if done and i >= len(job.lines):
                    self.chunk(f"event: done\ndata: {json.dumps({'exit': job.rc, 'seconds': round(job.ended - job.started, 1)})}\n\n".encode()); break
            self.wfile.write(b"0\r\n\r\n"); return
        if u.path == "/api/status": return self.send(200, json.dumps(stack_status()), "application/json")
        if u.path == "/teams" and q.get("persona"): return self.send(200, page("teams", "Persona", screen_persona(env, q["persona"]), env, last_action()))
        key = u.path.strip("/")
        if key in SCREENS:
            title, fn = SCREENS[key]
            try: body = fn(env)
            except Exception as ex:  # noqa: BLE001
                body = f"<h2>{esc(title)}</h2><pre>{esc(repr(ex))}</pre>"
            return self.send(200, page(key, title, body, env, last_action()))
        self.send(404, "not found", "text/plain")
    def do_POST(self):
        if not host_ok(self, self.server.hosts): return self.send(400, "bad Host", "text/plain")
        if not mutation_ok(self, self.server.origins): return self.send(403, "missing or bad token / origin", "text/plain")
        actor = actor_of(self); n = int(self.headers.get("Content-Length", "0") or 0)
        try: body = json.loads(self.rfile.read(n) or b"{}")
        except Exception: return self.send(400, "bad json", "text/plain")
        u = urlparse(self.path)
        try:
            if u.path == "/api/run":
                name = body.get("action", ""); spec = ACTIONS.get(name)
                if not spec: return self.send(404, "unknown action", "text/plain")
                argv, destructive = spec[0](body.get("params", {})), spec[1]
                if destructive and body.get("confirm") != name: return self.send(409, f"type {name} to confirm", "text/plain")
                job = RUNNER.submit(Job(name, argv, actor)); return self.send(200, json.dumps({"job": job.id, "cmd": job.cmd(), "queued": len(RUNNER.queue)}), "application/json")
            if u.path == "/api/diff":
                path = editable_path(body.get("kind", ""), body.get("name")); new = env_merge(body.get("form", {})) if body.get("kind") == "env" else body.get("content", "")
                d = diff_for(path, new); sig = hmac.new(TOKEN.encode(), (path + new).encode(), "sha256").hexdigest()
                return self.send(200, json.dumps({"path": path, "diff": d, "sig": sig, "empty": not d, "content": new}), "application/json")
            if u.path == "/api/apply":
                path = editable_path(body.get("kind", ""), body.get("name")); new = body.get("content", "")
                if not hmac.compare_digest(body.get("sig", ""), hmac.new(TOKEN.encode(), (path + new).encode(), "sha256").hexdigest()): return self.send(409, "diff changed; show it again", "text/plain")
                write_atomic(path, new)
                with open(AUDIT, "a") as f: f.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "actor": actor, "action": "write", "cmd": f"write {path}", "exit": 0, "seconds": 0}) + "\n")
                follow = {"registry": "reload", "persona": "recreate", "team": None, "env": None}.get(body.get("kind"))
                job = RUNNER.submit(Job(follow, ACTIONS[follow][0]({"S": body.get("name", "")}), actor)) if follow else None
                return self.send(200, json.dumps({"written": path, "job": job.id if job else None, "cmd": job.cmd() if job else None}), "application/json")
        except ValueError as ex: return self.send(400, str(ex), "text/plain")
        self.send(404, "not found", "text/plain")

def main():
    env = read_env(); host = env.get("BIND_HOST", "127.0.0.1"); port = int(env.get("CONSOLE_PORT") or 3004)
    hosts = {f"{host}:{port}", f"127.0.0.1:{port}", f"localhost:{port}"}; origins = {f"http://{h}" for h in hosts}
    try: srv = http.server.ThreadingHTTPServer((host, port), Handler)
    except OSError as ex:
        rc, who = sh(["bash", "-c", f"ss -Htlnp | grep -E '[:.]{port} ' | head -1"]); print(f"cannot bind {host}:{port}: {ex}\n{who.strip()}"); sys.exit(1)
    srv.hosts, srv.origins = hosts, origins; srv.daemon_threads = True
    print(f"console on http://{host}:{port}  (token in the page; audit: console/audit.log)")
    try: srv.serve_forever()
    except KeyboardInterrupt: pass

if __name__ == "__main__": main()
