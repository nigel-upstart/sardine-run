defmodule SardineRunWeb.SessionDetailPresenter do
  @moduledoc """
  Builds the payload rendered by `SardineRunWeb.SessionDetailLive` for a
  single issue's session detail page.

  Filesystem and shell-out helpers will be added incrementally; this
  module starts with identifier validation and the live-state slice
  derived from the orchestrator snapshot.
  """

  alias SardineRun.{PathSafety, StatusDashboard}

  @identifier_pattern ~r/\A[A-Za-z0-9._-]+\z/
  @git_log_max_count 10
  @git_log_timeout_ms 5_000
  @log_tail_cap_bytes 5_242_880
  @log_tail_max_lines 200
  @log_tail_timeout_ms 5_000
  @notes_max_bytes 65_536

  @typedoc "URL-supplied issue identifier after allow-list validation."
  @type session_identifier :: String.t()

  @typedoc """
  Filesystem context map. Reserved for filesystem-touching slices added
  in later tasks (workspace path, log file, state repo). Currently
  unused; payload/3 accepts an empty map.
  """
  @type filesystem :: map()

  @type git_log_status ::
          :ok | :empty | :workspace_not_present | :unsafe_workspace | :unconfigured

  @type git_log_section :: %{status: git_log_status(), lines: [String.t()]}

  @type log_tail_status :: :ok | :no_entries | :empty | :unconfigured | :error

  @type log_tail_section :: %{status: log_tail_status(), lines: [String.t()]}

  @type notes_status :: :ok | :missing | :memory_tracker

  @type notes_section :: %{status: notes_status(), content: String.t() | nil}

  @type paths_section ::
          :hidden
          | %{
              session_yaml: Path.t(),
              notes_md: Path.t(),
              links_yaml: Path.t(),
              workspace: Path.t() | nil
            }

  @type payload :: %{
          identifier: session_identifier(),
          status: String.t(),
          header: map(),
          live_state: map(),
          git_log: git_log_section(),
          log_tail: log_tail_section(),
          notes: notes_section(),
          paths: paths_section()
        }

  @doc """
  Validate an issue identifier supplied via URL.

  Returns `{:ok, identifier}` when the value matches the SessionWriter
  allow-list (`~r/\\A[A-Za-z0-9._-]+\\z/`). Anything else returns
  `{:error, :invalid_identifier}`. This is the only allow-list gate;
  every later slice that joins paths or shells out must call this first.
  """
  @spec validate_identifier(term()) :: {:ok, session_identifier()} | {:error, :invalid_identifier}
  def validate_identifier(identifier) when is_binary(identifier) do
    cond do
      not Regex.match?(@identifier_pattern, identifier) -> {:error, :invalid_identifier}
      String.contains?(identifier, "..") -> {:error, :invalid_identifier}
      identifier == "." -> {:error, :invalid_identifier}
      true -> {:ok, identifier}
    end
  end

  def validate_identifier(_other), do: {:error, :invalid_identifier}

  @doc """
  Build the session detail payload for an identifier from an orchestrator
  snapshot.

  - Returns `{:error, :invalid_identifier}` if the identifier fails the
    allow-list.
  - Returns `{:error, :not_found}` if the identifier is not present in
    either `snapshot.running` or `snapshot.retrying`.
  - Otherwise returns `{:ok, payload}` with the live-state slice.

  When the identifier appears in both lists, `running` wins and the
  status reads `"running"`.

  `filesystem` is a placeholder for later slices (git log, log tail,
  notes.md). Callers may pass `%{}` until those slices land.
  """
  @spec payload(term(), map(), filesystem()) ::
          {:ok, payload()} | {:error, :not_found | :invalid_identifier}
  def payload(identifier, snapshot, filesystem) when is_map(snapshot) and is_map(filesystem) do
    with {:ok, identifier} <- validate_identifier(identifier),
         {:ok, running, retry} <- find_entries(identifier, snapshot) do
      {:ok, build_payload(identifier, running, retry, filesystem)}
    end
  end

  def payload(_identifier, _snapshot, _filesystem), do: {:error, :not_found}

  @typedoc "Subset of payload/3 that depends only on the orchestrator snapshot."
  @type live_only :: %{
          identifier: session_identifier(),
          status: String.t(),
          header: map(),
          live_state: map()
        }

  @doc """
  Cheap snapshot-only projection of the session detail payload.

  Returns just the live-state slice — no filesystem reads, no shell-outs.
  Use this for high-frequency refreshes (e.g. orchestrator heartbeat
  broadcasts) where re-running git/tail/file reads on every tick is
  prohibitive. Pair with `payload/3` on a slower cadence to refresh the
  filesystem-derived sections.

  Note: `header.workspace_path` reflects only the orchestrator entry's
  `workspace_path`. The `<workspace_root>/<identifier>` fallback used by
  `payload/3` is not applied here because it requires a filesystem
  context.
  """
  @spec live_payload(term(), map()) ::
          {:ok, live_only()} | {:error, :not_found | :invalid_identifier}
  def live_payload(identifier, snapshot) when is_map(snapshot) do
    with {:ok, identifier} <- validate_identifier(identifier),
         {:ok, running, retry} <- find_entries(identifier, snapshot) do
      workspace_path = from_first(:workspace_path, running, retry)

      {:ok,
       %{
         identifier: identifier,
         status: status(running, retry),
         header: header(identifier, running, retry, workspace_path),
         live_state: live_state(running, retry)
       }}
    end
  end

  def live_payload(_identifier, _snapshot), do: {:error, :not_found}

  defp find_entries(identifier, snapshot) do
    running = Map.get(snapshot, :running, []) |> Enum.find(&match_identifier?(&1, identifier))
    retry = Map.get(snapshot, :retrying, []) |> Enum.find(&match_identifier?(&1, identifier))

    if is_nil(running) and is_nil(retry) do
      {:error, :not_found}
    else
      {:ok, running, retry}
    end
  end

  defp match_identifier?(entry, identifier) when is_map(entry) do
    Map.get(entry, :identifier) == identifier
  end

  defp match_identifier?(_entry, _identifier), do: false

  defp build_payload(identifier, running, retry, filesystem) do
    workspace_root = Map.get(filesystem, :workspace_root)

    workspace_path =
      from_first(:workspace_path, running, retry) ||
        workspace_path_fallback(identifier, workspace_root)

    log_file = Map.get(filesystem, :log_file)
    state_repo = Map.get(filesystem, :state_repo)

    %{
      identifier: identifier,
      status: status(running, retry),
      header: header(identifier, running, retry, workspace_path),
      live_state: live_state(running, retry),
      git_log: git_log_section(workspace_path, workspace_root),
      log_tail: log_tail_section(identifier, log_file),
      notes: notes_section(identifier, state_repo),
      paths: paths_section(identifier, state_repo, workspace_path)
    }
  end

  defp workspace_path_fallback(_identifier, nil), do: nil

  defp workspace_path_fallback(identifier, workspace_root) when is_binary(workspace_root),
    do: Path.join(workspace_root, identifier)

  @doc """
  Run `git log --pretty=format:"%h %s" --max-count=10` against the
  workspace and return the decoded lines.

  - `:ok` when the workspace is a git repo and `git` exits cleanly.
  - `:empty` when the dir exists but is not a git repo or `git` exits
    non-zero.
  - `:workspace_not_present` when the directory does not exist.
  - `:unsafe_workspace` when the workspace is not contained in
    `workspace_root` after canonicalization.
  - `:unconfigured` when either input is missing.

  Stderr is dropped on the floor — we never leak it into the rendered
  page.
  """
  @spec git_log_section(String.t() | nil, String.t() | nil) :: git_log_section()
  def git_log_section(nil, _workspace_root), do: %{status: :unconfigured, lines: []}
  def git_log_section(_workspace_path, nil), do: %{status: :unconfigured, lines: []}

  def git_log_section(workspace_path, workspace_root)
      when is_binary(workspace_path) and is_binary(workspace_root) do
    cond do
      not File.dir?(workspace_path) ->
        %{status: :workspace_not_present, lines: []}

      not contained?(workspace_path, workspace_root) ->
        %{status: :unsafe_workspace, lines: []}

      true ->
        run_git_log(workspace_path)
    end
  end

  defp contained?(workspace_path, workspace_root) do
    with {:ok, canonical_path} <- PathSafety.canonicalize(workspace_path),
         {:ok, canonical_root} <- PathSafety.canonicalize(workspace_root) do
      canonical_path == canonical_root or
        String.starts_with?(canonical_path, canonical_root <> "/")
    else
      _ -> false
    end
  end

  defp run_git_log(workspace_path) do
    task =
      Task.async(fn ->
        System.cmd(
          "git",
          ["-C", workspace_path, "log", "--pretty=format:%h %s", "--max-count=#{@git_log_max_count}"],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @git_log_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        # `stderr_to_stdout: true` suppresses BEAM-stderr noise but lets
        # warnings/hints through. Filter to lines matching `<sha> <subject>`
        # so stderr lines (e.g. `hint: ...`) never leak into the rendered
        # output.
        lines =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&Regex.match?(~r/^[0-9a-f]{4,}\s/, &1))

        %{status: :ok, lines: lines}

      _other ->
        %{status: :empty, lines: []}
    end
  end

  @doc """
  Tail the application log file and filter lines by the validated session
  identifier.

  - Reads up to `#{@log_tail_cap_bytes}` bytes from the end of `log_file`
    via `tail -c`, then keeps lines that contain `identifier` as a
    substring (case-sensitive).
  - Returns the last `#{@log_tail_max_lines}` matching lines in oldest-first
    order (newest line last).
  - A 5-second hard timeout applies; on timeout the section degrades to
    `:error`.
  - `:missing_file` when the log file does not exist.
  - `:no_entries` when the file exists but no lines match.
  - `:ok` when at least one matching line is found.
  - `:error` on tail failure or timeout.
  """
  @spec log_tail_section(session_identifier(), String.t() | nil) :: log_tail_section()
  def log_tail_section(_identifier, nil), do: %{status: :unconfigured, lines: []}

  def log_tail_section(identifier, log_file) when is_binary(log_file) do
    case File.stat(log_file) do
      {:error, :enoent} ->
        %{status: :empty, lines: []}

      {:error, _reason} ->
        %{status: :error, lines: []}

      {:ok, _stat} ->
        run_log_tail(identifier, log_file)
    end
  end

  defp run_log_tail(identifier, log_file) do
    task =
      Task.async(fn ->
        System.cmd("tail", ["-c", to_string(@log_tail_cap_bytes), log_file], stderr_to_stdout: true)
      end)

    case Task.yield(task, @log_tail_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        lines =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.contains?(&1, identifier))
          |> Enum.take(-@log_tail_max_lines)

        if lines == [] do
          %{status: :no_entries, lines: []}
        else
          %{status: :ok, lines: lines}
        end

      _other ->
        %{status: :error, lines: []}
    end
  end

  @doc """
  Read `sessions/<identifier>/notes.md` from the Traffic Control state repo.

  - `:ok` with the file content when the file exists.
  - `:missing` when the file does not exist.
  - `:memory_tracker` when `state_repo` is nil (memory tracker mode).
  """
  @spec notes_section(session_identifier(), Path.t() | nil) :: notes_section()
  def notes_section(_identifier, nil), do: %{status: :memory_tracker, content: nil}

  def notes_section(identifier, state_repo) when is_binary(state_repo) do
    notes_path = Path.join([state_repo, "sessions", identifier, "notes.md"])

    case read_capped(notes_path, @notes_max_bytes) do
      {:ok, content} -> %{status: :ok, content: content}
      :missing -> %{status: :missing, content: nil}
    end
  end

  defp read_capped(path, max_bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, fd} ->
        try do
          case IO.binread(fd, max_bytes) do
            :eof -> {:ok, ""}
            {:error, _reason} -> :missing
            data when is_binary(data) -> {:ok, trim_to_utf8_boundary(data)}
          end
        after
          File.close(fd)
        end

      {:error, _reason} ->
        :missing
    end
  end

  # Drop trailing bytes that form an incomplete UTF-8 codepoint. Up to
  # three bytes can be cut by a fixed-byte read; we walk back until the
  # remaining binary is valid or empty.
  defp trim_to_utf8_boundary(data) when is_binary(data) do
    if String.valid?(data), do: data, else: trim_to_utf8_boundary(binary_drop_last(data))
  end

  defp binary_drop_last(""), do: ""
  defp binary_drop_last(data), do: binary_part(data, 0, byte_size(data) - 1)

  @doc """
  Build the on-disk paths block for a session.

  Returns `:hidden` when `state_repo` is nil (memory tracker mode).
  Otherwise returns a map with the four canonical paths.
  """
  @spec paths_section(session_identifier(), Path.t() | nil, Path.t() | nil) :: paths_section()
  def paths_section(_identifier, nil, _workspace_path), do: :hidden

  def paths_section(identifier, state_repo, workspace_path) when is_binary(state_repo) do
    session_dir = Path.join([state_repo, "sessions", identifier])

    %{
      session_yaml: Path.join(session_dir, "session.yaml"),
      notes_md: Path.join(session_dir, "notes.md"),
      links_yaml: Path.join(session_dir, "links.yaml"),
      workspace: workspace_path
    }
  end

  defp status(running, _retry) when is_map(running), do: "running"
  defp status(_running, retry) when is_map(retry), do: "retrying"

  defp header(identifier, running, retry, workspace_path) do
    %{
      identifier: identifier,
      issue_id: (running && running.issue_id) || (retry && retry.issue_id),
      worker_host: from_first(:worker_host, running, retry),
      workspace_path: workspace_path
    }
  end

  defp live_state(running, retry) when is_map(running) do
    %{
      state: running.state,
      worker_kind: Map.get(running, :worker_kind),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      },
      retry: nil,
      last_error: retry && Map.get(retry, :error)
    }
  end

  defp live_state(_running, retry) when is_map(retry) do
    %{
      state: nil,
      worker_kind: Map.get(retry, :worker_kind),
      session_id: nil,
      turn_count: 0,
      started_at: nil,
      last_event: nil,
      last_message: nil,
      last_event_at: nil,
      tokens: %{input_tokens: nil, output_tokens: nil, total_tokens: nil},
      retry: %{
        attempt: retry.attempt,
        due_at: due_at_iso8601(Map.get(retry, :due_in_ms))
      },
      last_error: Map.get(retry, :error)
    }
  end

  defp from_first(key, %{} = a, b), do: Map.get(a, key) || (is_map(b) && Map.get(b, key)) || nil
  defp from_first(key, nil, %{} = b), do: Map.get(b, key)
  defp from_first(_key, nil, nil), do: nil

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_other), do: nil

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_other), do: nil
end
