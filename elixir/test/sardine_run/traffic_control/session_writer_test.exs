defmodule SardineRun.TrafficControl.SessionWriterTest do
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

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "traffic_control",
      tracker_state_repo: state_repo
    )

    {:ok, state_repo: state_repo}
  end

  defp session_path(repo, id), do: Path.join([repo, "sessions", id, "session.yaml"])

  defp read_yaml!(path) do
    {:ok, parsed} = path |> File.read!() |> YamlElixir.read_from_string()
    parsed
  end

  describe "validate_session_id" do
    test "rejects session_id containing path separators", %{state_repo: _repo} do
      assert {:error, :invalid_session_id} =
               SessionWriter.update_status("../etc", "active", nil)

      assert {:error, :invalid_session_id} =
               SessionWriter.update_status("ok/sub", "active", nil)
    end

    test "rejects empty session_id", %{state_repo: _repo} do
      assert {:error, :invalid_session_id} =
               SessionWriter.update_status("", "active", nil)
    end

    test "rejects null bytes and spaces", %{state_repo: _repo} do
      assert {:error, :invalid_session_id} =
               SessionWriter.update_status("a b", "active", nil)

      assert {:error, :invalid_session_id} =
               SessionWriter.update_field("..%2Fboom", "focus", "x")
    end

    test "accepts hex-style ids", %{state_repo: repo} do
      write_session_yaml!(repo, "abc123def", id: "abc123def", status: "active")
      assert :ok = SessionWriter.update_status("abc123def", "review", nil)
      assert read_yaml!(session_path(repo, "abc123def"))["status"] == "review"
    end
  end

  describe "update_status/3" do
    test "rewrites top-level status without affecting comment lines", %{state_repo: repo} do
      content = """
      id: s1
      # status: stale-comment
      title: foo
      status: active
      """

      File.mkdir_p!(Path.dirname(session_path(repo, "s1")))
      File.write!(session_path(repo, "s1"), content)

      assert :ok = SessionWriter.update_status("s1", "review", nil)
      raw = File.read!(session_path(repo, "s1"))

      assert raw =~ "status: review"
      assert raw =~ "# status: stale-comment"
      assert read_yaml!(session_path(repo, "s1"))["status"] == "review"
    end

    test "writes a waiting block when status is waiting", %{state_repo: repo} do
      write_session_yaml!(repo, "s2", id: "s2", status: "active")

      assert :ok =
               SessionWriter.update_status("s2", "waiting", %{
                 "kind" => "review",
                 "note" => "Need approval"
               })

      parsed = read_yaml!(session_path(repo, "s2"))
      assert parsed["status"] == "waiting"
      assert parsed["waiting"]["kind"] == "review"
      assert parsed["waiting"]["note"] == "Need approval"
    end

    test "clears waiting block when status leaves waiting", %{state_repo: repo} do
      content = """
      id: s3
      status: waiting
      waiting:
        kind: review
        note: Old
      """

      File.mkdir_p!(Path.dirname(session_path(repo, "s3")))
      File.write!(session_path(repo, "s3"), content)

      assert :ok = SessionWriter.update_status("s3", "active", nil)
      parsed = read_yaml!(session_path(repo, "s3"))
      assert parsed["status"] == "active"
      assert parsed["waiting"] == nil
    end

    test "errors when session file is missing", %{state_repo: _repo} do
      assert {:error, :enoent} = SessionWriter.update_status("ghost", "active", nil)
    end
  end

  describe "update_field/3" do
    test "quotes values containing colons", %{state_repo: repo} do
      write_session_yaml!(repo, "s4", id: "s4", status: "active", focus: "old")
      assert :ok = SessionWriter.update_field("s4", "focus", "lib/foo: extract module")

      parsed = read_yaml!(session_path(repo, "s4"))
      assert parsed["focus"] == "lib/foo: extract module"
    end

    test "appends field if missing and file lacks trailing newline", %{state_repo: repo} do
      File.mkdir_p!(Path.dirname(session_path(repo, "s5")))
      File.write!(session_path(repo, "s5"), "id: s5\nstatus: active")

      assert :ok = SessionWriter.update_field("s5", "next_step", "Run tests")
      parsed = read_yaml!(session_path(repo, "s5"))
      assert parsed["next_step"] == "Run tests"
      assert parsed["status"] == "active"
    end
  end

  describe "update_heartbeat/2" do
    test "merges runtime fields and stamps heartbeat_at", %{state_repo: repo} do
      write_session_yaml!(repo, "s6", id: "s6", status: "active")

      assert :ok =
               SessionWriter.update_heartbeat("s6", %{
                 "agent_id" => "worker-1",
                 "run_id" => "run-1",
                 "last_event" => "turn"
               })

      parsed = read_yaml!(session_path(repo, "s6"))
      assert parsed["sardine_run"]["agent_id"] == "worker-1"
      assert parsed["sardine_run"]["run_id"] == "run-1"
      assert parsed["sardine_run"]["last_event"] == "turn"
      assert is_binary(parsed["sardine_run"]["heartbeat_at"])
      assert is_binary(parsed["sardine_run"]["last_event_at"])
    end

    test "drops unknown sardine_run keys when merging", %{state_repo: repo} do
      content = """
      id: s7
      status: active
      sardine_run:
        agent_id: old-worker
        rogue_key: should-be-dropped
      """

      File.mkdir_p!(Path.dirname(session_path(repo, "s7")))
      File.write!(session_path(repo, "s7"), content)

      assert :ok = SessionWriter.update_heartbeat("s7", %{"agent_id" => "new-worker"})

      parsed = read_yaml!(session_path(repo, "s7"))
      assert parsed["sardine_run"]["agent_id"] == "new-worker"
      refute Map.has_key?(parsed["sardine_run"], "rogue_key")
    end
  end

  describe "append_note/2" do
    test "creates notes.md and appends timestamped entries", %{state_repo: repo} do
      assert :ok = SessionWriter.append_note("s8", "first note")
      assert :ok = SessionWriter.append_note("s8", "second note")

      notes = File.read!(Path.join([repo, "sessions", "s8", "notes.md"]))
      assert notes =~ "first note"
      assert notes =~ "second note"
      assert notes =~ "## Sardine Run @"
    end

    test "rejects malicious session_id", %{state_repo: repo} do
      assert {:error, :invalid_session_id} =
               SessionWriter.append_note("../escape", "boom")

      refute File.exists?(Path.join([Path.dirname(repo), "escape"]))
    end
  end

  describe "append_link/2" do
    test "creates links.yaml on first call and appends on subsequent calls", %{state_repo: repo} do
      assert :ok =
               SessionWriter.append_link("s9", %{
                 "label" => "PR",
                 "kind" => "pr",
                 "url" => "https://example.com/1"
               })

      assert :ok =
               SessionWriter.append_link("s9", %{
                 "label" => "Doc",
                 "kind" => "doc",
                 "url" => "https://example.com/2"
               })

      links_path = Path.join([repo, "sessions", "s9", "links.yaml"])
      {:ok, parsed} = links_path |> File.read!() |> YamlElixir.read_from_string()

      assert length(parsed) == 2
      assert Enum.at(parsed, 0)["url"] == "https://example.com/1"
      assert Enum.at(parsed, 1)["url"] == "https://example.com/2"
    end
  end
end
