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

    children = [
      {Phoenix.PubSub, name: SardineRun.PubSub},
      {Task.Supervisor, name: SardineRun.TaskSupervisor},
      SardineRun.WorkflowStore,
      SardineRun.Orchestrator,
      SardineRun.HttpServer,
      SardineRun.StatusDashboard
    ]

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
end
