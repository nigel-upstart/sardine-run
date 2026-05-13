# Sardine Run

Sardine Run turns project work into isolated, autonomous coding-agent runs. It polls a Traffic
Control state-repo for sessions, creates a workspace per session, and runs Codex inside each
workspace until the session reaches a terminal state.

> [!WARNING]
> Sardine Run is a low-key engineering preview for testing in trusted environments.

## How it works

1. Sardine Run reads sessions from a Traffic Control state-repo on disk
   (`$TRAFFIC_CONTROL_STATE_REPO`, by default `~/code/traffic-control-state`).
2. Each `sessions/<id>/session.yaml` file with a status in `tracker.active_states` is candidate
   work.
3. Sardine Run creates a workspace under `~/code/sardine-run-workspaces/<sanitized-id>` and
   launches a coding agent inside it. By default it runs Codex in
   [App Server mode](https://developers.openai.com/codex/app-server/); a small fraction of
   dispatches (default `5%`, configured via `agent.sampling.claude_probability`) instead
   launch the Claude Code CLI in headless stream-json mode. Either backend gets the same
   `sardine_run_session` tool — for Claude it is exposed through a per-session stdio MCP
   bridge that Sardine Run hosts.
4. The agent sees the workflow prompt and a single dynamic tool, `sardine_run_session`, which it
   uses to update its assigned session: change status, append notes, record links, send heartbeats,
   and set focus / next_step.
5. When the agent opens a PR and moves the session to `review`, a background watcher polls
   GitHub every ~5 minutes (with up to 60s jitter) for unresolved review comments and failing
   CI checks. If any show up, the session is flipped to `review_pending` and dispatched to the
   🐡 reviewer species — a specialized prompt focused on responding to each thread (push fix
   + reply, OR substantive reject + resolve, OR hand off to a human).
6. When the session moves to `done` or `archived`, Sardine Run stops the agent and cleans the
   workspace.

There is no API, no token, no cloud tracker. Reads and writes happen against a local Git-tracked
filesystem repo.

## Running it

### Option 1. Make your own

Hand a coding agent the spec and ask it to build Sardine Run in the language of your choice:

> Implement Sardine Run according to the following spec:
> https://github.com/nigel-upstart/sardine-run/blob/main/SPEC.md

### Option 2. Use the Elixir reference implementation

See [`elixir/README.md`](elixir/README.md) for setup and run instructions.

```bash
git clone https://github.com/nigel-upstart/sardine-run
cd sardine-run/elixir
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/sardine-run \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

The escript binary is `sardine-run`. By default it reads `WORKFLOW.md` from the current directory.
Pass `--port 4000` to also start the LiveView dashboard at `http://localhost:4000`. The dashboard lists active and retrying sessions; drill into individual sessions at `/session/<issue_identifier>` to view live agent state, workspace git history, filtered logs, notes, and on-disk paths. While the dashboard is running, the orchestrator writes its base URL to `sardine_run.dashboard_url` on each session so the Traffic Control dashboard can render a back-link. Set `SARDINE_RUN_PUBLIC_HOSTNAME` to override the hostname when auto-detection isn't reachable.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
