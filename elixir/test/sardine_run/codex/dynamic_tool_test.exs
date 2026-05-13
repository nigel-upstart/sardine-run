defmodule SardineRun.Codex.DynamicToolTest do
  use SardineRun.TestSupport

  alias SardineRun.Codex.DynamicTool
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

  describe "tool_specs/0" do
    test "advertises one sardine_run_session tool with the expected schema" do
      assert [tool] = DynamicTool.tool_specs()
      assert tool["name"] == "sardine_run_session"
      assert is_binary(tool["description"])
      assert String.length(tool["description"]) > 0

      params = tool["inputSchema"]
      assert params["type"] == "object"
      props = params["properties"]

      assert props["operation"]["enum"] == [
               "status",
               "heartbeat",
               "note",
               "link",
               "focus",
               "next_step",
               "git_push",
               "list_review_comments",
               "reply_to_comment",
               "resolve_thread",
               "request_human_help"
             ]

      assert props["session_id"]["type"] == "string"

      assert props["status"]["enum"] == [
               "active",
               "blocked",
               "waiting",
               "review",
               "done",
               "archived"
             ]

      assert props["waiting_kind"]["enum"] == [
               "human",
               "ci",
               "review",
               "external",
               "other"
             ]

      assert "operation" in params["required"]
      assert "session_id" in params["required"]

      for key <-
            ~w(waiting_note body label link_kind url last_event last_message last_error value thread_id reason) do
        assert props[key]["type"] == "string", "expected #{key} to be string typed"
      end

      for key <- ~w(input_tokens output_tokens total_tokens comment_id) do
        assert props[key]["type"] == "integer", "expected #{key} to be integer typed"
      end
    end
  end

  describe "execute/3 status operation" do
    test "rewrites top-level status field", %{state_repo: state_repo} do
      path =
        write_session_yaml!(state_repo, "abc",
          id: "abc",
          title: "T",
          status: "active"
        )

      assert %{"success" => true} =
               DynamicTool.execute("sardine_run_session", %{
                 "operation" => "status",
                 "session_id" => "abc",
                 "status" => "done"
               })

      raw = File.read!(path)
      assert raw =~ ~r/^status: done$/m
      refute raw =~ "status: active"
    end

    test "writes a waiting block when status=waiting and waiting_kind given", %{
      state_repo: state_repo
    } do
      path =
        write_session_yaml!(state_repo, "abc",
          id: "abc",
          title: "T",
          status: "active"
        )

      assert %{"success" => true} =
               DynamicTool.execute("sardine_run_session", %{
                 "operation" => "status",
                 "session_id" => "abc",
                 "status" => "waiting",
                 "waiting_kind" => "human",
                 "waiting_note" => "blocked on review"
               })

      raw = File.read!(path)
      assert {:ok, parsed} = YamlElixir.read_from_string(raw)
      assert parsed["status"] == "waiting"
      assert parsed["waiting"]["kind"] == "human"
      assert parsed["waiting"]["note"] == "blocked on review"
    end

    test "clears waiting block when status != waiting", %{state_repo: state_repo} do
      dir = Path.join([state_repo, "sessions", "abc"])
      File.mkdir_p!(dir)
      path = Path.join(dir, "session.yaml")

      File.write!(path, """
      id: abc
      title: T
      status: waiting
      waiting:
        kind: human
        note: 'old note'
        requested_at: '2026-04-01T00:00:00Z'
      """)

      assert %{"success" => true} =
               DynamicTool.execute("sardine_run_session", %{
                 "operation" => "status",
                 "session_id" => "abc",
                 "status" => "active"
               })

      raw = File.read!(path)
      {:ok, parsed} = YamlElixir.read_from_string(raw)
      assert parsed["status"] == "active"
      assert parsed["waiting"] in [nil, %{}]
    end

    test "returns failure when session.yaml is missing" do
      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "status",
          "session_id" => "ghost",
          "status" => "done"
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "ghost" or output =~ "not found" or output =~ "enoent"
    end
  end

  describe "execute/3 heartbeat operation" do
    test "patches sardine_run runtime fields and timestamps", %{state_repo: state_repo} do
      path =
        write_session_yaml!(state_repo, "abc",
          id: "abc",
          title: "T",
          status: "active"
        )

      assert %{"success" => true} =
               DynamicTool.execute("sardine_run_session", %{
                 "operation" => "heartbeat",
                 "session_id" => "abc",
                 "last_event" => "turn-completed",
                 "last_message" => "wrote tests",
                 "input_tokens" => 1234,
                 "output_tokens" => 567,
                 "total_tokens" => 1801
               })

      raw = File.read!(path)
      {:ok, parsed} = YamlElixir.read_from_string(raw)
      sr = parsed["sardine_run"]
      assert is_map(sr)
      assert sr["last_event"] == "turn-completed"
      assert sr["last_message"] == "wrote tests"
      assert sr["input_tokens"] == 1234
      assert sr["output_tokens"] == 567
      assert sr["total_tokens"] == 1801
      assert is_binary(sr["last_heartbeat"])
      assert sr["last_heartbeat"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end
  end

  describe "execute/3 note operation" do
    test "appends a note to notes.md", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "active")

      assert %{"success" => true} =
               DynamicTool.execute("sardine_run_session", %{
                 "operation" => "note",
                 "session_id" => "abc",
                 "body" => "Investigated the failing test."
               })

      notes = File.read!(Path.join([state_repo, "sessions", "abc", "notes.md"]))
      assert notes =~ "Investigated the failing test."
      assert notes =~ "## Sardine Run @"
    end

    test "missing body returns a structured failure", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "active")

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "note",
          "session_id" => "abc"
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "body"
    end
  end

  describe "execute/3 link operation" do
    test "appends an entry to links.yaml", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "active")

      assert %{"success" => true} =
               DynamicTool.execute("sardine_run_session", %{
                 "operation" => "link",
                 "session_id" => "abc",
                 "label" => "PR #42",
                 "link_kind" => "pr",
                 "url" => "https://github.com/example/repo/pull/42"
               })

      links_path = Path.join([state_repo, "sessions", "abc", "links.yaml"])
      assert File.exists?(links_path)
      raw = File.read!(links_path)
      {:ok, parsed} = YamlElixir.read_from_string(raw)

      assert parsed == [
               %{
                 "label" => "PR #42",
                 "kind" => "pr",
                 "url" => "https://github.com/example/repo/pull/42"
               }
             ]

      assert %{"success" => true} =
               DynamicTool.execute("sardine_run_session", %{
                 "operation" => "link",
                 "session_id" => "abc",
                 "label" => "Slack",
                 "link_kind" => "slack",
                 "url" => "https://slack.example/abc"
               })

      raw2 = File.read!(links_path)
      {:ok, parsed2} = YamlElixir.read_from_string(raw2)
      assert length(parsed2) == 2
      labels = parsed2 |> Enum.map(& &1["label"])
      assert "PR #42" in labels
      assert "Slack" in labels
    end
  end

  describe "execute/3 focus operation" do
    test "rewrites focus field", %{state_repo: state_repo} do
      path =
        write_session_yaml!(state_repo, "abc",
          id: "abc",
          title: "T",
          status: "active",
          focus: "old focus"
        )

      assert %{"success" => true} =
               DynamicTool.execute("sardine_run_session", %{
                 "operation" => "focus",
                 "session_id" => "abc",
                 "value" => "implement dynamic tool"
               })

      raw = File.read!(path)
      {:ok, parsed} = YamlElixir.read_from_string(raw)
      assert parsed["focus"] == "implement dynamic tool"
    end

    test "clears focus when value is empty", %{state_repo: state_repo} do
      path =
        write_session_yaml!(state_repo, "abc",
          id: "abc",
          title: "T",
          status: "active",
          focus: "old focus"
        )

      assert %{"success" => true} =
               DynamicTool.execute("sardine_run_session", %{
                 "operation" => "focus",
                 "session_id" => "abc",
                 "value" => ""
               })

      raw = File.read!(path)
      {:ok, parsed} = YamlElixir.read_from_string(raw)
      assert parsed["focus"] in [nil, ""]
    end
  end

  describe "execute/3 next_step operation" do
    test "rewrites next_step field", %{state_repo: state_repo} do
      path =
        write_session_yaml!(state_repo, "abc",
          id: "abc",
          title: "T",
          status: "active",
          next_step: "do A"
        )

      assert %{"success" => true} =
               DynamicTool.execute("sardine_run_session", %{
                 "operation" => "next_step",
                 "session_id" => "abc",
                 "value" => "ship the PR"
               })

      raw = File.read!(path)
      {:ok, parsed} = YamlElixir.read_from_string(raw)
      assert parsed["next_step"] == "ship the PR"
    end
  end

  describe "execute/3 git_push operation" do
    defp make_git_workspace! do
      dir = make_unique_tmp_dir!("git-ws")
      {_, 0} = System.cmd("git", ["-C", dir, "init", "--initial-branch=main"], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "Test"])
      {_, 0} = System.cmd("git", ["-C", dir, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(dir, "README.md"), "hello")
      {_, 0} = System.cmd("git", ["-C", dir, "add", "README.md"], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", dir, "commit", "-m", "init"], stderr_to_stdout: true)
      dir
    end

    defp make_bare_remote! do
      dir = make_unique_tmp_dir!("git-remote")
      {_, 0} = System.cmd("git", ["-C", dir, "init", "--bare"], stderr_to_stdout: true)
      dir
    end

    test "pushes branch to configured remote", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "active")
      workspace = make_git_workspace!()
      remote_path = make_bare_remote!()
      {_, 0} = System.cmd("git", ["remote", "add", "origin", remote_path], cd: workspace)

      assert %{"success" => true, "output" => output} =
               DynamicTool.execute(
                 "sardine_run_session",
                 %{"operation" => "git_push", "session_id" => "abc", "branch" => "main"},
                 workspace: workspace
               )

      assert is_binary(output)
    after
      :ok
    end

    test "defaults remote to origin when not specified", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "active")
      workspace = make_git_workspace!()
      remote_path = make_bare_remote!()
      {_, 0} = System.cmd("git", ["remote", "add", "origin", remote_path], cd: workspace)

      assert %{"success" => true} =
               DynamicTool.execute(
                 "sardine_run_session",
                 %{"operation" => "git_push", "session_id" => "abc", "branch" => "main"},
                 workspace: workspace
               )
    end

    test "returns failure when workspace opt is not supplied" do
      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "git_push",
          "session_id" => "abc",
          "branch" => "main"
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "workspace"
    end

    test "returns failure when branch is missing" do
      response =
        DynamicTool.execute(
          "sardine_run_session",
          %{"operation" => "git_push", "session_id" => "abc"},
          workspace: "/tmp/fake"
        )

      assert %{"success" => false, "output" => output} = response
      assert output =~ "branch"
    end

    test "rejects branch starting with -" do
      response =
        DynamicTool.execute(
          "sardine_run_session",
          %{
            "operation" => "git_push",
            "session_id" => "abc",
            "branch" => "--upload-pack=evil"
          },
          workspace: "/tmp/fake"
        )

      assert %{"success" => false, "output" => output} = response
      assert output =~ "'-'"
    end

    test "rejects branch containing .." do
      response =
        DynamicTool.execute(
          "sardine_run_session",
          %{"operation" => "git_push", "session_id" => "abc", "branch" => "main..evil"},
          workspace: "/tmp/fake"
        )

      assert %{"success" => false, "output" => output} = response
      assert output =~ "'..':"
    end

    test "returns git_push_failed when git exits non-zero", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "active")
      workspace = make_git_workspace!()

      response =
        DynamicTool.execute(
          "sardine_run_session",
          %{"operation" => "git_push", "session_id" => "abc", "branch" => "main"},
          workspace: workspace
        )

      assert %{"success" => false, "output" => output} = response
      assert output =~ "git_push_failed"
    end
  end

  describe "execute/3 list_review_comments" do
    test "returns the pending_feedback snapshot from disk", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review_pending")

      :ok =
        SessionWriter.write_pending_feedback("abc", %{
          "threads" => [%{"id" => "PRRT_1", "body" => "consider X"}],
          "failing_checks" => [%{"name" => "ci/test", "url" => "https://example.invalid"}]
        })

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "list_review_comments",
          "session_id" => "abc"
        })

      assert %{"success" => true, "output" => output} = response
      {:ok, decoded} = Jason.decode(output)
      assert decoded["feedback"]["threads"] |> List.first() |> Map.get("id") == "PRRT_1"
      assert decoded["feedback"]["failing_checks"] |> List.first() |> Map.get("name") == "ci/test"
    end

    test "returns empty feedback when no snapshot exists yet", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review")

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "list_review_comments",
          "session_id" => "abc"
        })

      assert %{"success" => true, "output" => output} = response
      {:ok, decoded} = Jason.decode(output)
      assert decoded["feedback"] == %{}
    end
  end

  describe "execute/3 reply_to_comment" do
    test "shells out to gh with the resolved PR ref and threads the reply", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review_pending")

      :ok =
        SessionWriter.append_link("abc", %{
          "label" => "PR",
          "kind" => "pr",
          "url" => "https://github.com/teamupstart/sardine-run/pull/42"
        })

      trace_file = with_fake_gh!(~s|{"id": 99}|)

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "reply_to_comment",
          "session_id" => "abc",
          "comment_id" => 12_345,
          "body" => "addressed in commit a1b2c3"
        })

      assert %{"success" => true, "output" => output} = response
      assert output =~ "reply_to_comment"
      trace = File.read!(trace_file)
      assert trace =~ "repos/teamupstart/sardine-run/pulls/42/comments"
      assert trace =~ "body=addressed in commit a1b2c3"
      assert trace =~ "in_reply_to=12345"
    end

    test "fails with validation error when session has no kind=pr link", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review_pending")

      _trace = with_fake_gh!("{}")

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "reply_to_comment",
          "session_id" => "abc",
          "comment_id" => 1,
          "body" => "..."
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "No link of kind=pr"
    end

    test "requires comment_id to be an integer", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review_pending")

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "reply_to_comment",
          "session_id" => "abc",
          "comment_id" => "not-a-number",
          "body" => "..."
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "comment_id"
    end
  end

  describe "execute/3 resolve_thread" do
    test "issues the resolveReviewThread mutation via gh api graphql", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review_pending")

      trace_file = with_fake_gh!(~s|{"data": {"resolveReviewThread": {"thread": {"isResolved": true}}}}|)

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "resolve_thread",
          "session_id" => "abc",
          "thread_id" => "PRRT_kwDOK0",
          "reason" => "we disagree because the existing pattern is intentional and consistent across modules"
        })

      assert %{"success" => true, "output" => output} = response
      assert output =~ "PRRT_kwDOK0"
      trace = File.read!(trace_file)
      assert trace =~ "api"
      assert trace =~ "graphql"
      assert trace =~ "resolveReviewThread"
      assert trace =~ ~s|threadId: "PRRT_kwDOK0"|
    end

    test "rejects thread_id containing disallowed characters", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review_pending")

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "resolve_thread",
          "session_id" => "abc",
          "thread_id" => ~s|" } } }|,
          "reason" => "..."
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "thread_id"
    end

    test "reason is required", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review_pending")

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "resolve_thread",
          "session_id" => "abc",
          "thread_id" => "PRRT_X"
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "reason"
    end
  end

  describe "execute/3 request_human_help" do
    test "flips status to waiting with waiting_kind=human and supplied note", %{state_repo: state_repo} do
      path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review_pending")

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "request_human_help",
          "session_id" => "abc",
          "body" => "Conflicting reviewer guidance on caching strategy."
        })

      assert %{"success" => true, "output" => output} = response
      assert output =~ "request_human_help"

      raw = File.read!(path)
      assert raw =~ ~r/^status: waiting$/m
      assert {:ok, parsed} = YamlElixir.read_from_string(raw)
      assert parsed["waiting"]["kind"] == "human"
      assert parsed["waiting"]["note"] =~ "Conflicting reviewer guidance"
    end

    test "missing body returns validation failure" do
      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "request_human_help",
          "session_id" => "abc"
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "body"
    end
  end

  describe "execute/3 validation" do
    test "unknown tool returns structured failure" do
      response = DynamicTool.execute("not_a_tool", %{})
      assert %{"success" => false, "output" => output} = response
      assert output =~ "not_a_tool" or output =~ "unknown"
    end

    test "unknown operation returns structured failure" do
      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "frobnicate",
          "session_id" => "abc"
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "frobnicate" or output =~ "operation"
    end

    test "missing session_id returns structured failure" do
      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "status",
          "status" => "done"
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "session_id"
    end

    test "missing required arg for status returns structured failure", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "active")

      response =
        DynamicTool.execute("sardine_run_session", %{
          "operation" => "status",
          "session_id" => "abc"
        })

      assert %{"success" => false, "output" => output} = response
      assert output =~ "status"
    end

    test "all responses include matched contentItems" do
      response = DynamicTool.execute(nil, :unexpected)
      assert %{"success" => false, "output" => output, "contentItems" => items} = response
      assert is_list(items)
      assert Enum.any?(items, &(&1["text"] == output))
    end
  end

  # Installs a fake `gh` binary on PATH that captures its argv to a trace file
  # and prints `stdout_body` on stdout. Returns the absolute path to the trace
  # file so tests can assert against what gh was called with.
  defp with_fake_gh!(stdout_body) do
    bin_dir = make_unique_tmp_dir!("sardine-run-fake-gh")
    trace_file = Path.join(bin_dir, "gh.trace")
    fake_gh = Path.join(bin_dir, "gh")

    File.write!(fake_gh, """
    #!/bin/sh
    printf '%s\\n' "$*" > #{trace_file}
    cat <<'PAYLOAD'
    #{stdout_body}
    PAYLOAD
    exit 0
    """)

    File.chmod!(fake_gh, 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
    on_exit(fn -> restore_env("PATH", previous_path) end)

    trace_file
  end
end
