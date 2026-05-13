defmodule SardineRun.ReviewWatcherTest do
  use SardineRun.TestSupport

  alias SardineRun.ReviewWatcher
  alias SardineRun.Tracker.Issue
  alias SardineRun.TrafficControl.SessionWriter

  setup do
    state_repo = make_state_repo!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "traffic_control",
      tracker_state_repo: state_repo
    )

    {:ok, state_repo: state_repo}
  end

  describe "tick_now/1" do
    test "flips a review session to review_pending when unresolved threads exist", %{state_repo: state_repo} do
      session_path =
        write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review")

      :ok =
        SessionWriter.append_link("abc", %{
          "label" => "PR",
          "kind" => "pr",
          "url" => "https://github.com/o/r/pull/9"
        })

      issue = %Issue{id: "abc", identifier: "abc", state: "review"}

      gh_runner = fn args -> {scripted_gh_response(args), 0} end

      pid = start_watcher!(tracker: fn _ -> {:ok, [issue]} end, gh_runner: gh_runner)

      summary = ReviewWatcher.tick_now(pid)
      assert summary.flipped == ["abc"]
      assert summary.clean == []
      assert summary.skipped_no_pr == []
      assert summary.errored == []

      raw = File.read!(session_path)
      assert raw =~ ~r/^status: review_pending$/m

      {:ok, feedback} = SessionWriter.read_pending_feedback("abc")
      assert [thread] = feedback["threads"]
      assert thread["thread_id"] == "PRRT_X"
      assert thread["comment_id"] == 42
      assert is_binary(feedback["snapshot_at"])
    end

    test "leaves the session alone when there are no threads and no failing checks", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review")

      :ok =
        SessionWriter.append_link("abc", %{
          "label" => "PR",
          "kind" => "pr",
          "url" => "https://github.com/o/r/pull/9"
        })

      issue = %Issue{id: "abc", state: "review"}
      gh_runner = fn _args -> {empty_graphql_response(), 0} end

      pid = start_watcher!(tracker: fn _ -> {:ok, [issue]} end, gh_runner: gh_runner)

      summary = ReviewWatcher.tick_now(pid)
      assert summary.clean == ["abc"]
      assert summary.flipped == []

      assert {:ok, %{}} = SessionWriter.read_pending_feedback("abc")
    end

    test "skips sessions missing a kind=pr link", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review")

      issue = %Issue{id: "abc", state: "review"}
      gh_runner = fn _args -> flunk("gh should not be called when no PR link is recorded") end

      pid = start_watcher!(tracker: fn _ -> {:ok, [issue]} end, gh_runner: gh_runner)

      summary = ReviewWatcher.tick_now(pid)
      assert summary.skipped_no_pr == ["abc"]
      assert summary.flipped == []
      assert summary.clean == []
    end

    test "returns empty summary when the tracker yields no review-status issues" do
      pid = start_watcher!(tracker: fn _ -> {:ok, []} end, gh_runner: fn _ -> flunk("unreachable") end)

      summary = ReviewWatcher.tick_now(pid)
      assert summary == %{flipped: [], clean: [], skipped_no_pr: [], errored: []}
    end

    test "buckets a session with an unparseable PR link as :errored", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review")

      :ok =
        SessionWriter.append_link("abc", %{
          "label" => "PR",
          "kind" => "pr",
          "url" => "not-a-github-url"
        })

      issue = %Issue{id: "abc", state: "review"}

      pid =
        start_watcher!(
          tracker: fn _ -> {:ok, [issue]} end,
          gh_runner: fn _ -> flunk("gh should not be called when PR URL is unparseable") end
        )

      summary = ReviewWatcher.tick_now(pid)
      assert summary.errored == ["abc"]
      assert summary.flipped == []
      assert summary.skipped_no_pr == []
    end

    test "absorbs gh failures and leaves the session as-is", %{state_repo: state_repo} do
      session_path =
        write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review")

      :ok =
        SessionWriter.append_link("abc", %{
          "label" => "PR",
          "kind" => "pr",
          "url" => "https://github.com/o/r/pull/9"
        })

      issue = %Issue{id: "abc", state: "review"}
      gh_runner = fn _args -> {"boom", 1} end

      pid = start_watcher!(tracker: fn _ -> {:ok, [issue]} end, gh_runner: gh_runner)

      summary = ReviewWatcher.tick_now(pid)
      assert summary == %{flipped: [], clean: ["abc"], skipped_no_pr: [], errored: []}

      raw = File.read!(session_path)
      assert raw =~ ~r/^status: "?review"?$/m
    end
  end

  defp start_watcher!(opts) do
    pid =
      start_supervised!(
        {ReviewWatcher,
         opts
         |> Keyword.put(:name, watcher_name())}
      )

    pid
  end

  defp watcher_name, do: :"review_watcher_#{System.unique_integer([:positive])}"

  defp scripted_gh_response(args) do
    cond do
      "graphql" in args ->
        Jason.encode!(%{
          "data" => %{
            "repository" => %{
              "pullRequest" => %{
                "reviewThreads" => %{
                  "nodes" => [
                    %{
                      "id" => "PRRT_X",
                      "isResolved" => false,
                      "isCollapsed" => false,
                      "comments" => %{
                        "nodes" => [
                          %{
                            "databaseId" => 42,
                            "body" => "please reconsider",
                            "path" => "lib/foo.ex",
                            "line" => 12,
                            "author" => %{"login" => "alice"}
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        })

      Enum.member?(args, "checks") ->
        Jason.encode!([])

      true ->
        Jason.encode!(%{})
    end
  end

  defp empty_graphql_response do
    Jason.encode!(%{
      "data" => %{
        "repository" => %{
          "pullRequest" => %{
            "reviewThreads" => %{"nodes" => []}
          }
        }
      }
    })
  end
end
