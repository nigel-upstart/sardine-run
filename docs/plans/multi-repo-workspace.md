# Multi-repo workspace seeding

## Problem

Sardine Run sessions target many different GitHub repos (notifichain, void,
traffic-control, …) but the orchestrator was leaving each per-session workspace
empty and asking the Codex agent to `git clone` from inside a `workspace-write`
sandbox with `networkAccess=false`. That fails predictably:

- DNS resolution for `github.com` is blocked inside the sandbox.
- Some `.git` writes are reported as `Operation not permitted`.
- A handful of older workspaces had been pre-seeded with `openai/symphony`
  (the repo's former name) and were never cleaned up, so agents landed on a
  clone of the *wrong* repo and had no recourse.

Two recent sessions (`4e5bf1ec` for `teamupstart/notifichain`, `c4d6a8e0` for
`teamupstart/void`) ended up `waiting / external` for exactly these reasons.

## Decision

Move repo seeding into the host process (`after_create` hook), keep the Codex
turn sandbox locked down (no extra network), and refuse rather than guess when
the session data is ambiguous.

## Implementation

1. **`elixir/scripts/seed-workspace.sh`** — new host-side script. Resolves the
   target repo from `links.yaml` (`kind: repo` → `kind: pr`) then `session.yaml`
   `cwd:`. Clones via SSH and checks out `session.branch`. Refuses on multi-repo
   ambiguity, on stale `openai/symphony` clones, and when the workspace already
   contains an unrelated remote.
2. **`elixir/WORKFLOW.md`** — `after_create` calls the script. Drops the
   `turn_sandbox_policy:` override so the Elixir default applies (workspace-only
   writes, full read access, no network). Prompt body updated: agent assumes the
   workspace is already seeded and stops/`waiting` instead of trying to clone.
3. **`SPEC.md` §9.6** — documents the seeder contract (priority, refusal cases,
   placement outside the sandbox).

## Out of scope (tracked separately)

- Enabling `networkAccess: true` inside the Codex turn sandbox so agents can hit
  GitHub directly (PR creation via `gh`, `git push`). Tracked as a follow-up.
- Auto-healing of `:wrong_repo` workspaces. For now we surface the error and
  the operator removes the directory manually.
- Shared repo cache / git worktrees per session for disk efficiency.

## Migration

- Wipe per-session workspace directories whose `origin` points at the legacy
  `openai/symphony` URL. Listed and removed via a one-shot script after
  operator confirmation. Traffic-control state is not touched.
- Reset the two stuck sessions (`4e5bf1ec`, `c4d6a8e0`) by clearing their
  `waiting` block so the next polling tick re-dispatches them through the
  new seeder.
