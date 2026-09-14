# Plan 13 — PR scoring: a judge agent gives every PR a complexity and a confidence score, and Gitea keeps the truth

**Spec:** `docs/spec.md` (this plan adds §5.14 and gates G26–G28). **Rules:** `AGENTS.md`. **Knowledge:** plan 08 §5.8 (team, tokens, scrubbed shell, role teams), plan 10 §5.11 (reviewers team permissions), plan 11 §5.12 (thread conventions: bold labels only on deliverables), plan 12 §5.13 (runtimes).
**Sequence:** 13. Requires plan 12 executed. Adds a judge duty to Jared (the coordinator: no new service, keys or Gitea user; the `coordinators` team already grants issue write, which is all labels and comments need), four scripts, three make targets, thirteen org labels. No new image, port or relay change. First executed with a sixth agent (Jared); moved to Jared the same day, see §7 addendum.
**Execute with:** `/execute plans/13-pr-scoring.md`
**No internet except `docker pull`.** Every Gitea behaviour below was verified live on 2026-09-14 against the forge (Gitea 1.27.3).

---

## 1. Overview

Every PR the team opens gets two scores, recorded where the PR lives:

- **Complexity 1–5** — how hard the change was, judged from the request, the diff and the process. Used to order the human review queue and, later, to route hard tasks to a stronger runtime or model ("grid").
- **Confidence low / medium / high** — how likely the PR merges as-is. Evidence-based (CI, tests, review, scope match, diff hygiene), never the builder's gut feeling. Checked against reality: a sync step reads each scored PR's final state from Gitea and labels the outcome, and a report shows whether "high" really merged as-is more often than "low". A confidence that is never checked is decoration.

Decisions taken with the operator (2026-09-14): scores serve review triage now and routing later; **Jared** scores (independent of the builder and the reviewer; a sixth persona was tried first and dropped: one more container and identity for one turn per PR), **after CI and the review** exist; records live as **Gitea labels + one PR comment** (system of record) and **one line in the Buzz thread**; outcomes are read back from Gitea automatically.

Who does what:

| Piece | Owner | LLM? |
|---|---|---|
| deterministic signals: files, lines, tests touched, risky paths, commits, CI state, review states, head sha | `agents/bin/score-signals` (in the judge's container) | no |
| rubric: 5 complexity dimensions + 5 confidence dimensions, each 0–2 with one line of evidence | **Jared** (coordinator and judge, rubric in `agents/jared.md`) | one turn per PR |
| combination, validation, labels, PR comment, thread line | `agents/bin/score-post` (in the container, bash, no jq) | no |
| outcome labels from the PR's final state, calibration report | `scripts/score-sync.sh`, `scripts/score-report.sh` (host, jq) | no |

Thread, after this plan (Jared's line is the only new one):

```
Dinesh    **PR:** https://git.colpitts.dev/piedpiper/demo-calc/pulls/27 … @Richard @Gilfoyle review please
Dinesh    🚩 CI success on 3f01552
Gilfoyle  **Review:** APPROVED — mirrors add, tests cover it. @Jared score please
Jared     **Score:** complexity 1/5 · confidence high — one function + test, CI green, approved, scope exact
```

PR #27 in Gitea: labels `complexity/1`, `confidence/high`; one comment by `jared` with the rubric as fenced JSON; after the merge, `make score-sync` adds `outcome/merged-as-is`.

**Best practices this design follows** (from evaluation work on coding agents, adapted to a local 35B model): complexity and confidence are independent axes; small ordinal scales with written anchors, not 0–100; raw signals logged next to the score so the formula can change without re-scoring; the judge is a separate identity with a fixed rubric at temperature 0 and strict JSON output validated by a script, with a script-only fallback; effort (tokens, time, tool calls) is **not** a confidence input (it measures work, not correctness); CI red is a hard cap; outcomes are recorded and a reliability table is the acceptance test of the confidence score; agents never see the formula (Goodhart).

**Success criteria:** G26 — script-only path, no LLM: `score-post` with a canned rubric labels an existing PR, posts the comment and the thread line; invalid rubric JSON is rejected with exit 2. G27 — team smoke: after Gilfoyle's verdict, Jared's `**Score:**` line appears in the job thread and both labels are on the PR within 3 min; two consecutive passes. G28 — `make score-sync` labels a closed smoke PR `outcome/closed` and a merged one `outcome/merged-as-is`; `make score-report` prints the reliability table.

**Out of scope:** routing on the scores (policy stub location named in §5.14; needs weeks of outcomes first), process signals from the harness log (tokens, tool calls: host-side, join later by PR number), a human gold set (recommended: score 10 PRs by hand once and compare; operator task), `outcome/reverted`.

## 2. Relevant files

| Path | Action |
|---|---|
| `agents/jared.md` | judge duty + the rubric anchors |
| `agents/bin/score-signals`, `agents/bin/score-post` | new: deterministic signals; validation + labels + comment + thread line (bash, no jq) |
| `scripts/score-sync.sh`, `scripts/score-report.sh` | new: outcomes and calibration report (host, jq, judge token) |
| `scripts/bootstrap-team.sh` | org labels |
| `docker-compose.yml` | `JARED_PUBKEY` in `&team-env` |
| `scripts/team-entrypoint.sh` | inline `$JARED_PUBKEY` |
| `agents/TEAM.md`, `agents/gilfoyle.md` | roster; Gilfoyle asks Jared after the verdict |
| `Makefile` | `score-sync`, `score-report`, `team-model` recreate list |
| `.env.example` | comment on `TEAM_JARED_GITEA_TOKEN` |
| `scripts/team-smoke.sh`, `scripts/smoke-test.sh` | G27 wait + gate; G26 `test_team_score` |
| `docs/spec.md` §3, §5.14, §7; `README.md`; `AGENTS.md` | docs |

## 3. Dependencies and verified facts (2026-09-14, forge Gitea 1.27.3)

- **Org labels with exclusive scopes.** `POST /orgs/{org}/labels` `{name, color, description, exclusive}` (201; `CreateLabelOption` has `exclusive`, `is_archived`). Scoped names `scope/value` with `exclusive: true` make one value per scope. `DELETE /orgs/{org}/labels/{id}` → 204 and the label disappears from issues. **verify** at execution that adding `complexity/3` to a PR that has `complexity/2` replaces it (exclusive semantics); otherwise `score-post` removes the old scope labels first (`DELETE …/issues/{n}/labels/{id}`).
- **A `reviewers`-team token can label and comment.** With Gilfoyle's token (scopes `write:repository,write:issue,read:user,write:organization`, team units `repo.code:read, repo.pulls:write, repo.issues:write`): `POST /repos/{o}/{r}/issues/{n}/labels` with `{"labels":[<id>]}` → 200 and with `{"labels":["scope/name"]}` → 200 (`IssueLabelsOption`: ids or names); `POST …/issues/{n}/comments` → 201; own comment `DELETE …/issues/comments/{id}` → 204.
- **The admin token cannot read issues.** `GET …/issues/{n}/labels` and `…/comments` with `GITEA_ADMIN_TOKEN` → `token does not have at least one of required scope(s), required=[read:issue]` (by design since plan 10: `write:admin,write:organization,write:repository,write:user`). The host-side sync/report therefore use the judge's own token (`TEAM_JARED_GITEA_TOKEN`); PR reads (`GET pulls/{n}`, `…/reviews`, `…/files`, `…/commits`, `.diff`) work with either.
- **PR fields for outcomes.** `GET pulls/{n}`: `state`, `merged`, `merged_at`, `merge_commit_sha`, `head.sha`, `labels[]`, `requested_reviewers[]`. Reviews: `GET pulls/{n}/reviews` → `[{user.login, state, commit_id, submitted_at}]` (PR #26 has `REQUEST_CHANGES` then `APPROVED` at `4b66ea5` while `head.sha` is `2ea0ad9`: a push after the review is detectable as `head.sha ≠ last review's commit_id`). `GET pulls/{n}/files` → `[{filename, status, additions, deletions, changes}]`; `GET pulls/{n}/commits` → list; `GET pulls/{n}.diff` → unified diff. Closed PRs: `GET pulls?state=closed` (`merged` true/false).
- **Team plumbing** (plans 08–12): `scripts/init.sh` mints keys from a `for who in …` list; `scripts/bootstrap-team.sh` creates users + tokens from `for who in dinesh gilfoyle jared monica`, teams via `ensure_team reviewers … gilfoyle`, strips agent collaborators by login list; `docker-compose.yml` lists every agent pubkey in `BUZZ_ACP_RESPOND_TO_ALLOWLIST` (or agent-to-agent mentions are dropped) and each service repeats the volume list; the entrypoint inlines `GILFOYLE_PUBKEY` into the prompt (`sed` on `.prompt.md`); `make team-model` recreates a fixed service list; the sprig image has bash, curl, git, **no jq/python**; thread conventions: bold labels and `@mentions` only on deliverables; a persona edit needs `--force-recreate`.
- **Scoring inputs the judge can read in-container without jq**: `.diff` (text), `files` (JSON, small: count `"filename"` with `grep -o`), `commits/{sha}/status` (`"state":"success|failure|pending"` by regex), `reviews` (states by `grep -o '"state":"[A-Z_]*"'`), the PR body (`GET pulls/{n}` → `"title"`, `"body"` by regex; long bodies are fine, no nesting).

## 4. Tasks

### Task 1 — identity, compose, bootstrap, labels

- No new identity: Jared already has a keypair (`TEAM_JARED_*`), a Gitea user on the `coordinators` team (`repo.code: read, repo.pulls: read, repo.issues: write, repo.actions: read`) and a token with `write:issue` — enough to read the PR, its files, reviews and commit status, and to label and comment (issue endpoints). `.env.example`: comment on `TEAM_JARED_GITEA_TOKEN` ("also the judge: make score-sync/score-report use this token").
- `docker-compose.yml`: `&team-env` gains `JARED_PUBKEY: ${TEAM_JARED_PUBKEY:-}` (Gilfoyle mentions the judge). Jared keeps `BUZZ_ACP_SESSION_POLICY: channel` and his heartbeat; the score request arrives in the job thread and its context block carries the thread root id, which `score-post` takes as an argument.
- `scripts/team-entrypoint.sh`: the prompt `sed` gains `s|\$JARED_PUBKEY|${JARED_PUBKEY:-}|g`.
- `scripts/bootstrap-team.sh`: new step after the teams:
  ```bash
  # Score labels (plan 13): exclusive scopes, one value per scope on a PR. Created once at org level with the admin token.
  ensure_label() {   # ensure_label <name> <color> <description>
    api "$B/orgs/$ORG/labels?limit=100" | jq -e --arg n "$1" '.[] | select(.name==$n)' >/dev/null && return 0
    api -o /dev/null -d "{\"name\":\"$1\",\"color\":\"$2\",\"description\":\"$3\",\"exclusive\":true}" "$B/orgs/$ORG/labels" && echo "label $1"
  }
  for i in 1 2 3 4 5; do ensure_label "complexity/$i" "#5b8def" "task + change complexity, 1 trivial .. 5 hard (Jared)"; done
  ensure_label confidence/low    "#d0312d" "unlikely to merge as-is (Jared)"
  ensure_label confidence/medium "#e0a800" "may need a change before merge (Jared)"
  ensure_label confidence/high   "#2e9e4f" "expected to merge as-is (Jared)"
  ensure_label outcome/merged-as-is        "#2e9e4f" "merged at the scored sha (make score-sync)"
  ensure_label outcome/merged-after-changes "#e0a800" "merged after more commits (make score-sync)"
  ensure_label outcome/closed              "#888888" "closed unmerged (make score-sync)"
  ```
  **verify**: `GET /orgs/{org}/labels` needs org read with the admin token (it created them; `?limit=100` because `[api] MAX_RESPONSE_ITEMS` is 50).

### Task 2 — `agents/bin/score-signals`

```bash
#!/usr/bin/env bash
# Deterministic PR signals for the judge (plan 13). Runs inside the judge's container: token from ~/.gitea.env, no jq.
# Usage: score-signals <repo> <pr-number>   -> prints KEY=VALUE lines, then the diff (first 400 lines). Exit 3 = not ready.
set -euo pipefail
repo="${1:?repo}"; n="${2:?pr number}"; . "$HOME/.gitea.env"; B="$GITEA_URL/api/v1"; H=(-H "Authorization: token $GITEA_TOKEN")
pr=$(curl -sS "${H[@]}" "$B/repos/$GITEA_OWNER/$repo/pulls/$n"); [[ $pr == *'"number":'* ]] || { echo "no such PR $repo#$n" >&2; exit 1; }
sha=""; [[ $pr =~ \"head\":\{[^}]*\"sha\":\"([0-9a-f]{40})\" ]] && sha="${BASH_REMATCH[1]}"
title=""; [[ $pr =~ \"title\":\"(([^\"\\]|\\.)*)\" ]] && title="${BASH_REMATCH[1]}"
state="unknown"; st=$(curl -sS "${H[@]}" "$B/repos/$GITEA_OWNER/$repo/commits/$sha/status"); [[ $st =~ \"state\":\"([a-z]+)\" ]] && state="${BASH_REMATCH[1]}"
reviews=$(curl -sS "${H[@]}" "$B/repos/$GITEA_OWNER/$repo/pulls/$n/reviews" | grep -oE '"state":"[A-Z_]+"' | cut -d'"' -f4 | grep -v PENDING | paste -sd, || true)
[ "$state" = success ] || [ "$state" = failure ] || { echo "not ready: CI state is '$state'" >&2; exit 3; }
[ -n "$reviews" ] || { echo "not ready: no submitted review yet" >&2; exit 3; }
files=$(curl -sS "${H[@]}" "$B/repos/$GITEA_OWNER/$repo/pulls/$n/files?limit=100")
nfiles=$(grep -o '"filename":"' <<<"$files" | wc -l)
adds=0; dels=0; for v in $(grep -oE '"additions":[0-9]+' <<<"$files" | cut -d: -f2); do adds=$((adds+v)); done; for v in $(grep -oE '"deletions":[0-9]+' <<<"$files" | cut -d: -f2); do dels=$((dels+v)); done
names=$(grep -oE '"filename":"[^"]+"' <<<"$files" | cut -d'"' -f4)
tests=$(grep -cE '(^|/)tests?/|_test\.|test_' <<<"$names" || true)
risky=$(grep -cE '^\.gitea/|^\.github/|pyproject\.toml|requirements|Dockerfile|docker-compose|\.env|Makefile' <<<"$names" || true)
commits=$(curl -sS "${H[@]}" "$B/repos/$GITEA_OWNER/$repo/pulls/$n/commits" | grep -o '"sha":"' | wc -l)
printf 'REPO=%s\nPR=%s\nHEAD=%s\nTITLE=%s\nCI=%s\nREVIEWS=%s\nFILES=%s\nADDED=%s\nDELETED=%s\nTEST_FILES=%s\nRISKY_FILES=%s\nCOMMITS=%s\nFILE_LIST=%s\n' \
  "$repo" "$n" "$sha" "$title" "$state" "$reviews" "$nfiles" "$adds" "$dels" "$tests" "$risky" "$commits" "$(paste -sd, <<<"$names")"
echo "--- diff (first 400 lines) ---"; curl -sS "${H[@]}" "$B/repos/$GITEA_OWNER/$repo/pulls/$n.diff" | head -400
```

### Task 3 — `agents/bin/score-post`

```bash
#!/usr/bin/env bash
# Combine the judge's rubric into scores; label the PR, post the breakdown comment, post the thread line (plan 13).
# Usage: score-post <repo> <pr> <rubric.json> [<channel-uuid> <thread-root-id>]. Bash only (no jq): the rubric is flat.
# rubric.json = {"scope":0-2,"novelty":0-2,"risk":0-2,"verification":0-2,"ambiguity":0-2,
#                "tests":0-2,"ci":0-2,"review":0-2,"scope_match":0-2,"hygiene":0-2,"summary":"<one clause>","evidence":{"<dim>":"<line>",...}}
set -euo pipefail
repo="${1:?}"; n="${2:?}"; rf="${3:?rubric.json}"; ch="${4:-}"; root="${5:-}"
. "$HOME/.gitea.env"; B="$GITEA_URL/api/v1"; H=(-H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json")
j=$(tr -d '\n' < "$rf")
get() { [[ $j =~ \"$1\":([0-2])([,}]) ]] && printf '%s' "${BASH_REMATCH[1]}" || { echo "rubric: '$1' missing or not 0..2" >&2; exit 2; }; }
for k in scope novelty risk verification ambiguity tests ci review scope_match hygiene; do declare "$k=$(get $k)"; done
summary=""; [[ $j =~ \"summary\":\"(([^\"\\]|\\.)*)\" ]] && summary="${BASH_REMATCH[1]}"; [ -n "$summary" ] || { echo "rubric: summary missing" >&2; exit 2; }
csum=$((scope+novelty+risk+verification+ambiguity)); case $csum in 0|1) cx=1 ;; 2|3) cx=2 ;; 4|5) cx=3 ;; 6|7) cx=4 ;; *) cx=5 ;; esac
fsum=$((tests+ci+review+scope_match+hygiene)); if [ "$ci" = 0 ]; then cf=low; elif [ $fsum -ge 8 ]; then cf=high; elif [ $fsum -ge 5 ]; then cf=medium; else cf=low; fi
sha=$(curl -sS "${H[@]}" "$B/repos/$GITEA_OWNER/$repo/pulls/$n" | grep -oE '"head":\{[^}]*"sha":"[0-9a-f]{40}"' | grep -oE '[0-9a-f]{40}' | head -1)
# labels (exclusive scopes: Gitea keeps one value per scope -- verified at execution, else remove the old one first)
curl -fsS -o /dev/null "${H[@]}" -d "{\"labels\":[\"complexity/$cx\",\"confidence/$cf\"]}" "$B/repos/$GITEA_OWNER/$repo/issues/$n/labels"
# one comment, machine-readable
body=$(printf '**Score:** complexity %s/5 · confidence %s — %s\n\n```json\n{"schema":1,"pr":"%s#%s","sha":"%s","complexity":%s,"confidence":"%s","rubric":%s,"judge":"%s","scored_at":"%s"}\n```' \
  "$cx" "$cf" "$summary" "$repo" "$n" "$sha" "$cx" "$cf" "$j" "$GITEA_USER" "$(date -u +%FT%TZ)")
esc=$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')
curl -fsS -o /dev/null "${H[@]}" -d "{\"body\":\"$esc\"}" "$B/repos/$GITEA_OWNER/$repo/issues/$n/comments"
echo "labelled $repo#$n complexity/$cx confidence/$cf (sha ${sha:0:7})"
# thread line (the judge's deliverable; bold label, no mention)
if [ -n "$ch" ] && [ -n "$root" ]; then
  printf '**Score:** complexity %s/5 · confidence %s — %s\n' "$cx" "$cf" "$summary" | buzz messages send --channel "$ch" --reply-to "$root" --content - >/dev/null && echo "posted in thread"
fi
```
`chmod +x agents/bin/score-signals agents/bin/score-post`. **verify** at execution: the comment JSON escaping through `sed`/`awk` for a rubric containing quotes in evidence lines (the persona keeps evidence to plain words); exclusive-label replacement; `head -1` under `set -o pipefail` (plan 08 gotcha 2: prefer a bash regex if SIGPIPE shows).

### Task 4 — the judge duty in `agents/jared.md` and the trigger

Appended to Jared's persona (first line becomes `You are Jared, the coordinator and the team's judge. … You never build and never review code; you score.`; a `Judge:` duty: calm, fair, literal, never argue with Gilfoyle's verdict, never re-review the code, never let the brief you wrote colour the score, one deliverable per request):

```markdown
When asked to score a PR (`@Jared score <url>`; the URL is `$GITEA_URL/$GITEA_OWNER/<repo>/pulls/<n>`):
1. Run `/opt/team/agents/bin/score-signals <repo> <n>`. If it prints `not ready` (CI pending or no submitted review), wait 30 seconds and run it again, up to 6 times. If still not ready, post `**Score:** not scored — <its reason>` in the thread and stop.
2. Read the signals and the diff. Fill the rubric below as `rubric.json` with a quoted heredoc (`cat > rubric.json <<'EOF'` … `EOF`), each dimension exactly 0, 1 or 2, one short evidence line per dimension in plain words (no quotes, no backticks), and a one-clause summary.
3. Run `/opt/team/agents/bin/score-post <repo> <n> rubric.json <channel uuid from the context block> <thread root id>`. It labels the PR, posts the breakdown in Gitea and posts your `**Score:**` line in the thread. Do not post anything else; do not @mention anyone.

Rubric — complexity (what the task demanded, independent of how well it went):
- scope: 0 one file or function · 1 two to four files in one area · 2 several areas, new module, or cross-cutting
- novelty: 0 mirrors an existing pattern in the repo · 1 adapts a pattern · 2 new design, new dependency, or new project
- risk: 0 pure logic and its tests · 1 touches config, data or public API · 2 touches CI, auth, secrets, dependencies or branch rules
- verification: 0 CI proves it fully · 1 CI proves part of it · 2 needs a human to see or run it
- ambiguity: 0 the request named the function, the file and the behaviour · 1 some choices were left open · 2 the request needed interpretation
Rubric — confidence (evidence the PR merges as-is):
- tests: 0 none · 1 present but shallow · 2 added or changed and they exercise the change
- ci: 0 failure · 1 pending or partial · 2 success on the head commit
- review: 0 REQUEST_CHANGES outstanding · 1 COMMENT or approval with findings · 2 APPROVED with no findings
- scope_match: 0 the diff does more or less than asked · 1 minor extras or gaps · 2 exactly what was asked
- hygiene: 0 stray files, secrets, amended history, formatting noise · 1 small noise · 2 clean
Do not use tokens, time, or how hard the builder worked as evidence for anything. Do not change a score because of who wrote the PR.
```
`agents/gilfoyle.md` step 4 gains: `Then, as a separate message, ask for the score: `@Jared score <PR url>` with `--mention $JARED_PUBKEY`.` `agents/TEAM.md` roster: `Jared (coordinator and judge: scores every PR after CI and the review)`; `Jared's is $JARED_PUBKEY` next to Gilfoyle's; the "Deliverables" bullet lists `**Score:**` as Jared's label; "one of five agents".

### Task 5 — host scripts and make targets

`scripts/score-sync.sh` (jq; judge token):
```bash
#!/usr/bin/env bash
# Outcome labels for scored PRs (plan 13): read each closed PR that carries a confidence/* label and record what happened.
set -euo pipefail; cd "$(dirname "$0")/.."; set -a; . ./.env; set +a
: "${TEAM_JARED_GITEA_TOKEN:?run make team-bootstrap}"; G="${GITEA_PUBLIC_URL:-http://127.0.0.1:3003}"; B="$G/api/v1"; ORG="${TEAM_GITEA_ORG:-piedpiper}"
J="Authorization: token $TEAM_JARED_GITEA_TOKEN"   # the admin token has no read:issue (plan 10)
api() { curl -fsS -H "$J" -H 'Content-Type: application/json' "$@"; }
for r in $(api "$B/orgs/$ORG/repos?limit=50" | jq -r '.[].name'); do
  api "$B/repos/$ORG/$r/pulls?state=closed&limit=50" | jq -c '.[] | select(any(.labels[]?; .name|startswith("confidence/"))) | select(all(.labels[]?; (.name|startswith("outcome/"))|not)) | {number, merged, head:.head.sha}' |
  while read -r pr; do
    n=$(jq -r .number <<<"$pr"); merged=$(jq -r .merged <<<"$pr"); head=$(jq -r .head <<<"$pr")
    scored=$(api "$B/repos/$ORG/$r/issues/$n/comments" | jq -r '[.[] | select(.body|startswith("**Score:**"))] | last | .body' | sed -n 's/.*"sha":"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
    if [ "$merged" = true ] && [ "$head" = "$scored" ]; then o=outcome/merged-as-is; elif [ "$merged" = true ]; then o=outcome/merged-after-changes; else o=outcome/closed; fi
    api -o /dev/null -d "{\"labels\":[\"$o\"]}" "$B/repos/$ORG/$r/issues/$n/labels" && echo "$r#$n: $o"
  done
done; echo "score sync complete"
```
`scripts/score-report.sh`: for every org repo, list PRs with a `complexity/*` label (open and closed), join labels, and print (a) counts per complexity, (b) the reliability table `confidence × outcome` (rows low/medium/high; columns merged-as-is / merged-after-changes / closed / open), (c) merged-as-is rate per confidence bucket. jq only; ~40 lines; **verify** field names on the live instance.
`Makefile`: `score-sync` and `score-report` targets (`./scripts/score-sync.sh`, `./scripts/score-report.sh`), `.PHONY` updated.

### Task 6 — gates

`scripts/smoke-test.sh` `test_team_score` (G26, no LLM), dispatcher after `test_team_runtime`:
```bash
test_team_score() {   # G26: script-only scoring path inside jared on the newest smoke PR; invalid rubric rejected
  local base="${GITEA_PUBLIC_URL%/}/api/v1" auth="Authorization: token ${GITEA_ADMIN_TOKEN}" org="${TEAM_GITEA_ORG:-piedpiper}" relay="${BUZZ_RELAY_URL:-ws://${BUZZ_PUBLIC_HOST:-127.0.0.1:3002}}" sprig=ghcr.io/block/buzz-sprig:sha-e17cdd9
  echo "--- team: PR scoring (score-post with a canned rubric inside jared, no LLM)"
  local n; n=$(curl -fsS -H "$auth" "$base/repos/$org/demo-calc/pulls?state=all&limit=1" | jq -r '.[0].number'); [ -n "$n" ] || fail "no PR in demo-calc"
  docker compose exec -T jared bash -c 'printf "{\"scope\":0,\"novelty\":3}" > /tmp/bad.json; /opt/team/agents/bin/score-post demo-calc '"$n"' /tmp/bad.json' >/dev/null 2>&1 && fail "score-post accepted a bad rubric" || echo "bad rubric rejected"
  docker compose exec -T jared bash -c 'cat > /tmp/r.json <<EOF
{"scope":0,"novelty":0,"risk":0,"verification":0,"ambiguity":0,"tests":2,"ci":2,"review":2,"scope_match":2,"hygiene":2,"summary":"smoke: canned rubric","evidence":{"scope":"one function"}}
EOF
/opt/team/agents/bin/score-post demo-calc '"$n"' /tmp/r.json'
  curl -fsS -H "Authorization: token ${TEAM_JARED_GITEA_TOKEN}" "$base/repos/$org/demo-calc/issues/$n/labels" | jq -r 'map(.name)|join(",")' | grep -E 'complexity/1' | grep -q 'confidence/high' && echo "labels: complexity/1, confidence/high" || fail "labels missing on demo-calc#$n"
  curl -fsS -H "Authorization: token ${TEAM_JARED_GITEA_TOKEN}" "$base/repos/$org/demo-calc/issues/$n/comments" | jq -e '[.[] | select(.body|startswith("**Score:**"))] | length > 0' >/dev/null && echo "score comment present" || fail "no score comment"
}
```
`scripts/team-smoke.sh` (G27): after the review verdict, mention Jared from the smoke identity as a fallback if Gilfoyle did not (`@Jared score <url>` with `--mention "$TEAM_JARED_PUBKEY"` posted in the job thread, `--reply-to "$root"`), then wait up to 3 min for a `**Score:**` post by `$TEAM_JARED_PUBKEY` in the job thread; gate `PASS: score line` and, via the judge token, `PASS: score labels` (both scopes present on the PR). Print the line.
G28 in the validation commands: close one smoke PR with the admin token (`PATCH pulls/{n} {"state":"closed"}`), merge one (`POST pulls/{n}/merge {"Do":"squash"}`, admin is on the merge whitelist; retry after `405 Please try again later`), then `make score-sync` → `outcome/closed`, `outcome/merged-as-is`; `make score-report` → the table.

### Task 7 — docs

- `docs/spec.md`: §3 comment on `TEAM_JARED_GITEA_TOKEN`; new **§5.14 PR scoring** (the two scores and their anchors, why effort is excluded, the label scopes, the comment schema, the sync/outcome rules, the admin-token `read:issue` gap, the reliability table as the acceptance test, the routing stub: "policy consumes `complexity/*` before a run and `confidence/*` after; lives in one script when it exists"); §7 gates G26–G28.
- `README.md` "The agent team": Jared's row gains `and judge` + scores PRs after CI + review, labels + comment + **Score:** line; a short **Scores** paragraph with the two scales and how to read the report; Make targets rows.
- `AGENTS.md`: status line; non-negotiables: "Scores are Jared's, computed by `agents/bin/score-post` from a fixed rubric; never gate a merge on them; agents never see the formula; effort is not evidence."
- `plans/13-pr-scoring.md` §7: execution report, including the first reliability table (will be mostly `open`).

## 5. Testing strategy

Task 1 → `make team-bootstrap` twice (labels; second run prints no `label` line) → `docker compose up -d --force-recreate jared gilfoyle` (personas) → G26 (`make test` runs `test_team_score`) → G27 twice (`make team-smoke`) → G28 (close one, merge one, sync, report) → `make test` once more. GPU idle for the smokes (no operator jobs).

## 6. Validation commands

```bash
bash -n agents/bin/score-signals agents/bin/score-post scripts/score-sync.sh scripts/score-report.sh scripts/bootstrap-team.sh scripts/team-smoke.sh scripts/smoke-test.sh && test -x agents/bin/score-signals -a -x agents/bin/score-post
make team-bootstrap && make team-bootstrap                     # label complexity/1 … outcome/closed; run 2 quiet
set -a; . ./.env; set +a; curl -fsS -H "Authorization: token $GITEA_ADMIN_TOKEN" "$GITEA_PUBLIC_URL/api/v1/orgs/$TEAM_GITEA_ORG/labels?limit=100" | jq -r '.[] | select(.exclusive) | .name' | sort   # 11 scoped labels
docker compose up -d --force-recreate jared gilfoyle && docker compose logs --since 1m jared | grep -E 'presence set|model='
docker compose exec -T jared /opt/team/agents/bin/score-signals demo-calc <n> | head -14                  # KEY=VALUE lines then the diff; exit 3 on a PR without CI/review
make test | sed -n '/PR scoring/,/score comment present/p'                                                # G26
make team-smoke | tail -12                                                                                # G27 run 1: … PASS: score line / PASS: score labels
make team-smoke | tail -12                                                                                # G27 run 2
# G28
curl -fsS -o /dev/null -X PATCH -H "Authorization: token $GITEA_ADMIN_TOKEN" -H 'Content-Type: application/json' -d '{"state":"closed"}' "$GITEA_PUBLIC_URL/api/v1/repos/$TEAM_GITEA_ORG/demo-calc/pulls/<closed-n>"
curl -fsS -o /dev/null -X POST  -H "Authorization: token $GITEA_ADMIN_TOKEN" -H 'Content-Type: application/json' -d '{"Do":"squash"}'     "$GITEA_PUBLIC_URL/api/v1/repos/$TEAM_GITEA_ORG/demo-calc/pulls/<merged-n>/merge"
make score-sync      # demo-calc#<closed-n>: outcome/closed / demo-calc#<merged-n>: outcome/merged-as-is
make score-report    # complexity counts; confidence × outcome table; merged-as-is rate per bucket
```

## 7. Execution report (executed 2026-09-14 with the judge as a sixth agent `bighead`; the same day the judge moved to Jared — addendum at the end — external Gitea mode, `ornith-max`, Dinesh on `buzz-agent`, `TEAM_NARRATE=tools` as found in `.env`)

### Findings and fixes

1. **Reviewer approvals did not count as official since plan 10.** `POST pulls/29/merge` with the admin token → `405 Does not have enough approvals` although Gilfoyle had approved three times: Gitea marks a review "official" only from a user with write access or on the protection's approvals whitelist, and the `reviewers` team has `repo.code: read` since plan 10. Fix: the protection rule (bootstrap `PROT`, the reconcile loop, hence the template every new repo copies) now sets `enable_approvals_whitelist: true`, `approvals_whitelist_username: ["gilfoyle"]`, `approvals_whitelist_teams: ["reviewers"]` (field names from `EditBranchProtectionOption`: `…_username` singular for users, `…_teams`; a first attempt with `approvals_whitelist_usernames` was silently ignored → `null`). `make team-bootstrap` repaired nine repos. Official-ness is stamped at review time: an existing approval stays non-official, so PR #29 needed a fresh `APPROVED` (`official: true`) before it merged. Until this fix, every PR on the forge since plan 10 needed a human approval on top of Gilfoyle's.
2. **`.env` had `TEAM_DINESH_RUNTIME=goose`** at the start of G27 (left from a manual switch after plan 12), and that goose turn ended after writing the files without commit, push or post (recorded in plan 12 §7 addendum). Dinesh was put back on `buzz-agent` for the gates.
3. **Gilfoyle asked with `@ Bighead` (space) inside a `**Score:**`-labelled message**: no `p` tag, no trigger, and a label misuse. Persona now gives the exact `buzz messages send … --mention $JARED_PUBKEY --content "@Jared score <url>"` command and forbids the label; the smoke mentions Bighead itself as a fallback.
4. **`| head -1` under `set -o pipefail` in the smoke's score wait** killed the script (SIGPIPE 141, plan 08 gotcha 2) before the score check. Removed.
5. **Admin token lacks `read:issue`**: confirmed; `score-sync.sh`, `score-report.sh` and the smoke's label checks use `TEAM_JARED_GITEA_TOKEN`.
6. `score-post` removes stale `complexity/*`/`confidence/*` label ids before adding (exclusive scopes would also replace; the belt-and-braces path was exercised by G26 on a PR scored twice). The comment JSON round-trips through `jq` (`schema`, `pr`, `sha`, `complexity`, `confidence`, `rubric`, `judge`, `scored_at`).
7. `score-signals` exit 3 on a PR whose CI is `pending` (demo-calc#1) and full output on a ready PR (#26: `CI=success`, `REVIEWS=REQUEST_CHANGES,APPROVED`, `FILES=2`, `ADDED=11`, `DELETED=1`, `TEST_FILES=1`, `RISKY_FILES=0`, `COMMITS=3`).

### Gate output (real)

```
# make init: generated TEAM_BIGHEAD_PRIVATE_KEY / TEAM_BIGHEAD_PUBKEY
# make team-bootstrap (run 1): created gitea user bighead / TEAM_BIGHEAD_GITEA_TOKEN written / team reviewers: member bighead /
#   label complexity/1 … complexity/5 confidence/low|medium|high outcome/merged-as-is|merged-after-changes|closed; run 2: only member/owner lines
# bighead: model=ornith-max context=237568 output=16384 / profile name set: Bighead / respond_to=allowlist(8) / presence set to online; Gilfoyle's prompt carries BIGHEAD_PUBKEY
# G26 (make test section): bad rubric rejected / labelled demo-calc#26 complexity/1 confidence/high (sha 2ea0ad9) / labels: complexity/1, confidence/high / score comment present
# G27 attempt 1: FAIL — Dinesh on goose (finding 2), no PR in 15 min
# G27 attempt 2 (buzz-agent): conventions 5/5 PASS, then the script died at the score wait (finding 4); Gilfoyle's "@ Bighead" (finding 3)
# G27 run 2: PR #28, 7/7 — PASS: score line: **Score:** complexity 1/5 · confidence high — one function plus test, CI green, approved / PASS: score labels: complexity/1,confidence/high
#   Bighead's turn: signals → "Signals are ready — CI success, APPROVED. Writing the rubric and scoring." → score-post; ~26 s after Gilfoyle's mention
# G27 run 3: PR #29, 7/7 — **Score:** complexity 1/5 · confidence high — one function plus its test, CI green and approved   (two consecutive passes)
# G28: close #28 → 201; merge #29 → 405 "Does not have enough approvals" ×10 (finding 1) → whitelist + fresh official approval → merge 200 (merge_commit 755ce56)
#   make score-sync: demo-calc#29: outcome/merged-as-is / demo-calc#28: outcome/closed
#   make score-report:
scored PRs: 3
complexity:  1: 3
confidence x outcome:  low (none) / medium (none) / high closed=1 merged-as-is=1 open=1
merged-as-is rate per confidence bucket:  high 1/2   (the "closed" is #28, closed by hand for the gate, not a real outcome)
```
Final `make test` (exit 0): every layer section / TEAM SMOKE PASS PR #30 (milestones present, PR + Review labels, mirror git push, **Score:** complexity 1/5 · confidence high, score labels) / factory: collaborators none / progress mirror: 2 replies / dinesh runtime = buzz-agent / PR scoring: bad rubric rejected, labelled demo-calc#30, score comment present / smoke test finished.

Note on G26: the canned rubric is applied to the newest `demo-calc` PR, which `make test` may have just had scored for real; the fixture repository is disposable by definition (bootstrap recreates it), so the overwrite is accepted, but never point `test_team_score` at a real project repo.

### Reading the first numbers

Three scored PRs, all `complexity/1` `confidence/high`: the fixture task is trivial and the judge said so. The reliability table only becomes informative with real work (Monica's UI jobs, new projects) and real merges by the operator. Calibration to check after a few weeks: `high` merged-as-is rate should sit near 1; if `medium` merges as-is as often as `high`, the review dimension is doing all the work and the rubric needs a harder evidence dimension (e.g. test count delta vs. lines changed).

### Not run and why

- A human gold set (10 PRs scored by hand): operator task; the rubric anchors in `agents/jared.md` are what to compare against.
- `outcome/reverted`: out of scope.
- Routing on scores: deliberately absent; stub location in §5.14.

### Addendum — judge moved from Bighead to Jared (2026-09-14, external Gitea mode, `ornith-max`, Dinesh on `buzz-agent`)

Decision (operator): no sixth agent. Jared, who never builds or reviews, scores. Removed: service `bighead`, volume `team-bighead`, `TEAM_BIGHEAD_*`, Gitea user `bighead` (deleted with purge; the labels and closed smoke PRs stay), the `reviewers` membership, `agents/bighead.md`. Added: the judge duty and rubric in `agents/jared.md`, `JARED_PUBKEY` in `&team-env` and the entrypoint `sed`, `TEAM_JARED_GITEA_TOKEN` for the host scripts and the smoke. Label descriptions on the forge re-pointed at Jared with `PATCH /orgs/{org}/labels/{id}`.

Findings and fixes:

1. **A PR label needs `repo.pulls: write`, not `repo.issues: write`.** `POST …/issues/{n}/labels` with Jared's token (coordinators: pulls read, issues write) → `403 write permission is required`; the comment on the same PR → 201. Gitea checks issue-labels on a pull request against the pulls unit. Fix: `coordinators` now `repo.pulls: write` (his approvals are still not official: the approvals whitelist names only `gilfoyle` and the `reviewers` team). `ensure_team` in the bootstrap now PATCHes `units_map` on an existing team (`{"name","units_map"}`), so the change reached the forge on the next `make team-bootstrap` (`team piedpiper/coordinators exists (units reconciled)`; `GET /orgs/{org}/teams` shows `"repo.pulls":"write"`). `score-post` now exits 4 with `cannot label …` when the label call fails, before the comment and the thread line: a score line without labels would be invisible to `score-sync`/`score-report`.
2. **The judge must be a member of the job channel.** Delivery is members-only (primer: "only member channels + DMs"), and `buzz messages send` refuses a body containing `@Jared` when he is not a member (`mention '@jared' does not match a current channel member`). The smoke never added the judge; the earlier G27 passes worked because Gilfoyle happened to run `add-member` for Bighead/Jared himself. Two runs (PR #32, #33) ended with no score line and the smoke script dying at its own fallback `bz messages send` (set -e). Fix: the smoke adds `TEAM_JARED_PUBKEY` as a bot member next to Dinesh and Gilfoyle; Gilfoyle's persona adds him when the send fails; the README tells the operator to add Jared to project channels.
3. On the first attempt (PR #31, before fix 1) Jared spent nine calls debugging the 403 inside one turn, posted a stray `test` comment, then wrote the score comment and thread line by hand without labels (`**Score:** complexity 2/5 · confidence high`). Stray comment deleted with his own token; labels added by hand after fix 1. Expect this shape whenever a persona script fails under a 35B model: it improvises around the tool.
4. Jared's channel-scoped session carries the score request's thread root id in the context block (`Scope: thread` / `Session scope: channel`), so `score-post` posts into the right thread with no persona change. The heartbeat and the judge share one session per channel; job channels are per smoke run, so no cross-talk was seen in four runs.

Gate output (real):

```
# make team-bootstrap ×2: team piedpiper/coordinators exists (units reconciled) / team coordinators: member jared; run 2 identical, no label lines
# docker compose up -d --remove-orphans --force-recreate dinesh gilfoyle jared erlich monica: Container open-llm-stack-bighead-1 Removed; volume open-llm-stack_team-bighead removed
# jared: model=ornith-max context=237568 output=16384 / presence set to online; gilfoyle prompt: `@Jared score <PR url>` + JARED pubkey ×2; jared prompt: score-signals ×1, Bighead ×0
# score-signals as jared on demo-calc#19: HEAD=1fcd414… CI=success REVIEWS=APPROVED FILES=2 ADDED=11 DELETED=1
# G27 run 1 (before fixes): PR #31 — PASS: score line: **Score:** complexity 2/5 · confidence high … / FAIL: score labels missing () (finding 1)
# G27 runs A, B (after fix 1, before fix 2): PR #32, #33 — no score section: the smoke died at its own `bz messages send` (finding 2)
# G27 run C: PR #34, 7/7 — PASS: score line: **Score:** complexity 2/5 · confidence high — one function plus test, CI green, approved / PASS: score labels: complexity/2,confidence/high
# G27 run D: PR #35, 7/7 — **Score:** complexity 1/5 · confidence high — one function plus test, CI green, approved / complexity/1,confidence/high   (two consecutive passes)
# G28: close #34 → 201; merge #35 → 200 (Gilfoyle's approval official after the whitelist fix, first try)
#   make score-sync: demo-calc#34: outcome/closed (+ #30, #26 closed by the operator earlier); #35 labels: complexity/1,confidence/high,outcome/merged-as-is
#   make score-report: high closed=4 merged-as-is=2 open=2 / merged-as-is rate high 2/6 (the closed ones are gate fixtures, not real outcomes)
# make test (exit 0): every layer section / TEAM SMOKE PASS PR #36 (**Score:** complexity 1/5 · confidence high — one function and its test mirroring the existing subtract pattern, CI green, approved; labels complexity/1,confidence/high)
#   / factory: collaborators none / progress mirror: 2 replies / dinesh runtime = buzz-agent / PR scoring (inside jared): bad rubric rejected, labelled demo-calc#36, score comment present / smoke test finished
```

Complexity on the trivial fixture came out 2/5 twice (Jared scored `verification=2`, "needs a human to see it", for a pure function with a test) and 1/5 twice: the anchor is read loosely by a 35B model. Not fixed here; a human gold set will show whether the rubric needs a harder wording.

