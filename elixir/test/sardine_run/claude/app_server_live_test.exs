defmodule SardineRun.Claude.AppServerLiveTest do
  @moduledoc """
  Live end-to-end test against the real Claude Code CLI.

  Gated by `SARDINE_RUN_LIVE_E2E=1`. Skipped in normal CI runs because it
  requires the `claude` binary to be installed and authenticated.
  """

  use SardineRun.TestSupport

  @moduletag :live_e2e

  alias SardineRun.Claude.AppServer

  setup do
    if System.get_env("SARDINE_RUN_LIVE_E2E") != "1" do
      {:ok, skip: true}
    else
      workspace_root =
        Path.join(System.tmp_dir!(), "sardine-run-claude-live-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "session")
      File.mkdir_p!(workspace)

      on_exit(fn -> File.rm_rf!(workspace_root) end)

      state_repo = make_state_repo!()
      previous_env = System.get_env("TRAFFIC_CONTROL_STATE_REPO")
      System.delete_env("TRAFFIC_CONTROL_STATE_REPO")

      on_exit(fn ->
        restore_env("TRAFFIC_CONTROL_STATE_REPO", previous_env)
        File.rm_rf!(state_repo)
      end)

      {:ok, workspace: workspace, state_repo: state_repo, workspace_root: workspace_root}
    end
  end

  @tag :live_e2e
  test "round-trips a single turn against the real claude CLI", ctx do
    if Map.get(ctx, :skip, false) do
      :ok
    else
      live_round_trip(ctx)
    end
  end

  defp live_round_trip(%{
         workspace: workspace,
         state_repo: state_repo,
         workspace_root: workspace_root
       }) do
    script_path = Path.expand(Path.join([File.cwd!(), "scripts", "claude-launch.sh"]))

    body = """
    ---
    tracker:
      kind: traffic_control
      state_repo: "#{state_repo}"
    workspace:
      root: "#{workspace_root}"
    claude:
      command: "#{script_path}"
      model: sonnet
      effort: high
      permission_mode: bypassPermissions
    ---

    Workflow body.
    """

    File.write!(Workflow.workflow_file_path(), body)

    if Process.whereis(SardineRun.WorkflowStore) do
      try do
        SardineRun.WorkflowStore.force_reload()
      catch
        :exit, _ -> :ok
      end
    end

    issue = %{id: "LIVE-1", identifier: "LIVE-1", title: "Live"}

    {:ok, session} = AppServer.start_session(workspace)

    try do
      assert {:ok, _result} = AppServer.run_turn(session, "Respond with the word OK.", issue)
    after
      AppServer.stop_session(session)
    end
  end
end
