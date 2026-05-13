#!/usr/bin/env bash
# Wrapper that pins the Claude Code CLI flags Sardine Run depends on.
#
# Sardine Run launches this script per-session via `claude.command`. Flags
# like `--mcp-config <path>` are appended by `SardineRun.Claude.AppServer`,
# so we pass `"$@"` at the end.
#
# Environment knobs read here (all set by SardineRun.Claude.AppServer):
#   CLAUDE_MODEL              - model alias (default: sonnet)
#   CLAUDE_PERMISSION_MODE    - permission mode (default: bypassPermissions)
#   CLAUDE_REASONING_EFFORT   - reasoning effort tier (default: high)
#                               Exported as an env var because there is no
#                               stable CLI flag for it today; the binary
#                               picks it up via its own settings.
set -euo pipefail

MODEL="${CLAUDE_MODEL:-sonnet}"
PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
EFFORT="${CLAUDE_REASONING_EFFORT:-high}"

# Keep effort exported so the child process (claude) can read it.
export CLAUDE_REASONING_EFFORT="${EFFORT}"

exec claude \
  --print \
  --output-format stream-json \
  --input-format stream-json \
  --verbose \
  --model "${MODEL}" \
  --permission-mode "${PERMISSION_MODE}" \
  --strict-mcp-config \
  "$@"
