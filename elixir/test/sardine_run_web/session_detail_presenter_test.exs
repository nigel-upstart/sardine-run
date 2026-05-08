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

    test "falls back to <workspace_root>/<identifier> when entry has no workspace_path",
         %{root: root} do
      workspace = Path.join(root, "UPS-FALLBACK")
      init_git_repo!(workspace)
      commit_file!(workspace, "a.txt", "fallback commit")

      now = DateTime.utc_now()

      running_entry =
        running_entry("UPS-FALLBACK", DateTime.add(now, -1, :second), now)
        |> Map.put(:workspace_path, nil)

      snapshot = %{running: [running_entry], retrying: []}

      assert {:ok, payload} =
               SessionDetailPresenter.payload(
                 "UPS-FALLBACK",
                 snapshot,
                 %{workspace_root: root}
               )

      assert payload.git_log.status == :ok
      assert Enum.any?(payload.git_log.lines, &String.contains?(&1, "fallback commit"))

      assert payload.header.workspace_path == workspace
    end

    test "returns :unconfigured when neither entry nor workspace_root is available" do
      now = DateTime.utc_now()

      running_entry =
        running_entry("UPS-NOWS", DateTime.add(now, -1, :second), now)
        |> Map.put(:workspace_path, nil)

      snapshot = %{running: [running_entry], retrying: []}

      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-NOWS", snapshot, %{})

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

  describe "payload/3 — filtered log-tail section" do
    setup do
      tmp_root =
        Path.join(
          System.tmp_dir!(),
          "sr-presenter-log-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_root)
      on_exit(fn -> File.rm_rf!(tmp_root) end)

      {:ok, root: tmp_root}
    end

    test "returns matching lines newest-at-bottom for a populated log", %{root: root} do
      log_path = Path.join(root, "sardine-run.log")

      lines =
        for i <- 1..20 do
          if rem(i, 3) == 0 do
            "ts=#{i} level=info msg=ignore-me other-id=ZZZ-99"
          else
            "ts=#{i} level=info msg=match issue_identifier=UPS-LOG seq=#{i}"
          end
        end

      File.write!(log_path, Enum.join(lines, "\n") <> "\n")

      snapshot = log_running_snapshot("UPS-LOG")

      assert {:ok, payload} =
               SessionDetailPresenter.payload(
                 "UPS-LOG",
                 snapshot,
                 %{log_file: log_path}
               )

      assert payload.log_tail.status == :ok
      assert Enum.all?(payload.log_tail.lines, &String.contains?(&1, "UPS-LOG"))
      refute Enum.any?(payload.log_tail.lines, &String.contains?(&1, "ZZZ-99"))

      [first | _] = payload.log_tail.lines
      last = List.last(payload.log_tail.lines)
      assert String.contains?(first, "seq=1")
      assert String.contains?(last, "seq=20") or String.contains?(last, "seq=19")
    end

    test "caps the result at 200 matching lines", %{root: root} do
      log_path = Path.join(root, "sardine-run.log")

      lines = for i <- 1..500, do: "msg=ping issue_identifier=UPS-LOG seq=#{i}"
      File.write!(log_path, Enum.join(lines, "\n") <> "\n")

      snapshot = log_running_snapshot("UPS-LOG")

      assert {:ok, payload} =
               SessionDetailPresenter.payload(
                 "UPS-LOG",
                 snapshot,
                 %{log_file: log_path}
               )

      assert payload.log_tail.status == :ok
      assert length(payload.log_tail.lines) == 200
      assert List.last(payload.log_tail.lines) =~ "seq=500"
    end

    test "returns :empty for a log file that does not exist", %{root: root} do
      missing = Path.join(root, "no-such-log")

      snapshot = log_running_snapshot("UPS-LOG")

      assert {:ok, payload} =
               SessionDetailPresenter.payload(
                 "UPS-LOG",
                 snapshot,
                 %{log_file: missing}
               )

      assert payload.log_tail.status == :empty
      assert payload.log_tail.lines == []
    end

    test "returns :unconfigured when filesystem has no log_file" do
      snapshot = log_running_snapshot("UPS-LOG")

      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-LOG", snapshot, %{})
      assert payload.log_tail.status == :unconfigured
      assert payload.log_tail.lines == []
    end

    defp log_running_snapshot(identifier) do
      now = DateTime.utc_now()
      started_at = DateTime.add(now, -10, :second)

      %{
        running: [
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
        ],
        retrying: []
      }
    end
  end

  describe "payload/3 — notes.md section" do
    setup do
      tmp_root =
        Path.join(
          System.tmp_dir!(),
          "sr-presenter-notes-#{System.unique_integer([:positive])}"
        )

      state_repo = Path.join(tmp_root, "state")
      session_dir = Path.join([state_repo, "sessions", "UPS-NOTES"])
      File.mkdir_p!(session_dir)
      on_exit(fn -> File.rm_rf!(tmp_root) end)

      {:ok, state_repo: state_repo, session_dir: session_dir}
    end

    test "returns :ok with content when notes.md exists", %{
      state_repo: state_repo,
      session_dir: session_dir
    } do
      File.write!(Path.join(session_dir, "notes.md"), "hello world\n")

      snapshot = notes_running_snapshot("UPS-NOTES")

      assert {:ok, payload} =
               SessionDetailPresenter.payload("UPS-NOTES", snapshot, %{state_repo: state_repo})

      assert payload.notes.status == :ok
      assert payload.notes.content == "hello world\n"
    end

    test "returns :missing when notes.md does not exist", %{state_repo: state_repo} do
      snapshot = notes_running_snapshot("UPS-NOTES")

      assert {:ok, payload} =
               SessionDetailPresenter.payload("UPS-NOTES", snapshot, %{state_repo: state_repo})

      assert payload.notes.status == :missing
      assert payload.notes.content == nil
    end

    test "caps the notes content at 64 KiB", %{
      state_repo: state_repo,
      session_dir: session_dir
    } do
      huge = String.duplicate("x", 200_000)
      File.write!(Path.join(session_dir, "notes.md"), huge)

      snapshot = notes_running_snapshot("UPS-NOTES")

      assert {:ok, payload} =
               SessionDetailPresenter.payload("UPS-NOTES", snapshot, %{state_repo: state_repo})

      assert payload.notes.status == :ok
      assert byte_size(payload.notes.content) == 65_536
    end

    test "returns :memory_tracker when state_repo is not in filesystem" do
      snapshot = notes_running_snapshot("UPS-NOTES")

      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-NOTES", snapshot, %{})

      assert payload.notes.status == :memory_tracker
      assert payload.notes.content == nil
    end

    defp notes_running_snapshot(identifier) do
      now = DateTime.utc_now()

      %{
        running: [
          %{
            issue_id: "id-#{identifier}",
            identifier: identifier,
            state: "In Progress",
            worker_host: nil,
            workspace_path: "/tmp/ws/#{identifier}",
            session_id: "sess-#{identifier}",
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            turn_count: 0,
            started_at: DateTime.add(now, -10, :second),
            last_codex_timestamp: now,
            last_codex_message: nil,
            last_codex_event: nil,
            runtime_seconds: 10
          }
        ],
        retrying: []
      }
    end
  end

  describe "payload/3 — on-disk paths section" do
    test "returns the four paths when state_repo is configured" do
      state_repo = "/fake/state-repo"
      workspace = "/fake/ws/UPS-PATHS"
      snapshot = paths_running_snapshot("UPS-PATHS", workspace)

      assert {:ok, payload} =
               SessionDetailPresenter.payload(
                 "UPS-PATHS",
                 snapshot,
                 %{state_repo: state_repo}
               )

      assert payload.paths != :hidden
      assert payload.paths.session_yaml == "/fake/state-repo/sessions/UPS-PATHS/session.yaml"
      assert payload.paths.notes_md == "/fake/state-repo/sessions/UPS-PATHS/notes.md"
      assert payload.paths.links_yaml == "/fake/state-repo/sessions/UPS-PATHS/links.yaml"
      assert payload.paths.workspace == workspace
    end

    test "returns :hidden when state_repo is not configured" do
      workspace = "/fake/ws/UPS-PATHS"
      snapshot = paths_running_snapshot("UPS-PATHS", workspace)

      assert {:ok, payload} = SessionDetailPresenter.payload("UPS-PATHS", snapshot, %{})

      assert payload.paths == :hidden
    end

    defp paths_running_snapshot(identifier, workspace) do
      now = DateTime.utc_now()

      %{
        running: [
          %{
            issue_id: "id-#{identifier}",
            identifier: identifier,
            state: "In Progress",
            worker_host: nil,
            workspace_path: workspace,
            session_id: "sess-#{identifier}",
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            turn_count: 0,
            started_at: DateTime.add(now, -10, :second),
            last_codex_timestamp: now,
            last_codex_message: nil,
            last_codex_event: nil,
            runtime_seconds: 10
          }
        ],
        retrying: []
      }
    end
  end

  describe "live_payload/2 — cheap snapshot-only projection" do
    test "returns identifier, status, header, live_state but no filesystem keys" do
      now = DateTime.utc_now()
      started_at = DateTime.add(now, -10, :second)

      running_entry = %{
        issue_id: "id-live",
        identifier: "UPS-LIVE",
        state: "In Progress",
        worker_host: "worker-1",
        workspace_path: "/tmp/ws",
        session_id: "sess-live",
        codex_app_server_pid: nil,
        codex_input_tokens: 1,
        codex_output_tokens: 2,
        codex_total_tokens: 3,
        turn_count: 5,
        started_at: started_at,
        last_codex_timestamp: now,
        last_codex_message: nil,
        last_codex_event: nil,
        runtime_seconds: 10
      }

      snapshot = %{running: [running_entry], retrying: []}

      assert {:ok, live} = SessionDetailPresenter.live_payload("UPS-LIVE", snapshot)

      assert Map.keys(live) |> Enum.sort() == [:header, :identifier, :live_state, :status]
      assert live.live_state.session_id == "sess-live"
      assert live.live_state.turn_count == 5
    end

    test "returns :error tuples for unknown / invalid identifiers" do
      assert {:error, :not_found} =
               SessionDetailPresenter.live_payload("UPS-NOPE", %{running: [], retrying: []})

      assert {:error, :invalid_identifier} =
               SessionDetailPresenter.live_payload("../etc", %{running: [], retrying: []})
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
