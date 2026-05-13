defmodule SardineRun.ReviewerLoopTest do
  @moduledoc """
  End-to-end test for the reviewer loop: a session sitting in `review` with a
  recorded PR link is detected by the watcher, flipped to `review_pending`
  with a `pending_feedback.yaml` snapshot, picked up by the orchestrator's
  dispatch selector as the `:reviewer` species, and rendered through the
  reviewer prompt with the snapshot the watcher just wrote.

  Each stage is also unit-tested in isolation; this fixture exercises the
  contract between them so a future regression (e.g. a misnamed snapshot
  field, a status string drift between writer and watcher) shows up here.
  """
  use SardineRun.TestSupport

  alias SardineRun.Orchestrator
  alias SardineRun.Reviewer
  alias SardineRun.ReviewWatcher
  alias SardineRun.Tracker.Issue
  alias SardineRun.TrafficControl.SessionWriter

  setup do
    state_repo = make_state_repo!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "traffic_control",
      tracker_state_repo: state_repo
    )

    # The reviewer renders REVIEW_FEEDBACK.md relative to WORKFLOW.md's dir.
    workflow_dir = Path.dirname(Workflow.workflow_file_path())

    File.write!(Path.join(workflow_dir, "REVIEW_FEEDBACK.md"), """
    session={{ issue.identifier }}
    snapshot_at={{ snapshot_at }}
    {% for t in pending_feedback.threads %}thread={{ t.thread_id }} comment={{ t.comment_id }} body={{ t.body }}
    {% endfor %}{% for c in pending_feedback.failing_checks %}check={{ c.name }} state={{ c.state }} link={{ c.link }}
    {% endfor %}
    """)

    {:ok, state_repo: state_repo}
  end

  test "watcher → flip → dispatch → reviewer prompt round-trips the snapshot", %{
    state_repo: state_repo
  } do
    session_path =
      write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review")

    :ok =
      SessionWriter.append_link("abc", %{
        "label" => "PR",
        "kind" => "pr",
        "url" => "https://github.com/teamupstart/sardine-run/pull/91"
      })

    review_issue = %Issue{id: "abc", identifier: "ABC-91", state: "review"}

    # Inject a tracker stub that simulates how `Tracker.fetch_issues_by_states`
    # would behave at each stage: first the watcher sees the `review` session;
    # later, the orchestrator's pick_worker sees the post-flip `review_pending`.
    gh_runner = fn _args ->
      {Jason.encode!(%{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "reviewThreads" => %{
                 "nodes" => [
                   %{
                     "id" => "PRRT_loop_a",
                     "isResolved" => false,
                     "isCollapsed" => false,
                     "comments" => %{
                       "nodes" => [
                         %{
                           "databaseId" => 7,
                           "body" => "please justify this approach",
                           "path" => "lib/foo.ex",
                           "line" => 4,
                           "author" => %{"login" => "reviewer-bot"}
                         }
                       ]
                     }
                   }
                 ]
               }
             }
           }
         }
       }), 0}
    end

    watcher = start_watcher!(tracker: fn _ -> {:ok, [review_issue]} end, gh_runner: gh_runner)

    # === Stage 1: watcher polls and flips ===
    summary = ReviewWatcher.tick_now(watcher)
    assert summary.flipped == ["abc"]

    raw = File.read!(session_path)
    assert raw =~ ~r/^status: review_pending$/m

    {:ok, snapshot} = SessionWriter.read_pending_feedback("abc")
    assert is_binary(snapshot["snapshot_at"])
    assert [persisted_thread] = snapshot["threads"]
    assert persisted_thread["thread_id"] == "PRRT_loop_a"

    # === Stage 2: orchestrator's dispatch sees review_pending and picks :reviewer ===
    flipped_issue = %Issue{review_issue | state: "review_pending"}

    assert {SardineRun.Codex.AppServer, :reviewer} =
             Orchestrator.pick_worker(%SardineRun.Orchestrator.State{}, flipped_issue)

    # === Stage 3: reviewer prompt renders with the just-written snapshot ===
    rendered = Reviewer.prompt(flipped_issue, [])
    assert rendered =~ "session=ABC-91"
    assert rendered =~ "thread=PRRT_loop_a comment=7 body=please justify this approach"
    assert rendered =~ "snapshot_at=" <> snapshot["snapshot_at"]
  end

  defp start_watcher!(opts) do
    name = :"review_watcher_loop_#{System.unique_integer([:positive])}"
    start_supervised!({ReviewWatcher, Keyword.put(opts, :name, name)})
  end
end
