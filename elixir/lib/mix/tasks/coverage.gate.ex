defmodule Mix.Tasks.Coverage.Gate do
  @moduledoc """
  Per-module coverage gate.

  Locks listed modules at 100% coverage and enforces a global floor on the rest.
  Reads `mix test --cover`'s summary table from `cover/summary.txt`. The
  Makefile `coverage` target captures the file for you.
  """
  use Mix.Task

  @summary_path "cover/summary.txt"
  @global_minimum 75.0

  # Modules locked at 100% — ratchet up by editing the list. A regression on any
  # of these (drop below 100%) fails the gate, naming the offender.
  @locked_100 [
    Mix.Tasks.PrBody.Check,
    Mix.Tasks.Specs.Check,
    Mix.Tasks.Workspace.BeforeRemove,
    SardineRun,
    SardineRun.Config.Schema,
    SardineRun.Config.Schema.Agent,
    SardineRun.Config.Schema.Claude,
    SardineRun.Config.Schema.Codex,
    SardineRun.Config.Schema.Hooks,
    SardineRun.Config.Schema.Observability,
    SardineRun.Config.Schema.Polling,
    SardineRun.Config.Schema.Sampling,
    SardineRun.Config.Schema.Server,
    SardineRun.Config.Schema.StringOrMap,
    SardineRun.Config.Schema.Tracker,
    SardineRun.Config.Schema.Worker,
    SardineRun.Config.Schema.Workspace,
    SardineRun.Orchestrator.State,
    SardineRun.PathSafety,
    SardineRun.PromptBuilder,
    SardineRun.SSH,
    SardineRun.Tracker,
    SardineRun.Tracker.Issue,
    SardineRun.Tracker.Memory,
    SardineRun.Worker,
    SardineRun.Worker.Sampler,
    SardineRun.Workflow,
    SardineRun.WorkflowStore,
    SardineRun.WorkflowStore.State,
    SardineRunWeb.ObservabilityApiController,
    SardineRunWeb.ObservabilityPubSub
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok | no_return()
  def run(_args) do
    unless File.exists?(@summary_path) do
      Mix.raise(
        "Coverage summary not found at #{@summary_path}. " <>
          "Run `make coverage` (or `mix test --cover | tee #{@summary_path}` then `mix coverage.gate`)."
      )
    end

    results = parse_summary(File.read!(@summary_path))
    {global, locked_failures} = evaluate(results)

    cond do
      locked_failures != [] ->
        IO.puts(:stderr, "Locked-100% modules regressed:")

        for {m, c} <- locked_failures do
          IO.puts(:stderr, "  #{inspect(m)}: #{fmt(c)}% (expected 100.00%)")
        end

        Mix.raise("Coverage gate failed: #{length(locked_failures)} locked module(s) below 100%")

      global < @global_minimum ->
        Mix.raise("Coverage gate failed: global #{fmt(global)}% < #{fmt(@global_minimum)}%")

      true ->
        Mix.shell().info("Coverage gate OK: global #{fmt(global)}%, #{length(@locked_100)} locked-100% modules clean")

        :ok
    end
  end

  @doc """
  Parses the per-module table emitted by `mix test --cover`.

  Returns a map keyed by module atom (or `:total` for the totals row) with
  the percentage as a float. Modules absent from the table are not in the map.
  """
  @spec parse_summary(String.t()) :: %{(module() | :total) => float()}
  def parse_summary(text) do
    ~r/\|\s+([\d.]+)%\s+\|\s+([\w.]+)\s+\|/
    |> Regex.scan(text)
    |> Enum.reduce(%{}, fn [_, pct, name], acc ->
      Map.put(acc, key(name), String.to_float(pct))
    end)
  end

  defp key("Total"), do: :total
  defp key(name), do: Module.concat([name])

  defp evaluate(results) do
    global = Map.get(results, :total, 0.0)

    locked_failures =
      for module <- @locked_100,
          coverage = Map.get(results, module),
          not is_nil(coverage),
          coverage < 100.0,
          do: {module, coverage}

    {global, locked_failures}
  end

  defp fmt(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
end
