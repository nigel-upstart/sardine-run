defmodule SardineRun.Reviewer do
  @moduledoc """
  Reviewer species 🐡 — the prompt rendering half of the review-feedback
  worker. The transport half is reused from `SardineRun.Codex.AppServer`
  or `SardineRun.Claude.AppServer` (selected via `review.backend`); only
  the prompt body differs.

  When `Orchestrator.pick_worker/2` returns `{backend_module, :reviewer}`
  for a session in `review_pending`, `AgentRunner` calls
  `Reviewer.prompt/2` instead of the default `PromptBuilder.build_prompt/2`.
  This module loads `REVIEW_FEEDBACK.md` (path configurable via
  `review.prompt_file`, resolved relative to `WORKFLOW.md`'s directory)
  and renders it as a Liquid template with two top-level vars:

  - `issue` — the same `Tracker.Issue` struct the default prompt sees.
  - `pending_feedback` — the snapshot the `ReviewWatcher` wrote to
    `sessions/<id>/pending_feedback.yaml`, or an empty shape if no
    snapshot is on disk.
  """

  alias SardineRun.{Config, Tracker, Workflow}
  alias SardineRun.TrafficControl.SessionWriter

  @render_opts [strict_variables: false, strict_filters: true]

  @spec prompt(Tracker.Issue.t(), keyword()) :: String.t()
  def prompt(issue, opts \\ []) do
    template =
      load_template()
      |> parse_template!()

    template
    |> Solid.render!(render_vars(issue, opts), @render_opts)
    |> IO.iodata_to_binary()
  end

  defp render_vars(issue, _opts) do
    %{
      "issue" => issue |> Map.from_struct() |> to_solid_map(),
      "pending_feedback" => load_pending_feedback(issue)
    }
  end

  defp load_pending_feedback(%{id: session_id}) when is_binary(session_id) do
    feedback =
      case SessionWriter.read_pending_feedback(session_id) do
        {:ok, snapshot} when is_map(snapshot) -> snapshot
        _ -> %{}
      end

    feedback
    |> Map.put_new("threads", [])
    |> Map.put_new("failing_checks", [])
    |> to_solid_map()
  end

  defp load_pending_feedback(_issue) do
    %{"threads" => [], "failing_checks" => []} |> to_solid_map()
  end

  defp load_template do
    settings = Config.settings!()
    prompt_file = settings.review.prompt_file
    base_dir = Path.dirname(Workflow.workflow_file_path())
    path = Path.join(base_dir, prompt_file)

    case File.read(path) do
      {:ok, contents} ->
        contents

      {:error, reason} ->
        raise RuntimeError,
              "reviewer_prompt_missing: cannot read #{path} (#{inspect(reason)}). " <>
                "Configure review.prompt_file in WORKFLOW.md or place REVIEW_FEEDBACK.md next to it."
    end
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "reviewer_template_parse_error: #{Exception.message(error)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value
end
