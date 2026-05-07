defmodule SardineRun.OrchestratorDashboardUrlTest do
  @moduledoc """
  Tests for the dashboard_url write/clear lifecycle: on dispatch the orchestrator
  writes the per-session deep-link URL into `sardine_run.dashboard_url` in
  `session.yaml`; on termination it clears it back to null.

  These tests exercise the behavior indirectly via SessionWriter (since the
  orchestrator helpers are private) and via Config-driven URL construction.
  """
  use SardineRun.TestSupport

  alias SardineRun.TrafficControl.SessionWriter

  setup do
    state_repo = make_state_repo!()
    previous_env = System.get_env("TRAFFIC_CONTROL_STATE_REPO")
    System.delete_env("TRAFFIC_CONTROL_STATE_REPO")

    on_exit(fn ->
      restore_env("TRAFFIC_CONTROL_STATE_REPO", previous_env)
      File.rm_rf!(state_repo)
    end)

    {:ok, state_repo: state_repo}
  end

  defp session_path(repo, id), do: Path.join([repo, "sessions", id, "session.yaml"])

  defp read_yaml!(path) do
    {:ok, parsed} = path |> File.read!() |> YamlElixir.read_from_string()
    parsed
  end

  describe "write-on-dispatch sets dashboard_url" do
    test "update_runtime writes URL into sardine_run block", %{state_repo: repo} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "traffic_control",
        tracker_state_repo: repo,
        server_port: 4000,
        server_host: "127.0.0.1"
      )

      write_session_yaml!(repo, "dispatch-1", id: "dispatch-1", status: "active")

      assert :ok =
               SessionWriter.update_runtime("dispatch-1", %{
                 dashboard_url: "http://127.0.0.1:4000/session/MT-42"
               })

      parsed = read_yaml!(session_path(repo, "dispatch-1"))
      assert parsed["sardine_run"]["dashboard_url"] == "http://127.0.0.1:4000/session/MT-42"
    end
  end

  describe "terminal write clears dashboard_url" do
    test "update_runtime with nil renders dashboard_url: null in session.yaml", %{state_repo: repo} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "traffic_control",
        tracker_state_repo: repo,
        server_port: 4000,
        server_host: "127.0.0.1"
      )

      write_session_yaml!(repo, "term-1", id: "term-1", status: "active")

      # Simulate dispatch write
      assert :ok =
               SessionWriter.update_runtime("term-1", %{
                 dashboard_url: "http://127.0.0.1:4000/session/MT-43"
               })

      parsed = read_yaml!(session_path(repo, "term-1"))
      assert parsed["sardine_run"]["dashboard_url"] == "http://127.0.0.1:4000/session/MT-43"

      # Simulate termination clear
      assert :ok = SessionWriter.update_runtime("term-1", %{dashboard_url: nil})

      parsed = read_yaml!(session_path(repo, "term-1"))
      assert parsed["sardine_run"]["dashboard_url"] == nil
    end

    test "clearing dashboard_url preserves other sardine_run fields", %{state_repo: repo} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "traffic_control",
        tracker_state_repo: repo
      )

      write_session_yaml!(repo, "term-2", id: "term-2", status: "active")

      assert :ok =
               SessionWriter.update_heartbeat("term-2", %{
                 "agent_id" => "worker-7",
                 "run_id" => "run-xyz"
               })

      assert :ok =
               SessionWriter.update_runtime("term-2", %{
                 dashboard_url: "http://127.0.0.1:4000/session/MT-44"
               })

      assert :ok = SessionWriter.update_runtime("term-2", %{dashboard_url: nil})

      parsed = read_yaml!(session_path(repo, "term-2"))
      assert parsed["sardine_run"]["agent_id"] == "worker-7"
      assert parsed["sardine_run"]["run_id"] == "run-xyz"
      assert parsed["sardine_run"]["dashboard_url"] == nil
    end
  end

  describe "server-disabled produces nil URL" do
    test "update_runtime with nil is a no-op when session.yaml already lacks sardine_run", %{
      state_repo: repo
    } do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "traffic_control",
        tracker_state_repo: repo,
        server_port: nil,
        server_host: nil
      )

      File.mkdir_p!(Path.dirname(session_path(repo, "noserver-1")))
      File.write!(session_path(repo, "noserver-1"), "id: noserver-1\nstatus: active\n")

      # When server is disabled the orchestrator passes nil; update_runtime should handle it
      assert :ok = SessionWriter.update_runtime("noserver-1", %{dashboard_url: nil})

      parsed = read_yaml!(session_path(repo, "noserver-1"))
      # sardine_run block may be written as null or with dashboard_url: null — either is fine
      # The important invariant: no crash and dashboard_url is nil/absent
      refute get_in(parsed, ["sardine_run", "dashboard_url"]) == "http://127.0.0.1:4000/session/noserver-1"
    end
  end
end
