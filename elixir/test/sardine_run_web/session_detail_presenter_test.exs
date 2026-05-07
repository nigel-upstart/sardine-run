defmodule SardineRunWeb.SessionDetailPresenterTest do
  use ExUnit.Case, async: true

  alias SardineRunWeb.SessionDetailPresenter

  describe "validate_identifier/1" do
    test "accepts identifiers matching the SessionWriter allow-list" do
      for identifier <- ["UPS-123", "MT-188", "foo.bar", "a_b", "abc", "9999", "X-1.0_2"] do
        assert {:ok, ^identifier} = SessionDetailPresenter.validate_identifier(identifier)
      end
    end

    test "rejects empty, traversal, slash, and whitespace identifiers" do
      for identifier <- ["", "..", "../etc", "a/b", "a b", "a\nb", "foo/", "/abs", "../../boom"] do
        assert {:error, :invalid_identifier} =
                 SessionDetailPresenter.validate_identifier(identifier)
      end
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_identifier} = SessionDetailPresenter.validate_identifier(nil)
      assert {:error, :invalid_identifier} = SessionDetailPresenter.validate_identifier(123)
      assert {:error, :invalid_identifier} = SessionDetailPresenter.validate_identifier(:atom)
    end
  end

  describe "payload/3 — running issue" do
    setup do
      now = DateTime.utc_now()
      started_at = DateTime.add(now, -90, :second)

      running_entry = %{
        issue_id: "id-001",
        identifier: "UPS-123",
        state: "In Progress",
        worker_host: "worker-1",
        workspace_path: "/tmp/ws/UPS-123",
        session_id: "sess-abc",
        codex_app_server_pid: nil,
        codex_input_tokens: 100,
        codex_output_tokens: 250,
        codex_total_tokens: 350,
        turn_count: 4,
        started_at: started_at,
        last_codex_timestamp: now,
        last_codex_message: %{"type" => "agent_message", "message" => "hello"},
        last_codex_event: "agent_message",
        runtime_seconds: 90
      }

      snapshot = %{running: [running_entry], retrying: []}

      {:ok, snapshot: snapshot, started_at: started_at, now: now}
    end

    test "returns a running payload for a known identifier", %{snapshot: snapshot} do
      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-123", snapshot, %{})

      assert payload.identifier == "UPS-123"
      assert payload.status == "running"

      assert payload.header.issue_id == "id-001"
      assert payload.header.identifier == "UPS-123"
      assert payload.header.worker_host == "worker-1"
      assert payload.header.workspace_path == "/tmp/ws/UPS-123"

      assert payload.live_state.session_id == "sess-abc"
      assert payload.live_state.turn_count == 4
      assert payload.live_state.state == "In Progress"
      assert payload.live_state.last_event == "agent_message"
      assert payload.live_state.tokens == %{input_tokens: 100, output_tokens: 250, total_tokens: 350}
      assert is_binary(payload.live_state.started_at)
      assert is_binary(payload.live_state.last_event_at)
      assert is_binary(payload.live_state.last_message)
      assert payload.live_state.retry == nil
      assert payload.live_state.last_error == nil
    end
  end

  describe "payload/3 — retrying issue" do
    setup do
      retry_entry = %{
        issue_id: "id-002",
        identifier: "UPS-456",
        attempt: 2,
        due_in_ms: 30_000,
        error: "boom",
        worker_host: "worker-2",
        workspace_path: "/tmp/ws/UPS-456"
      }

      snapshot = %{running: [], retrying: [retry_entry]}

      {:ok, snapshot: snapshot}
    end

    test "returns a retrying payload for a known identifier", %{snapshot: snapshot} do
      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-456", snapshot, %{})

      assert payload.identifier == "UPS-456"
      assert payload.status == "retrying"

      assert payload.header.issue_id == "id-002"
      assert payload.header.worker_host == "worker-2"
      assert payload.header.workspace_path == "/tmp/ws/UPS-456"

      assert payload.live_state.retry == %{
               attempt: 2,
               due_at: payload.live_state.retry.due_at
             }

      assert is_binary(payload.live_state.retry.due_at)
      assert payload.live_state.last_error == "boom"
    end
  end

  describe "payload/3 — not found and invalid input" do
    test "returns :not_found when the identifier is in neither list" do
      snapshot = %{running: [], retrying: []}

      assert {:error, :not_found} =
               SessionDetailPresenter.payload("UPS-MISSING", snapshot, %{})
    end

    test "returns :invalid_identifier when the identifier fails the allow-list" do
      snapshot = %{running: [], retrying: []}

      assert {:error, :invalid_identifier} =
               SessionDetailPresenter.payload("../etc", snapshot, %{})

      assert {:error, :invalid_identifier} =
               SessionDetailPresenter.payload("a/b", snapshot, %{})
    end

    test "returns :not_found when the snapshot is malformed (no lists)" do
      assert {:error, :not_found} = SessionDetailPresenter.payload("UPS-1", %{}, %{})
    end
  end

  describe "payload/3 — workspace git log section" do
    setup do
      tmp_root =
        Path.join(
          System.tmp_dir!(),
          "sr-presenter-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_root)
      on_exit(fn -> File.rm_rf!(tmp_root) end)

      {:ok, root: tmp_root}
    end

    test "returns the last commits for a real git repo workspace", %{root: root} do
      workspace = Path.join(root, "UPS-GIT")
      init_git_repo!(workspace)
      commit_file!(workspace, "first.txt", "first commit")
      commit_file!(workspace, "second.txt", "second commit")

      snapshot = build_running_snapshot("UPS-GIT", workspace)
      filesystem = %{workspace_root: root}

      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-GIT", snapshot, filesystem)

      assert payload.git_log.status == :ok
      assert length(payload.git_log.lines) == 2

      assert Enum.any?(payload.git_log.lines, &String.contains?(&1, "second commit"))
      assert Enum.any?(payload.git_log.lines, &String.contains?(&1, "first commit"))
    end

    test "returns :empty for a directory that is not a git repo", %{root: root} do
      workspace = Path.join(root, "UPS-NOREPO")
      File.mkdir_p!(workspace)

      snapshot = build_running_snapshot("UPS-NOREPO", workspace)

      assert {:ok, payload} =
               SessionDetailPresenter.payload("UPS-NOREPO", snapshot, %{workspace_root: root})

      assert payload.git_log.status == :empty
      assert payload.git_log.lines == []
    end

    test "returns :workspace_not_present when the directory does not exist", %{root: root} do
      missing = Path.join(root, "UPS-MISSING-DIR")
      snapshot = build_running_snapshot("UPS-MISSING-DIR", missing)

      assert {:ok, payload} =
               SessionDetailPresenter.payload("UPS-MISSING-DIR", snapshot, %{workspace_root: root})

      assert payload.git_log.status == :workspace_not_present
      assert payload.git_log.lines == []
    end

    test "returns :unsafe_workspace when the workspace_path falls outside workspace_root", %{root: root} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "sr-outside-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside)
      init_git_repo!(outside)
      commit_file!(outside, "a.txt", "a")

      snapshot = build_running_snapshot("UPS-OUTSIDE", outside)

      assert {:ok, payload} =
               SessionDetailPresenter.payload("UPS-OUTSIDE", snapshot, %{workspace_root: root})

      assert payload.git_log.status == :unsafe_workspace
      assert payload.git_log.lines == []

      File.rm_rf!(outside)
    end

    test "returns :unconfigured when filesystem has no workspace_root", %{root: root} do
      workspace = Path.join(root, "UPS-NOFS")
      File.mkdir_p!(workspace)

      snapshot = build_running_snapshot("UPS-NOFS", workspace)

      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-NOFS", snapshot, %{})

      assert payload.git_log.status == :unconfigured
      assert payload.git_log.lines == []
    end

    test "returns :unconfigured when the entry has no workspace_path" do
      now = DateTime.utc_now()

      running_entry =
        running_entry("UPS-NOWS", DateTime.add(now, -1, :second), now)
        |> Map.put(:workspace_path, nil)

      snapshot = %{running: [running_entry], retrying: []}

      assert {:ok, payload} =
               SessionDetailPresenter.payload("UPS-NOWS", snapshot, %{workspace_root: "/tmp"})

      assert payload.git_log.status == :unconfigured
      assert payload.git_log.lines == []
    end

    defp build_running_snapshot(identifier, workspace) do
      now = DateTime.utc_now()
      started_at = DateTime.add(now, -10, :second)

      %{
        running: [
          running_entry(identifier, started_at, now) |> Map.put(:workspace_path, workspace)
        ],
        retrying: []
      }
    end

    defp running_entry(identifier, started_at, now) do
      %{
        issue_id: "id-#{identifier}",
        identifier: identifier,
        state: "In Progress",
        worker_host: nil,
        workspace_path: nil,
        session_id: "sess-#{identifier}",
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        turn_count: 0,
        started_at: started_at,
        last_codex_timestamp: now,
        last_codex_message: nil,
        last_codex_event: nil,
        runtime_seconds: 10
      }
    end

    defp init_git_repo!(path) do
      File.mkdir_p!(path)
      {_, 0} = System.cmd("git", ["-C", path, "init", "--initial-branch=main"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["-C", path, "config", "user.name", "Test"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["-C", path, "config", "commit.gpgsign", "false"], stderr_to_stdout: true)

      :ok
    end

    defp commit_file!(repo, filename, message) do
      File.write!(Path.join(repo, filename), "content\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", filename], stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["-C", repo, "commit", "-m", message], stderr_to_stdout: true)

      :ok
    end
  end

  describe "payload/3 — running takes precedence over retrying" do
    test "if the identifier appears in both running and retrying, status is running" do
      now = DateTime.utc_now()
      started_at = DateTime.add(now, -10, :second)

      running_entry = %{
        issue_id: "id-001",
        identifier: "UPS-DUP",
        state: "In Progress",
        worker_host: nil,
        workspace_path: nil,
        session_id: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        turn_count: 0,
        started_at: started_at,
        last_codex_timestamp: nil,
        last_codex_message: nil,
        last_codex_event: nil,
        runtime_seconds: 10
      }

      retry_entry = %{
        issue_id: "id-001",
        identifier: "UPS-DUP",
        attempt: 1,
        due_in_ms: 1_000,
        error: nil,
        worker_host: nil,
        workspace_path: nil
      }

      snapshot = %{running: [running_entry], retrying: [retry_entry]}

      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-DUP", snapshot, %{})
      assert payload.status == "running"
    end
  end
end
