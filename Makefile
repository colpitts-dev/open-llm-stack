.PHONY: init up down ps logs test reload gitea-bootstrap

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
