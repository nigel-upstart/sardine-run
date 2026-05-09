# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Sardine Run is an Elixir/OTP service that polls a [Traffic Control](https://github.com/nigel-upstart/traffic-control) state-repo for sessions, creates per-session workspaces, and runs Codex in app-server mode inside each workspace. The specification is in `SPEC.md`; the Elixir reference implementation lives under `elixir/`.

Traffic Control is a local filesystem directory (not an API or cloud service). All session reads and writes go through the filesystem under `$TRAFFIC_CONTROL_STATE_REPO` (default `~/code/traffic-control-state`).

## Commands (run from `elixir/`)

```bash
mise install              # install Elixir/Erlang via mise
mix setup                 # fetch deps
mix build                 # build escript binary → elixir/bin/sardine-run
mix test                  # run all tests
mix test <path>           # run a single test file
mix format                # format code
mix format --check-formatted  # check formatting (used in CI)
mix lint                  # Credo strict + specs check
mix specs.check           # enforce public @spec in lib/
mix test --cover          # test coverage
mix dialyzer              # type analysis
make all                  # full gate: setup, build, fmt-check, lint, coverage, dialyzer
make e2e                  # live E2E test (requires SARDINE_RUN_LIVE_E2E=1)
```

Running the binary:

```bash
./bin/sardine-run --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
./bin/sardine-run --port 4000 ./WORKFLOW.md   # also start LiveView dashboard
```

## Architecture

The Elixir implementation maps directly to the spec's component model:

| Module | Role |
|---|---|
| `SardineRun.CLI` | Entry point; parses CLI flags, starts OTP application |
| `SardineRun.Workflow` | Loads and parses `WORKFLOW.md` (YAML front matter + prompt body) |
| `SardineRun.WorkflowStore` | GenServer that watches `WORKFLOW.md` for changes and reloads without restart |
| `SardineRun.Config` | Typed getters over workflow config; handles `~` expansion and `$VAR` resolution |
| `SardineRun.Orchestrator` | GenServer owning all scheduling state: polling tick, dispatch, reconciliation, retry queue, token totals |
| `SardineRun.AgentRunner` | Spawned per-session; builds prompt, runs Codex turns, emits events back to the orchestrator |
| `SardineRun.Workspace` | Workspace path derivation, directory creation, lifecycle hooks |
| `SardineRun.Tracker` | Behaviour + dispatch; delegates to `TrafficControl.Adapter` or `Tracker.Memory` |
| `SardineRun.TrafficControl.Adapter` | Reads `sessions/*/session.yaml` from the state repo |
| `SardineRun.TrafficControl.SessionWriter` | Atomic writes to `session.yaml`, `notes.md`, `links.yaml` |
| `SardineRun.Codex.AppServer` | Codex app-server subprocess client (stdio transport) |
| `SardineRun.Codex.DynamicTool` | Implements the `sardine_run_session` tool advertised to every Codex session |
| `SardineRun.PathSafety` | Invariant enforcement: workspace path must stay inside workspace root |
| `SardineRun.PromptBuilder` | Liquid-template rendering of `WORKFLOW.md` body with `issue` and `attempt` vars |
| `SardineRun.HttpServer` | Optional Phoenix/Bandit HTTP server (enabled via `--port` or `server.port`) |
| `SardineRun.StatusDashboard` | Terminal/LiveView dashboard state |
| `SardineRun.LogFile` | Structured rotating log to `log/sardine-run.log.*` |
| `SardineRunWeb.*` | Phoenix LiveView dashboard and JSON REST API (`/api/v1/state`, `/api/v1/:id`, `POST /api/v1/refresh`) |

## Key Conventions

- **Config access**: Always go through `SardineRun.Config`; no ad-hoc `System.get_env/1` calls in business logic.
- **Tracker writes**: Only via `SardineRun.TrafficControl.SessionWriter` (routed through the `sardine_run_session` dynamic tool).
- **Workspace safety**: `PathSafety` enforces that workspaces stay under `workspace.root`. Codex always runs with `cwd = workspace_path`, never the source repo.
- **Public specs**: Every public `def` in `lib/` needs a `@spec`. `@impl` callbacks are exempt. Enforced by `mix specs.check`.
- **Tests**: Use the `memory` tracker (`tracker.kind: memory`) for deterministic unit tests. Live E2E tests use `SARDINE_RUN_LIVE_E2E=1`.
- **Logging**: Follow `docs/logging.md`; session-related log lines must include `issue_id` and `issue_identifier`; agent session lines must include `session_id`.

## Spec Alignment

The implementation must not conflict with `SPEC.md`. The implementation may be a superset. Meaningful behavior changes require updating `SPEC.md` in the same PR.

## Docs Update Policy

When behavior or config changes, update in the same PR:
- `README.md` (elixir implementation details)
- `../README.md` (project-level concept)
- `WORKFLOW.md` (workflow/config contract)
- `../SPEC.md` (tracker contract, dynamic tool surface, etc.)

## PR Requirements

PR body must follow `.github/pull_request_template.md`. Validate locally with:

```bash
mix pr_body.check --file /path/to/pr_body.md
```
