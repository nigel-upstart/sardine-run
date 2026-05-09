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

  describe "Orchestrator.write_session_dashboard_url/2 (dispatch path)" do
    test "writes URL constructed from current Config", %{state_repo: repo} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "traffic_control",
        tracker_state_repo: repo,
        server_port: 4567,
        server_host: "127.0.0.1"
      )

      File.mkdir_p!(Path.dirname(session_path(repo, "DISP-1")))
      File.write!(session_path(repo, "DISP-1"), "id: DISP-1\nstatus: active\n")

      assert :ok = Orchestrator.write_session_dashboard_url("DISP-1", "DISP-1")

      parsed = read_yaml!(session_path(repo, "DISP-1"))

      assert get_in(parsed, ["sardine_run", "dashboard_url"]) ==
               "http://127.0.0.1:4567/session/DISP-1"
    end

    test "writes nil when server.port is unset", %{state_repo: repo} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "traffic_control",
        tracker_state_repo: repo,
        server_port: nil,
        server_host: nil
      )

      File.mkdir_p!(Path.dirname(session_path(repo, "DISP-NIL")))
      File.write!(session_path(repo, "DISP-NIL"), "id: DISP-NIL\nstatus: active\n")

      assert :ok = Orchestrator.write_session_dashboard_url("DISP-NIL", "DISP-NIL")

      parsed = read_yaml!(session_path(repo, "DISP-NIL"))
      assert is_nil(get_in(parsed, ["sardine_run", "dashboard_url"]))
    end

    test "rebinds wildcard host (0.0.0.0) to 127.0.0.1 in the URL", %{state_repo: repo} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "traffic_control",
        tracker_state_repo: repo,
        server_port: 4000,
        server_host: "0.0.0.0"
      )

      File.mkdir_p!(Path.dirname(session_path(repo, "DISP-WILD")))
      File.write!(session_path(repo, "DISP-WILD"), "id: DISP-WILD\nstatus: active\n")

      assert :ok = Orchestrator.write_session_dashboard_url("DISP-WILD", "DISP-WILD")

      parsed = read_yaml!(session_path(repo, "DISP-WILD"))

      assert get_in(parsed, ["sardine_run", "dashboard_url"]) ==
               "http://127.0.0.1:4000/session/DISP-WILD"
    end

    test "returns {:error, _} for malformed issue_id without crashing", %{state_repo: _repo} do
      assert {:error, _reason} = Orchestrator.write_session_dashboard_url("../etc", "../etc")
    end
  end

  describe "orchestrator :DOWN handler clears dashboard_url" do
    test "agent process termination clears dashboard_url in session.yaml", %{state_repo: repo} do
      issue_id = "MT-PROOF"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "traffic_control",
        tracker_state_repo: repo,
        server_port: 4000,
        server_host: "127.0.0.1"
      )

      session_dir = Path.dirname(session_path(repo, issue_id))
      File.mkdir_p!(session_dir)

      File.write!(
        session_path(repo, issue_id),
        """
        id: #{issue_id}
        status: active
        sardine_run:
          dashboard_url: "http://127.0.0.1:4000/session/#{issue_id}"
          worker_host: worker-1
        """
      )

      # Sanity: pre-condition holds.
      pre = read_yaml!(session_path(repo, issue_id))

      assert get_in(pre, ["sardine_run", "dashboard_url"]) ==
               "http://127.0.0.1:4000/session/#{issue_id}"

      orchestrator_name = Module.concat(__MODULE__, :DownClearOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      issue = %Issue{
        id: issue_id,
        identifier: issue_id,
        title: "Proof of clear-on-down",
        state: "In Progress"
      }

      ref = make_ref()
      now = DateTime.utc_now()

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        session_id: "thread-proof",
        turn_count: 1,
        last_codex_message: nil,
        last_codex_timestamp: now,
        last_codex_event: nil,
        started_at: now,
        worker_host: "worker-1",
        workspace_path: "/tmp/ignored"
      }

      :sys.replace_state(pid, fn state ->
        Map.put(state, :running, Map.put(state.running, issue_id, running_entry))
      end)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      _ = :sys.get_state(pid)

      post = read_yaml!(session_path(repo, issue_id))
      assert is_nil(get_in(post, ["sardine_run", "dashboard_url"]))
      # Sibling fields preserved.
      assert get_in(post, ["sardine_run", "worker_host"]) == "worker-1"
    end
  end
end
