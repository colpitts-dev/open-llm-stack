.PHONY: init up down ps logs test reload gitea-bootstrap team-bootstrap team-smoke team-model

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

team-smoke:      ## submit a job thread; expect a green PR and a review
	./scripts/team-smoke.sh

team-model:      ## switch every team agent's model: make team-model M=qwen3.8-max
	@test -n "$(M)" || { echo "usage: make team-model M=<model_name from proxy/config.yaml>"; exit 1; }
	@set -a; . ./.env; set +a; curl -fsS -H "Authorization: Bearer $$LITELLM_MASTER_KEY" "$${LITELLM_PUBLIC_URL:-http://127.0.0.1:3000}/v1/models" | jq -e --arg m "$(M)" '.data[] | select(.id==$$m)' >/dev/null || { echo "$(M) is not registered in proxy/config.yaml"; exit 1; }
	sed -i 's|^TEAM_MODEL=.*|TEAM_MODEL=$(M)|' .env
	docker compose up -d --force-recreate dinesh gilfoyle jared erlich   # --force-recreate: a plain up -d once skipped the restart after the .env edit
	@echo "team now on $(M); each agent re-reads its context window from the registry on start"
