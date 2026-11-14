.PHONY: help build test test-adv demo e2e check-ci verify ci query path explain graph-update bugs dashboard dashboard-serve debug-test clean
.DEFAULT_GOAL := help

ZIG ?= zig
PYTHON ?= python3

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build ReleaseSafe binary to zig-out/bin/zigpod
	$(ZIG) build -Doptimize=ReleaseSafe

test: ## Run all unit and integration tests
	$(ZIG) build test

test-adv: ## Run security & hardening gates (requires zig)
	./scripts/security-check.sh --require-zig

demo: ## Run built-in 18-case fail-closed enforcement demo
	$(ZIG) build run -- demo

e2e: ## Run end-to-end smoke, hardening, and audit-tamper verification
	sh ./scripts/smoke.sh

check-ci: ## Check CI, Makefile, CLI, vault, and README parity
	$(PYTHON) ./scripts/check-ci-parity.py

graph-update: ## Rebuild offline knowledge graph index (.zig-cache/knowledge-graph.json)
	$(PYTHON) ./scripts/graph-query.py update

query: ## Search knowledge graph (usage: make query Q=memory)
	@test -n "$(Q)" || (echo "Usage: make query Q=<term>" >&2; exit 2)
	$(PYTHON) ./scripts/graph-query.py query "$(Q)"

path: ## Find shortest knowledge path (usage: make path A=BUG-002 B=cli.zig)
	@test -n "$(A)" && test -n "$(B)" || (echo "Usage: make path A=<src> B=<dst>" >&2; exit 2)
	$(PYTHON) ./scripts/graph-query.py path "$(A)" "$(B)"

explain: ## Inspect a node and its citations (usage: make explain NODE=verifyAuditFile)
	@test -n "$(NODE)" || (echo "Usage: make explain NODE=<id-or-symbol>" >&2; exit 2)
	$(PYTHON) ./scripts/graph-query.py explain "$(NODE)"

bugs: ## Show terminal bug & security dashboard
	$(PYTHON) ./scripts/bug-dashboard.py summary

dashboard: ## Generate Obsidian Bug-Dashboard.md and HTML dashboard
	$(PYTHON) ./scripts/bug-dashboard.py generate

dashboard-serve: ## Serve interactive web bug dashboard on http://127.0.0.1:8765
	$(PYTHON) ./scripts/bug-dashboard.py serve

debug-test: ## Run Zig test binary directly for detailed diagnostics
	$(ZIG) test src/main.zig

verify: test test-adv build demo e2e check-ci graph-update ## Run full local verification suite

ci: verify ## Run all CI checks including static audit gate
	./scripts/auto-audit.sh

clean: ## Remove build artifacts and cached graph index
	rm -rf zig-out .zig-cache
