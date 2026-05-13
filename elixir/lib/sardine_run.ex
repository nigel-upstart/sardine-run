defmodule SardineRun do
  @moduledoc """
  Entry point for the Sardine Run orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SardineRun.Orchestrator.start_link(opts)
  end
end

defmodule SardineRun.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SardineRun.LogFile.configure()

    children =
      [
        {Phoenix.PubSub, name: SardineRun.PubSub},
        {Task.Supervisor, name: SardineRun.TaskSupervisor},
        SardineRun.WorkflowStore,
        SardineRun.Orchestrator,
        SardineRun.HttpServer,
        SardineRun.StatusDashboard
      ] ++ maybe_review_watcher_child()

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SardineRun.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SardineRun.StatusDashboard.render_offline_status()
    :ok
  end

  defp maybe_review_watcher_child do
    if SardineRun.Config.settings!().review.enabled do
      [SardineRun.ReviewWatcher]
    else
      []
    end
  rescue
    # Config can fail to parse on early boot (e.g. missing WORKFLOW.md);
    # the orchestrator surfaces those errors. Don't crash the supervisor
    # just because the watcher couldn't be added.
    _ -> []
  end
end
