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
   launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside it.
4. Codex sees the workflow prompt and a single dynamic tool, `sardine_run_session`, which it uses
   to update its assigned session: change status, append notes, record links, send heartbeats,
   and set focus / next_step.
5. When the session moves to `done` or `archived`, Sardine Run stops the agent and cleans the
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
Pass `--port 4000` to also start the LiveView dashboard at `http://localhost:4000`. The dashboard lists active and retrying sessions; drill into individual sessions at `/session/<issue_identifier>` to view live agent state, workspace git history, filtered logs, notes, and on-disk paths.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
