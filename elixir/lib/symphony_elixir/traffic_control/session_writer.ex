defmodule SymphonyElixir.TrafficControl.SessionWriter do
  @moduledoc """
  Writes back into the Traffic Control state-repo `sessions/{id}/` files.

  This is the companion to `SymphonyElixir.TrafficControl.Adapter` for Sardine
  Run agents that need to mutate their assigned session via the
  `sardine_run_session` Codex dynamic tool.

  Top-level scalar fields (`status`, `focus`, `next_step`) are patched with
  line-oriented regex rewrites. Nested blocks (`waiting`, `sardine_run`) are
  decoded with `YamlElixir`, modified in place, and re-rendered with a
  hand-written serializer that preserves keys we know about and ignores keys
  we do not. The format is YAML-compatible and round-trips through
  `YamlElixir.read_from_string/1`.
  """

  alias SymphonyElixir.TrafficControl.Adapter

  @waiting_keys ~w(kind note requested_at since)
  @sardine_run_keys ~w(
    agent_id
    run_id
    last_heartbeat
    heartbeat_at
    worker_host
    workspace_path
    codex_session_id
    last_event
    last_message
    last_error
    last_event_at
    input_tokens
    output_tokens
    total_tokens
  )

  @spec update_status(String.t(), String.t(), map() | nil) :: :ok | {:error, term()}
  def update_status(session_id, status, waiting)
      when is_binary(session_id) and is_binary(status) do
    with {:ok, session_path} <- session_path(session_id),
         {:ok, raw} <- File.read(session_path),
         {:ok, parsed} <- decode_yaml(raw) do
      patched =
        raw
        |> patch_top_level("status", status)
        |> patch_waiting_block(parsed, status, waiting)

      File.write(session_path, patched)
    end
  end

  @spec update_heartbeat(String.t(), map()) :: :ok | {:error, term()}
  def update_heartbeat(session_id, runtime) when is_binary(session_id) and is_map(runtime) do
    with {:ok, session_path} <- session_path(session_id),
         {:ok, raw} <- File.read(session_path),
         {:ok, parsed} <- decode_yaml(raw) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      merged_runtime =
        runtime
        |> Map.put("heartbeat_at", now)
        |> Map.put("last_heartbeat", now)
        |> then(fn map ->
          if Map.has_key?(runtime, "last_event") do
            Map.put(map, "last_event_at", now)
          else
            map
          end
        end)

      patched = patch_sardine_run_block(raw, parsed, merged_runtime)
      File.write(session_path, patched)
    end
  end

  @spec append_note(String.t(), String.t()) :: :ok | {:error, term()}
  def append_note(session_id, body) when is_binary(session_id) and is_binary(body) do
    Adapter.create_comment(session_id, body)
  end

  @spec append_link(String.t(), map()) :: :ok | {:error, term()}
  def append_link(session_id, %{"label" => label, "kind" => kind, "url" => url})
      when is_binary(session_id) and is_binary(label) and is_binary(kind) and is_binary(url) do
    with {:ok, repo} <- Adapter.resolve_state_repo() do
      links_path = Path.join([repo, "sessions", session_id, "links.yaml"])
      File.mkdir_p!(Path.dirname(links_path))

      existing =
        case File.read(links_path) do
          {:ok, raw} ->
            case YamlElixir.read_from_string(raw) do
              {:ok, list} when is_list(list) -> list
              _ -> []
            end

          {:error, :enoent} ->
            []

          {:error, reason} ->
            throw({:read_error, reason})
        end

      new_entry = %{"label" => label, "kind" => kind, "url" => url}
      updated = existing ++ [new_entry]
      File.write(links_path, render_links_yaml(updated))
    end
  catch
    {:read_error, reason} -> {:error, reason}
  end

  @spec update_field(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def update_field(session_id, field, value)
      when is_binary(session_id) and field in ~w(focus next_step) do
    with {:ok, session_path} <- session_path(session_id),
         {:ok, raw} <- File.read(session_path) do
      patched = patch_top_level(raw, field, value)
      File.write(session_path, patched)
    end
  end

  defp session_path(session_id) do
    with {:ok, repo} <- Adapter.resolve_state_repo() do
      {:ok, Path.join([repo, "sessions", session_id, "session.yaml"])}
    end
  end

  defp decode_yaml(raw) do
    case YamlElixir.read_from_string(raw) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- top-level scalar patches ---------------------------------------------

  defp patch_top_level(raw, key, nil), do: patch_top_level(raw, key, "")

  defp patch_top_level(raw, key, value) when is_binary(value) do
    rendered_value = scalar_yaml(value)
    line = "#{key}: #{rendered_value}"
    pattern = ~r/^#{Regex.escape(key)}:\s*.*$/m

    if Regex.match?(pattern, raw) do
      Regex.replace(pattern, raw, line, global: false)
    else
      ensure_trailing_newline(raw) <> line <> "\n"
    end
  end

  defp ensure_trailing_newline(raw) do
    if String.ends_with?(raw, "\n"), do: raw, else: raw <> "\n"
  end

  # ---- nested-block patches -------------------------------------------------

  defp patch_waiting_block(raw, _parsed, status, waiting)
       when status == "waiting" and is_map(waiting) do
    rendered = render_block("waiting", waiting, @waiting_keys)
    replace_block(raw, "waiting", rendered)
  end

  defp patch_waiting_block(raw, _parsed, _status, _waiting) do
    replace_block(raw, "waiting", "waiting: null")
  end

  defp patch_sardine_run_block(raw, parsed, runtime) do
    existing = Map.get(parsed, "sardine_run") || %{}

    merged =
      existing
      |> coerce_map()
      |> Map.merge(stringify_runtime_values(runtime))

    rendered = render_block("sardine_run", merged, @sardine_run_keys)
    replace_block(raw, "sardine_run", rendered)
  end

  defp coerce_map(value) when is_map(value), do: value
  defp coerce_map(_), do: %{}

  defp stringify_runtime_values(runtime) do
    Map.new(runtime, fn {k, v} -> {to_string(k), v} end)
  end

  # Replace (or append) a top-level YAML key whose value may be a scalar
  # `key: ...` or a nested block (`key:\n  subkey: ...`).
  defp replace_block(raw, key, rendered) do
    case find_block_range(raw, key) do
      {:ok, prefix, suffix} ->
        prefix <> rendered <> ensure_block_separator(rendered, suffix) <> suffix

      :not_found ->
        ensure_trailing_newline(raw) <> rendered <> "\n"
    end
  end

  defp ensure_block_separator(rendered, suffix) do
    cond do
      suffix == "" -> "\n"
      String.ends_with?(rendered, "\n") -> ""
      String.starts_with?(suffix, "\n") -> ""
      true -> "\n"
    end
  end

  # Find the byte range of the existing top-level block with the given key so
  # we can replace it. A block ends at the next non-indented, non-blank line or
  # at end-of-file.
  defp find_block_range(raw, key) do
    lines = String.split(raw, "\n", trim: false)
    walk_lines(lines, key, [], 0, length(lines))
  end

  defp walk_lines([], _key, _acc_prefix, _idx, _total), do: :not_found

  defp walk_lines([line | rest], key, acc_prefix, idx, total) do
    if top_level_match?(line, key) do
      {block_lines, after_lines} = take_block_continuation(rest, [])
      _ = block_lines

      prefix =
        case acc_prefix do
          [] -> ""
          _ -> Enum.reverse(acc_prefix) |> Enum.join("\n") |> Kernel.<>("\n")
        end

      suffix =
        case after_lines do
          [] ->
            ""

          _ ->
            Enum.join(after_lines, "\n")
        end

      _ = idx
      _ = total

      {:ok, prefix, suffix}
    else
      walk_lines(rest, key, [line | acc_prefix], idx + 1, total)
    end
  end

  defp top_level_match?(line, key) do
    String.match?(line, ~r/^#{Regex.escape(key)}:(\s|$)/)
  end

  # After the matching `key:` line, consume continuation lines: blank lines or
  # indented lines belong to the block.
  defp take_block_continuation([], block), do: {Enum.reverse(block), []}

  defp take_block_continuation([line | rest] = all, block) do
    cond do
      String.starts_with?(line, " ") or String.starts_with?(line, "\t") ->
        take_block_continuation(rest, [line | block])

      String.trim(line) == "" ->
        # blank line — peek ahead. If the next non-blank line is indented, keep
        # going; otherwise the blank line is the boundary and not part of the
        # block (we leave it on the suffix).
        if next_indented?(rest) do
          take_block_continuation(rest, [line | block])
        else
          {Enum.reverse(block), all}
        end

      true ->
        {Enum.reverse(block), all}
    end
  end

  defp next_indented?([]), do: false

  defp next_indented?([line | rest]) do
    cond do
      String.trim(line) == "" -> next_indented?(rest)
      String.starts_with?(line, " ") or String.starts_with?(line, "\t") -> true
      true -> false
    end
  end

  # Render a known nested block. Unknown keys are dropped to avoid surprising
  # writes; this is a write-back of fields the tool understands.
  defp render_block(key, map, allowed_keys) when is_map(map) do
    entries =
      allowed_keys
      |> Enum.flat_map(fn k ->
        case Map.fetch(map, k) do
          {:ok, nil} -> []
          {:ok, value} -> [{k, value}]
          :error -> []
        end
      end)

    case entries do
      [] ->
        "#{key}: null"

      _ ->
        body =
          Enum.map_join(entries, "\n", fn {k, v} -> "  #{k}: #{scalar_yaml(v)}" end)

        "#{key}:\n" <> body
    end
  end

  # ---- links.yaml rendering -------------------------------------------------

  defp render_links_yaml(entries) do
    entries
    |> Enum.map_join("\n", &render_link_entry/1)
    |> Kernel.<>("\n")
  end

  defp render_link_entry(%{"label" => label, "kind" => kind, "url" => url}) do
    "- label: #{scalar_yaml(label)}\n" <>
      "  kind: #{scalar_yaml(kind)}\n" <>
      "  url: #{scalar_yaml(url)}"
  end

  # ---- scalar rendering ------------------------------------------------------

  defp scalar_yaml(nil), do: "null"
  defp scalar_yaml(true), do: "true"
  defp scalar_yaml(false), do: "false"
  defp scalar_yaml(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar_yaml(value) when is_float(value), do: Float.to_string(value)

  defp scalar_yaml(value) when is_binary(value) do
    if needs_quoting?(value) do
      "\"" <> escape_double(value) <> "\""
    else
      value
    end
  end

  defp scalar_yaml(value), do: scalar_yaml(to_string(value))

  defp needs_quoting?(""), do: true

  defp needs_quoting?(value) do
    cond do
      String.starts_with?(value, " ") -> true
      String.ends_with?(value, " ") -> true
      String.contains?(value, "\n") -> true
      String.contains?(value, "\"") -> true
      String.contains?(value, ":") -> true
      String.contains?(value, "#") -> true
      String.starts_with?(value, "-") -> true
      String.starts_with?(value, "?") -> true
      String.starts_with?(value, "*") -> true
      String.starts_with?(value, "&") -> true
      String.starts_with?(value, "!") -> true
      String.starts_with?(value, "[") -> true
      String.starts_with?(value, "{") -> true
      String.starts_with?(value, "'") -> true
      reserved_word?(value) -> true
      true -> false
    end
  end

  defp reserved_word?(value) do
    String.downcase(value) in ~w(null true false yes no on off ~)
  end

  defp escape_double(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
