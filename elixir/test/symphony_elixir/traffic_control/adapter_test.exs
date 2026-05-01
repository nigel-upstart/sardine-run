defmodule SymphonyElixir.TrafficControl.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TrafficControl.Adapter

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

  describe "resolve_state_repo/0" do
    test "returns expanded state repo path", %{state_repo: state_repo} do
      assert {:ok, ^state_repo} = Adapter.resolve_state_repo()
    end

    test "errors when state_repo is missing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "traffic_control",
        tracker_state_repo: nil
      )

      assert {:error, :state_repo_not_configured} = Adapter.resolve_state_repo()
    end
  end

  describe "fetch_candidate_issues/0" do
    test "returns an empty list when sessions/ is empty", %{state_repo: _state_repo} do
      assert {:ok, []} = Adapter.fetch_candidate_issues()
    end

    test "loads sessions and maps fields onto Issue structs", %{state_repo: state_repo} do
      write_session_yaml!(state_repo, "abc123",
        id: "abc123",
        title: "Implement traffic_control adapter",
        objective: "Add an Elixir tracker adapter",
        focus: "lib/symphony_elixir/traffic_control/adapter.ex",
        next_step: "Write more tests",
        status: "active",
        branch: "feat/tc-adapter",
        tags: ["tracker", "elixir"]
      )

      assert {:ok, [issue]} = Adapter.fetch_candidate_issues()
      assert issue.id == "abc123"
      assert issue.identifier == "abc123"
      assert issue.title == "Implement traffic_control adapter"
      assert issue.state == "active"
      assert issue.branch_name == "feat/tc-adapter"
      assert issue.labels == ["tracker", "elixir"]
      assert issue.assigned_to_worker == true

      assert issue.description ==
               """
               ## Objective

               Add an Elixir tracker adapter

               ## Focus

               lib/symphony_elixir/traffic_control/adapter.ex

               ## Next step

               Write more tests\
               """
    end

    test "skips sessions with missing/unreadable session.yaml", %{state_repo: state_repo} do
      write_session_yaml!(state_repo, "good", id: "good", title: "Good", status: "active")

      empty_session_dir = Path.join([state_repo, "sessions", "broken"])
      File.mkdir_p!(empty_session_dir)
      File.write!(Path.join(empty_session_dir, "session.yaml"), "::: not yaml :::")

      assert {:ok, [issue]} = Adapter.fetch_candidate_issues()
      assert issue.id == "good"
    end

    test "errors when state_repo is missing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "traffic_control",
        tracker_state_repo: nil
      )

      assert {:error, :state_repo_not_configured} = Adapter.fetch_candidate_issues()
    end
  end

  describe "fetch_issues_by_states/1" do
    test "filters sessions case-insensitively by status", %{state_repo: state_repo} do
      write_session_yaml!(state_repo, "a", id: "a", title: "A", status: "active")
      write_session_yaml!(state_repo, "b", id: "b", title: "B", status: "Waiting")
      write_session_yaml!(state_repo, "c", id: "c", title: "C", status: "done")

      assert {:ok, results} = Adapter.fetch_issues_by_states(["ACTIVE", " waiting "])
      ids = results |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["a", "b"]
    end
  end

  describe "fetch_issue_states_by_ids/1" do
    test "loads only the requested sessions", %{state_repo: state_repo} do
      write_session_yaml!(state_repo, "a", id: "a", title: "A", status: "active")
      write_session_yaml!(state_repo, "b", id: "b", title: "B", status: "active")
      write_session_yaml!(state_repo, "c", id: "c", title: "C", status: "active")

      assert {:ok, results} = Adapter.fetch_issue_states_by_ids(["a", "c", "missing"])
      ids = results |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["a", "c"]
    end

    test "returns an empty list when no ids match", %{state_repo: _state_repo} do
      assert {:ok, []} = Adapter.fetch_issue_states_by_ids(["nope", "nada"])
    end
  end

  describe "create_comment/2" do
    test "appends a timestamped section to notes.md", %{state_repo: state_repo} do
      assert :ok = Adapter.create_comment("session-1", "Kicked off run.")
      assert :ok = Adapter.create_comment("session-1", "Second update.")

      notes = File.read!(Path.join([state_repo, "sessions", "session-1", "notes.md"]))
      assert notes =~ "## Sardine Run @"
      assert notes =~ "Kicked off run."
      assert notes =~ "Second update."
    end
  end

  describe "update_issue_state/2" do
    test "rewrites the existing status line in session.yaml", %{state_repo: state_repo} do
      path =
        write_session_yaml!(state_repo, "session-1",
          id: "session-1",
          title: "Title",
          status: "active"
        )

      assert :ok = Adapter.update_issue_state("session-1", "Done")
      raw = File.read!(path)
      assert raw =~ "status: done"
      refute raw =~ "status: active"
    end

    test "appends a status line if none exists", %{state_repo: state_repo} do
      dir = Path.join([state_repo, "sessions", "session-no-status"])
      File.mkdir_p!(dir)
      path = Path.join(dir, "session.yaml")
      File.write!(path, "id: session-no-status\ntitle: needs status\n")

      assert :ok = Adapter.update_issue_state("session-no-status", "active")
      assert File.read!(path) =~ "status: active"
    end

    test "returns an error when session.yaml is missing", %{state_repo: _state_repo} do
      assert {:error, :enoent} = Adapter.update_issue_state("ghost", "done")
    end
  end
end
