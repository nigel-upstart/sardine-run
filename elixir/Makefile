.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage: SHELL := /bin/bash
coverage:
	@mkdir -p cover
	# `coverage.gate` is the per-module enforcement; this target captures the
	# summary table for it. A pre-existing flake in dynamic_tool_test git
	# workspace setup makes `mix test --cover` fail ~5-20% of runs, so retry
	# once before propagating failure.
	@set -o pipefail; $(MIX) test --cover 2>&1 | tee cover/summary.txt || \
		( echo "==> mix test --cover failed once, retrying..."; \
		  set -o pipefail; $(MIX) test --cover 2>&1 | tee cover/summary.txt )
	$(MIX) coverage.gate

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SARDINE_RUN_LIVE_E2E=1 $(MIX) test test/sardine_run/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
