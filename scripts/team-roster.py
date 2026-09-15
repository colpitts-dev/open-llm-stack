#!/usr/bin/env python3
"""Read teams/<team>/team.toml for shell scripts (plan 16). Standard library only.
  team-roster.py [--team T] members            -> one line per member: name role display login ENV_PREFIX
  team-roster.py [--team T] role <role>        -> names of the members with that role, first one first
  team-roster.py [--team T] get <key>          -> a top-level value (org, model, ci_label, name)
  team-roster.py [--team T] humans             -> comma-separated pubkeys from `humans`
  team-roster.py [--team T] add <name> <role> [title]   -> append a [[members]] block (exit 1 if present)
  team-roster.py [--team T] rm <name>          -> remove that member's block (exit 1 if absent)
  team-roster.py [--team T] set <name> <key> <value>    -> set one member key (runtime, model, title, persona, display)
The team is --team, else TEAM_NAME in .env, else piedpiper. Logins carry AGENT_LOGIN_SUFFIX from .env.
Edits rewrite only the member's block; the rest of team.toml (comments included) is left byte for byte."""
import os, re, sys, tomllib
os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
args = sys.argv[1:]
team = args[args.index("--team") + 1] if "--team" in args else None
if "--team" in args: i = args.index("--team"); del args[i:i + 2]
env = open(".env").read() if os.path.exists(".env") else ""
def env_get(k):
    m = re.search(rf"(?m)^{re.escape(k)}=(.*)$", env); return m.group(1).split("#", 1)[0].strip() if m else ""
team = team or env_get("TEAM_NAME") or "piedpiper"
t = tomllib.load(open(f"teams/{team}/team.toml", "rb"))
suffix = env_get("AGENT_LOGIN_SUFFIX")
cmd = args[0] if args else "members"
if cmd == "members":
    for m in t["members"]:
        print(m["name"], m["role"], m.get("display") or m["name"].capitalize(), m["name"] + suffix, "TEAM_" + m["name"].upper().replace("-", "_"))
elif cmd == "role":
    print("\n".join(m["name"] for m in t["members"] if m["role"] == args[1]))
elif cmd == "get":
    print(t.get(args[1], ""))
elif cmd == "humans":
    print(",".join(t.get("humans", [])))
elif cmd in ("add", "rm", "set"):
    p = f"teams/{team}/team.toml"; s = open(p).read(); n = args[1]
    blk = re.search(rf'(?ms)^\[\[members\]\]\nname = "{re.escape(n)}"\n(?:(?!^\[\[members\]\]).)*', s)
    if cmd == "add":
        if blk: sys.exit(f"{n} is already a member")
        role = args[2]; title = f'title = "{args[3]}"\n' if len(args) > 3 else ""
        s = s.rstrip("\n") + f'\n\n[[members]]\nname = "{n}"\nrole = "{role}"\n{title}'
    elif cmd == "rm":
        if not blk: sys.exit(f"{n} is not a member")
        s = s[:blk.start()].rstrip("\n") + "\n" + s[blk.end():].lstrip("\n")
    else:
        if not blk: sys.exit(f"{n} is not a member")
        key, val = args[2], args[3]; b = blk.group(0).rstrip("\n")
        b = re.sub(rf'(?m)^{key} = .*\n?', '', b + "\n").rstrip("\n") + f'\n{key} = "{val}"\n'
        s = s[:blk.start()] + b + s[blk.end():].lstrip("\n") if s[blk.end():] else s[:blk.start()] + b
    open(p, "w").write(s.rstrip("\n") + "\n"); print(f"{cmd} {n}: ok")
else:
    sys.exit(__doc__)
