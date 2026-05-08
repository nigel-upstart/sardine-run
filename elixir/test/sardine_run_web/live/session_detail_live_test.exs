defmodule SardineRunWeb.SessionDetailLiveTest do
  use SardineRun.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SardineRunWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  setup do
    endpoint_config = Application.get_env(:sardine_run, SardineRunWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:sardine_run, SardineRunWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  describe "GET /session/:issue_identifier" do
    test "renders header and live-state section for a running issue" do
      now = DateTime.utc_now()
      started_at = DateTime.add(now, -120, :second)

      snapshot = %{
        running: [
          %{
            issue_id: "id-001",
            identifier: "UPS-LIVE",
            state: "In Progress",
            worker_host: "worker-1",
            workspace_path: "/tmp/ws/UPS-LIVE",
            session_id: "thread-live",
            codex_app_server_pid: nil,
            codex_input_tokens: 10,
            codex_output_tokens: 20,
            codex_total_tokens: 30,
            turn_count: 5,
            started_at: started_at,
            last_codex_timestamp: now,
            last_codex_message: %{"type" => "agent_message", "message" => "rendered"},
            last_codex_event: "agent_message",
            runtime_seconds: 120
          }
        ],
        retrying: []
      }

      orchestrator_name = start_static_orchestrator!(snapshot)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/session/UPS-LIVE")

      assert html =~ "UPS-LIVE"
      assert html =~ "running"
      assert html =~ "thread-live"
      assert html =~ "worker-1"
      assert html =~ "/tmp/ws/UPS-LIVE"
      assert html =~ "Tokens"
      assert html =~ ~s(href="/")
    end

    test "renders retry block for a retrying issue" do
      snapshot = %{
        running: [],
        retrying: [
          %{
            issue_id: "id-002",
            identifier: "UPS-RETRY",
            attempt: 3,
            due_in_ms: 60_000,
            error: "boom",
            worker_host: "worker-2",
            workspace_path: "/tmp/ws/UPS-RETRY"
          }
        ]
      }

      orchestrator_name = start_static_orchestrator!(snapshot)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/session/UPS-RETRY")

      assert html =~ "UPS-RETRY"
      assert html =~ "retrying"
      assert html =~ "boom"
      assert html =~ "Attempt"
    end

    test "renders not-found page for an unknown identifier" do
      orchestrator_name = start_static_orchestrator!(%{running: [], retrying: []})
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/session/UPS-MISSING")

      assert html =~ "Session not active"
      assert html =~ ~s(href="/")
      refute html =~ "Tokens"
    end

    test "renders not-found page for an invalid identifier (path traversal)" do
      orchestrator_name = start_static_orchestrator!(%{running: [], retrying: []})
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/session/..")

      assert html =~ "Session not active"
      assert html =~ ~s(href="/")
    end

    test "renders the workspace git log section for a real repo" do
      workspace_root = Path.join(System.tmp_dir!(), "sr-live-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf!(workspace_root) end)

      workspace = Path.join(workspace_root, "UPS-LIVELOG")
      File.mkdir_p!(workspace)
      System.cmd("git", ["-C", workspace, "init", "--initial-branch=main"], stderr_to_stdout: true)
      System.cmd("git", ["-C", workspace, "config", "user.email", "t@example.com"], stderr_to_stdout: true)
      System.cmd("git", ["-C", workspace, "config", "user.name", "T"], stderr_to_stdout: true)
      System.cmd("git", ["-C", workspace, "config", "commit.gpgsign", "false"], stderr_to_stdout: true)
      File.write!(Path.join(workspace, "a.txt"), "x\n")
      System.cmd("git", ["-C", workspace, "add", "a.txt"], stderr_to_stdout: true)
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial commit visible"], stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      now = DateTime.utc_now()
      started_at = DateTime.add(now, -1, :second)

      snapshot = %{
        running: [
          %{
            issue_id: "id-livelog",
            identifier: "UPS-LIVELOG",
            state: "In Progress",
            worker_host: nil,
            workspace_path: workspace,
            session_id: "thread-livelog",
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            turn_count: 0,
            started_at: started_at,
            last_codex_timestamp: now,
            last_codex_message: nil,
            last_codex_event: nil,
            runtime_seconds: 1
          }
        ],
        retrying: []
      }

      orchestrator_name = start_static_orchestrator!(snapshot)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/session/UPS-LIVELOG")

      assert html =~ "Workspace git log"
      assert html =~ "initial commit visible"
    end

    test "renders the recent log entries section heading for a running session" do
      now = DateTime.utc_now()

      snapshot = %{
        running: [
          %{
            issue_id: "id-logtail",
            identifier: "UPS-LOGTAIL",
            state: "In Progress",
            worker_host: nil,
            workspace_path: nil,
            session_id: "thread-logtail",
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            turn_count: 0,
            started_at: DateTime.add(now, -1, :second),
            last_codex_timestamp: now,
            last_codex_message: nil,
            last_codex_event: nil,
            runtime_seconds: 1
          }
        ],
        retrying: []
      }

      orchestrator_name = start_static_orchestrator!(snapshot)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/session/UPS-LOGTAIL")

      assert html =~ "Recent log entries"
    end

    test "renders session notes and on-disk paths sections for a running session" do
      now = DateTime.utc_now()

      snapshot = %{
        running: [
          %{
            issue_id: "id-notes",
            identifier: "UPS-NOTES",
            state: "In Progress",
            worker_host: nil,
            workspace_path: nil,
            session_id: "thread-notes",
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            turn_count: 0,
            started_at: DateTime.add(now, -1, :second),
            last_codex_timestamp: now,
            last_codex_message: nil,
            last_codex_event: nil,
            runtime_seconds: 1
          }
        ],
        retrying: []
      }

      orchestrator_name = start_static_orchestrator!(snapshot)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/session/UPS-NOTES")

      assert html =~ "Session notes"
    end

    test "preserves filesystem-derived sections across :observability_updated broadcasts" do
      workspace_root =
        Path.join(System.tmp_dir!(), "sr-live-pres-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf!(workspace_root) end)

      workspace = Path.join(workspace_root, "UPS-PRESERVE")
      File.mkdir_p!(workspace)

      System.cmd("git", ["-C", workspace, "init", "--initial-branch=main"], stderr_to_stdout: true)

      System.cmd("git", ["-C", workspace, "config", "user.email", "t@example.com"], stderr_to_stdout: true)

      System.cmd("git", ["-C", workspace, "config", "user.name", "T"], stderr_to_stdout: true)

      System.cmd("git", ["-C", workspace, "config", "commit.gpgsign", "false"], stderr_to_stdout: true)

      File.write!(Path.join(workspace, "a.txt"), "x\n")
      System.cmd("git", ["-C", workspace, "add", "a.txt"], stderr_to_stdout: true)

      System.cmd("git", ["-C", workspace, "commit", "-m", "preserved-commit-line"], stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      now = DateTime.utc_now()

      snapshot_v1 = %{
        running: [
          %{
            issue_id: "id-preserve",
            identifier: "UPS-PRESERVE",
            state: "In Progress",
            worker_host: nil,
            workspace_path: workspace,
            session_id: "thread-preserve",
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            turn_count: 1,
            started_at: DateTime.add(now, -1, :second),
            last_codex_timestamp: now,
            last_codex_message: %{"type" => "agent_message", "message" => "v1-msg"},
            last_codex_event: "agent_message",
            runtime_seconds: 1
          }
        ],
        retrying: []
      }

      orchestrator_name = start_static_orchestrator!(snapshot_v1)
      orchestrator_pid = Process.whereis(orchestrator_name)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, html} = live(build_conn(), "/session/UPS-PRESERVE")
      assert html =~ "preserved-commit-line"
      assert html =~ "v1-msg"

      File.rm_rf!(workspace)

      snapshot_v2 =
        put_in(
          snapshot_v1.running,
          [
            put_in(hd(snapshot_v1.running).last_codex_message, %{
              "type" => "agent_message",
              "message" => "v2-msg"
            })
          ]
        )

      :sys.replace_state(orchestrator_pid, fn state ->
        Keyword.put(state, :snapshot, snapshot_v2)
      end)

      send(view.pid, :observability_updated)
      _ = :sys.get_state(view.pid)

      html_after = render(view)
      assert html_after =~ "v2-msg"

      assert html_after =~ "preserved-commit-line",
             "git log section should be preserved across observability broadcasts"
    end

    test "re-renders when an :observability_updated broadcast fires" do
      snapshot_v1 = build_running_snapshot("UPS-PUBSUB", "first message")

      orchestrator_name = start_static_orchestrator!(snapshot_v1)

      orchestrator_pid = Process.whereis(orchestrator_name)
      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, html} = live(build_conn(), "/session/UPS-PUBSUB")
      assert html =~ "first message"

      snapshot_v2 = build_running_snapshot("UPS-PUBSUB", "second message")

      :sys.replace_state(orchestrator_pid, fn state ->
        Keyword.put(state, :snapshot, snapshot_v2)
      end)

      send(view.pid, :observability_updated)
      _ = :sys.get_state(view.pid)

      assert render(view) =~ "second message"
    end
  end

  defp start_static_orchestrator!(snapshot) do
    name =
      Module.concat([
        __MODULE__,
        "Orchestrator#{System.unique_integer([:positive])}"
      ])

    {:ok, _pid} = StaticOrchestrator.start_link(name: name, snapshot: snapshot)
    name
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :sardine_run
      |> Application.get_env(SardineRunWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:sardine_run, SardineRunWeb.Endpoint, endpoint_config)
    start_supervised!({SardineRunWeb.Endpoint, []})
  end

  defp build_running_snapshot(identifier, message) do
    now = DateTime.utc_now()

    %{
      running: [
        %{
          issue_id: "id-pubsub",
          identifier: identifier,
          state: "In Progress",
          worker_host: nil,
          workspace_path: nil,
          session_id: "thread-pubsub",
          codex_app_server_pid: nil,
          codex_input_tokens: 1,
          codex_output_tokens: 2,
          codex_total_tokens: 3,
          turn_count: 1,
          started_at: DateTime.add(now, -10, :second),
          last_codex_timestamp: now,
          last_codex_message: %{"type" => "agent_message", "message" => message},
          last_codex_event: "agent_message",
          runtime_seconds: 10
        }
      ],
      retrying: []
    }
  end
end
