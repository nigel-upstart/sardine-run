defmodule SardineRun.Claude.MCPServer do
  @moduledoc """
  Stdio JSON-RPC 2.0 server that exposes the `sardine_run_session` tool to
  Claude Code over MCP.

  Claude Code's `--mcp-config` flag accepts entries that point at a child
  process. We launch this module as the child (via the Elixir `escript`
  binary in `claude-launch.sh`) so each Claude session gets its own bridge.

  Implements the minimum surface Claude Code uses:

  - `initialize` → returns server capabilities (`{"tools": {}}`)
  - `tools/list` → returns one entry built from
    `SardineRun.Codex.DynamicTool.tool_spec/0`
  - `tools/call` → delegates to `SardineRun.Codex.DynamicTool.execute/3` and
    wraps the result in `{"content": [{"type": "text", "text": ...}]}`
  - `notifications/initialized` → no-op
  - Anything else → JSON-RPC error `-32601` (Method not found)

  The `:workspace` opt is passed through to `DynamicTool.execute/3` so
  workspace-scoped operations like `git_push` work the same way they do for
  Codex.
  """

  alias SardineRun.Codex.DynamicTool

  @protocol_version "2025-06-18"

  @typedoc "Server runtime opts; `:workspace` is forwarded to the dynamic tool."
  @type opts :: keyword()

  @doc """
  Runs the stdio server loop, reading newline-delimited JSON requests from
  `:stdio` and writing JSON-RPC responses back to stdout.

  Exits with status 0 when stdin closes. Used by the escript wrapper that
  Claude Code launches via its `.mcp.json`.
  """
  @spec run(opts()) :: :ok
  def run(opts \\ []) do
    workspace = Keyword.get(opts, :workspace)
    loop(workspace)
  end

  @doc """
  Handles a single decoded JSON-RPC request map and returns either a response
  map (synchronous reply) or `:no_reply` (notification).

  Public so unit tests can drive the protocol without spawning a process.
  """
  @spec handle_message(map(), opts()) :: map() | :no_reply
  def handle_message(%{"method" => method} = message, opts) do
    id = Map.get(message, "id")
    params = Map.get(message, "params", %{}) || %{}
    workspace = Keyword.get(opts, :workspace)

    case dispatch(method, params, workspace) do
      {:reply, result} when not is_nil(id) ->
        %{"jsonrpc" => "2.0", "id" => id, "result" => result}

      {:reply, _result} ->
        # Notification-style request that we treated as a method; no id, no reply.
        :no_reply

      :notification ->
        :no_reply

      {:error, code, msg} when not is_nil(id) ->
        %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => msg}}

      {:error, _code, _msg} ->
        :no_reply
    end
  end

  def handle_message(_other, _opts), do: :no_reply

  defp loop(workspace) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line when is_binary(line) ->
        handle_line(line, workspace)
        loop(workspace)
    end
  end

  defp handle_line(line, workspace) do
    trimmed = String.trim(line)

    if trimmed == "" do
      :ok
    else
      decode_and_dispatch(Jason.decode(trimmed), workspace)
    end
  end

  defp decode_and_dispatch({:ok, message}, workspace) when is_map(message) do
    case handle_message(message, workspace: workspace) do
      :no_reply -> :ok
      response -> write_response(response)
    end
  end

  defp decode_and_dispatch(_other, _workspace), do: :ok

  defp write_response(response) do
    encoded = Jason.encode!(response)
    IO.puts(encoded)
  end

  defp dispatch("initialize", _params, _workspace) do
    {:reply,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{
         "name" => "sardine-run-claude-bridge",
         "version" => "0.1.0"
       }
     }}
  end

  defp dispatch("notifications/initialized", _params, _workspace), do: :notification
  defp dispatch("notifications/cancelled", _params, _workspace), do: :notification

  defp dispatch("tools/list", _params, _workspace) do
    {:reply, %{"tools" => [DynamicTool.tool_spec()]}}
  end

  defp dispatch("tools/call", params, workspace) when is_map(params) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments") || %{}

    result =
      name
      |> DynamicTool.execute(arguments, workspace: workspace)
      |> mcp_tool_result()

    {:reply, result}
  end

  defp dispatch("ping", _params, _workspace), do: {:reply, %{}}

  defp dispatch(_method, _params, _workspace) do
    {:error, -32_601, "Method not found"}
  end

  defp mcp_tool_result(%{"success" => success?} = tool_result) do
    text =
      case Map.get(tool_result, "output") do
        bin when is_binary(bin) -> bin
        _ -> Jason.encode!(tool_result, pretty: true)
      end

    %{
      "content" => [%{"type" => "text", "text" => text}],
      "isError" => not success?
    }
  end

  defp mcp_tool_result(other) do
    text = if is_binary(other), do: other, else: inspect(other)

    %{
      "content" => [%{"type" => "text", "text" => text}],
      "isError" => true
    }
  end
end
