# Spec: Session Detail LiveView

Status: Proposed
Owner: nigel.stuke@upstart.com
Last updated: 2026-05-07
Scope: Adds a per-session drill-down page to the Sardine Run observability
dashboard. This is a feature spec; the service-level contract continues to
live in `/SPEC.md`.

## 1. Objective

Give a Sardine Run operator a single page that answers "what is this agent
doing right now?" for one issue at a time.

The existing dashboard at `/` lists all running and retrying issues. From
each row the operator should be able to drill into a detail page that
surfaces the runtime artifacts only Sardine Run has access to:

- Live agent state (turn, last event, tokens, runtime) — already in the
  orchestrator's in-memory snapshot.
- Workspace git log (`git -C <workspace> log --oneline -10`) — the agent's
  git activity inside its workspace.
- The tail of `log/sardine-run.log.*` filtered to lines tagged with this
  `issue_identifier`.
- `notes.md` from the traffic-control state-repo, rendered as monospace
  plain text.
- The resolved on-disk paths for the cross-tool view (`session.yaml`,
  `notes.md`, `links.yaml`, workspace path).

Out of scope: writes, comment posting, retry triggers, log search across
issues, multi-issue diffing, post-mortem rendering of issues no longer in
the orchestrator snapshot.

### Why this lives in Sardine Run

Logs and workspaces are runtime artifacts owned by the agent process that
produced them. Traffic Control sees session yaml/notes/links but cannot see
`log/sardine-run.log.*` or the workspace git tree. The operator's "what is
this agent doing right now?" question therefore lands here, not in
Traffic Control.

## 2. Route, params, and dashboard integration

| Item | Decision |
|---|---|
| Route | `live("/session/:issue_identifier", SessionDetailLive, :show)` |
| Param | `:issue_identifier` (matches the existing `/api/v1/:issue_identifier` convention; resolves to the orchestrator entry's `identifier` and to `<state_repo>/sessions/<identifier>/`) |
| Drill-down link | The Running and Retrying tables in `DashboardLive` gain a "View session" link per row pointing at `/session/<entry.issue_identifier>`. The existing "JSON details" link is preserved. |
| Live updates | The detail LiveView subscribes to `SardineRunWeb.ObservabilityPubSub` (same channel `DashboardLive` uses). The runtime/turn counter updates on the same one-second tick `DashboardLive` already schedules. |

### Not-found behavior

If `Orchestrator.snapshot/2` returns no entry with this `issue_identifier`
in either `running` or `retrying`, the page renders a "session not active"
state with a link back to `/`. Same contract as the existing
`/api/v1/:issue_identifier` 404 path. We do not attempt to render
historical artifacts for cleaned-up sessions in this iteration.

## 3. Page sections

The page renders five sections, top to bottom, in `~H` heredoc style
matching `DashboardLive`. Reuse `dashboard.css` classes (`section-card`,
`code-panel`, `metric-card`, etc.).

1. **Header** — issue identifier, current status badge (running/retrying),
   workspace host, link back to `/`.
2. **Live agent state** — runtime, turn count, last event + last message,
   last event timestamp, token totals (in / out / total), retry attempt and
   due-at when retrying. Source: same projection used by
   `Presenter.issue_payload/3`.
3. **Workspace git log** — last 10 commits, one per line, oneline format.
4. **Recent log lines** — last N (default 200) lines from
   `log/sardine-run.log.*` whose payload contains the `issue_identifier`.
   Newest at the bottom, monospace, scrollable.
5. **notes.md** — full file contents rendered inside a `<pre>` block. No
   markdown processing.
6. **On-disk paths** — three plain-text rows showing the absolute paths to
   `session.yaml`, `notes.md`, `links.yaml` under the resolved
   `state_repo`, plus the workspace path. No clickable file:// links.

Empty/error sub-states for each section:
- Workspace dir missing: "workspace not present" message.
- `git` exits non-zero or repo not initialized: "no git history" message,
  do not render stderr.
- Log file missing or unreadable: "no log entries" message.
- `notes.md` missing: "no notes" message.
- `state_repo` not configured (`tracker.kind: memory`): the on-disk paths
  section is hidden; the notes block reads "notes unavailable in memory
  tracker mode".

## 4. Data sources and module touch points

The spec is declarative; the implementation may shape modules differently
provided the contract holds.

| Datum | Source |
|---|---|
| Live agent state | `SardineRun.Orchestrator.snapshot/2` (already exposed via `Presenter.issue_payload/3`) |
| Workspace path | Orchestrator entry's `workspace_path`, falling back to `Path.join(Config.settings!().workspace.root, issue_identifier)` |
| Git log | Shell out: `git -C <workspace> log --pretty=format:%h %s --max-count=10`. Hard 5-second timeout. Never run if workspace dir is missing. |
| Log tail | Shell out: `tail -c 5242880 <log_file>` to read at most the last 5 MiB of the active log file (path from `SardineRun.LogFile.default_log_file/0`); filter matching lines containing the `issue_identifier`; keep the last 200 matches. Avoids loading the full file into memory. Hard 5-second timeout. |
| `notes.md` | Read directly from `<state_repo>/sessions/<issue_identifier>/notes.md` via `SardineRun.TrafficControl.Adapter.resolve_state_repo/0`. No new traffic-control adapter API required. |
| On-disk paths | Computed from the same `resolve_state_repo/0` plus the workspace path. |

New modules (suggested, non-binding):

- `SardineRunWeb.SessionDetailLive` — the LiveView (mount, handle_info,
  render, runtime tick).
- `SardineRunWeb.SessionDetailPresenter` — pure functions that build the
  payload from snapshot + filesystem reads. Mirrors the role of
  `SardineRunWeb.Presenter`. All filesystem reads go through this module
  so the LiveView module stays free of side effects beyond the presenter
  call.

## 5. Project structure (new and changed files)

New:

- `elixir/lib/sardine_run_web/live/session_detail_live.ex`
- `elixir/lib/sardine_run_web/session_detail_presenter.ex`
- `elixir/test/sardine_run_web/live/session_detail_live_test.exs`
- `elixir/test/sardine_run_web/session_detail_presenter_test.exs`
- `docs/session-detail-liveview.md` (this file)

Changed:

- `elixir/lib/sardine_run_web/router.ex` — add the live route.
- `elixir/lib/sardine_run_web/live/dashboard_live.ex` — add "View session"
  links in the Running and Retrying row markup. No other behavior change.
- `elixir/lib/sardine_run_web/static_assets.ex` / `dashboard.css` — only
  if a small handful of new utility classes are needed; reuse existing
  classes wherever possible.
- `README.md` (elixir/) and `../README.md` — note the new route under
  observability.
- `WORKFLOW.md` — no change; the route is not configurable in this
  iteration.
- `SPEC.md` — no change; this is a UI surface, not part of the tracker
  contract or the dynamic tool surface.

## 6. Code style and conventions

- Public `def` in `lib/` requires a `@spec`. Enforced by `mix specs.check`.
- Config access through `SardineRun.Config`; no ad-hoc `System.get_env/1`
  in the new modules.
- Filesystem reads go through `SardineRun.TrafficControl.Adapter.resolve_state_repo/0`
  for the state-repo paths and through `SardineRun.PathSafety` if any path
  is derived from user input. The `:issue_identifier` from the URL must
  pass a strict allow-list match (`~r/\A[A-Za-z0-9._-]+\z/`, the same
  pattern used by `SessionWriter`) before being joined into a path or
  passed to `git`. Reject (404) on mismatch.
- Shell-outs use `System.cmd/3` with explicit args (no shell interp), a
  hard `:stderr_to_stdout` capture, and a process-level timeout.
- Templates use inline `~H` heredocs in the LiveView, matching the
  existing `DashboardLive` style.

## 7. Testing strategy

Unit tests (presenter):

- Builds a complete payload from a synthetic snapshot containing the
  identifier in `running`.
- Same, but identifier in `retrying` only.
- Returns the not-found shape when the identifier is in neither list.
- Workspace-missing path produces the "workspace not present" sub-state.
- Log-file-missing path produces an empty log section without raising.
- `notes.md` missing produces an empty notes section without raising.
- `tracker.kind: memory` (no state_repo) hides on-disk paths and notes.
- Rejects an `issue_identifier` that fails the allow-list pattern.

LiveView tests (`Phoenix.LiveViewTest`):

- Mount with a valid identifier renders the header, all five sections,
  and the back link.
- Mount with an unknown identifier renders the not-found state and a
  link back to `/`.
- A `:observability_updated` PubSub broadcast triggers a re-render and
  the live agent state values reflect the new snapshot.
- A `:runtime_tick` updates the runtime counter without re-fetching the
  full snapshot.

Dashboard regression test:

- Each Running and Retrying row in `DashboardLive` renders a "View
  session" link with `href="/session/<identifier>"`.

Test data:

- All tests use the `memory` tracker. No live E2E coverage in this
  feature; existing `SARDINE_RUN_LIVE_E2E=1` suite is untouched.
- For the log-tail test, write a temporary log file with a mix of
  matching and non-matching lines and assert filtering and ordering.
- For the git-log test, initialize a tmp git repo with a couple of
  commits and assert the rendered output.

## 8. Acceptance criteria

The change is shippable when all of the following hold:

- `make all` (setup, build, fmt-check, lint, coverage, dialyzer) passes.
- `mix test` passes including new tests.
- Manual: with `./bin/sardine-run --port 4000 ./WORKFLOW.md` running
  against a populated state-repo, navigating from a dashboard row to its
  "View session" link renders all five sections with live data.
- Manual: hitting `/session/<unknown>` renders the not-found state.
- Manual: tail and git-log sections degrade cleanly when their sources
  are missing (no 500, no stack traces in the page).
- README.md (root) and elixir/README.md mention the new route.

## 9. Boundaries

Always:
- Validate `:issue_identifier` against the SessionWriter allow-list before
  any path join or shell-out.
- Run `git` with `git -C <workspace>` and an absolute workspace path that
  is verified to live under `Config.settings!().workspace.root` via
  `SardineRun.PathSafety`.
- Cap the log scan size and the rendered line count.
- Reuse existing CSS and the existing PubSub channel.

Ask first:
- Adding a markdown rendering dependency (earmark / html_sanitize_ex).
  Default in this spec is plain `<pre>`.
- Exposing a parallel JSON endpoint at `/api/v1/:issue_identifier/detail`.
  Default in this spec is LiveView only.
- Rendering historical artifacts for sessions no longer in the snapshot.
  Default in this spec is 404.
- Any change to `SPEC.md`, `WORKFLOW.md`, or the tracker contract.
  This feature does not require any.

Never:
- Run shell commands using user-supplied path components without the
  allow-list match.
- Read files outside `state_repo/sessions/<identifier>/` or the workspace
  for this session.
- Mutate session state from this view (no writes, no traffic-control
  updates, no orchestrator commands).
- Skip pre-commit hooks or bypass `mix specs.check`.

## 10. Open questions

None at spec-acceptance time. Anything that surfaces during build will be
recorded here in a follow-up commit before implementation continues.
