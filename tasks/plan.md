# Implementation Plan: Needs-Attention Triage + SR Session Detail

Spec: `docs/plans/needs-attention-triage.md`
Last updated: 2026-05-07

This plan supersedes the prior "Session Detail LiveView" plan; that work is
now Slice C below. Every prior task (T1–T6) is preserved as C1–C6.

## Overview

Three concurrent threads of work, one combined PR set:

1. **TC triage view + schema** (Python / FastAPI / Jinja, `traffic-control`).
2. **SR per-session LiveView** (Elixir / Phoenix LiveView, `sardine-run`).
3. **Cross-link wiring** between the two dashboards via a new
   `dashboard_url` field on `SardineRunRuntime`.

## Architecture decisions

- Triage view lives in TC dashboard (always-on, tool-agnostic).
- SR exposes a real LiveView at `/session/:issue_identifier` (own module,
  own `mount/3`).
- TC discovers SR via runtime payload (`session.sardine_run.dashboard_url`),
  not config. Button only renders when the field is populated.
- Schema is backwards compatible — new field is optional.
- Identifier validation is the security gate for all SR per-session reads
  (allow-list `~r/\A[A-Za-z0-9._-]+\z/`).

## Dependency graph

```
A: schema.dashboard_url (TC)
   ├── D: SR populates/clears dashboard_url
   │      └── E: TC "Open in Sardine Run" button
   └── (no other consumers)

B: TC "Needs your attention" section (TC)              [independent]

C1: identifier validation + presenter skeleton (SR)
    └── C2: route + LiveView + live-state + 404 (SR)
            ├── C3: workspace git log section (SR)     [parallel C3/C4/C5]
            ├── C4: log-tail section (SR)
            ├── C5: notes.md + on-disk paths (SR)
            └── C6: dashboard drill-down links (SR)

F: docs sweep — after all of the above
```

Parallel-safe at the start: **A, B, C1** (different repos for C1 vs A/B;
different files within TC for A vs B).

## Phase 1 — Foundations (parallel)

### Task A — Add `dashboard_url` to `SardineRunRuntime`
**Repo:** traffic-control. **Scope:** XS.
- Add `dashboard_url: str | None = None` field.
- Round-trip serialization test (set + unset).
- Verify: `cd packages/schema && uv run pytest`; storage tests still pass.
- Files: `packages/schema/src/schema/session.py`, schema tests.

### Task B — TC "Needs your attention" section
**Repo:** traffic-control. **Scope:** M.
- New section above fleet table on `/`.
- Filter: `status=waiting AND waiting.kind=external`, sort by
  `waiting.requested_at` ascending.
- Row: ID, title (linked to `/sessions/{id}`), waiting note (≤140 chars),
  age (bold > 24h), tool badge.
- Tool badge: `sardine_run.agent_id` set → `sardine-run`; else
  `metadata.tool == "claude-code"` → `claude-code`; else `manual`.
- Empty state: "No sessions waiting on you. Nice."
- Files: `apps/dashboard/src/dashboard/routes/home.py`,
  `apps/dashboard/src/dashboard/templates/home.html`, helper for age
  formatting if not present, `apps/dashboard/tests/test_routes.py` +
  fixtures.
- Verify: `cd apps/dashboard && uv run pytest -k attention`; manual load
  of `/`.

### Task C1 — Identifier validation + `SessionDetailPresenter` skeleton
**Repo:** sardine-run. **Scope:** S.
- `SardineRunWeb.SessionDetailPresenter` with:
  - `validate_identifier/1` — allow-list `~r/\A[A-Za-z0-9._-]+\z/`,
    returns `{:ok, id}` | `{:error, :invalid_identifier}`.
  - `payload/3` — `(identifier, snapshot, filesystem)` → `{:ok, %{...}}`
    | `{:error, :not_found}`. Initial fields: header + live-state only.
- All public defs `@spec`'d.
- No filesystem reads yet.
- Files: `lib/sardine_run_web/session_detail_presenter.ex` (new), test.
- Verify: `mix test test/sardine_run_web/session_detail_presenter_test.exs`,
  `mix specs.check`, `mix lint`.

### Checkpoint 1
- [ ] A, B, C1 merged.
- [ ] `make all` green (SR), `uv run pytest` green (TC).
- [ ] Manual: TC fleet shows triage section; SR test suite passes.

## Phase 2 — SR slice 1 end-to-end

### Task C2 — Route + `SessionDetailLive` + live-state + 404
**Repo:** sardine-run. **Scope:** M.
- `live "/session/:issue_identifier", SessionDetailLive, :show` in browser
  pipeline.
- Mount: validate identifier → fetch snapshot → render header + live-state
  (runtime, turns, last event, last message, tokens, retry attempt).
- Subscribe to `SardineRunWeb.ObservabilityPubSub`; re-render on
  `:observability_updated`.
- `:runtime_tick` updates the runtime counter without re-fetching the
  snapshot.
- Unknown / invalid identifier → not-found page (200, not 500), back-link
  to `/`.
- Files: `lib/sardine_run_web/router.ex`,
  `lib/sardine_run_web/live/session_detail_live.ex` (new),
  `lib/sardine_run_web/session_detail_presenter.ex`,
  `test/sardine_run_web/live/session_detail_live_test.exs` (new),
  presenter test.
- Verify: LiveView mount tests (known/unknown/invalid id); PubSub
  re-render test; manual smoke.

### Checkpoint 2
- [ ] C2 merged. SR per-session route loads end-to-end.
- [ ] Identifier-injection cases (`../etc`, `a/b`, `a b`) all rejected
      in tests.

## Phase 3 — SR section slices (parallelizable)

### Task C3 — Workspace git log section
**Repo:** sardine-run. **Scope:** S–M.
- Presenter helper: `git -C <workspace_path> log --pretty=format:"%h %s"
  --max-count=10` via `System.cmd/3`, `stderr_to_stdout: true`, 5s
  timeout.
- `PathSafety` containment check before any shell-out.
- Empty / git error → "no git history". Missing dir → "workspace not
  present". Out-of-root → never executed.
- Files: presenter, LiveView render, two test files.
- Verify: tmp-repo presenter test (happy + error paths); LiveView render
  test.

### Task C4 — Filtered log-tail section
**Repo:** sardine-run. **Scope:** S–M.
- Presenter helper: `tail -c 5242880 <log_file>` (cap at 5 MiB), filter
  for identifier substring (validated allow-list), keep last 200 matches,
  newest at bottom. 5s timeout.
- Missing file / tail failure / timeout → "no log entries", no stack
  trace, no leaked stderr.
- Files: presenter, LiveView render, two test files.
- Verify: tmp-log presenter test (ordering, cap, missing file); LiveView
  render test.

### Task C5 — `notes.md` + on-disk paths section
**Repo:** sardine-run. **Scope:** S–M.
- Presenter helper resolves
  `<state_repo>/sessions/<identifier>/notes.md` via the existing
  `TrafficControl.Adapter.resolve_state_repo/0`.
- Renders notes inside `<pre>` (Phoenix auto-escapes via `~H`).
- On-disk paths block: `session.yaml`, `notes.md`, `links.yaml`,
  workspace path. Hidden when `tracker.kind: memory`.
- Files: presenter, LiveView render, two test files.
- Verify: presenter tests for present/missing/memory cases; LiveView
  render test.

### Checkpoint 3
- [ ] C3 + C4 + C5 merged. All five sections visible for live issue.
- [ ] Degraded states (missing workspace, missing notes, missing log)
      verified.
- [ ] Presenter branch coverage materially complete.

## Phase 4 — SR drill-down + cross-link wiring (parallel)

### Task C6 — Dashboard drill-down links
**Repo:** sardine-run. **Scope:** S.
- Each Running and Retrying row in `DashboardLive` gets `View session →`
  link to `/session/<identifier>`.
- Existing JSON details link preserved.
- Files: `lib/sardine_run_web/live/dashboard_live.ex`, regression test.

### Task D — SR populates `dashboard_url`
**Repo:** sardine-run. **Scope:** M. **Depends on:** A merged.
- On dispatch, write `dashboard_url = "http://<host>:<port>"` via
  `SessionWriter` for the active session.
- Hostname source: `SARDINE_RUN_PUBLIC_HOSTNAME` env > `:inet.gethostname/0`.
- Port: configured server port. If dashboard disabled, never write.
- On orderly shutdown (`terminate/2`), nil the field for every active
  session.
- Files: `lib/sardine_run/orchestrator.ex`,
  `lib/sardine_run/traffic_control/session_writer.ex` (if signature
  needs the new field), `lib/sardine_run/config.ex` (public hostname
  getter), tests.

### Task E — TC "Open in Sardine Run" button
**Repo:** traffic-control. **Scope:** S. **Depends on:** A merged.
- On `/sessions/{id}`, render button when
  `session.sardine_run.dashboard_url` is non-empty:
  `{dashboard_url}/session/{issue_identifier}`.
- `target="_blank" rel="noopener noreferrer"`.
- Omit entirely when null.
- Files: `apps/dashboard/src/dashboard/templates/session_detail.html`,
  `apps/dashboard/tests/test_routes.py`.

### Checkpoint 4
- [ ] C6, D, E merged. End-to-end mutual deep-link verified.
- [ ] SR shutdown clears the field; TC button vanishes on next reload.

## Phase 5 — Docs

### Task F — Documentation sweep
**Scope:** S.
- `traffic-control/README.md` — describe new fleet section.
- `sardine-run/README.md` and `sardine-run/elixir/README.md` — document
  `/session/:issue_identifier`, `dashboard_url` field,
  `SARDINE_RUN_PUBLIC_HOSTNAME` env var.
- `sardine-run/SPEC.md` — add `dashboard_url` to runtime contract,
  declare `/session/:issue_identifier` as canonical deep-link path.
- Verify: human read.

### Checkpoint 5 — Done
- [ ] All acceptance criteria from `docs/plans/needs-attention-triage.md`
      met.
- [ ] PRs opened in both repos with the spec linked.
- [ ] `mix pr_body.check` clean for the SR PR.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| URL-injected identifier reaches `git`, `Path.join`, `File.read!` | High | `validate_identifier/1` allow-list at LiveView entry; tests assert dot-dot, slash, whitespace rejection |
| Shell-out to `git` hangs on corrupt repo / network FS | Med | 5s hard timeout; degrade to "no git history" |
| Log scanning scales with disk size | Med | `tail -c 5242880` partial read + 200-line cap + 5s timeout |
| `notes.md` contains hostile content rendered as raw HTML | Med | Render in `<pre>`, Phoenix auto-escapes via `~H`; no markdown rendering this iteration |
| Hostname resolution returns unreachable address | Med | `SARDINE_RUN_PUBLIC_HOSTNAME` override; document fallback chain |
| Stale `dashboard_url` after hard kill | Low | Spec accepts; user gets connection-refused, not corrupted state |
| Existing session.yaml files break on schema change | High | New field optional with default `None`; round-trip test |
| Workspace path falls outside `workspace.root` (mis-config) | Med | `PathSafety` containment check before any read or shell-out |

## Parallelization

- **Phase 1:** A ‖ B ‖ C1 (separate worktrees / repos).
- **Phase 3:** C3 ‖ C4 ‖ C5 (touch the same two SR files; safe to
  parallelize only if conflicts are resolved by a single merger or done
  sequentially in one worktree).
- **Phase 4:** C6 ‖ D ‖ E (D and E both depend on A; C6 is independent).

## Open questions

None at plan acceptance. Append here on surprise.
