defmodule SardineRun.Claude.AppServer do
  @moduledoc """
  Worker backend that drives the Claude Code CLI in headless stream-json mode.

  Implements `SardineRun.Worker` so it slots into `SardineRun.AgentRunner` the
  same way `SardineRun.Codex.AppServer` does. One `Port` per session; the
  prompt is fed in as a stream-json `user` message, and the CLI streams back
  newline-delimited JSON events (`system`, `assistant`, `user`, `result`).

  Tool calls hit the `sardine_run_session` tool indirectly via the MCP bridge
  Claude Code launches per `--mcp-config`; this module does not have to
  intercept tool_use blocks itself. Tool results come back as `user` messages
  with `tool_result` content.

  Lifecycle log lines carry one fish emoji each (matching the parallel
  Workstream-B convention): 🐟 start, 🐬 completion, 🦈 warnings/errors.
  """

  @behaviour SardineRun.Worker

  require Logger
  alias SardineRun.Claude.MCPConfig
  alias SardineRun.Config

  @port_line_bytes 1_048_576

  @typedoc "Per-session state owned by this module; opaque to callers."
  @type session :: %{
          port: port(),
          workspace: Path.t(),
          mcp_config_path: Path.t(),
          metadata: map(),
          thread_id: String.t() | nil,
          worker_host: String.t() | nil
        }

  @impl SardineRun.Worker
  @spec kind() :: :claude
  def kind, do: :claude

  @impl SardineRun.Worker
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    worker_host = Keyword.get(opts, :worker_host)
    claude_cfg = claude_config()

    with {:ok, mcp_config_path} <- write_mcp_config(workspace, claude_cfg),
         {:ok, port} <- start_port(workspace, mcp_config_path, claude_cfg) do
      metadata = port_metadata(port, worker_host)

      Logger.info("🐟 Claude session started workspace=#{workspace} model=#{claude_cfg.model}")

      {:ok,
       %{
         port: port,
         workspace: workspace,
         mcp_config_path: mcp_config_path,
         metadata: metadata,
         thread_id: nil,
         worker_host: worker_host
       }}
    end
  end

  @impl SardineRun.Worker
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{port: port, metadata: metadata} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    turn_id = Keyword.get(opts, :turn_id, generate_id())

    case send_user_message(port, prompt) do
      :ok ->
        await_turn(port, session, issue, turn_id, on_message, metadata)

      {:error, reason} ->
        Logger.error("🦈 Claude turn failed to start for #{issue_context(issue)}: #{inspect(reason)}")
        emit(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @impl SardineRun.Worker
  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port, mcp_config_path: mcp_config_path}) do
    stop_port(port)
    cleanup_mcp_config(mcp_config_path)
    :ok
  end

  def stop_session(_), do: :ok

  # --- Port lifecycle --------------------------------------------------------

  defp claude_config do
    settings = Config.settings!()

    case Map.get(settings, :claude) do
      nil ->
        %{
          command: "claude",
          model: "sonnet",
          effort: "high",
          permission_mode: "bypassPermissions",
          turn_timeout_ms: 3_600_000,
          read_timeout_ms: 5_000,
          stall_timeout_ms: 300_000
        }

      cfg ->
        %{
          command: cfg.command,
          model: cfg.model,
          effort: cfg.effort,
          permission_mode: cfg.permission_mode,
          turn_timeout_ms: cfg.turn_timeout_ms,
          read_timeout_ms: cfg.read_timeout_ms,
          stall_timeout_ms: cfg.stall_timeout_ms
        }
    end
  end

  defp start_port(workspace, mcp_config_path, claude_cfg) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      cmd = build_command(claude_cfg, mcp_config_path)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :use_stdio,
            args: [~c"-lc", String.to_charlist(cmd)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes,
            env: build_env(claude_cfg)
          ]
        )

      {:ok, port}
    end
  end

  defp build_command(%{command: command} = _claude_cfg, mcp_config_path) do
    # The launch script is responsible for forwarding the rest of the
    # CLI flags (--print, --output-format stream-json, etc.). We add the
    # per-session mcp-config path here because it varies per workspace.
    "#{command} --mcp-config #{shell_escape(mcp_config_path)}"
  end

  defp build_env(%{effort: effort, model: model, permission_mode: permission_mode}) do
    # Re-export the knobs the launch script reads. Effort is exported because
    # there is no stable Claude CLI flag for it today; the script may upgrade
    # to a flag when one ships.
    [
      {~c"CLAUDE_REASONING_EFFORT", String.to_charlist(to_string(effort))},
      {~c"CLAUDE_MODEL", String.to_charlist(to_string(model))},
      {~c"CLAUDE_PERMISSION_MODE", String.to_charlist(to_string(permission_mode))}
    ]
  end

  defp write_mcp_config(workspace, _claude_cfg) do
    path = Path.join([workspace, ".sardine-run", "claude.mcp.json"])
    escript = mcp_bridge_escript_path()

    try do
      MCPConfig.write!(path, workspace, nil, escript)
      {:ok, path}
    rescue
      err -> {:error, {:mcp_config_write_failed, err}}
    end
  end

  defp mcp_bridge_escript_path do
    System.get_env("SARDINE_RUN_BIN") || default_escript_path()
  end

  defp default_escript_path do
    # When running from the dev tree we can locate the escript output.
    candidate = Path.join([File.cwd!(), "bin", "sardine-run"])

    if File.exists?(candidate) do
      candidate
    else
      System.find_executable("sardine-run") || "sardine-run"
    end
  end

  defp cleanup_mcp_config(path) when is_binary(path) do
    File.rm(path)

    parent = Path.dirname(path)

    case File.ls(parent) do
      {:ok, []} -> File.rmdir(parent)
      _ -> :ok
    end
  end

  defp cleanup_mcp_config(_), do: :ok

  defp port_metadata(port, worker_host) do
    base =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{claude_app_server_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base, :worker_host, host)
      _ -> base
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp stop_port(_), do: :ok

  # --- Send user message -----------------------------------------------------

  defp send_user_message(port, prompt) do
    payload = %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => prompt
      }
    }

    line = Jason.encode!(payload) <> "\n"

    try do
      Port.command(port, line)
      :ok
    rescue
      err -> {:error, {:port_command_failed, err}}
    end
  end

  # --- Receive and decode stream-json ---------------------------------------

  defp await_turn(port, session, issue, turn_id, on_message, metadata) do
    timeout_ms = Map.get(claude_config(), :turn_timeout_ms, 3_600_000)

    ctx = %{
      port: port,
      issue: issue,
      turn_id: turn_id,
      on_message: on_message,
      metadata: metadata,
      timeout_ms: timeout_ms
    }

    receive_loop(ctx, session, "")
  end

  defp receive_loop(ctx, session, pending) do
    port = ctx.port

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_line(ctx, session, pending <> to_string(chunk))

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(ctx, session, pending <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        if status != 0 do
          Logger.warning("🦈 Claude CLI exited with status=#{status} for #{issue_context(ctx.issue)}")
        end

        {:error, {:port_exit, status}}
    after
      ctx.timeout_ms ->
        Logger.warning("🦈 Claude turn timed out for #{issue_context(ctx.issue)} after #{ctx.timeout_ms}ms")
        {:error, :turn_timeout}
    end
  end

  defp handle_line(ctx, session, line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      receive_loop(ctx, session, "")
    else
      handle_decoded(ctx, session, Jason.decode(trimmed), trimmed)
    end
  end

  defp handle_decoded(ctx, session, {:ok, %{} = event}, _trimmed) do
    handle_event(ctx, session, event)
  end

  defp handle_decoded(ctx, session, _other, trimmed) do
    Logger.debug("Claude non-JSON line: #{String.slice(trimmed, 0, 500)}")
    receive_loop(ctx, session, "")
  end

  defp handle_event(ctx, session, event) do
    case Map.get(event, "type") do
      "system" ->
        handle_system_event(ctx, session, event)

      "assistant" ->
        emit(ctx.on_message, :other_message, %{payload: event}, with_usage(ctx.metadata, event))
        receive_loop(ctx, session, "")

      "user" ->
        emit(ctx.on_message, :notification, %{payload: event}, ctx.metadata)
        receive_loop(ctx, session, "")

      "result" ->
        handle_result_event(ctx, session, event)

      _other ->
        emit(ctx.on_message, :other_message, %{payload: event}, ctx.metadata)
        receive_loop(ctx, session, "")
    end
  end

  defp handle_system_event(ctx, session, event) do
    case Map.get(event, "subtype") do
      "init" ->
        thread_id = Map.get(event, "session_id") || generate_id()
        session = %{session | thread_id: thread_id}
        session_id = "#{thread_id}-#{ctx.turn_id}"

        emit(
          ctx.on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: ctx.turn_id
          },
          ctx.metadata
        )

        Logger.info("🐟 Claude system/init received for #{issue_context(ctx.issue)} session_id=#{session_id}")
        receive_loop(ctx, session, "")

      _ ->
        emit(ctx.on_message, :notification, %{payload: event}, ctx.metadata)
        receive_loop(ctx, session, "")
    end
  end

  defp handle_result_event(ctx, session, event) do
    thread_id = session.thread_id || Map.get(event, "session_id") || generate_id()
    session_id = "#{thread_id}-#{ctx.turn_id}"
    is_error = Map.get(event, "is_error") == true

    if is_error do
      reason = Map.get(event, "result") || "claude reported is_error"
      Logger.warning("🦈 Claude result error for #{issue_context(ctx.issue)} session_id=#{session_id}: #{inspect(reason)}")

      emit(
        ctx.on_message,
        :turn_ended_with_error,
        %{session_id: session_id, reason: reason, payload: event},
        ctx.metadata
      )

      {:error, {:claude_result_error, reason}}
    else
      Logger.info("🐬 Claude session completed for #{issue_context(ctx.issue)} session_id=#{session_id}")

      emit(
        ctx.on_message,
        :turn_completed,
        %{
          session_id: session_id,
          thread_id: thread_id,
          turn_id: ctx.turn_id,
          payload: event
        },
        with_usage(ctx.metadata, event)
      )

      {:ok,
       %{
         result: event,
         session_id: session_id,
         thread_id: thread_id,
         turn_id: ctx.turn_id
       }}
    end
  end

  # --- Helpers ---------------------------------------------------------------

  defp emit(on_message, event, details, metadata) when is_function(on_message, 1) do
    msg =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(msg)
  end

  defp with_usage(metadata, %{"message" => %{"usage" => usage}}) when is_map(usage),
    do: Map.put(metadata, :usage, usage)

  defp with_usage(metadata, %{"usage" => usage}) when is_map(usage),
    do: Map.put(metadata, :usage, usage)

  defp with_usage(metadata, _event), do: metadata

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp issue_context(%{id: id, identifier: ident}), do: "issue_id=#{id} issue_identifier=#{ident}"
  defp issue_context(_), do: "issue=unknown"
end
