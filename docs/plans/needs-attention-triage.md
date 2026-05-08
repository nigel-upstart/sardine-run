# "Needs your attention" triage in the Traffic Control dashboard

## Problem

When a coding agent (Sardine Run, Claude Code, manual) gets stuck and hands the
session back to a human, the operator has no single place to find it. Today:

- Sardine Run's LiveView dashboard (`http://<host>:4000/`) only shows sessions
  the orchestrator has touched, and it's only running while the daemon is up.
- Traffic Control's web dashboard (`http://localhost:8000/`) shows every
  session it can read off disk, but has no triage view filtered to ones that
  need a human.
- `status: waiting` + `kind: external` is a tool-agnostic signal — any agent
  can write it. Putting the triage view in Sardine Run would tie a cross-tool
  concept to a single tool.

## Decision

The triage view lives in the **Traffic Control dashboard**, because:

- It is the single pane of glass for sessions across all tools.
- It already iterates `sessions/*/session.yaml`.
- It is persistent — always-on, independent of whether Sardine Run is running.

Sardine Run gains one small contribution: it advertises its dashboard URL on
its runtime payload so Traffic Control can deep-link back when (and only when)
the orchestrator is up.

## Scope

In scope:

1. New "Needs your attention" section on the Traffic Control fleet view.
2. Cross-link from each Sardine Run row in TC → canonical TC session detail
   page.
3. Cross-link from TC session detail page → Sardine Run dashboard deep-link,
   gated on the orchestrator being live.
4. Schema: optional `dashboard_url` field on `SardineRunRuntime`.
5. Sardine Run gains a per-session LiveView at
   `GET /session/:issue_identifier` for deep-linking from TC.

Out of scope (tracked separately):

- Editing waiting state from the dashboard (resolve / reassign / nudge).
- Notifications / alerting when items enter the queue.
- Filters by tool, age threshold, or assignee.
- Aggregating waiting items from non-Traffic-Control trackers.

## Surface 1 — "Needs your attention" section (Traffic Control)

**Where:** `apps/dashboard/src/dashboard/templates/home.html` (the fleet view).
Renders above the existing fleet table when the queue is non-empty; collapses
to a compact "0 items" line when empty.

**Source query:** all sessions where
- `status == SessionStatus.WAITING` AND
- `waiting.kind == WaitingKind.EXTERNAL`

Sorted by `waiting.requested_at` ascending (oldest first — surface what's been
stuck longest).

**Row contents:**

| Column | Source | Notes |
|---|---|---|
| Session ID | `session.id` | Monospace, 8-char short ID |
| Title | `session.title` | Links to `/sessions/{id}` (canonical TC view) |
| Waiting note | `session.waiting.note` | Truncate at ~140 chars with ellipsis |
| Age | now − `session.waiting.requested_at` | Render as `2h 14m`, `3d 1h`, etc.; bold when > 24h |
| Tool | derived (see below) | Small badge: `sardine-run` / `claude-code` / `manual` |

**Tool derivation rule:**

- If `session.sardine_run.agent_id` is set → `sardine-run`.
- Else if `session.metadata.tool == "claude-code"` (or equivalent existing
  marker) → `claude-code`.
- Else → `manual`.

The tool badge is informational only — it does NOT filter, hide, or alter
ordering. It exists so the operator can scan the queue and see which agent
needs their attention.

**Empty state:** "No sessions waiting on you. Nice." (Single line, muted.)

## Surface 2 — Cross-link: TC → canonical session view

The "Needs your attention" section already links rows to `/sessions/{id}` —
that's it. No additional plumbing required; this is the existing TC route.

The same applies to the existing Sardine Run view in TC
(`/sardine-run`): each row's title MUST link to `/sessions/{id}` so the TC
session detail page is always the canonical jump-off. (The current template
already does this — verify and lock in.)

## Surface 3 — Cross-link: TC session detail → Sardine Run dashboard

On `/sessions/{id}`, when `session.sardine_run.dashboard_url` is non-empty,
render a button: **"Open in Sardine Run →"** that navigates to
`{dashboard_url}/session/{issue_identifier}`.

When the field is empty (orchestrator not running, or this session was never
handled by Sardine Run), the button is omitted entirely. The rule:

- `dashboard_url` is set ONLY while the orchestrator is up.
- On orderly shutdown, the orchestrator MUST clear `dashboard_url` on every
  active session.
- A stale URL (e.g. after crash) is acceptable — the user just gets a
  connection-refused; this is a triage UI, not a system of record.

## Schema change — `SardineRunRuntime.dashboard_url`

Add to `packages/schema/src/schema/session.py`:

```python
class SardineRunRuntime(BaseModel):
    # ... existing fields ...
    dashboard_url: str | None = None  # e.g. "http://hostname:4000"
```

Backwards-compatible: optional, defaults to None. Existing session.yaml files
load unchanged.

## Sardine Run contributions

1. **Populate `dashboard_url`** on the runtime payload whenever the dashboard
   is enabled (i.e. `--port` was passed or `server.port` is set in
   `WORKFLOW.md`):
   - On dispatch, the orchestrator writes
     `dashboard_url = "http://<host>:<port>"` into the session's
     `sardine_run.dashboard_url` via the existing `sardine_run_session`
     dynamic tool path (or directly through `SessionWriter`, whichever is
     cleaner).
   - `<host>` resolves from `SARDINE_RUN_PUBLIC_HOSTNAME` env var if set,
     otherwise from `Node.self()` / `:inet.gethostname/0`.
   - `<port>` is the configured server port.

2. **Clear `dashboard_url` on shutdown.** The orchestrator's
   `terminate/2` (or equivalent shutdown hook) iterates active sessions and
   nils the field. Best-effort — a hard kill is allowed to leave it stale.

3. **Add `live "/session/:issue_identifier", SessionDetailLive, :show`** to
   `SardineRunWeb.Router` (browser pipeline). This is a distinct LiveView
   module with its own `mount/3`, not a query-param branch on
   `DashboardLive`. Multiple LiveViews per router is the idiomatic Phoenix
   shape.
   - `SessionDetailLive` mounts subscribed to the same observability PubSub
     topic as `DashboardLive`, scoped to the requested
     `issue_identifier`.
   - If the orchestrator has never seen the session, render a 404-style
     notice: "This session isn't currently tracked by Sardine Run." with a
     link back to `/`.
   - The fleet view (`/`) gets a per-row link to `/session/:issue_identifier`
     so users can drill in from inside Sardine Run too — not just from TC.

## URL contract (strict)

| From | To | URL shape |
|---|---|---|
| TC fleet attention row | TC session detail | `http://<tc-host>:8000/sessions/{id}` |
| TC `/sardine-run` row | TC session detail | `http://<tc-host>:8000/sessions/{id}` |
| TC session detail | Sardine Run session view | `{sardine_run.dashboard_url}/session/{issue_identifier}` |
| Sardine Run row (existing) | TC session detail | `http://<tc-host>:8000/sessions/{id}` |

The Traffic Control base URL is **not** stored in `session.yaml`. Sardine Run
templates that link out to TC use `TRAFFIC_CONTROL_DASHBOARD_URL` env var
(default `http://localhost:8000`).

## Acceptance criteria

- [ ] Fleet view (`/`) renders a "Needs your attention" section listing all
      sessions matching `status=waiting` AND `waiting.kind=external`.
- [ ] Section is sorted oldest-first by `waiting.requested_at`.
- [ ] Each row shows session ID, title (linked), waiting note, age, tool
      badge.
- [ ] Empty queue renders the empty-state line and not an empty table.
- [ ] On TC session detail page, "Open in Sardine Run →" button appears iff
      `session.sardine_run.dashboard_url` is non-empty.
- [ ] Sardine Run writes `dashboard_url` on dispatch when serving.
- [ ] Sardine Run clears `dashboard_url` on graceful shutdown.
- [ ] Sardine Run serves `GET /session/:issue_identifier` as a distinct
      LiveView showing per-session detail.
- [ ] Unknown `issue_identifier` renders the not-tracked notice, not a 500.
- [ ] Existing `session.yaml` files load without migration.

## Testing

- **Schema:** unit test that `SardineRunRuntime` round-trips with and without
  `dashboard_url`.
- **TC dashboard:**
  - `tests/test_routes.py`: fixture with a mix of sessions
    (waiting/external, waiting/human, active, done) — assert only
    waiting/external appear in the section, ordered correctly.
  - Empty queue renders empty-state copy.
  - Age formatter unit test covers minutes / hours / days / >24h bold rule.
  - `dashboard_url` set → button rendered; unset → button absent.
- **Sardine Run:**
  - `SessionDetailLive` mount with a known `issue_identifier` renders the
    session payload (status, last event, runtime fields, links).
  - `SessionDetailLive` mount with an unknown `issue_identifier` renders the
    not-tracked notice with a link back to `/`.
  - PubSub broadcast for the focused session updates the LiveView assigns.
  - Orchestrator unit test: dispatch writes `dashboard_url`; shutdown clears
    it.

## Documentation updates (same PR)

- Traffic Control: `README.md` — describe the new fleet section.
- Sardine Run: `README.md` and `elixir/README.md` — document the
  `/session/:issue_identifier` route, the `dashboard_url` runtime field, and
  the `SARDINE_RUN_PUBLIC_HOSTNAME` env var.
- Sardine Run: `SPEC.md` — add `dashboard_url` to the runtime contract and
  declare `/session/:issue_identifier` as the canonical per-session deep-link
  path.

## Boundaries

**Always:**
- Reads of waiting state are derived from `session.yaml` on disk; nothing is
  cached or synthesized.
- Cross-tool concepts (status, waiting kind) live in `packages/schema`, not in
  any one app.
- Links between dashboards degrade gracefully when the other side is offline.

**Ask first:**
- Adding write actions to the attention section (resolve, reassign).
- Adding tool-specific filtering or grouping.
- Changing the `WaitingKind` enum or `SessionStatus` enum.

**Never:**
- Writing to `session.yaml` from the Traffic Control dashboard process.
- Hardcoding a Sardine Run hostname or port in TC code or templates — the URL
  comes from the runtime payload.
- Treating an absent `dashboard_url` as an error; absence means "not running."
