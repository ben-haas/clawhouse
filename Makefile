.PHONY: help typecheck smoke check local-up local-down provision create-instance terminal-url dashboard-url

COUNT ?= 2

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-20s %s\n", $$1, $$2}'

typecheck: ## Run TypeScript type-checking
	npm run typecheck

smoke: ## Run provision script smoke test
	npm run smoke:provision-script

check: typecheck smoke ## Run all checks (typecheck + smoke)

local-up: ## Start local demo (COUNT=2)
	./scripts/local-up.sh $(COUNT)

local-down: ## Tear down local demo
	./scripts/local-down.sh

provision: ## Provision server (requires sudo)
	sudo ./scripts/provision-host.sh

create-instance: ## Create instance (ID=name)
	@test -n "$(ID)" || (echo "Usage: make create-instance ID=alice" >&2; exit 1)
	sudo ./scripts/create-instance.sh $(ID)

terminal-url: ## Print terminal URL (ID=name)
	@test -n "$(ID)" || (echo "Usage: make terminal-url ID=alice" >&2; exit 1)
	./scripts/terminal-url.sh $(ID)

dashboard-url: ## Print dashboard URL (ID=name)
	@test -n "$(ID)" || (echo "Usage: make dashboard-url ID=alice" >&2; exit 1)
	./scripts/dashboard-url.sh $(ID)
