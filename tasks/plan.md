# Implementation Plan: Session Detail LiveView

Spec: `docs/session-detail-liveview.md`
Status: Ready for review
Last updated: 2026-05-07

## Overview

Add a per-session drill-down route at `/session/:issue_identifier` to the
Sardine Run observability dashboard. Each page surfaces five sections —
live agent state, workspace git log, filtered log tail, `notes.md`, and
on-disk paths — for one issue tracked by the running orchestrator.

We slice vertically: every task leaves a route the operator can navigate
to and that is fully tested. The first slice ships the route end-to-end
with only the live-state section. Subsequent slices add one section at a
time. The dashboard drill-down link and docs land last.

## Architecture decisions

- **One LiveView module, one presenter module.** `SessionDetailLive` owns
  mount/handle_info/render. `SessionDetailPresenter` owns all data
  shaping and all filesystem reads. Mirrors the
  `DashboardLive` / `Presenter` split already in the codebase.
- **Inline `~H` heredoc templates** matching `DashboardLive`, no separate
  `.heex` files. Reuse existing `dashboard.css` classes.
- **Reuse the existing PubSub channel** (`SardineRunWeb.ObservabilityPubSub`)
  and `:runtime_tick` cadence. No new pubsub topics, no new GenServers.
- **Identifier validation gate is the foundation.** A single
  `validate_identifier/1` helper is the only allow-listed entry point for
  the URL parameter; every section that joins paths or shells out must
  call it first. Lives in the presenter so unit tests stay simple.
- **Filesystem reads are pure functions taking a "filesystem-like" map of
  paths**, not implicit `File.read!` calls. Lets the presenter tests
  point at tmp dirs and hit real disk without mocks.
- **404 path goes through the same render module**, not a separate
  controller. Matches Phoenix LiveView convention and keeps behavior
  consistent with the existing `/api/v1/:issue_identifier` 404 contract.

## Dependency graph

```
            ┌──────────────────────────────────┐
            │ T1  identifier validation +      │
            │     SessionDetailPresenter skel  │
            └───────────────┬──────────────────┘
                            │
            ┌───────────────▼──────────────────┐
            │ T2  Route + LiveView + live      │
            │     agent state section + 404    │
            └───────────────┬──────────────────┘
                            │
   ┌────────────────────────┼─────────────────────────┐
   │                        │                         │
┌──▼──────────────┐  ┌──────▼─────────────┐  ┌───────▼────────────┐
│ T3 git log      │  │ T4 log tail        │  │ T5 notes.md +      │
│ section         │  │ section            │  │    on-disk paths   │
└──┬──────────────┘  └──────┬─────────────┘  └───────┬────────────┘
   │                        │                        │
   └────────────────────────┼────────────────────────┘
                            │
            ┌───────────────▼──────────────────┐
            │ T6  Dashboard drill-down links + │
            │     READMEs                      │
            └──────────────────────────────────┘
```

T3, T4, T5 are independent of each other. They can be parallelized after
T2 lands (one feature branch per slice, or a single agent doing them
serially — same result).

## Task list

### Phase 1 — Foundation (do first, sequential)

#### Task 1: Identifier validation + presenter skeleton

**Description.** Stand up `SardineRunWeb.SessionDetailPresenter` with one
public function: `validate_identifier/1` that enforces the allow-list
pattern `~r/\A[A-Za-z0-9._-]+\z/` (same regex `SessionWriter` uses) and
returns `{:ok, identifier}` or `{:error, :invalid_identifier}`. Add a
second public function `payload/3` that takes `(identifier, snapshot,
filesystem)` and returns `{:ok, %{...}}` or `{:error, :not_found}`,
initially populating only the live-state slice. `filesystem` is a map
with `:state_repo`, `:workspace_path`, `:log_file` keys so tests can
point at tmp dirs.

**Acceptance criteria:**
- [ ] `validate_identifier/1` accepts `"UPS-123"`, `"foo.bar"`, `"a_b"`;
      rejects `""`, `"../etc"`, `"a/b"`, `"a b"`.
- [ ] `payload/3` returns `{:error, :not_found}` when the identifier is
      in neither `snapshot.running` nor `snapshot.retrying`.
- [ ] `payload/3` returns `{:ok, %{header: ..., live_state: ..., status:
      "running" | "retrying"}}` with values matching the existing
      `Presenter.issue_payload/3` shape for `running` / `retrying` /
      `tokens` / `last_event` / `runtime` fields.
- [ ] All public defs carry `@spec`.
- [ ] No filesystem reads happen yet (sections T3–T5 add them).

**Verification:**
- [ ] `mix test test/sardine_run_web/session_detail_presenter_test.exs`
- [ ] `mix specs.check`
- [ ] `mix format --check-formatted` and `mix lint` clean.

**Dependencies:** None.

**Files likely touched:**
- `elixir/lib/sardine_run_web/session_detail_presenter.ex` (new)
- `elixir/test/sardine_run_web/session_detail_presenter_test.exs` (new)

**Estimated scope:** S (2 files).

---

### Phase 2 — Vertical slice 1: route works end-to-end

#### Task 2: Route + LiveView + live-state section + 404

**Description.** Wire the route, mount the LiveView, render the header
and the live-agent-state section, and handle the 404 case. Subscribe to
`ObservabilityPubSub` and re-render on `:observability_updated`. Schedule
a `:runtime_tick` and increment the runtime counter without re-fetching
the snapshot, mirroring `DashboardLive`. After this task ships, an
operator can manually type `/session/<identifier>` and see live state for
an active issue, or a clean "session not active" page otherwise.

**Acceptance criteria:**
- [ ] `GET /session/<identifier>` mounts `SessionDetailLive`.
- [ ] Page renders header (identifier + status badge + back link),
      live-state section (runtime, turns, last event, last message,
      tokens, retry attempt + due_at when retrying).
- [ ] Unknown or invalid identifier renders the not-found page with a
      back link to `/`. Returns `200`, not `500` (matches LiveView
      conventions; the controller-level 404 is reserved for the JSON
      API).
- [ ] `:observability_updated` PubSub broadcast triggers a re-render
      with the latest snapshot values.
- [ ] `:runtime_tick` updates the on-screen runtime counter without a
      snapshot refetch.

**Verification:**
- [ ] `Phoenix.LiveViewTest` mount-with-known-identifier test passes.
- [ ] Mount-with-unknown-identifier renders the not-found state.
- [ ] Mount-with-invalid-identifier (`"../etc"`) renders the not-found
      state and never joins a path.
- [ ] PubSub broadcast triggers re-render in test.
- [ ] `:runtime_tick` test updates the counter.
- [ ] Manual: start `./bin/sardine-run --port 4000 ./WORKFLOW.md`
      against a populated state-repo, navigate to
      `/session/<known-id>`, see live state. Navigate to
      `/session/zzz-unknown`, see the not-found page.

**Dependencies:** T1.

**Files likely touched:**
- `elixir/lib/sardine_run_web/router.ex`
- `elixir/lib/sardine_run_web/live/session_detail_live.ex` (new)
- `elixir/lib/sardine_run_web/session_detail_presenter.ex`
- `elixir/test/sardine_run_web/live/session_detail_live_test.exs` (new)
- `elixir/test/sardine_run_web/session_detail_presenter_test.exs`

**Estimated scope:** M (5 files).

---

### Checkpoint: Foundation + slice 1

Stop and confirm before starting T3–T5:

- [ ] `make all` is green (setup, build, fmt-check, lint, coverage,
      dialyzer).
- [ ] Manual smoke against a real state-repo confirms the live-state
      section reflects what `DashboardLive` shows for the same issue.
- [ ] Identifier validation rejects the dot-dot/slash cases in tests.
- [ ] Human review: spec alignment, naming, file layout.

---

### Phase 3 — Section slices (independent; can parallelize)

#### Task 3: Workspace git log section

**Description.** Add a presenter helper that runs
`git -C <workspace_path> log --pretty=format:"%h %s" --max-count=10`
through `System.cmd/3` with `stderr_to_stdout: true` and a 5-second
timeout. The workspace path must already be inside
`Config.settings!().workspace.root` (verified via `PathSafety` before
the shell-out). Render the result in a new `section-card`. Empty / git
errors / missing dir all degrade to a clean inline message.

**Acceptance criteria:**
- [ ] Section renders the last 10 commits when the workspace contains a
      git repo.
- [ ] Renders "no git history" (no stderr leaked) when `git` exits
      non-zero or the dir is not a repo.
- [ ] Renders "workspace not present" when the dir does not exist.
- [ ] Never executes `git` if the workspace path fails `PathSafety`
      containment.
- [ ] Hard 5-second timeout enforced; tests cover the timeout branch
      via a mock or short-circuit.

**Verification:**
- [ ] Presenter test against a tmp repo with a fixed sequence of
      commits.
- [ ] Presenter test for missing-dir, non-repo-dir, and out-of-root
      cases.
- [ ] LiveView test asserting the section renders for the happy path.
- [ ] `mix test`, `mix lint`, `mix specs.check` clean.

**Dependencies:** T2.

**Files likely touched:**
- `elixir/lib/sardine_run_web/session_detail_presenter.ex`
- `elixir/lib/sardine_run_web/live/session_detail_live.ex`
- `elixir/test/sardine_run_web/session_detail_presenter_test.exs`
- `elixir/test/sardine_run_web/live/session_detail_live_test.exs`

**Estimated scope:** S–M (4 files, one new section, one new shell-out).

---

#### Task 4: Filtered log-tail section

**Description.** Add a presenter helper that shells out to
`tail -c 5242880 <log_file>` (path from
`SardineRun.LogFile.default_log_file/0`) so we never load more than the
last 5 MiB of the active log, filters lines containing the identifier
(case-sensitive substring; identifier already validated to a tight
allow-list), and returns the last 200 matches. Hard 5-second timeout.
Render in a scrollable monospace pane, newest at the bottom. Cleanly
handles missing file.

**Acceptance criteria:**
- [ ] Section shows the last 200 matching log lines.
- [ ] Lines are returned newest-at-bottom for chronological reading.
- [ ] `tail -c 5242880` partial read: peak memory bounded regardless
      of file size.
- [ ] Missing log file renders "no log entries" (no exception).
- [ ] `tail` failure or 5-second timeout renders "no log entries"
      cleanly (no stack trace, no leaked stderr).
- [ ] Non-matching lines never appear in output.

**Verification:**
- [ ] Presenter test writes a tmp log file with a controlled mix of
      matching/non-matching lines and asserts ordering and cap.
- [ ] Presenter test asserts the missing-file case.
- [ ] LiveView test asserts the section is rendered.
- [ ] `mix test`, `mix lint`, `mix specs.check` clean.

**Dependencies:** T2.

**Files likely touched:**
- `elixir/lib/sardine_run_web/session_detail_presenter.ex`
- `elixir/lib/sardine_run_web/live/session_detail_live.ex`
- `elixir/test/sardine_run_web/session_detail_presenter_test.exs`
- `elixir/test/sardine_run_web/live/session_detail_live_test.exs`

**Estimated scope:** S–M (4 files).

---

#### Task 5: notes.md + on-disk paths section

**Description.** Add a presenter helper that resolves
`<state_repo>/sessions/<identifier>/notes.md` via
`SardineRun.TrafficControl.Adapter.resolve_state_repo/0`, reads the file
if present, and returns plain text plus the resolved on-disk paths for
`session.yaml`, `notes.md`, `links.yaml`, and the workspace path. When
`tracker.kind: memory` (no state_repo configured), the on-disk-paths
block is hidden and the notes block reads "notes unavailable in memory
tracker mode".

**Acceptance criteria:**
- [ ] notes.md present → renders inside `<pre>`.
- [ ] notes.md missing → renders "no notes".
- [ ] state_repo not configured → renders the memory-tracker message
      and hides the on-disk-paths block.
- [ ] On-disk-paths block lists the four absolute paths verbatim.
- [ ] No path is constructed from the URL parameter without going
      through `validate_identifier/1` first.

**Verification:**
- [ ] Presenter tests for the three notes states (present, missing,
      memory).
- [ ] Presenter test asserts the four on-disk paths are correct given a
      synthetic state_repo and workspace_root.
- [ ] LiveView test asserts the section renders for the happy path.
- [ ] `mix test`, `mix lint`, `mix specs.check` clean.

**Dependencies:** T2.

**Files likely touched:**
- `elixir/lib/sardine_run_web/session_detail_presenter.ex`
- `elixir/lib/sardine_run_web/live/session_detail_live.ex`
- `elixir/test/sardine_run_web/session_detail_presenter_test.exs`
- `elixir/test/sardine_run_web/live/session_detail_live_test.exs`

**Estimated scope:** S–M (4 files).

---

### Checkpoint: All section slices

Stop and confirm before T6:

- [ ] `make all` green.
- [ ] Manual smoke: every section visible for a live issue; degraded
      states verified by temporarily renaming the workspace, deleting
      `notes.md`, and clearing the log file (or by switching to a
      memory tracker).
- [ ] Test coverage for the presenter is materially complete (every
      branch in a section has at least one assertion).

---

### Phase 4 — Wire-up and docs

#### Task 6: Dashboard drill-down links + READMEs

**Description.** Add a "View session" link to each row in the Running
and Retrying tables in `DashboardLive` pointing at
`/session/<entry.issue_identifier>`. Update the elixir/README.md and
project-root README.md to mention the new route under observability. No
changes to `SPEC.md` or `WORKFLOW.md`.

**Acceptance criteria:**
- [ ] Each Running row renders a link with
      `href="/session/<identifier>"`.
- [ ] Each Retrying row renders a link with
      `href="/session/<identifier>"`.
- [ ] Existing "JSON details" link is preserved.
- [ ] Both READMEs document the new route in one or two lines.

**Verification:**
- [ ] LiveView regression test against `DashboardLive` asserting the
      new links render for both tables.
- [ ] `mix test`, `mix lint`, `mix specs.check` clean.
- [ ] `make all` passes.
- [ ] Manual: clicking the link from the dashboard navigates to the
      detail page.

**Dependencies:** T3, T4, T5 (so the destination page is feature-complete
before we point users at it; can be relaxed if we want to ship the link
earlier as a manual-typing aid).

**Files likely touched:**
- `elixir/lib/sardine_run_web/live/dashboard_live.ex`
- `elixir/test/sardine_run/status_dashboard_snapshot_test.exs` or a
  dedicated `dashboard_live_test.exs` if regression coverage doesn't
  already exist.
- `README.md`
- `elixir/README.md`

**Estimated scope:** S (3–4 files).

---

### Checkpoint: Complete

Before declaring done and opening the PR:

- [ ] All acceptance criteria across T1–T6 are checked.
- [ ] `make all` is green on the feature branch.
- [ ] PR body conforms to `.github/pull_request_template.md` and passes
      `mix pr_body.check`.
- [ ] Manual smoke: dashboard → drill-down → all five sections → back to
      dashboard works against a real state-repo.
- [ ] Manual smoke: identifier-not-active path produces the not-found
      page.
- [ ] Code review by the human (or `agent-skills:review`).

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Shell-out to `git` hangs (e.g. inside a corrupted repo or a network FS) | Med | 5-second hard timeout; render "no git history" on timeout. |
| Log file scanning scales with disk size | Med | `tail -c 5242880` partial read (last 5 MiB) + 5-second timeout; cap at 200 returned lines. |
| URL-injected identifier reaches `git`, `Path.join`, or `File.read!` | High | Single `validate_identifier/1` allow-list gate at the LiveView entry; tests assert rejection of dot-dot, slash, whitespace. |
| `notes.md` contains sensitive content rendered as raw HTML | Med | Render inside `<pre>` with `~H` interpolation (Phoenix auto-escapes). No markdown rendering this iteration. |
| Live PubSub re-renders thrash with many issues open | Low | Same broadcast cadence as `DashboardLive`, which already operates at this rate without issues. |
| Workspace path falls outside `workspace.root` (mis-config) | Med | `PathSafety` containment check before any read or shell-out; render "workspace not present" otherwise. |

## Parallelization

After T2 ships, T3, T4, and T5 are independent and can be split across
sessions or branches. They touch the same two files (presenter and
LiveView) so a single agent serially is the simpler default; only split
if multiple agents are running in parallel.

## Open questions

None at plan acceptance time. Any surprise during build will be appended
here and to the spec's open-questions section.
