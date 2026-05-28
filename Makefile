.PHONY: help up down watch logs heal listen monitor graph setup migrate backup shell iex quality test format credo compile dialyzer

APP_CONTAINER = big_bill-app-1

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Docker ---

up: ## Start containers (PORT=8080 make up)
	PORT=$(or $(PORT),4000) docker compose up --build -d

watch: ## Start file sync for hot reload (run after make up)
	docker compose watch

down: ## Stop everything
	docker compose down

logs: ## Tail container logs
	docker compose logs -f

graph: ## Start the decision graph viewer (GRAPH_PORT=3001 make graph)
	GRAPH_PORT=$(or $(GRAPH_PORT),3000) docker compose up --build -d graph
	@echo "Decision graph viewer at http://localhost:$(or $(GRAPH_PORT),3000)"

# --- Database ---

setup: ## Create database and run migrations (first-time setup)
	docker compose exec app mix ecto.create
	docker compose exec app mix ecto.migrate

migrate: ## Run pending migrations
	docker compose exec app mix ecto.migrate

backup: ## Backup the database to backups/
	@mkdir -p backups
	docker compose exec db pg_dump -U postgres big_bill_dev > backups/backup_$$(date +%Y%m%d_%H%M%S).sql
	@echo "Backup saved to backups/"

# --- Shell access ---

iex: ## Open an IEx shell on the running app container
	docker compose exec app iex -S mix

shell: ## Open a bash shell inside the app container
	docker compose exec app /bin/bash

# --- Code quality (local) ---

compile: ## Compile with warnings-as-errors
	mix compile --warnings-as-errors

test: ## Run the test suite
	mix compile --warnings-as-errors && mix test

format: ## Format the project
	mix format

credo: ## Run credo in strict mode
	mix credo --strict

dialyzer: ## Run dialyzer for static analysis
	mix dialyzer

quality: ## Compile, credo, test, dialyzer, format
	@failed=0; \
	echo "==> Compiling (warnings-as-errors)..."; \
	mix compile --warnings-as-errors || failed=1; \
	echo "==> Running credo --strict..."; \
	mix credo --strict || failed=1; \
	echo "==> Running tests..."; \
	mix test || failed=1; \
	echo "==> Running dialyzer..."; \
	mix dialyzer || failed=1; \
	echo "==> Formatting..."; \
	mix format || failed=1; \
	if [ $$failed -ne 0 ]; then echo "==> Some checks failed."; exit 1; else echo "==> All checks passed."; fi
