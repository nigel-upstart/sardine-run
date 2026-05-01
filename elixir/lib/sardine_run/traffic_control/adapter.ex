defmodule SardineRun.TrafficControl.Adapter do
  @moduledoc """
  Traffic Control state-repo backed tracker adapter.

  Reads sessions from `$TRAFFIC_CONTROL_STATE_REPO` (or the configured
  `tracker.state_repo`), parses `sessions/{id}/session.yaml`, and exposes
  them through the `SardineRun.Tracker` behaviour as `Tracker.Issue`s.
  """

  @behaviour SardineRun.Tracker

  alias SardineRun.Config
  alias SardineRun.Tracker.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, repo} <- resolve_state_repo() do
      {:ok, load_all_issues(repo)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    with {:ok, repo} <- resolve_state_repo() do
      wanted = states |> Enum.map(&normalize_state/1) |> MapSet.new()

      {:ok,
       repo
       |> load_all_issues()
       |> Enum.filter(fn %Issue{state: state} ->
         MapSet.member?(wanted, normalize_state(state))
       end)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(ids) when is_list(ids) do
    with {:ok, repo} <- resolve_state_repo() do
      issues =
        ids
        |> Enum.flat_map(fn id ->
          case load_issue(repo, id) do
            {:ok, issue} -> [issue]
            _ -> []
          end
        end)

      {:ok, issues}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(session_id, body)
      when is_binary(session_id) and is_binary(body) do
    with {:ok, repo} <- resolve_state_repo() do
      notes_path = Path.join([repo, "sessions", session_id, "notes.md"])
      File.mkdir_p!(Path.dirname(notes_path))

      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      entry = "\n\n## Sardine Run @ #{timestamp}\n\n#{body}\n"
      File.write(notes_path, entry, [:append])
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(session_id, state_name)
      when is_binary(session_id) and is_binary(state_name) do
    with {:ok, repo} <- resolve_state_repo(),
         session_path = Path.join([repo, "sessions", session_id, "session.yaml"]),
         {:ok, raw} <- File.read(session_path),
         {:ok, _parsed} <- decode_yaml(raw) do
      replaced = patch_status(raw, normalize_state(state_name))
      File.write(session_path, replaced)
    end
  end

  @doc false
  @spec resolve_state_repo() :: {:ok, Path.t()} | {:error, :state_repo_not_configured}
  def resolve_state_repo do
    case Config.settings!().tracker.state_repo do
      repo when is_binary(repo) and repo != "" ->
        {:ok, Path.expand(repo)}

      _ ->
        {:error, :state_repo_not_configured}
    end
  end

  defp load_all_issues(repo) do
    sessions_dir = Path.join(repo, "sessions")

    case File.ls(sessions_dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn id ->
          case load_issue(repo, id) do
            {:ok, issue} -> [issue]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp load_issue(repo, session_id) do
    path = Path.join([repo, "sessions", session_id, "session.yaml"])

    with {:ok, raw} <- File.read(path),
         {:ok, parsed} when is_map(parsed) <- decode_yaml(raw) do
      {:ok, build_issue(session_id, parsed)}
    end
  end

  defp build_issue(session_id, data) do
    id = Map.get(data, "id", session_id)

    %Issue{
      id: id,
      identifier: id,
      title: Map.get(data, "title"),
      description: build_description(data),
      priority: Map.get(data, "rank"),
      state: Map.get(data, "status"),
      branch_name: Map.get(data, "branch"),
      url: nil,
      assignee_id: nil,
      labels: Map.get(data, "tags") || [],
      assigned_to_worker: true,
      created_at: parse_datetime(Map.get(data, "created_at")),
      updated_at: parse_datetime(Map.get(data, "updated_at"))
    }
  end

  defp build_description(data) do
    sections =
      [
        section("Objective", Map.get(data, "objective")),
        section("Focus", Map.get(data, "focus")),
        section("Next step", Map.get(data, "next_step"))
      ]
      |> Enum.reject(&is_nil/1)

    case sections do
      [] -> Map.get(data, "description")
      sections -> Enum.join(sections, "\n\n")
    end
  end

  defp section(_label, nil), do: nil
  defp section(_label, ""), do: nil
  defp section(label, value), do: "## #{label}\n\n#{value}"

  defp normalize_state(state) when is_binary(state),
    do: state |> String.trim() |> String.downcase()

  defp normalize_state(_state), do: ""

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(_value), do: nil

  defp decode_yaml(raw) do
    case YamlElixir.read_from_string(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp patch_status(raw, status) do
    if Regex.match?(~r/^status:\s.*/m, raw) do
      Regex.replace(~r/^status:\s.*$/m, raw, "status: #{status}", global: false)
    else
      raw <> "\nstatus: #{status}\n"
    end
  end
end
