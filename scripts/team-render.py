#!/usr/bin/env python3
"""Render a team (plan 16): teams/<team>/team.toml -> teams/<team>/compose.yml, plus the .env lines every member needs.
Deterministic and idempotent: the same team.toml always renders the same file; rendering twice changes nothing.
Secrets are minted only when blank and never overwritten. Standard library only (tomllib, Python 3.11+).
Usage: make team-render [T=<team>]      scripts/team-render.py [--team T] [--check] [--no-mint]
  --check    exit 1 if teams/<team>/compose.yml or .env would change (nothing written)
  --no-mint  do not mint missing keypairs (CI, dry runs)"""
import os, re, subprocess, sys, tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
ROLES = {   # role -> (Gitea team, session policy, forge account); the closed list of plan 10 (docs/spec.md §5.11)
    "builder":     ("builders",     "thread",  True),
    "reviewer":    ("reviewers",    "thread",  True),
    "coordinator": ("coordinators", "channel", True),
    "assistant":   (None,           "channel", False),
}
ROLE_WORD = {"builder": "builder", "reviewer": "reviewer", "coordinator": "coordinator and judge: scores every PR after CI and the review", "assistant": "assistant"}
IMAGES = {"buzz-agent": "ghcr.io/block/buzz-sprig:sha-e17cdd9", "goose": "open-llm-stack/goose-agent:1.50.0"}   # spec §1
BUZZ_IMAGE = "ghcr.io/block/buzz:sha-e17cdd9"   # its buzz-admin mints keypairs (same as scripts/init.sh)

args = sys.argv[1:]
check = "--check" in args; mint = "--no-mint" not in args
team = args[args.index("--team") + 1] if "--team" in args else None

def read_env():
    return open(".env").read() if os.path.exists(".env") else ""
env_text = read_env()
def env_get(k):
    m = re.search(rf"(?m)^{re.escape(k)}=(.*)$", env_text); return m.group(1).split("#", 1)[0].strip() if m else None
team = team or env_get("TEAM_NAME") or "piedpiper"
path = f"teams/{team}/team.toml"
if not os.path.exists(path): sys.exit(f"no {path}: make team-new T={team} FROM=<preset>")
t = tomllib.load(open(path, "rb"))

# --- validate ---------------------------------------------------------------------------------------------------
errs = []
if t.get("name") != team: errs.append(f"name = {t.get('name')!r} must equal the directory name {team!r}")
for k in ("org", "model"):
    if not t.get(k): errs.append(f"{k} is required")
members = t.get("members") or []
if not members: errs.append("at least one [[members]] entry")
seen = set()
for m in members:
    n = m.get("name", "")
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,30}", n): errs.append(f"member name {n!r}: lowercase letters, digits, dashes, 2-31 characters")
    if n in seen: errs.append(f"member {n!r} listed twice")
    seen.add(n)
    if m.get("role") not in ROLES: errs.append(f"member {n}: role {m.get('role')!r} not in {sorted(ROLES)}")
    if m.get("runtime", "buzz-agent") not in IMAGES: errs.append(f"member {n}: runtime {m.get('runtime')!r} not in {sorted(IMAGES)}")
    persona = f"teams/{team}/personas/{m.get('persona', n + '.md')}"
    if not os.path.exists(persona): errs.append(f"member {n}: persona file {persona} missing")
if errs: sys.exit("team.toml invalid:\n  " + "\n  ".join(errs))

# --- .env lines: keys minted when blank, the rest ensured present (bootstrap and litellm-keys fill them) ------------
def gen_key():
    out = subprocess.run(["docker", "run", "--rm", "--entrypoint", "/usr/local/bin/buzz-admin", BUZZ_IMAGE, "generate-key"], text=True, capture_output=True, check=True).stdout
    sec = re.search(r"Secret key:\s*(\S+)", out).group(1); pub = re.search(r"Public key:\s*(\S+)", out).group(1); return sec, pub
new_env = env_text; changes = []
def ensure(k, v=None, force=False):
    """Ensure `k=` exists; set it when blank and v is given, or always when force."""
    global new_env
    cur = re.search(rf"(?m)^{re.escape(k)}=(.*)$", new_env)
    if cur is None:
        new_env += ("" if new_env.endswith("\n") or not new_env else "\n") + f"{k}={v or ''}\n"; changes.append(f"added {k}")
    elif v is not None and (force or not cur.group(1).split('#', 1)[0].strip()):
        if cur.group(1).split("#", 1)[0].strip() != v:
            new_env = re.sub(rf"(?m)^{re.escape(k)}=.*$", f"{k}={v}", new_env); changes.append(f"set {k}")
ensure("TEAM_NAME", team, force=True)
ensure("TEAM_MODEL", t["model"], force=True)   # derived from team.toml: scripts that only read .env keep working
ensure("TEAM_GITEA_ORG", t["org"], force=True)
if t.get("ci_label"): ensure("TEAM_CI_LABEL", t["ci_label"], force=True)   # optional: the runner label is a forge property; unset = .env keeps its own
else: ensure("TEAM_CI_LABEL", "python")
for m in members:
    M = m["name"].upper().replace("-", "_")
    if not env_get(f"TEAM_{M}_PRIVATE_KEY") and mint and not check:
        sec, pub = gen_key(); ensure(f"TEAM_{M}_PRIVATE_KEY", sec); ensure(f"TEAM_{M}_PUBKEY", pub)
    else:
        ensure(f"TEAM_{M}_PRIVATE_KEY"); ensure(f"TEAM_{M}_PUBKEY")
    if ROLES[m["role"]][2]: ensure(f"TEAM_{M}_GITEA_TOKEN")
    ensure(f"TEAM_{M}_LITELLM_KEY")

# --- compose ------------------------------------------------------------------------------------------------------
def display(m): return m.get("display") or m["name"].capitalize()
suffix = env_get("AGENT_LOGIN_SUFFIX") or ""
pubkeys = ",".join(f"${{TEAM_{m['name'].upper().replace('-', '_')}_PUBKEY:-}}" for m in members)
allow = "${TEAM_ALLOWLIST:-},${TEAM_SMOKE_PUBKEY:-}," + pubkeys
roster = ";".join(f"{m['name']}={m['role']}={display(m)}={m.get('title', ROLE_WORD[m['role']])}=${{TEAM_{m['name'].upper().replace('-', '_')}_PUBKEY:-}}" for m in members)
out = [f"# GENERATED by scripts/team-render.py from teams/{team}/team.toml. Do not edit: edit team.toml, then `make team-render`.",
       f"# One service per member, extending teams/_base.yml (the shared shape). Included by docker-compose.yml through TEAM_NAME.",
       "services:"]
for m in members:
    n = m["name"]; M = n.upper().replace("-", "_"); role = m["role"]; gteam, policy, forge = ROLES[role]
    runtime = m.get("runtime", "buzz-agent")
    out += [f"  {n}:",
            "    extends: { file: teams/_base.yml, service: agent-base }",
            "    profiles: [team]",
            f"    image: {IMAGES[runtime]}",
            "    volumes:",
            f"      - team-{n}:/home/agent",
            "    environment:",
            f"      TEAM_MEMBER: {n}",
            f"      TEAM_ROLE: {role}",
            f"      TEAM_RUNTIME: {runtime}",
            f"      BUZZ_ACP_DISPLAY_NAME: {display(m)}",
            f"      BUZZ_PRIVATE_KEY: ${{TEAM_{M}_PRIVATE_KEY:?run make team-render}}",
            f"      BUZZ_ACP_SESSION_POLICY: {policy}",
            f"      BUZZ_ACP_RESPOND_TO_ALLOWLIST: {allow}",
            f"      TEAM_ROSTER: \"{roster}\"",
            f"      OPENAI_COMPAT_MODEL: {m.get('model', t['model'])}",
            f"      OPENAI_COMPAT_API_KEY: ${{TEAM_{M}_LITELLM_KEY:-${{LITELLM_MASTER_KEY}}}}",
            *([f"      TEAM_PERSONA: {m['persona']}"] if m.get('persona') else [])]
    if forge:
        out += [f"      GITEA_USER: {n}{suffix}", f"      GITEA_TOKEN: ${{TEAM_{M}_GITEA_TOKEN:-}}"]
    if role == "coordinator":
        out += [f"      BUZZ_ACP_HEARTBEAT_INTERVAL: \"{int(m.get('heartbeat', 0))}\"",
                "      BUZZ_ACP_HEARTBEAT_PROMPT_FILE: /opt/team/agents/roles/coordinator-heartbeat.md"]
out += ["volumes:"] + [f"  team-{m['name']}:" for m in members]
compose = "\n".join(out) + "\n"
target = f"teams/{team}/compose.yml"
old = open(target).read() if os.path.exists(target) else None
if check:
    diff = (old != compose) or (new_env != env_text)
    print(f"{target}: {'differs' if old != compose else 'up to date'}; .env: {'would change' if new_env != env_text else 'up to date'}")
    sys.exit(1 if diff else 0)
if old != compose:
    open(target, "w").write(compose); print(f"rendered {target} ({len(members)} members)")
else: print(f"{target} unchanged")
if new_env != env_text:
    open(".env", "w").write(new_env); print(".env: " + ", ".join(changes))
else: print(".env unchanged")
