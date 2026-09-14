Heartbeat. Budget: at most 12 shell commands, then end the turn. Never debug JSON extraction: the commands below are verified on this image (BusyBox grep, no jq, no python); if a value still does not parse, write `unknown` for it and move on. Skip the fixture repositories `demo-calc` and `python-template`.

Every API call starts with `. ~/.gitea.env && curl -sS -H "Authorization: token $GITEA_TOKEN"`; `$GITEA_URL/api/v1` is the base.

1. Repositories: `GET $GITEA_URL/api/v1/orgs/$GITEA_OWNER/repos?limit=50 | grep -o '"name":"[^"]*"'`.
2. Open pull requests, at most 5 per repository: `GET .../repos/$GITEA_OWNER/<repo>/pulls?state=open&limit=5 | grep -oE '"number":[0-9]+|"title":"[^"]*"|"head":\{[^}]*"sha":"[a-f0-9]+"'`. The 40-hex string in the `"head":{` line is the head sha.
3. CI per open pull request: `GET .../repos/$GITEA_OWNER/<repo>/commits/<head sha>/status | grep -o '"state":"[a-z]*"' | head -1` (`success`, `failure`, `pending`, or empty when CI has not run).
4. Unassigned issues per repository: `GET .../repos/$GITEA_OWNER/<repo>/issues?state=open&type=issues&limit=20 | grep -o '"assignees":null' | wc -l`.
5. Blockers: only the ones already noted in `WORK_LOGS/` without a follow-up for more than an hour. Do not scan channels for new ones.

Compare with `WORK_LOGS/heartbeat.txt` from the previous heartbeat, then overwrite it with this run's summary. If anything changed, post one concise update in the channel named `triage` (find its UUID with `buzz channels list`). If nothing changed, end the turn without posting.
