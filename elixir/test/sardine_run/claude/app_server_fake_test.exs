defmodule SardineRun.Claude.AppServerFakeTest do
  use SardineRun.TestSupport

  alias SardineRun.Claude.AppServer

  setup do
    workspace_root =
      Path.join(System.tmp_dir!(), "sardine-run-claude-test-#{System.unique_integer([:positive])}")

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

    {:ok, workspace: workspace, workspace_root: workspace_root, state_repo: state_repo}
  end

  test "runs a turn against a scripted fake claude binary and reports completion",
       %{workspace: workspace, workspace_root: workspace_root, state_repo: state_repo} do
    fake_script_path = write_fake_claude!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "traffic_control",
      tracker_state_repo: state_repo,
      workspace_root: workspace_root
    )

    # Override the claude command via Application env. The schema reads from
    # WORKFLOW.md but we don't have a dedicated `claude_command` override in
    # the test helper, so we patch the resolved settings by writing claude
    # config directly into a fresh workflow file.
    write_workflow_file_with_claude!(state_repo, workspace_root, fake_script_path)

    issue = %{id: "S-1", identifier: "S-1", title: "Test session"}

    parent = self()

    on_message = fn msg ->
      send(parent, {:event, msg.event, msg})
      :ok
    end

    assert {:ok, session} = AppServer.start_session(workspace)

    try do
      assert {:ok, result} = AppServer.run_turn(session, "hello world", issue, on_message: on_message)

      assert result.session_id =~ "-"
      assert is_binary(result.thread_id)
      assert is_binary(result.turn_id)
    after
      AppServer.stop_session(session)
    end

    assert_receive {:event, :session_started, _}, 5_000
    assert_receive {:event, :turn_completed, _}, 5_000
  end

  defp write_fake_claude!(workspace_root) do
    path = Path.join(workspace_root, "fake-claude.sh")

    script = """
    #!/usr/bin/env bash
    set -euo pipefail
    # Emit init
    printf '{"type":"system","subtype":"init","session_id":"fake-thread-1"}\n'
    # Drain one line of stdin so the Port write does not block forever
    IFS= read -r _line || true
    # Emit a result
    printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"fake-thread-1"}\n'
    exit 0
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp write_workflow_file_with_claude!(state_repo, workspace_root, fake_script_path) do
    path = Workflow.workflow_file_path()

    body = """
    ---
    tracker:
      kind: traffic_control
      state_repo: "#{state_repo}"
    workspace:
      root: "#{workspace_root}"
    agent:
      max_concurrent_agents: 10
      max_turns: 20
    codex:
      command: "codex app-server"
    claude:
      command: "#{fake_script_path}"
      model: sonnet
      effort: high
      permission_mode: bypassPermissions
      turn_timeout_ms: 5000
      read_timeout_ms: 2000
      stall_timeout_ms: 10000
    ---

    Workflow body.
    """

    File.write!(path, body)

    if Process.whereis(SardineRun.WorkflowStore) do
      try do
        SardineRun.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end
end
