#### Context

Sardine Run only knew how to drive Codex. Add a second backend so we can sanity-check the harness against the Claude Code CLI at low cost.

#### TL;DR

Add a Claude Code worker; dispatches pick it about 5% of the time, with Codex still the default.

#### Summary

- Introduce `SardineRun.Worker` behaviour; Codex and the new Claude backend both implement it.
- `SardineRun.Worker.Sampler.pick/2` rolls an injectable RNG against `agents.sampling.claude_probability` (default `0.05`).
- New `SardineRun.Claude.AppServer` drives `claude --print --output-format stream-json --input-format stream-json --model sonnet --permission-mode bypassPermissions` per session.
- New `SardineRun.Claude.MCPServer` exposes `sardine_run_session` over stdio JSON-RPC; tool calls delegate to `SardineRun.Codex.DynamicTool.execute/3`.
- `worker_kind` threaded through orchestrator → AgentRunner → SessionWriter → presenter → LiveView badge.
- Schema adds `claude:` config block + `agents.sampling.claude_probability`; defaults match the plan (`sonnet` / `high` / `bypassPermissions`).
- WORKFLOW.md, SPEC.md (§4.1.6, §5.3.6, §5.3.5.1, §6.5), elixir/README.md, README.md updated to describe the two-worker model.
- Pre-existing credo + dialyzer + coverage friction cleaned up so `make -C elixir all` is green.

#### Alternatives

- Hard-coding 100% Claude or a feature flag — rejected; probabilistic sampling at 5% lets us validate end-to-end without disrupting Codex throughput, and `0.0` disables Claude entirely.
- Re-implementing the dynamic tool inside Claude — rejected; the MCP bridge delegates to `DynamicTool.execute/3` so there is only one operation surface to maintain.

#### Test Plan

- [x] `make -C elixir all`
- [x] `mix test test/sardine_run/worker/sampler_test.exs test/sardine_run/claude/`
- [x] Manual: scripted-fake Claude binary round-trip in `app_server_fake_test.exs` exercises start_session/run_turn/stop_session.
- [ ] Live: `SARDINE_RUN_LIVE_E2E=1 mix test test/sardine_run/claude/app_server_live_test.exs` (requires an authenticated `claude` binary; not run in CI).
