# Sardine Run Elixir

This directory contains the current Elixir/OTP implementation of Sardine Run, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Sardine Run Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## How it works

1. Polls a Traffic Control state-repo (`$TRAFFIC_CONTROL_STATE_REPO`, default
   `~/code/traffic-control-state`) for sessions whose `status` is in `tracker.active_states`.
2. Creates a workspace per session under `workspace.root` (recommended:
   `~/code/sardine-run-workspaces`).
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace.
4. Renders the `WORKFLOW.md` prompt body with the session's `Issue` record and sends it as the
   first turn.
5. Advertises one client-side dynamic tool, `sardine_run_session`, that the agent uses to manage
   its assigned session (status, heartbeat, note, link, focus, next_step).
6. Keeps Codex running on the session until it reaches a terminal status (`done`, `archived` by
   default).

If a claimed session moves to a terminal state, Sardine Run stops the active agent and cleans the
matching workspace.

## How to use it

1. Make sure your codebase is set up to work well with agents
   ([Harness engineering](https://openai.com/index/harness-engineering/)).
2. Set `TRAFFIC_CONTROL_STATE_REPO` to the absolute path of your Traffic Control state repo (the
   directory with the `sessions/` tree). Sardine Run reads and writes sessions there.
3. Copy this directory's `WORKFLOW.md` to your repo and customize the prompt body for your
   project. The YAML front matter holds runtime config; the Markdown body is the agent prompt
   template.
4. Optionally copy the `commit`, `push`, `pull`, and `land` skills from `.codex/skills/` to your
   repo so the agent can drive PRs through their lifecycle.
5. Install runtime dependencies (below) and start the service.

## Prerequisites

We recommend [mise](https://mise.jdx.dev/) for managing Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/nigel-upstart/sardine-run
cd sardine-run/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
export TRAFFIC_CONTROL_STATE_REPO="$HOME/code/traffic-control-state"
mise exec -- ./bin/sardine-run \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

The escript binary is `sardine-run`. The `--i-understand-...` flag is required: Sardine Run runs
Codex without the usual guardrails and the binary refuses to start without acknowledgement. See
`sardine-run --help`-style invocation by passing no args; the usage banner is
`Usage: sardine-run [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]`.

## Configuration

Pass a custom workflow path when starting:

```bash
./bin/sardine-run --i-understand-... /path/to/custom/WORKFLOW.md
```

If no path is passed, Sardine Run defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root <path>` writes logs under that directory (default: `./log`).
- `--port <port>` starts the Phoenix LiveView dashboard and JSON API on that port (default:
  disabled). Setting `server.port` in `WORKFLOW.md` does the same thing; CLI `--port` wins when
  both are present.

The `WORKFLOW.md` file uses YAML front matter for configuration plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: traffic_control
  state_repo: $TRAFFIC_CONTROL_STATE_REPO
  active_states: [active]
  terminal_states: [done, archived]
workspace:
  root: ~/code/sardine-run-workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on Traffic Control session `{{ issue.identifier }}`.

Title: {{ issue.title }}
Description: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current
    session workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the
  current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and
  `never`; object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Sardine Run passes the map through to Codex
  unchanged.
- `agent.max_turns` caps how many back-to-back Codex turns Sardine Run will run in a single agent
  invocation when a turn completes normally but the session is still active. Default: `20`.
- If the Markdown body is blank, Sardine Run uses a default prompt template that introduces the
  `sardine_run_session` dynamic tool and tells the agent how to drive its session.
- Use `hooks.after_create` to bootstrap a fresh workspace (typical: `git clone ... .`).
- `tracker.state_repo` reads from `$TRAFFIC_CONTROL_STATE_REPO` when unset or set to
  `$TRAFFIC_CONTROL_STATE_REPO`. There is no auth token; Traffic Control is a local filesystem
  repo.
- For path values, `~` is expanded.
- For env-backed path values, use `$VAR`. `workspace.root` and `tracker.state_repo` resolve `$VAR`
  before path handling. `codex.command` is a shell command string and any `$VAR` expansion there
  happens in the launched shell.

```yaml
tracker:
  kind: traffic_control
  state_repo: $TRAFFIC_CONTROL_STATE_REPO
workspace:
  root: $SARDINE_RUN_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Sardine Run does not boot.
- If a later reload fails, Sardine Run keeps running with the last known good workflow and logs
  the reload error until the file is fixed.
- `server.port` or CLI `--port` enables the Phoenix LiveView dashboard and JSON API at `/`,
  `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## The `sardine_run_session` dynamic tool

Every Codex session sees one client-side dynamic tool: `sardine_run_session`. The agent uses it to
keep its assigned Traffic Control session in sync with its work. Operations:

- `status` — set `status` (`active|blocked|waiting|review|done|archived`). When `waiting`, also
  pass `waiting_kind` (`human|ci|review|external|other`) and an optional `waiting_note`.
- `heartbeat` — record `last_event`, `last_message`, `last_error`, and cumulative
  `input_tokens` / `output_tokens` / `total_tokens`.
- `note` — append `body` (markdown) to `sessions/<id>/notes.md`.
- `link` — append `{label, link_kind, url}` to `sessions/<id>/links.yaml`.
- `focus` and `next_step` — set or clear the corresponding `session.yaml` field with `value`.

Every call requires `operation` and `session_id`. The agent receives the assigned session ID via
the prompt template's `{{ issue.identifier }}` and uses it for every call.

The implementation lives in `lib/sardine_run/codex/dynamic_tool.ex` and writes through
`lib/sardine_run/traffic_control/session_writer.ex`.

## Web dashboard

When `--port` (or `server.port`) is set, Sardine Run runs:

- LiveView dashboard at `/` (suggested: `http://localhost:4000`) listing active and retrying sessions
- Per-session drill-down at `/session/<issue_identifier>` with live agent state, workspace git log, filtered logs, notes, and on-disk paths
- JSON API under `/api/v1/*`
- Bandit as the HTTP server

While the dashboard is running, the orchestrator advertises its base URL on each active
session's `sardine_run.dashboard_url` field in `session.yaml`, enabling external tools (e.g. the
Traffic Control dashboard) to render a deep-link back to `/session/<issue_identifier>`. Set
`SARDINE_RUN_PUBLIC_HOSTNAME` to override the hostname component when the auto-detected name
isn't reachable from peers. The field is cleared on orderly shutdown.

## Project layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the live end-to-end test only when you want Sardine Run to drive a real Codex session against
a temporary Traffic Control state repo:

```bash
cd elixir
make e2e
```

The live test creates a temporary state repo with one session, writes a temporary `WORKFLOW.md`,
runs a real agent turn, verifies the workspace side effect, then walks the session to a terminal
status via the `sardine_run_session` writer.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has
an active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Sardine Run repo, and ask it to set things up.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
