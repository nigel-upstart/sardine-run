#!/usr/bin/env bash
# Wraps Codex app-server launch with credential injection.
# Injects GITHUB_TOKEN from gh auth so that gh CLI works inside Codex turns.
# Executed via `bash -lc` by the sardine-run Elixir orchestrator.

set -euo pipefail

if [[ -z "${GITHUB_TOKEN:-}" ]] && [[ -z "${GH_TOKEN:-}" ]]; then
  _gh_token=$(gh auth token 2>/dev/null || true)
  if [[ -n "$_gh_token" ]]; then
    export GITHUB_TOKEN="$_gh_token"
  fi
fi

exec codex \
  --config shell_environment_policy.inherit=all \
  --config 'model="gpt-5.5"' \
  --config model_reasoning_effort=xhigh \
  app-server
