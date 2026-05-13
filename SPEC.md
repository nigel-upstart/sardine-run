# Sardine Run Service Specification

Status: Draft v2 (language-agnostic)

Purpose: Define a service that orchestrates coding agents to get project work done, using a
filesystem state-repo (Traffic Control) as the work tracker.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and
`OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this
specification does not prescribe one universal policy. Implementations MUST document the selected
behavior.

## 1. Problem Statement

Sardine Run is a long-running automation service that continuously reads work from a Traffic
Control state-repo on the local filesystem, creates an isolated workspace for each session, and
runs a coding agent for that session inside the workspace.

The service solves four operational problems:

- It turns session execution into a repeatable daemon workflow instead of manual scripts.
- It isolates agent execution in per-session workspaces so agent commands run only inside per-session
  workspace directories.
- It keeps the workflow policy in-repo (`WORKFLOW.md`) so teams version the agent prompt and runtime
  settings with their code.
- It provides enough observability to operate and debug multiple concurrent agent runs.

Implementations are expected to document their trust and safety posture explicitly. This
specification does not require a single approval, sandbox, or operator-confirmation policy.

Important boundary:

- Sardine Run is a scheduler/runner and tracker reader.
- Session writes (status transitions, notes, links) are typically performed by the coding agent
  using the `sardine_run_session` dynamic tool advertised by the orchestrator.
- A successful run can end at a workflow-defined handoff state (for example `review`), not
  necessarily `done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the tracker on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Create deterministic per-session workspaces and preserve them across runs.
- Stop active runs when session state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from a repository-owned `WORKFLOW.md` contract.
- Expose operator-visible observability (at minimum structured logs).
- Support tracker/filesystem-driven restart recovery without requiring a persistent database.

### 2.2 Non-Goals

- Rich web UI or multi-tenant control plane.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- Built-in business logic for how to mutate sessions. (That logic lives in the workflow prompt and
  the agent's use of the `sardine_run_session` dynamic tool.)
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - Reads `WORKFLOW.md`.
   - Parses YAML front matter and prompt body.
   - Returns `{config, prompt_template}`.

2. `Config Layer`
   - Exposes typed getters for workflow config values.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

3. `Tracker Adapter`
   - Reads candidate sessions from the configured state-repo.
   - Reads current state for specific session IDs (reconciliation).
   - Reads terminal-state sessions during startup cleanup.
   - Normalizes session payloads into a stable issue model.

4. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which sessions to dispatch, retry, stop, or release.
   - Tracks session metrics and retry queue state.

5. `Workspace Manager`
   - Maps session identifiers to workspace paths.
   - Ensures per-session workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal sessions.

6. `Agent Runner`
   - Creates workspace.
   - Builds prompt from session + workflow template.
   - Launches the coding agent app-server client.
   - Streams agent updates back to the orchestrator.
   - Advertises the `sardine_run_session` dynamic tool to the agent.

7. `Status Surface` (OPTIONAL)
   - Presents human-readable runtime status (terminal output, dashboard, JSON API).

8. `Logging`
   - Emits structured runtime logs.

### 3.2 Abstraction Levels

1. `Policy Layer` — `WORKFLOW.md` prompt body and team-specific session-handling rules.
2. `Configuration Layer` — typed getters parsing the front matter.
3. `Coordination Layer` — orchestrator polling, eligibility, concurrency, retries, reconciliation.
4. `Execution Layer` — workspace lifecycle and coding-agent subprocess.
5. `Integration Layer` — Traffic Control state-repo adapter.
6. `Observability Layer` — logs and OPTIONAL status surface.

### 3.3 External Dependencies

- A Traffic Control state-repo on the local filesystem (default tracker kind).
- Local filesystem for workspaces and logs.
- OPTIONAL workspace population tooling (typically `git`).
- Coding-agent executable that supports the targeted Codex app-server protocol.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue (Normalized Session Record)

The orchestrator's internal record for a tracker session, used by orchestration, prompt rendering,
and observability output.

Fields:

- `id` (string) — Stable tracker-internal ID. For Traffic Control this equals the session directory
  name.
- `identifier` (string) — Human-readable session key (example: `MT-123`). For Traffic Control,
  identical to `id`.
- `title` (string)
- `description` (string or null)
- `priority` (integer or null) — Lower numbers are higher priority in dispatch sorting.
- `state` (string) — Current tracker state name.
- `branch_name` (string or null)
- `url` (string or null)
- `labels` (list of strings) — Normalized to lowercase.
- `blocked_by` (list of blocker refs) — Each ref contains `id`, `identifier`, `state`.
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Workflow Definition

Parsed `WORKFLOW.md` payload:

- `config` (map) — YAML front matter root object.
- `prompt_template` (string) — Markdown body after front matter, trimmed.

#### 4.1.3 Service Config (Typed View)

Typed runtime values derived from `WorkflowDefinition.config` plus environment resolution.

Examples: poll interval, workspace root, active and terminal session states, concurrency limits,
coding-agent executable/args/timeouts, workspace hooks.

#### 4.1.4 Workspace

Filesystem workspace assigned to one session identifier.

- `path` — absolute workspace path
- `workspace_key` — sanitized session identifier
- `created_now` — boolean, used to gate `after_create` hook

#### 4.1.5 Run Attempt

One execution attempt for one session.

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null; `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (OPTIONAL)

#### 4.1.6 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string)
- `turn_id` (string)
- `worker_kind` (string or null) — the agent species bound to this session
  (`codex`, `claude`, or `reviewer`). For `codex`/`claude` the species is
  selected probabilistically per §6.5. For `reviewer` the species is
  deterministically selected when the session's `status` is
  `review_pending`; see §6.6.
- `codex_app_server_pid` (string or null)
- `last_codex_event` (string or null)
- `last_codex_timestamp` (timestamp or null)
- `last_codex_message` (summarized payload)
- `codex_input_tokens` (integer)
- `codex_output_tokens` (integer)
- `codex_total_tokens` (integer)
- `last_reported_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `turn_count` (integer)

#### 4.1.7 Retry Entry

- `issue_id`
- `identifier`
- `attempt` (integer, 1-based)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle`
- `error` (string or null)

#### 4.1.8 Orchestrator Runtime State

- `poll_interval_ms`
- `max_concurrent_agents`
- `running` — map `issue_id -> running entry`
- `claimed` — set of session IDs reserved/running/retrying
- `retry_attempts` — map `issue_id -> RetryEntry`
- `completed` — set of session IDs (bookkeeping only)
- `codex_totals` — aggregate tokens + runtime seconds
- `codex_rate_limits` — latest rate-limit snapshot

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID` — for tracker lookups and internal map keys.
- `Issue Identifier` — for human-readable logs and workspace naming.
- `Workspace Key` — derived from `issue.identifier` by replacing any character not in
  `[A-Za-z0-9._-]` with `_`.
- `Normalized Issue State` — compare states after `lowercase`.
- `Session ID` — `<thread_id>-<turn_id>`.

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Workflow file path precedence:

1. Explicit application/runtime setting (set by CLI startup path).
2. Default: `WORKFLOW.md` in the current process working directory.

The workflow file is repository-owned and version-controlled.

### 5.2 File Format

`WORKFLOW.md` is a Markdown file with OPTIONAL YAML front matter.

`WORKFLOW.md` SHOULD be self-contained enough to describe and run different workflows (prompt,
runtime settings, hooks, and tracker selection/config) without out-of-band configuration.

Parsing rules:

- If the file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config map.
- YAML front matter MUST decode to a map; non-map YAML is an error.
- Prompt body is trimmed before use.

Returned workflow object:

- `config` — front matter root object.
- `prompt_template` — trimmed Markdown body.

### 5.3 Front Matter Schema

Top-level keys: `tracker`, `polling`, `workspace`, `hooks`, `agent`, `codex`. Implementations MAY
define additional top-level keys (for example `worker`, `server`, `observability`).

Unknown keys SHOULD be ignored for forward compatibility.

#### 5.3.1 `tracker` (object)

- `kind` (string) — REQUIRED. Supported values: `traffic_control` (filesystem state-repo),
  `memory` (in-process, used by tests).
- `state_repo` (path string or `$VAR`) — REQUIRED when `kind == "traffic_control"`. Absolute or
  `~`-expanded path to the Traffic Control state repository.
  - Canonical environment variable: `TRAFFIC_CONTROL_STATE_REPO`. If `state_repo` is omitted or
    set to `$TRAFFIC_CONTROL_STATE_REPO`, the runtime resolves it from that environment variable.
  - Default: `~/code/traffic-control-state`.
- `active_states` (list of strings) — Default: `["active"]`.
- `terminal_states` (list of strings) — Default: `["done", "archived"]`.

There is no API endpoint or token. Traffic Control is a local filesystem repository; all reads and
writes go through the filesystem.

#### 5.3.2 `polling` (object)

- `interval_ms` (integer) — Default: `30000`.

Changes SHOULD be re-applied at runtime and affect future tick scheduling without restart.

#### 5.3.3 `workspace` (object)

- `root` (path string or `$VAR`) — Default: `<system-temp>/sardine_run_workspaces`. Recommended
  user value: `~/code/sardine-run-workspaces`. `~` is expanded; relative paths resolve relative to
  the directory containing `WORKFLOW.md`.

#### 5.3.4 `hooks` (object)

- `after_create` (shell script, OPTIONAL) — Runs only on freshly created workspace. Failure aborts
  workspace creation.
- `before_run` (shell script, OPTIONAL) — Runs before each agent attempt. Failure aborts the
  attempt.
- `after_run` (shell script, OPTIONAL) — Runs after each agent attempt. Failure is logged and
  ignored.
- `before_remove` (shell script, OPTIONAL) — Runs before workspace deletion. Failure is logged and
  ignored; cleanup still proceeds.
- `timeout_ms` (integer) — Default: `60000`.

#### 5.3.5 `agent` (object)

- `max_concurrent_agents` (integer) — Default: `10`.
- `max_turns` (positive integer) — Default: `20`.
- `max_retry_backoff_ms` (integer) — Default: `300000` (5 minutes).
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`) — Default: `{}`.

##### 5.3.5.1 `agent.sampling` (object, OPTIONAL)

Probabilistic dispatch selector. When the implementation supports more than
one worker backend, it MAY use this block to pick one per dispatch.

- `claude_probability` (float in `[0.0, 1.0]`) — Default: `0.05`. Probability
  that a dispatch picks the Claude worker; otherwise it falls back to the
  Codex worker. Set to `0.0` to disable Claude entirely.

#### 5.3.6 `claude` (object, OPTIONAL)

Configuration for the Claude Code CLI worker backend. Required when
`agent.sampling.claude_probability > 0.0`.

- `command` (string shell command) — Default: `claude`. Launched via
  `bash -lc` in the workspace directory. Sardine Run appends
  `--mcp-config <path>` so the per-session `sardine_run_session` MCP bridge
  is loaded.
- `model` (string) — Default: `sonnet`. Forwarded to the CLI via `--model`.
- `effort` (string) — Default: `high`. Exported as the
  `CLAUDE_REASONING_EFFORT` environment variable; there is no stable CLI
  flag for reasoning effort today.
- `permission_mode` (string) — Default: `bypassPermissions`. Forwarded via
  `--permission-mode`.
- `turn_timeout_ms` (integer) — Default: `3600000` (1 hour).
- `read_timeout_ms` (integer) — Default: `5000`.
- `stall_timeout_ms` (integer) — Default: `300000` (5 minutes).

#### 5.3.7 `codex` (object)

For Codex-owned config values such as `approval_policy`, `thread_sandbox`, and
`turn_sandbox_policy`, supported values are defined by the targeted Codex app-server version.
Treat them as pass-through Codex config values rather than relying on a hand-maintained enum here.
To inspect the installed Codex schema, run `codex app-server generate-json-schema --out <dir>`.

- `command` (string shell command) — Default: `codex app-server`. Launched via `bash -lc` in the
  workspace directory.
- `approval_policy` (Codex `AskForApproval` value)
- `thread_sandbox` (Codex `SandboxMode` value)
- `turn_sandbox_policy` (Codex `SandboxPolicy` value)
- `turn_timeout_ms` (integer) — Default: `3600000` (1 hour).
- `read_timeout_ms` (integer) — Default: `5000`.
- `stall_timeout_ms` (integer) — Default: `300000` (5 minutes). `<= 0` disables stall detection.

#### 5.3.8 `review` (object, OPTIONAL)

Configuration for the 🐡 review-feedback processor — the deterministic
worker species dispatched when a session is in `review_pending` (see §6.6).

- `enabled` (boolean) — Default: `true`. When `false`, the implementation
  MUST NOT start the watcher and MUST NOT auto-flip any session from
  `review` to `review_pending`. The `:reviewer` species is still selectable
  if external code manually puts a session into `review_pending`.
- `poll_interval_ms` (positive integer) — Default: `300000` (5 minutes).
  Base interval between watcher ticks.
- `poll_jitter_ms` (non-negative integer) — Default: `60000` (1 minute).
  Each tick fires `poll_interval_ms + uniform_random(0, poll_jitter_ms)`
  after the previous tick to avoid lock-step polling across instances.
- `backend` (`codex` or `claude`) — Default: `codex`. Which underlying
  agent backend the `:reviewer` species wraps. The reviewer reuses the
  selected backend's transport (Codex App Server or Claude Code CLI) but
  renders a different prompt body.
- `prompt_file` (string) — Default: `REVIEW_FEEDBACK.md`. Path to the
  reviewer prompt template, resolved relative to `WORKFLOW.md`'s
  directory. Liquid-templated; input vars are `issue` (per §5.4) and
  `pending_feedback` (the snapshot the watcher wrote to
  `sessions/<id>/pending_feedback.yaml`).
- `check_ci` (boolean) — Default: `true`. When `true`, the watcher also
  pulls `gh pr checks --json` and treats `state ∈ {FAILURE, TIMED_OUT}`
  entries as pending feedback.
- `auto_resolve_on_reject` (boolean) — Default: `true`. Whether the
  reviewer is permitted to call `resolve_thread` after a substantive
  `reply_to_comment`. When `false`, the reviewer SHOULD only `reply` and
  let humans resolve. The implementation MAY enforce a minimum-substance
  check; the prompt SHOULD set the bar (at least two sentences of
  substantive reasoning).

### 5.4 Prompt Template Contract

The Markdown body of `WORKFLOW.md` is the per-session prompt template.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables MUST fail rendering for the default `WORKFLOW.md` prompt.
- Unknown filters MUST fail rendering for all prompts.
- The reviewer prompt (§6.6, `review.prompt_file`) MAY render with lenient
  variable resolution because per-thread snapshot fields can legitimately be
  `nil` when a comment lacks a path/line (e.g. PR-level reviews). Strict
  filter resolution still applies.

Template input variables:

- `issue` (object) — All normalized session fields, including labels and blockers.
- `attempt` (integer or null) — `null`/absent on first attempt, integer on retry/continuation.

Fallback prompt behavior:

- If the workflow prompt body is empty, the runtime MAY use a minimal default prompt. The default
  prompt SHOULD describe the `sardine_run_session` dynamic tool contract so agents can drive their
  assigned session correctly even when a custom prompt body is missing.
- Workflow file read/parse failures are configuration errors and SHOULD NOT silently fall back.

### 5.5 Workflow Validation and Error Surface

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error`
- `template_render_error`

Dispatch gating:

- Workflow file read/YAML errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

## 6. Configuration Specification

### 6.1 Configuration Resolution Pipeline

1. Select the workflow file path (explicit runtime setting, otherwise cwd default).
2. Parse YAML front matter into a raw config map.
3. Apply built-in defaults for missing OPTIONAL fields.
4. Resolve `$VAR_NAME` indirection only for config values that explicitly contain `$VAR_NAME`.
5. Coerce and validate typed values.

Environment variables do not globally override YAML values. They are only used when a config value
explicitly references them via `$VAR_NAME`.

Path/command coercion semantics:

- `~` home expansion for path values.
- `$VAR` expansion for env-backed path values (for example `tracker.state_repo` and
  `workspace.root`).
- Apply expansion only to values intended as local filesystem paths; do not rewrite arbitrary
  shell command strings.
- Relative `workspace.root` resolves relative to the directory containing `WORKFLOW.md`.

### 6.2 Dynamic Reload Semantics

Dynamic reload is REQUIRED:

- The software MUST detect `WORKFLOW.md` changes.
- On change, it MUST re-read and re-apply workflow config and prompt template without restart.
- Reloaded config applies to future dispatch, retry scheduling, reconciliation, hook execution,
  and agent launches.
- Implementations are not REQUIRED to restart in-flight agent sessions automatically when config
  changes.
- Extensions that manage their own listeners (for example an HTTP server port change) MAY require
  restart.
- Invalid reloads MUST NOT crash the service; keep operating with the last known good
  configuration and emit an operator-visible error.

### 6.3 Dispatch Preflight Validation

Startup validation:

- Validate configuration before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, emit an
  operator-visible error.

Validation checks:

- Workflow file can be loaded and parsed.
- `tracker.kind` is present and supported.
- `tracker.state_repo` is present and resolvable when `kind == "traffic_control"`.
- `codex.command` is present and non-empty.

### 6.4 Core Config Fields Summary (Cheat Sheet)

- `tracker.kind`: string, REQUIRED, supported values `traffic_control`, `memory`.
- `tracker.state_repo`: path or `$VAR`, REQUIRED when `kind=traffic_control`. Default
  `~/code/traffic-control-state`. Canonical env: `TRAFFIC_CONTROL_STATE_REPO`.
- `tracker.active_states`: list of strings, default `["active", "review_pending"]`.
- `tracker.terminal_states`: list of strings, default `["done", "archived"]`.
- `polling.interval_ms`: integer, default `30000`.
- `workspace.root`: path resolved to absolute, default `<system-temp>/sardine_run_workspaces`;
  recommended user value `~/code/sardine-run-workspaces`.
- `hooks.after_create`: shell script or null.
- `hooks.before_run`: shell script or null.
- `hooks.after_run`: shell script or null.
- `hooks.before_remove`: shell script or null.
- `hooks.timeout_ms`: integer, default `60000`.
- `agent.max_concurrent_agents`: integer, default `10`.
- `agent.max_turns`: integer, default `20`.
- `agent.max_retry_backoff_ms`: integer, default `300000`.
- `agent.max_concurrent_agents_by_state`: map of positive integers, default `{}`.
- `codex.command`: shell command, default `codex app-server`.
- `codex.approval_policy`: Codex `AskForApproval` value.
- `codex.thread_sandbox`: Codex `SandboxMode` value.
- `codex.turn_sandbox_policy`: Codex `SandboxPolicy` value.
- `codex.turn_timeout_ms`: integer, default `3600000`.
- `codex.read_timeout_ms`: integer, default `5000`.
- `codex.stall_timeout_ms`: integer, default `300000`.
- `review.enabled`: boolean, default `true`.
- `review.poll_interval_ms`: integer, default `300000` (5 minutes).
- `review.poll_jitter_ms`: integer, default `60000` (1 minute).
- `review.backend`: `codex` or `claude`, default `codex`.
- `review.prompt_file`: string, default `REVIEW_FEEDBACK.md` (resolved
  relative to `WORKFLOW.md`'s directory).
- `review.check_ci`: boolean, default `true`.
- `review.auto_resolve_on_reject`: boolean, default `true`.

### 6.5 Probabilistic Worker Selection (OPTIONAL)

Implementations MAY support more than one coding-agent backend (for example,
both Codex and Claude Code). When they do, each dispatch SHOULD select a
backend independently using `agent.sampling.claude_probability` (or an
equivalent named selector for additional backends). The selected backend's
identifier MUST be recorded on the live session (§4.1.6 `worker_kind`) and
MAY be exposed via the runtime/`sardine_run.worker_kind` block on
`session.yaml`, so operators can see which backend handled the run.

Selection is per-dispatch and bound for the entire worker lifetime, including
continuation turns; the runtime MUST NOT swap workers mid-session.

### 6.6 Review-Feedback Worker Selection (OPTIONAL)

When the implementation supports the 🐡 reviewer species, dispatch MUST
short-circuit the probabilistic selector from §6.5 for any session whose
normalized `state` is `"review_pending"` and instead bind the
`:reviewer` species, transported by the backend configured in
`review.backend`. The selected `worker_kind` for the live session
(§4.1.6) is the literal string `"reviewer"`.

The reviewer SHARES the `sardine_run_session` dynamic-tool surface with
the other species and gets four additional operations:
`list_review_comments`, `reply_to_comment`, `resolve_thread`, and
`request_human_help` (§10.5). The default WORKFLOW.md prompt body is
replaced by the contents of `review.prompt_file` (default
`REVIEW_FEEDBACK.md`), rendered with the same Liquid engine as the
default prompt plus an additional top-level `pending_feedback` variable.

The transition into `review_pending` MAY happen via §6.7's watcher, or
via any external mechanism that writes `status: review_pending` to
`session.yaml` (for example a CLI helper or a webhook bridge).

### 6.7 Review Watcher (OPTIONAL)

When `review.enabled` is `true` the implementation MUST start a
background watcher that:

1. Wakes on a recurring schedule. Each tick fires
   `review.poll_interval_ms + uniform_random(0, review.poll_jitter_ms)`
   after the previous tick.
2. Queries the configured tracker for issues whose normalized state is
   `"review"`.
3. For each such session, resolves the first `link_kind: pr` entry in
   `links.yaml`. Sessions without a PR link are skipped.
4. Queries GitHub for that PR's unresolved review threads and — when
   `review.check_ci` is `true` — its failing CI checks.
5. If either has any entries, writes a snapshot to
   `sessions/<id>/pending_feedback.yaml` (JSON-encoded; JSON ⊂ YAML 1.2)
   and updates the session's `status` from `"review"` to
   `"review_pending"`, signalling the orchestrator's dispatch path to
   pick up the session with the reviewer species.

`pending_feedback.yaml` shape:

```yaml
{
  "snapshot_at": "<RFC 3339 timestamp>",
  "threads": [
    {
      "thread_id": "<GraphQL node id, e.g. PRRT_…>",
      "comment_id": <REST databaseId of the first comment>,
      "path": "<file path>",
      "line": <line number>,
      "author": "<github login>",
      "body": "<comment body>"
    }
  ],
  "failing_checks": [
    {"name": "<check name>", "state": "FAILURE | TIMED_OUT", "link": "<url>"}
  ]
}
```

External (non-watcher) tooling MAY write the same file shape directly
and flip the status manually; the reviewer prompt reads whatever
snapshot is on disk.

## 7. Orchestration State Machine

The orchestrator is the only component that mutates scheduling state. All worker outcomes are
reported back to it and converted into explicit state transitions.

### 7.1 Session Orchestration States

This is not the same as tracker states (`active`, `done`, etc.). This is the service's internal
claim state.

1. `Unclaimed` — Session is not running and has no retry scheduled.
2. `Claimed` — Orchestrator has reserved the session.
3. `Running` — Worker task exists.
4. `RetryQueued` — Retry timer exists.
5. `Released` — Claim removed because session is terminal, non-active, missing, or retry path
   completed without re-dispatch.

Important nuance:

- A successful worker exit does not mean the session is done.
- The worker MAY continue through multiple back-to-back coding-agent turns before it exits.
- After each normal turn completion, the worker re-checks tracker state.
- If the session is still in an active state, the worker SHOULD start another turn on the same live
  coding-agent thread in the same workspace, up to `agent.max_turns`.
- The first turn SHOULD use the full rendered task prompt; continuation turns SHOULD send only
  continuation guidance.
- Once the worker exits normally, the orchestrator schedules a short continuation retry (about
  1 second) so it can re-check whether the session remains active.

### 7.2 Run Attempt Lifecycle

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

### 7.3 Transition Triggers

- `Poll Tick` — reconcile, validate, fetch candidates, dispatch.
- `Worker Exit (normal)` — remove running entry, schedule continuation retry.
- `Worker Exit (abnormal)` — remove running entry, schedule exponential-backoff retry.
- `Codex Update Event` — update live session fields, token counters, rate limits.
- `Retry Timer Fired` — re-fetch candidates and attempt re-dispatch, or release claim.
- `Reconciliation State Refresh` — stop runs whose session states are terminal or no longer active.
- `Stall Timeout` — kill worker and schedule retry.

### 7.4 Idempotency and Recovery Rules

- Single-authority state mutation prevents duplicate dispatch.
- `claimed` and `running` checks are REQUIRED before launching any worker.
- Reconciliation runs before dispatch on every tick.
- Restart recovery is tracker-driven and filesystem-driven.
- Startup terminal cleanup removes stale workspaces for sessions already in terminal states.

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

At startup, the service validates config, performs startup cleanup, schedules an immediate tick,
and then repeats every `polling.interval_ms`.

Tick sequence:

1. Reconcile running sessions.
2. Run dispatch preflight validation.
3. Fetch candidate sessions from tracker using active states.
4. Sort sessions by dispatch priority.
5. Dispatch eligible sessions while slots remain.
6. Notify observability/status consumers of state changes.

### 8.2 Candidate Selection Rules

A session is dispatch-eligible only if all are true:

- It has `id`, `identifier`, `title`, and `state`.
- Its state is in `active_states` and not in `terminal_states`.
- It is not already in `running`.
- It is not already in `claimed`.
- Global concurrency slots are available.
- Per-state concurrency slots are available.
- Blocker rule passes for any tracker state the workflow treats as a `Todo`-equivalent queue
  state: do not dispatch when any blocker is non-terminal.

Sorting order (stable intent):

1. `priority` ascending (1..4 preferred; null/unknown sorts last).
2. `created_at` oldest first.
3. `identifier` lexicographic tie-breaker.

### 8.3 Concurrency Control

Global limit:

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state limit:

- `max_concurrent_agents_by_state[state]` if present (state key normalized).
- Otherwise fallback to global limit.

### 8.4 Retry and Backoff

Retry entry creation:

- Cancel any existing retry timer for the same session.
- Store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle.

Backoff formula:

- Continuation retries after a clean exit use a short fixed delay of `1000` ms.
- Failure-driven retries: `delay = min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)`.

Retry handling behavior:

1. Fetch active candidate sessions.
2. Find the specific session by `issue_id`.
3. If not found, release claim.
4. If found and still candidate-eligible: dispatch if slots available, otherwise requeue.
5. If found but no longer active, release claim.

### 8.5 Active Run Reconciliation

Part A: Stall detection — terminate workers whose `elapsed_ms` since the last codex event (or
`started_at` if none) exceeds `codex.stall_timeout_ms`, and schedule retry.

Part B: Tracker state refresh — fetch current session states for all running session IDs.

- Terminal -> terminate worker and clean workspace.
- Active -> update in-memory snapshot.
- Other -> terminate worker without workspace cleanup.

### 8.6 Startup Terminal Workspace Cleanup

When the service starts:

1. Query tracker for sessions in terminal states.
2. For each returned session, remove the corresponding workspace directory.
3. If the terminal-sessions fetch fails, log a warning and continue.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

- Workspace root: `workspace.root` (normalized absolute path).
- Per-session workspace path: `<workspace.root>/<sanitized_issue_identifier>`.
- Workspaces are reused across runs for the same session; successful runs do not auto-delete
  workspaces.

### 9.2 Workspace Creation and Reuse

1. Sanitize identifier to `workspace_key`.
2. Compute workspace path under workspace root.
3. Ensure the workspace path exists as a directory.
4. Mark `created_now=true` only if the directory was created during this call.
5. If `created_now=true`, run `after_create` hook if configured.

### 9.3 OPTIONAL Workspace Population

The spec does not require any built-in VCS bootstrap behavior. Implementations MAY populate the
workspace using hooks (typical: `git clone` in `after_create`).

### 9.4 Workspace Hooks

Supported hooks: `after_create`, `before_run`, `after_run`, `before_remove`.

Execution: `bash -lc <script>` (or equivalent), `cwd = workspace_path`,
timeout = `hooks.timeout_ms`.

Failure semantics:

- `after_create` failure/timeout is fatal to workspace creation.
- `before_run` failure/timeout is fatal to the current attempt.
- `after_run` and `before_remove` failures/timeouts are logged and ignored.

### 9.5 Safety Invariants

Invariant 1: Run the coding agent only in the per-session workspace path.

Invariant 2: Workspace path MUST stay inside workspace root (normalize both to absolute and require
prefix containment).

Invariant 3: Workspace key is sanitized to `[A-Za-z0-9._-]`; replace all other characters with `_`.

### 9.6 Workspace Repo Seeding (Recommended)

A Traffic Control session typically targets a single GitHub repository. To avoid asking the coding
agent to perform clones from inside a network-restricted sandbox, implementations SHOULD seed the
workspace from the host process (e.g. an `after_create` hook) before the agent starts.

Resolution priority (first non-empty wins):

1. `links.yaml` entries with `kind: repo` whose URL matches `https://github.com/<org>/<name>`.
2. `links.yaml` entries with `kind: pr` — extract `<org>/<name>` from
   `https://github.com/<org>/<name>/pull/<n>`.
3. `session.yaml` `cwd:` if it contains a `<known-org>/<repo>` segment (`teamupstart`,
   `nigel-upstart`, `openai`, `getprodigy`).

Outcomes the seeder MUST distinguish:

| Condition | Behavior |
|---|---|
| Workspace already a clone of the resolved repo | No-op (idempotent re-runs). |
| Workspace empty, exactly one resolved repo | Clone via SSH, `git checkout` `session.branch` if set (create from `origin/main` if absent). |
| Multiple distinct repos resolved across signals | Refuse; non-zero exit. Session SHOULD be split before re-dispatch. |
| Workspace already a clone of a *different* repo | Refuse; non-zero exit. Operator must clear the workspace before re-dispatch. |
| No repo signal in session data | Refuse; non-zero exit. Session SHOULD be enriched with a `kind: repo` link or a `cwd` containing a known org/repo path. |

Refusal cases bubble up as `after_create` hook failures (per §9.4), which are fatal to workspace
creation; the orchestrator surfaces these in logs and the session remains undispatched.

Seeding runs OUTSIDE the Codex sandbox, so DNS, SSH, and writes to `.git` succeed even when the
turn sandbox is `workspaceWrite` with `networkAccess=false`.

## 10. Agent Runner Protocol (Coding Agent Integration)

### 10.1 Launch Contract

- Command: `codex.command`
- Invocation: `bash -lc <codex.command>`
- Working directory: workspace path
- Transport: protocol transport required by the targeted Codex app-server version

### 10.2 Session Startup Responsibilities

The client MUST:

- Start the app-server subprocess in the per-session workspace.
- Initialize the app-server session per the targeted Codex protocol.
- Create or resume a coding-agent thread.
- Supply the absolute per-session workspace path as the working directory.
- Start the first turn with the rendered prompt.
- Use continuation guidance (not a fresh task prompt) for in-worker continuation turns on the same
  thread.
- Apply the implementation's documented approval and sandbox policy.
- Include session-identifying metadata (for example `<issue.identifier>: <issue.title>`) when the
  protocol supports turn or session titles.
- Advertise implemented client-side tools, including the `sardine_run_session` dynamic tool
  defined in Section 10.5.

Session identifiers:

- `thread_id` from the thread identity returned by the app-server.
- `turn_id` from each turn identity.
- `session_id = "<thread_id>-<turn_id>"`.
- Reuse the same `thread_id` for all continuation turns inside one worker run.

### 10.3 Streaming Turn Processing

Process app-server updates until the active turn terminates.

Completion conditions:

- Protocol turn completion -> success
- Protocol turn failure / cancellation / timeout / subprocess exit -> failure

Continuation processing keeps the app-server alive across continuation turns; stop only when the
worker run is ending.

### 10.4 Emitted Runtime Events (Upstream to Orchestrator)

Each event SHOULD include `event`, `timestamp`, `codex_app_server_pid` (when available), OPTIONAL
`usage` map, and event-specific payload.

Important emitted events: `session_started`, `startup_failed`, `turn_completed`, `turn_failed`,
`turn_cancelled`, `turn_ended_with_error`, `turn_input_required`, `approval_auto_approved`,
`unsupported_tool_call`, `notification`, `other_message`, `malformed`.

### 10.5 Approval, Tool Calls, and the `sardine_run_session` Dynamic Tool

Approval, sandbox, and user-input behavior is implementation-defined. Approval requests and
user-input-required events MUST NOT leave a run stalled indefinitely.

Unsupported dynamic tool calls return a tool failure response and continue the session.

#### `sardine_run_session` (REQUIRED dynamic tool)

The orchestrator advertises one client-side dynamic tool to every Codex session: `sardine_run_session`.
The agent uses it to keep its assigned Traffic Control session in sync with its work without writing
files directly.

Tool input shape:

```json
{
  "operation": "status | heartbeat | note | link | focus | next_step | git_push | list_review_comments | reply_to_comment | resolve_thread | request_human_help",
  "session_id": "<traffic-control-session-id>",
  "status": "active | blocked | waiting | review | done | archived",
  "waiting_kind": "human | ci | review | external | other",
  "waiting_note": "free text",
  "body": "markdown body for note / reply / human-help request",
  "label": "link label",
  "link_kind": "jira | slack | pr | doc | repo | other",
  "url": "https://...",
  "last_event": "string",
  "last_message": "string",
  "last_error": "string",
  "input_tokens": 123,
  "output_tokens": 456,
  "total_tokens": 579,
  "value": "string for focus/next_step",
  "branch": "branch-name-to-push",
  "remote": "origin",
  "comment_id": 12345,
  "thread_id": "PRRT_…",
  "reason": "rationale for resolve_thread"
}
```

`operation` and `session_id` are always required. Per-operation requirements:

- `status` — `status` is required. When `status == "waiting"`, `waiting_kind` defaults to
  `"other"` and `waiting_note` is OPTIONAL. `review_pending` is intentionally NOT a valid
  argument: it is a watcher-derived state and the agent transitions out of it (back to
  `review`, or onward to `waiting`/`done`) rather than into it.
- `heartbeat` — all runtime fields (`last_event`, `last_message`, `last_error`, token counters)
  are OPTIONAL; the writer records whatever is supplied.
- `note` — `body` is required and is appended to `notes.md` for the session.
- `link` — `label`, `link_kind`, and `url` are required and append an entry to `links.yaml`.
- `focus` and `next_step` — `value` sets the field; an empty string clears it.
- `git_push` — `branch` is required (branch name to push); `remote` is OPTIONAL and defaults to
  `"origin"`. The orchestrator executes `git push <remote> <branch>` in the workspace on behalf
  of the agent, so the agent's sandbox network restrictions do not apply. Branch and remote names
  are validated: must not start with `-`, must not contain `..`, and must match
  `[a-zA-Z0-9][a-zA-Z0-9._\-\/]*`. On success returns `{"success": true, "output": "..."}`. On
  push failure returns `{"success": false, "error": {"kind": "git_push_failed", ...}}`.
- `list_review_comments` — reviewer-only. No additional args. Returns the
  current `pending_feedback` snapshot the watcher (§6.6) wrote to
  `sessions/<id>/pending_feedback.yaml`, or `{}` when no snapshot exists.
- `reply_to_comment` — reviewer-only. `comment_id` (integer) and `body`
  (string) are required. The orchestrator resolves the PR via the
  session's first `link_kind: pr` link and POSTs an inline reply via
  `gh api repos/{owner}/{repo}/pulls/{number}/comments -f body=… -F
  in_reply_to=<comment_id>`. Fails with `kind: gh_failed` on gh
  non-zero exit.
- `resolve_thread` — reviewer-only. `thread_id` (GraphQL node id,
  validated against `[A-Za-z0-9_-]+`) and `reason` (string, recorded for
  caller bookkeeping) are required. Issues the
  `resolveReviewThread` GraphQL mutation via `gh api graphql`. The
  substantive reply belongs in the preceding `reply_to_comment`; the
  `reason` is a short rationale for the resolve action itself.
- `request_human_help` — reviewer-only. `body` (string) is required.
  Flips the session's status to `waiting` with `waiting_kind: human` and
  records `body` as the waiting note.

Tool result semantics:

- Success returns `{"success": true, ...}` with the operation echo.
- Validation failures return `{"success": false, "error": {"kind": "invalid_arguments", ...}}`.
- Filesystem write failures return `{"success": false, "error": {"kind": "writer_error", ...}}`.
- gh non-zero exits return `{"success": false, "error": {"kind": "gh_failed", ...}}`.

Implementations MUST advertise this tool during session startup so that the agent can drive its
assigned session. Implementations MAY add additional client-side tools.

### 10.6 Timeouts and Error Mapping

- `codex.read_timeout_ms` — request/response timeout during startup and sync requests.
- `codex.turn_timeout_ms` — total turn stream timeout.
- `codex.stall_timeout_ms` — enforced by orchestrator based on event inactivity.

Error categories: `codex_not_found`, `invalid_workspace_cwd`, `response_timeout`, `turn_timeout`,
`port_exit`, `response_error`, `turn_failed`, `turn_cancelled`, `turn_input_required`.

### 10.7 Agent Runner Contract

1. Create/reuse workspace.
2. Build prompt from workflow template.
3. Start app-server session (advertising `sardine_run_session`).
4. Forward app-server events to orchestrator.
5. On any error, fail the worker attempt; the orchestrator will retry.

Workspaces are intentionally preserved after successful runs.

## 11. Tracker Integration Contract (Traffic Control)

### 11.1 REQUIRED Operations

A tracker adapter MUST support:

1. `fetch_candidate_issues()` — Sessions in configured active states.
2. `fetch_issues_by_states(state_names)` — Used for startup terminal cleanup.
3. `fetch_issue_states_by_ids(issue_ids)` — Used for active-run reconciliation.

### 11.2 Traffic Control State Repo Layout

A Traffic Control state repo is a regular filesystem directory (typically version-controlled) with
this layout:

```
<state_repo>/
  sessions/
    <session_id>/
      session.yaml      # core state (status, title, links, focus, next_step, runtime)
      notes.md          # append-only narrative log
      links.yaml        # structured related-resource entries
```

The adapter:

- Lists `sessions/*/session.yaml` to enumerate candidate sessions.
- Parses each `session.yaml` into a normalized `Issue` record.
- Treats the `status` field of `session.yaml` as the canonical session state.
- Normalizes status values for state comparison (`lowercase`).
- Maps the directory name to both `id` and `identifier`.

Recognized status values: `active`, `blocked`, `waiting`, `review`, `review_pending`,
`done`, `archived`. `review_pending` is a derived state: an external watcher (§6.7) or
the reviewer agent itself transitions a session into and out of this status; tracker
adapters MUST round-trip it like any other status value.

### 11.3 Tracker Writes

Tracker writes go through the `sardine_run_session` dynamic tool (Section 10.5). The orchestrator
exposes a `SessionWriter` that performs atomic writes to `session.yaml`, `notes.md`, and
`links.yaml` under the configured `state_repo`.

Direct write APIs from the orchestrator are not required; agents drive session updates through the
dynamic tool.

### 11.4 Error Categories

- `state_repo_not_configured`
- `state_repo_not_found`
- `session_not_found`
- `session_yaml_parse_error`
- `session_yaml_write_error`

Orchestrator behavior on tracker errors:

- Candidate fetch failure: log and skip dispatch for this tick.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal cleanup failure: log warning and continue startup.

### 11.5 Memory Tracker (Test Use)

`tracker.kind: memory` selects an in-process memory adapter. It exists to support deterministic
tests and is not intended for production use.

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

- `workflow.prompt_template`
- normalized `issue` object
- OPTIONAL `attempt` integer

### 12.2 Rendering Rules

- Strict variable checking.
- Strict filter checking.
- Convert issue object keys to strings for template compatibility.
- Preserve nested arrays/maps so templates can iterate.

### 12.3 Retry/Continuation Semantics

`attempt` SHOULD be passed to the template so the workflow prompt can branch on first run, retry,
or continuation.

### 12.4 Failure Semantics

If prompt rendering fails, fail the run attempt immediately and let the orchestrator retry.

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

REQUIRED context for session-related logs: `issue_id`, `issue_identifier`.

REQUIRED context for coding-agent session lifecycle logs: `session_id`.

Use stable `key=value` phrasing. Include outcome (`completed`, `failed`, `retrying`, etc.) and a
concise reason. Avoid logging large raw payloads.

### 13.2 Logging Outputs and Sinks

The spec does not prescribe sinks. Operators MUST be able to see startup/validation/dispatch
failures without a debugger. Sink failure SHOULD NOT crash the service.

### 13.3 Runtime Snapshot / Monitoring Interface (OPTIONAL but RECOMMENDED)

Snapshot SHOULD return:

- `running` (rows with `turn_count`)
- `retrying`
- `codex_totals` (`input_tokens`, `output_tokens`, `total_tokens`, `seconds_running`)
- `rate_limits`

### 13.4 OPTIONAL Human-Readable Status Surface

A status surface MUST draw from orchestrator state only and MUST NOT be REQUIRED for correctness.

### 13.5 Session Metrics and Token Accounting

- Prefer absolute thread totals (`thread/tokenUsage/updated`, `total_token_usage`).
- Ignore delta payloads (`last_token_usage`) for dashboard totals.
- Track deltas relative to last reported totals to avoid double-counting.
- Do not treat generic `usage` maps as cumulative totals.

Runtime accounting SHOULD be reported as a live aggregate at snapshot/render time.

Track the latest rate-limit payload seen in any agent update.

### 13.6 Humanized Agent Event Summaries (OPTIONAL)

Treat humanized summaries as observability-only. Do not make orchestrator logic depend on them.

### 13.7 OPTIONAL HTTP Server Extension

Enabled when CLI `--port` is set or `server.port` is present in `WORKFLOW.md`. CLI `--port`
overrides `server.port`. Implementations SHOULD bind loopback by default. Restart-required
behavior is conformant for HTTP listener changes.

#### 13.7.1 Human-Readable Dashboard (`/`)

A dashboard SHOULD depict active sessions, retry delays, token consumption, runtime totals, recent
events, and health/error indicators.

#### 13.7.2 JSON REST API (`/api/v1/*`)

Minimum endpoints:

- `GET /api/v1/state` — Summary of running/retrying sessions, token totals, rate limits.

  ```json
  {
    "generated_at": "2026-04-30T20:15:30Z",
    "counts": { "running": 2, "retrying": 1 },
    "running": [
      {
        "issue_id": "MT-649",
        "issue_identifier": "MT-649",
        "state": "active",
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "last_event": "turn_completed",
        "last_message": "",
        "started_at": "2026-04-30T20:10:12Z",
        "last_event_at": "2026-04-30T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      }
    ],
    "retrying": [
      {
        "issue_id": "MT-650",
        "issue_identifier": "MT-650",
        "attempt": 3,
        "due_at": "2026-04-30T20:16:00Z",
        "error": "no available orchestrator slots"
      }
    ],
    "codex_totals": {
      "input_tokens": 5000,
      "output_tokens": 2400,
      "total_tokens": 7400,
      "seconds_running": 1834.2
    },
    "rate_limits": null
  }
  ```

- `GET /api/v1/<issue_identifier>` — Session-specific runtime/debug details. `404` if unknown.

- `POST /api/v1/refresh` — Queues an immediate poll + reconciliation cycle.

  ```json
  {
    "queued": true,
    "coalesced": false,
    "requested_at": "2026-04-30T20:15:30Z",
    "operations": ["poll", "reconcile"]
  }
  ```

API design notes:

- Endpoints SHOULD be read-only except for operational triggers like `/refresh`.
- Unsupported methods SHOULD return `405`.
- Errors use `{"error":{"code":"...","message":"..."}}`.

#### 13.7.3 Session Detail View (`/session/<issue_identifier>`)

A per-session drill-down page SHOULD surface live agent state (turn count, last event, tokens,
runtime), workspace git history, the tail of the session's log lines, notes.md contents, and
on-disk file paths (session.yaml, notes.md, links.yaml, workspace path). Returns `404` if the
`issue_identifier` is not in the current snapshot. Does not mutate session state.

`/session/<issue_identifier>` is the canonical deep-link path. External tools (e.g. the Traffic
Control dashboard) MAY render a back-link by composing `<dashboard_url>/session/<issue_identifier>`
where `<dashboard_url>` is the value advertised on the session runtime payload (§13.7.4).

#### 13.7.4 Dashboard URL Advertisement on Session Runtime

When the HTTP server is enabled, an implementation SHOULD write its public dashboard URL to the
session's runtime payload (`sardine_run.dashboard_url`) on dispatch and clear it on orderly
shutdown. The URL takes the form `http://<host>:<port>` where `<host>` resolves from the
`SARDINE_RUN_PUBLIC_HOSTNAME` environment variable when set, falling back to the host's resolved
hostname. When the dashboard is disabled, the field MUST NOT be written. A stale value left
behind by a hard kill is acceptable; consumers MUST tolerate connection failures gracefully.

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. Workflow/Config — missing or invalid `WORKFLOW.md`, unsupported tracker kind, missing
   `tracker.state_repo`, missing coding-agent executable.
2. Workspace — directory creation, hook failure/timeout, invalid workspace path.
3. Agent Session — startup handshake, turn failure/cancellation/timeout, subprocess exit, stalled
   session.
4. Tracker — state-repo not found, session.yaml parse error, write error.
5. Observability — snapshot timeout, dashboard render errors, log sink configuration failure.

### 14.2 Recovery Behavior

- Dispatch validation failures: skip new dispatches, keep service alive, continue reconciliation.
- Worker failures: retries with exponential backoff.
- Tracker candidate-fetch failures: skip this tick, retry next tick.
- Reconciliation refresh failures: keep current workers, retry next tick.
- Dashboard/log failures: do not crash the orchestrator.

### 14.3 Partial State Recovery (Restart)

Scheduler state is intentionally in-memory. After restart:

- No retry timers are restored.
- No running sessions are assumed recoverable.
- Service recovers via startup terminal workspace cleanup, fresh polling of active sessions, and
  re-dispatching eligible work.

### 14.4 Operator Intervention Points

- Editing `WORKFLOW.md` (auto-detected and re-applied).
- Editing `session.yaml` directly in the state repo (terminal status -> running session is stopped
  and workspace cleaned when reconciled).
- Restarting the service.

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

Implementations SHOULD state clearly whether they target trusted or restrictive environments and
which controls (auto-approval, operator approvals, sandboxing) they rely on.

### 15.2 Filesystem Safety Requirements

- Workspace path MUST remain under configured workspace root.
- Coding-agent cwd MUST be the per-session workspace path.
- Workspace directory names MUST use sanitized identifiers.

### 15.3 Secret Handling

- Support `$VAR` indirection in workflow config.
- Do not log secret env values.

### 15.4 Hook Script Safety

- Hooks are arbitrary shell scripts from `WORKFLOW.md` and are fully trusted configuration.
- Hooks run inside the workspace directory.
- Hook timeouts are REQUIRED.

### 15.5 Harness Hardening Guidance

Running coding agents against a Traffic Control state repo, a workspace tree, and the
`sardine_run_session` writer can be dangerous in permissive deployments. Implementations SHOULD:

- Use stricter Codex approval and sandbox settings rather than running fully permissive.
- Add OS/container/VM isolation, network restrictions, or separate credentials where appropriate.
- Filter which sessions are eligible for dispatch (by status, label, or repo) so out-of-scope work
  does not auto-route to the agent.
- Restrict the set of client-side tools, credentials, and paths exposed to the agent to the minimum
  the workflow needs.

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_workflow_watch(on_change=reload_and_reapply_workflow)

  state = {
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    completed: set(),
    codex_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    codex_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  for issue in sort_for_dispatch(issues):
    if no_available_slots(state):
      break
    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

### 16.4 Dispatch One Session

```text
function dispatch_issue(issue, state, attempt):
  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid) end
  )
  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })
  state.running[issue.id] = new_running_entry(...)
  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed: fail_worker("workspace error")
  if run_hook("before_run", workspace.path) failed: fail_worker("before_run hook error")

  session = app_server.start_session(
    workspace=workspace.path,
    tools=[sardine_run_session_tool_spec()]
  )
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  max_turns = config.agent.max_turns
  turn_number = 1

  while true:
    prompt = build_turn_prompt(workflow_template, issue, attempt, turn_number, max_turns)
    if prompt failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("prompt error")

    turn_result = app_server.run_turn(
      session=session,
      prompt=prompt,
      issue=issue,
      on_message=(msg) -> send(orchestrator_channel, {codex_update, issue.id, msg}),
      on_tool_call=(tool, args) -> handle_dynamic_tool_call(tool, args)
    )
    if turn_result failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("agent turn error")

    refreshed_issue = tracker.fetch_issue_states_by_ids([issue.id])
    if refreshed_issue failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("issue state refresh error")

    issue = refreshed_issue[0] or issue
    if issue.state is not active: break
    if turn_number >= max_turns: break
    turn_number = turn_number + 1

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)
  exit_normal()
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    state.completed.add(issue_id)
    state = schedule_retry(state, issue_id, 1, {
      identifier: running_entry.identifier,
      delay_type: continuation
    })
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      identifier: running_entry.identifier,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

```text
on_retry_timer(issue_id, state):
  retry_entry = state.retry_attempts.pop(issue_id)
  if missing: return state

  candidates = tracker.fetch_candidate_issues()
  if fetch failed:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: retry_entry.identifier,
      error: "retry poll failed"
    })

  issue = find_by_id(candidates, issue_id)
  if issue is null:
    state.claimed.remove(issue_id)
    return state

  if available_slots(state) == 0:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: issue.identifier,
      error: "no available orchestrator slots"
    })

  return dispatch_issue(issue, state, attempt=retry_entry.attempt)
```

## 17. Test and Validation Matrix

A conforming implementation SHOULD include tests covering the behaviors below.

### 17.1 Workflow and Config Parsing

- Workflow file path precedence (explicit runtime path vs cwd default).
- Workflow file changes detected and re-applied without restart.
- Invalid reload keeps last known good configuration and emits operator-visible error.
- Missing/invalid `WORKFLOW.md` produces typed errors.
- Config defaults apply when OPTIONAL values are missing.
- `tracker.kind` validation enforces supported kinds (`traffic_control`, `memory`).
- `tracker.state_repo` resolution handles `$TRAFFIC_CONTROL_STATE_REPO` and literal paths.
- `~` and `$VAR` path expansion works.
- `codex.command` is preserved as a shell command string.
- Per-state concurrency override map normalizes state names and ignores invalid values.
- Prompt template renders `issue` and `attempt`, fails on unknown variables.

### 17.2 Workspace Manager and Safety

- Deterministic workspace path per session identifier.
- Missing workspace directory is created; existing directory is reused.
- `after_create` runs only on new creation.
- `before_run` failure/timeout aborts the attempt; `after_run`/`before_remove` failures are logged
  and ignored.
- Workspace path sanitization and root containment invariants enforced before agent launch.

### 17.3 Tracker Adapter (Traffic Control)

- Candidate fetch lists `sessions/*/session.yaml` filtered by active states.
- Issue-state refresh by ID returns minimal normalized issues.
- Empty `fetch_issues_by_states([])` returns empty without filesystem traversal.
- Missing/invalid state repo produces typed errors.
- Status normalization handles `active|blocked|waiting|review|review_pending|done|archived`.

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch sort order is priority then oldest creation time.
- Active-state refresh updates running entry state.
- Non-active state stops running agent without workspace cleanup.
- Terminal state stops running agent and cleans workspace.
- Normal worker exit schedules a short continuation retry.
- Abnormal worker exit increments retries with 10s-based exponential backoff.
- Stall detection kills stalled sessions and schedules retry.
- Slot exhaustion requeues retries with explicit error reason.
- If a snapshot API is implemented, it returns running rows, retry rows, token totals, rate limits.

### 17.5 Coding-Agent App-Server Client

- Launch command uses workspace cwd and invokes `bash -lc <codex.command>`.
- Session startup follows the targeted Codex app-server protocol.
- Policy-related startup payloads use the implementation's documented approval/sandbox settings.
- Thread/turn identities are extracted into `session_started` with `<thread_id>-<turn_id>`.
- Read timeout, turn timeout, and stall timeout are enforced.
- Unsupported dynamic tool calls are rejected without stalling the session.
- The `sardine_run_session` dynamic tool is advertised at startup and routed to the SessionWriter.
  - Each operation (`status`, `heartbeat`, `note`, `link`, `focus`, `next_step`) validates inputs
    and writes the expected file artifacts under `sessions/<id>/` in the state repo.
  - Validation errors return `{"success": false, "error": {"kind": "invalid_arguments", ...}}`.
  - Filesystem write errors return `{"success": false, "error": {"kind": "writer_error", ...}}`.
- Usage and rate-limit telemetry from the targeted protocol is extracted.

### 17.6 Observability

- Validation failures are operator-visible.
- Structured logging includes `issue_id`, `issue_identifier`, and `session_id` context fields.
- Logging sink failures do not crash orchestration.
- Token/rate-limit aggregation remains correct across repeated agent updates.

### 17.7 CLI and Host Lifecycle

- CLI accepts a positional workflow path argument.
- CLI uses `./WORKFLOW.md` when no path is provided.
- CLI errors on nonexistent explicit workflow path or missing default `./WORKFLOW.md`.
- CLI surfaces startup failure cleanly and exits nonzero on abnormal startup/exit.
- CLI requires the documented guardrails-acknowledgement flag when the implementation enforces it.

## 18. Implementation Checklist (Definition of Done)

### 18.1 REQUIRED for Conformance

- Workflow path selection (explicit or cwd default).
- `WORKFLOW.md` loader with YAML front matter + prompt body split.
- Typed config layer with defaults and `$` resolution.
- Dynamic `WORKFLOW.md` watch/reload/re-apply for config and prompt.
- Polling orchestrator with single-authority mutable state.
- Traffic Control tracker adapter with candidate fetch + state refresh + terminal fetch.
- Workspace manager with sanitized per-session workspaces.
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`).
- Hook timeout config (`hooks.timeout_ms`).
- Coding-agent app-server subprocess client.
- Codex launch command config (`codex.command`).
- Strict prompt rendering with `issue` and `attempt` variables.
- Exponential retry queue with continuation retries after normal exit.
- Configurable retry backoff cap (`agent.max_retry_backoff_ms`).
- Reconciliation that stops runs on terminal/non-active tracker states.
- Workspace cleanup for terminal sessions (startup sweep + active transition).
- `sardine_run_session` dynamic tool advertised at startup and routed to a SessionWriter that
  performs atomic writes to the state repo.
- Structured logs with `issue_id`, `issue_identifier`, and `session_id`.
- Operator-visible observability (structured logs; OPTIONAL snapshot/status surface).

### 18.2 RECOMMENDED Extensions

- HTTP server extension honoring CLI `--port` over `server.port`, with safe default bind host.
- SSH worker extension for remote worker execution (Appendix A).
- Additional client-side tools beyond `sardine_run_session`.
- TODO: Persist retry queue and session metadata across restarts.
- TODO: Pluggable tracker adapters beyond Traffic Control + memory.

### 18.3 Operational Validation Before Production

- Verify hook execution and workflow path resolution on the target host OS/shell.
- If the OPTIONAL HTTP server is shipped, verify port behavior and loopback bind expectations.

## Appendix A. SSH Worker Extension (OPTIONAL)

Sardine Run keeps one central orchestrator and OPTIONALLY executes worker runs on remote hosts over
SSH.

Extension config:

- `worker.ssh_hosts` (list of SSH host strings, OPTIONAL) — when omitted, work runs locally.
- `worker.max_concurrent_agents_per_host` (positive integer, OPTIONAL) — shared per-host cap.

### A.1 Execution Model

- The orchestrator remains the single source of truth for polling, claims, retries, reconciliation.
- `workspace.root` is interpreted on the remote host.
- The coding-agent app-server is launched over SSH stdio.
- Continuation turns inside one worker lifetime SHOULD stay on the same host and workspace.
- A remote host SHOULD satisfy the same contract as a local worker environment.

### A.2 Scheduling Notes

- SSH hosts MAY be treated as a pool for dispatch.
- Implementations MAY prefer the previously used host on retries.
- When all SSH hosts are at capacity, dispatch SHOULD wait rather than silently falling back to a
  different execution mode.
- Implementations MAY fail over to another host before work has meaningfully started; once side
  effects exist, a transparent rerun on another host SHOULD be treated as a new attempt.

### A.3 Problems to Consider

- Remote environment drift (shell, agent binary, auth, repo prerequisites).
- Workspace locality — moving a session to a different host is typically a cold restart.
- Path/command safety crosses a machine boundary.
- Distinguish host-connectivity/startup failures from in-workspace agent failures.
- Dead/overloaded host SHOULD reduce capacity, not duplicate execution.
- Operators need to know which host owns a run and where its workspace lives.
