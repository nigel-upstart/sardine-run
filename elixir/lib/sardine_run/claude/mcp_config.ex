defmodule SardineRun.Claude.MCPConfig do
  @moduledoc """
  Writes a per-session `.mcp.json` file pointing Claude Code at the
  `SardineRun.Claude.MCPServer` stdio bridge.

  Claude Code expects an mcpServers map with `command` / `args` / `env` for
  each stdio server (see https://code.claude.com/docs/en/mcp). We write the
  bridge entry to a workspace-scoped path so distinct sessions never collide.
  """

  @doc """
  Builds the mcpServers map for one session.

  The bridge is invoked via the same escript that ships the rest of Sardine
  Run; the escript exposes a `mcp-bridge` subcommand handled by
  `SardineRun.CLI`. `:workspace` is forwarded so workspace-scoped operations
  like `git_push` work end-to-end.
  """
  @spec build(Path.t() | nil, String.t() | nil, String.t()) :: map()
  def build(workspace, session_id, escript_path) when is_binary(escript_path) do
    args = mcp_bridge_args(workspace, session_id)

    %{
      "mcpServers" => %{
        "sardine_run" => %{
          "command" => escript_path,
          "args" => args,
          "env" => %{}
        }
      }
    }
  end

  @doc """
  Writes the mcpServers JSON document to `path`. Creates any missing
  intermediate directories.
  """
  @spec write!(Path.t(), Path.t() | nil, String.t() | nil, String.t()) :: :ok
  def write!(path, workspace, session_id, escript_path) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    payload = build(workspace, session_id, escript_path)
    File.write!(path, Jason.encode!(payload, pretty: true))
    :ok
  end

  defp mcp_bridge_args(workspace, session_id) do
    base = ["mcp-bridge"]

    base
    |> append_arg("--workspace", workspace)
    |> append_arg("--session-id", session_id)
  end

  defp append_arg(args, _flag, nil), do: args
  defp append_arg(args, _flag, ""), do: args
  defp append_arg(args, flag, value) when is_binary(value), do: args ++ [flag, value]
end
