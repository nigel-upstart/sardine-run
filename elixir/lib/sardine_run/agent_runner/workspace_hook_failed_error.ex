defmodule SardineRun.AgentRunner.WorkspaceHookFailedError do
  @moduledoc """
  Raised by `SardineRun.AgentRunner.run/3` when a workspace lifecycle hook
  (today: `after_create`) returns a non-zero exit. The orchestrator pattern-
  matches on this struct in its `:DOWN` handler so it can surface the failure
  to the session's Traffic Control state instead of looping on retries.
  """

  defexception [:hook_name, :status, :output, :issue_id, :issue_identifier]

  @type t :: %__MODULE__{
          hook_name: String.t() | nil,
          status: non_neg_integer() | nil,
          output: String.t() | nil,
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil
        }

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{
        hook_name: hook_name,
        issue_identifier: identifier,
        status: status,
        output: output
      }) do
    snippet = output |> to_string() |> String.slice(0, 200)
    "Workspace hook #{hook_name || "?"} failed for #{identifier || "?"} (status=#{status || "?"}): #{snippet}"
  end
end
