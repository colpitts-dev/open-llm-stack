.PHONY: init up down ps logs test reload gitea-bootstrap team-bootstrap team-smoke team-render litellm-keys team-status team-model goose-image member-runtime dinesh-runtime member-add member-rm team-new score-sync score-report context-probe model-fit context-report power-meter power-ingest cost-report

init:            ## first run: .env + secrets + proxy/config.yaml (idempotent)
	./scripts/init.sh

up:              ## start every layer in COMPOSE_PROFILES, wait for healthy, check the LLM backend
	./scripts/check-ports.sh
	docker compose up -d --wait
	./scripts/preflight.sh

down:
	docker compose down

ps:
	docker compose ps

logs:            ## make logs S=litellm
	docker compose logs -f $(S)

test:            ## smoke test every running layer
	./scripts/smoke-test.sh

reload:          ## after editing proxy/config.yaml
	docker compose restart litellm

gitea-bootstrap: ## admin user + API token for the bundled Gitea (plan 04)
	./scripts/bootstrap-gitea.sh

team-bootstrap:  ## Gitea users/tokens for the agents, runner token, fixture repo (plan 08)
	./scripts/bootstrap-team.sh

team-smoke:      ## job -> **Plan:** -> approved -> PR + green CI -> review + conformance -> attack in #attack -> verdict + score in #gate (plan 16.5)
	./scripts/team-smoke.sh

goose-image:     ## build open-llm-stack/goose-agent (plan 12; downloads the pinned goose release, apt-get)
	docker build -t open-llm-stack/goose-agent:1.50.0 agents/goose

MEMBERS = $(shell python3 scripts/team-roster.py members 2>/dev/null | cut -d' ' -f1)

team-render:     ## render teams/$(TEAM_NAME)/compose.yml from team.toml and mint missing member keys (plan 16): make team-render [T=<team>]
	python3 scripts/team-render.py $(if $(T),--team $(T),)

litellm-keys:    ## mint one LiteLLM virtual key per member, Open WebUI and the Buzz agent into .env (plan 16; team-bootstrap runs it)
	./scripts/litellm-keys.sh

team-status:     ## members, roles, runtimes, container state (plan 16)
	@python3 scripts/team-roster.py members | while read -r n r d l p; do printf '%-10s %-12s %-10s %s\n' "$$n" "$$r" "$$l" "$$(docker compose ps --format '{{.Status}}' $$n 2>/dev/null | head -1)"; done

team-model:      ## switch the team's model: make team-model M=qwen3.8-max (edits team.toml, re-renders, recreates the members)
	@test -n "$(M)" || { echo "usage: make team-model M=<model_name from proxy/config.yaml>"; exit 1; }
	@set -a; . ./.env; set +a; curl -fsS -H "Authorization: Bearer $$LITELLM_MASTER_KEY" "$${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}/v1/models" | jq -e --arg m "$(M)" '.data[] | select(.id==$$m)' >/dev/null || { echo "$(M) is not registered in proxy/config.yaml"; exit 1; }
	@set -a; . ./.env; set +a; sed -i 's|^model = .*|model = "$(M)"|' teams/$${TEAM_NAME:-piedpiper}/team.toml
	python3 scripts/team-render.py
	docker compose up -d --force-recreate $(MEMBERS)
	@echo "team now on $(M); each agent re-reads its context window from the registry on start"

member-runtime:  ## switch one member's runtime: make member-runtime N=dinesh R=goose|buzz-agent (plan 12 knob, per member)
	@test -n "$(N)" && test -n "$(R)" || { echo "usage: make member-runtime N=<member> R=goose|buzz-agent"; exit 1; }
	python3 scripts/team-roster.py set $(N) runtime $(R)
	python3 scripts/team-render.py && docker compose up -d --force-recreate --wait $(N) && docker compose logs --since 1m --no-log-prefix $(N) | grep -E 'runtime=|agent initialized|presence set' | cut -c1-120
dinesh-runtime:  ## kept for plan 12's gates: make dinesh-runtime R=goose|buzz-agent
	$(MAKE) member-runtime N=dinesh R=$(R)

member-add:      ## add a member: make member-add N=<name> R=builder|reviewer|coordinator|assistant [TITLE="…"] (plan 16)
	@test -n "$(N)" && test -n "$(R)" || { echo "usage: make member-add N=<name> R=<role> [TITLE=\"…\"]"; exit 1; }
	python3 scripts/team-roster.py add $(N) $(R) $(if $(TITLE),"$(TITLE)",)
	@set -a; . ./.env; set +a; t=teams/$${TEAM_NAME:-piedpiper}; [ -f $$t/personas/$(N).md ] || printf 'You are %s, the %s. (Edit this persona: voice, specialities, what you never do.)\n' "$$(python3 -c 'print("$(N)".capitalize())')" "$(R)" > $$t/personas/$(N).md
	python3 scripts/team-render.py
	./scripts/bootstrap-team.sh      # idempotent: creates the forge user, token and team membership for the new member, keys for LiteLLM
	docker compose up -d --force-recreate --wait $(N) && docker compose logs --since 1m --no-log-prefix $(N) | grep -E 'model=|presence set' | cut -c1-120
	@echo "$(N) is on the team: add its pubkey to your project channels (buzz channels add-member --pubkey \$$TEAM_$$(echo $(N) | tr a-z- A-Z_)_PUBKEY --role bot)"

member-rm:       ## remove a member's service and forge membership; keys stay in .env (PURGE=1 also deletes the forge user and the volume)
	@test -n "$(N)" || { echo "usage: make member-rm N=<name> [PURGE=1]"; exit 1; }
	-docker compose rm -sf $(N)
	python3 scripts/team-roster.py rm $(N)
	python3 scripts/team-render.py
	@set -a; . ./.env; set +a; B="$${GITEA_PUBLIC_URL%/}/api/v1"; A="Authorization: token $$GITEA_ADMIN_TOKEN"; login="$(N)$${AGENT_LOGIN_SUFFIX:-}"; \
	for tm in builders reviewers coordinators; do tid=$$(curl -fsS -H "$$A" "$$B/orgs/$${TEAM_GITEA_ORG:-piedpiper}/teams" | jq -r --arg n $$tm '.[]|select(.name==$$n)|.id'); [ -n "$$tid" ] && curl -sS -o /dev/null -X DELETE -H "$$A" "$$B/teams/$$tid/members/$$login"; done; \
	if [ "$(PURGE)" = 1 ]; then curl -sS -o /dev/null -X DELETE -H "$$A" "$$B/admin/users/$$login?purge=true" && echo "forge user $$login purged"; docker volume rm -f open-llm-stack_team-$(N) >/dev/null && echo "volume removed"; fi
	@echo "$(N) removed; TEAM_$$(echo $(N) | tr a-z- A-Z_)_* stay in .env$(if $(PURGE),, (PURGE=1 deletes the forge user and the volume))"

team-new:        ## start a team from a preset in a fresh deployment: make team-new T=<name> FROM=dev-squad|solo-builder|review-board|content-studio
	@test -n "$(T)" && test -n "$(FROM)" || { echo "usage: make team-new T=<team> FROM=<preset>"; exit 1; }
	@test ! -d teams/$(T) || { echo "teams/$(T) exists"; exit 1; }
	mkdir -p teams/$(T)/personas && sed '0,/^\[\[members\]\]/{s|^name = .*|name = "$(T)"|; s|^org = .*|org = "$(T)"|}' teams/_presets/$(FROM).toml > teams/$(T)/team.toml   # top-level keys only: members have name = too
	@for n in $$(python3 scripts/team-roster.py --team $(T) members | cut -d' ' -f1); do cp -n teams/_presets/personas/$$n.md teams/$(T)/personas/$$n.md 2>/dev/null || printf 'You are %s.\n' "$$n" > teams/$(T)/personas/$$n.md; done
	sed -i 's|^TEAM_NAME=.*|TEAM_NAME=$(T)|' .env; grep -q '^TEAM_NAME=' .env || echo 'TEAM_NAME=$(T)' >> .env
	python3 scripts/team-render.py --team $(T)
	@echo "team $(T) rendered from $(FROM): edit teams/$(T)/team.toml and personas, then make up && make team-bootstrap"

score-sync:      ## outcome labels for scored PRs from their final state in Gitea (plan 13)
	./scripts/score-sync.sh

score-report:    ## complexity counts and the confidence x outcome reliability table (plan 13)
	./scripts/score-report.sh

context-probe:   ## prove every chat model's declared window through the gateway (any backend): make context-probe [M=<model>] [FULL=1] (plan 14)
	./scripts/context-probe.sh

model-fit:       ## Ollama: measure a model's window on the live backend, print its registry block: make model-fit M=<tag> [OUT=32768] [MAX_WINDOW=131072] (plan 14)
	@test -n "$(M)" || { echo "usage: make model-fit M=<ollama tag> [OUT=<max_output_tokens>] [HEADROOM_MB=2048] [MAX_WINDOW=131072]"; exit 1; }
	M=$(M) ./scripts/model-fit.sh

context-report:  ## real prompt/completion sizes per model vs the registry caps, from LiteLLM's spend log (plan 14)
	./scripts/context-report.sh

power-meter:     ## meter energy into litellm-db, 1 row/s per domain (plan 15; foreground, Ctrl-C to stop): probes from POWER_PROBES
	@set -a; . ./.env; set +a; [ -n "$$POWER_COST_PER_KWH" ] || { echo "POWER_COST_PER_KWH is blank in .env: energy accounting off"; exit 0; }; \
	python3 scripts/power-meter.py --probes "$${POWER_PROBES:-nvml}" | python3 scripts/power-meter.py --ingest

power-ingest:    ## meter lines on stdin into litellm-db; a second host: ssh gpu2 python3 - --probes nvml < scripts/power-meter.py | make power-ingest (plan 15)
	@python3 scripts/power-meter.py --ingest

cost-report:     ## kWh the local models burned and what it cost, then per model, client, domain (plan 15): make cost-report [SINCE="24 hours"]
	./scripts/cost-report.sh
