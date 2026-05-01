# Sardine Run Elixir

This directory contains the Elixir agent orchestration service that polls a Traffic Control
state-repo, creates per-session workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).

## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SardineRun.Workflow` and
  `SardineRun.Config`.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter intended behavior, update the spec in the same
    change so the spec stays current.
- Prefer adding config access through `SardineRun.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run a Codex turn in the source repo cwd.
  - Workspaces must stay under `workspace.root`.
- Tracker reads/writes go through `SardineRun.Tracker` (Traffic Control filesystem adapter by
  default; in-process memory adapter for tests).
- Agent session writes go through `SardineRun.TrafficControl.SessionWriter`, exposed to Codex via
  the `sardine_run_session` dynamic tool in `SardineRun.Codex.DynamicTool`.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and
  cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/sardine_run/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
- `../SPEC.md` for spec-level changes (tracker contract, dynamic tool surface, etc.).
