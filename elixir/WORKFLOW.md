---
tracker:
  kind: traffic_control
  state_repo: "$TRAFFIC_CONTROL_STATE_REPO"
  active_states:
    - active
  terminal_states:
    - done
    - archived
polling:
  interval_ms: 5000
workspace:
  root: ~/code/sardine-run-workspaces
hooks:
  # Seeds the workspace by resolving the target repo from session.yaml /
  # links.yaml (links `kind: repo`, then `kind: pr`, then `cwd:`), cloning it
  # via SSH, and checking out session.branch. Runs outside the Codex sandbox
  # so DNS / .git writes work. See `elixir/scripts/seed-workspace.sh` and
  # SPEC.md §11 (Workspace Repo Seeding).
  after_create: "$HOME/repos/nigel-upstart/sardine-run/elixir/scripts/seed-workspace.sh"
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: "$HOME/repos/nigel-upstart/sardine-run/elixir/scripts/codex-launch.sh"
  approval_policy: never
  thread_sandbox: workspace-write
  # Network access is ON so turns can run npm ci / uv sync / CDK commands against
  # CodeArtifact and PyPI. Cloning still happens in the after_create hook (host
  # process, outside the sandbox) so SSH credentials stay on the host.
  network_access: true
  # turn_sandbox_policy intentionally unset: Elixir injects a default with
  # writableRoots=[<workspace>], readOnlyAccess=fullAccess, networkAccess=<above>.
---

You are working on a Traffic Control session `{{ issue.identifier }}`.

## Known repositories

The repos you may be working in:

| GitHub repo | Typical session title patterns |
|---|---|
| `github.com/nigel-upstart/traffic-control` | `tc:`, `feat:` or `fix:` for dashboard/CLI/agent_runtime |
| `github.com/teamupstart/claude-code-extensions` | `tce-XXX:`, `cce:` |
| `github.com/teamupstart/coral` | `coral-XXX` in title or branch |
| `github.com/teamupstart/ai-acceleration` | AWS infra, ai-acceleration in title |
| `github.com/teamupstart/otel-ai-gateway` | otel or gateway in title |
| `github.com/teamupstart/template-slack-bot-vercel` | `escape-velocity-api-XXX`, `slack_bot_vercel` |
| `github.com/teamupstart/gen-ai-guild-slack-bot` | `GENAI-XXX` issues, bufmoji, guild |
| `github.com/teamupstart/cicd-reusable-workflows` | `fix:` or `feat:` for CI/CD workflow pins and updates |

## Workspace and repo setup

Your workspace has already been seeded by the orchestrator (see SPEC.md §11):
the target repo is cloned and `{{ issue.branch_name }}` (if set) is checked out.
Codex runs with `cwd = <workspace>`, network access OFF, and write access
restricted to the workspace.

At the start of each session:

1. Run any standard project setup (e.g. `npm install`, `mix setup`, `uv sync`) based
   on what you find in the repo root.
2. Confirm the seeded clone matches `{{ issue.title }}` / `{{ issue.branch_name }}`.
   If `git config remote.origin.url` does not match the expected repo, stop
   immediately and set `status: waiting` (`waiting_kind: external`) — do not
   attempt to re-clone, since network is disabled inside the sandbox.
3. If the workspace is empty (no `.git`), the seeder could not resolve a single
   target repo from the session data. Set `status: waiting` with a note that
   names what data is missing or ambiguous.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the session is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the session remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the session to `waiting` via the `sardine_run_session` tool.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only inside the assigned workspace directory. Do not touch any other path on the filesystem.

## The `sardine_run_session` dynamic tool (your interface to Traffic Control)

The orchestrator advertises one client-side tool, `sardine_run_session`. Use it to keep the
Traffic Control session in sync with your work. Always pass the assigned `session_id`
(`{{ issue.identifier }}`).

Operations:

- `operation: status` with `status: active|blocked|waiting|review|done|archived`. When
  `status: waiting`, also pass `waiting_kind` (`human|ci|review|external|other`) and an optional
  `waiting_note` describing the reason.
- `operation: heartbeat` periodically with `last_event`, `last_message`, optional `last_error`,
  and any cumulative `input_tokens` / `output_tokens` / `total_tokens` you have. This is how
  observers see live progress.
- `operation: note` with `body` (markdown) — appends to `sessions/{{ issue.identifier }}/notes.md`.
- `operation: link` with `label`, `link_kind` (`jira|slack|pr|doc|repo|other`), and `url` —
  appends an entry to `sessions/{{ issue.identifier }}/links.yaml`.
- `operation: focus` with `value` — sets the session's current focus (empty string clears it).
- `operation: next_step` with `value` — sets the intended next step (empty string clears it).

Use `note` for narrative progress; use `focus` / `next_step` for the one-line summary fields.

## Default posture

- Start by reading the current `session.yaml` status and notes via your repo skills, then follow
  the matching flow for that status.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: confirm the current behavior/issue signal before changing code so the fix
  target is explicit.
- Treat the workpad in `notes.md` as the source of truth for progress; do not duplicate it
  elsewhere.
- Treat any session-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable
  acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution, file a separate
  Traffic Control session instead of expanding scope. The follow-up session must include a clear
  title, description, and acceptance criteria; link the current session as `related`; and use the
  appropriate blocker relation if it depends on the current session.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers after exhausting documented
  fallbacks.

## Related skills

- `commit`: produce clean, logical commits during implementation.
- `push`: keep the remote branch current and publish updates.
- `pull`: keep the branch updated with latest `origin/main` before handoff.
- `land`: when the session reaches `Merging`, explicitly open and follow
  `.codex/skills/land/SKILL.md`, which includes the `land` loop.
- `tc-sync-in` / `tc-sync-out`: keep your local Traffic Control state repo in sync with shared
  storage when applicable.

## Status map

Traffic Control session status values you will set via `sardine_run_session`:

- `active` -> implementation actively underway.
- `blocked` -> a hard external dependency prevents progress; record details in the workpad.
- `waiting` -> waiting on a human, CI, review, or other external signal. Always set `waiting_kind`
  and a `waiting_note`.
- `review` -> work is complete and a PR is attached; waiting on human approval.
- `done` -> terminal; merged and confirmed.
- `archived` -> terminal; superseded or not pursued.

Workflow-internal handoff cues you may also see in `notes.md`:

- `Todo` (informal) -> queued; transition to `active` before starting work.
- `Rework` (informal) -> reviewer requested changes; planning + implementation required.
- `Merging` (informal) -> approved by human; execute the `land` skill flow (do not call
  `gh pr merge` directly).

## Step 0: Determine current session state and route

1. Read the session via your repo skills (or note its current status from the prompt context).
2. Route to the matching flow:
   - new/queued -> set `status: active` via `sardine_run_session` and ensure a `## Codex Workpad`
     entry exists in `notes.md` (create one with `operation: note` if missing).
   - already `active` -> continue execution flow from the current workpad.
   - `review` -> wait and poll for decision/review updates; do not change code.
   - merging cue in workpad -> open and follow `.codex/skills/land/SKILL.md`; do not call
     `gh pr merge` directly.
   - `blocked` or `waiting` -> if you can resolve the blocker, set `status: active` and proceed;
     otherwise leave it and record progress.
   - `done` / `archived` -> shut down for this session.
3. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable
     for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.

## Step 1: Start/continue execution

1.  Find or create a single persistent workpad in `notes.md`:
    - Look for a marker header: `## Codex Workpad`.
    - If found, reuse it; do not create a new one.
    - If missing, append one via `sardine_run_session operation: note` and use it for all updates.
2.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
3.  Start work by writing/updating a hierarchical plan in the workpad.
4.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/sardine-run-workspaces/MT-32@7bdde33bc`
5.  Add explicit acceptance criteria and TODOs in checklist form in the same workpad.
    - If changes are user-facing, include a UI walkthrough acceptance criterion.
    - If changes touch app behavior, add explicit app-specific flow checks.
    - Copy any `Validation`, `Test Plan`, or `Testing` section from the session description into
      the workpad as required checkboxes (no optional downgrade).
6.  Run a principal-style self-review of the plan and refine it.
7.  Before implementing, capture a concrete reproduction signal and record it in the workpad
    `Notes` section (command/output, screenshot, or deterministic UI behavior).
8.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the
    pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with merge source(s), result, and resulting `HEAD`
      short SHA.
9.  Send a `heartbeat` (with `last_event`, `last_message`, and current token totals) and update
    `focus` / `next_step` so observers see what you are doing now.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a session has an attached PR, run this protocol before moving to `review`:

1. Identify the PR number from session links (`links.yaml`).
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as
   blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat the sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or auth/permissions that
cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, set
  `status: waiting` with `waiting_kind: external` (or `human`) and a `waiting_note` that
  includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Add a corresponding workpad section in `notes.md` describing the same.

## Step 2: Execution phase

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull`
    sync result is already recorded in the workpad before implementation continues.
2.  Ensure the session status is `active`; if not, set it via `sardine_run_session`.
3.  Load the existing workpad and treat it as the active execution checklist. Edit it whenever
    reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the workpad current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Update the workpad immediately after each meaningful milestone.
    - Never leave completed work unchecked in the plan.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all session-provided `Validation` / `Test Plan` / `Testing`
      requirements.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - Document any temporary proof steps and outcomes in the workpad and revert them before
      commit/push.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push`, run the required validation for your scope and confirm it passes.
8.  Attach the PR URL via `sardine_run_session operation: link` (`link_kind: pr`).
    - Ensure the GitHub PR has label `sardine-run` (add it if missing).
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad with final checklist status and validation notes.
11. Before moving to `review`, poll PR feedback and checks:
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green).
    - Confirm every required validation/test-plan item is explicitly marked complete.
    - Repeat the check-address-verify loop until no outstanding comments remain.
12. Only then set `status: review` via `sardine_run_session`.
    - Exception: if blocked per the blocked-access escape hatch, set `status: waiting` with the
      blocker brief.

## Step 3: Review and merge handling

1. While `status: review`, do not code or change session content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If review feedback requires changes, set `status: active` again and follow the rework flow
   (Step 4).
4. If approved, the session moves toward merging.
5. When the session reaches the merging cue, open and follow `.codex/skills/land/SKILL.md`, then
   run the `land` skill in a loop until the PR is merged. Do not call `gh pr merge` directly.
6. After merge is complete, set `status: done`.

## Step 4: Rework handling

1. Treat rework as a full approach reset, not incremental patching.
2. Re-read the full session description and all human notes; explicitly identify what will be
   done differently this attempt.
3. Close the existing PR tied to the session.
4. Remove the existing `## Codex Workpad` section from `notes.md` (append a fresh one).
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - Set `status: active` if not already.
   - Create a new bootstrap `## Codex Workpad` note.
   - Build a fresh plan/checklist and execute end-to-end.

## Completion bar before `review`

- Step 1/2 checklist is fully complete and accurately reflected in the workpad.
- Acceptance criteria and required session-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the session via `link`.
- Required PR metadata is present (`sardine-run` label).
- If app-touching, runtime validation/media requirements are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation
  state for continuation. Create a new branch from `origin/main` and restart from
  reproduction/planning.
- Do not edit the session description for planning or progress tracking; use `notes.md`.
- Use exactly one persistent workpad section (`## Codex Workpad`) per session.
- Temporary proof edits are allowed only for local verification and must be reverted before
  commit.
- If out-of-scope improvements are found, create a separate Traffic Control session rather than
  expanding current scope.
- Do not move to `review` unless the `Completion bar before review` is satisfied.
- In `review`, do not make changes; wait and poll.
- If status is `done` or `archived`, do nothing and shut down.
- Keep session text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, append a single blocker note describing blocker, impact,
  and next unblock action, and set `status: waiting`.

## Workpad template

Use this exact structure for the persistent workpad section in `notes.md` and keep it updated in
place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
