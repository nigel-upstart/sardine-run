defmodule SardineRun.ReviewerTest do
  use SardineRun.TestSupport

  alias SardineRun.Reviewer
  alias SardineRun.Tracker.Issue
  alias SardineRun.TrafficControl.SessionWriter

  setup do
    state_repo = make_state_repo!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "traffic_control",
      tracker_state_repo: state_repo
    )

    # REVIEW_FEEDBACK.md is resolved relative to WORKFLOW.md's directory.
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    review_prompt_path = Path.join(workflow_dir, "REVIEW_FEEDBACK.md")

    File.write!(review_prompt_path, """
    session={{ issue.identifier }}
    threads={{ pending_feedback.threads.size }}
    checks={{ pending_feedback.failing_checks.size }}
    {% for t in pending_feedback.threads %}- {{ t.thread_id }} {{ t.path }}:{{ t.line }} by {{ t.author }}: {{ t.body }}
    {% endfor %}{% for c in pending_feedback.failing_checks %}* {{ c.name }} {{ c.state }} {{ c.link }}
    {% endfor %}
    """)

    {:ok, state_repo: state_repo}
  end

  describe "prompt/2" do
    test "renders threads + failing_checks from the on-disk snapshot", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review_pending")

      :ok =
        SessionWriter.write_pending_feedback("abc", %{
          "threads" => [
            %{
              "thread_id" => "PRRT_a",
              "comment_id" => 11,
              "body" => "consider X",
              "path" => "lib/a.ex",
              "line" => 9,
              "author" => "alice"
            },
            %{
              "thread_id" => "PRRT_b",
              "comment_id" => 12,
              "body" => "what about Y",
              "path" => "lib/b.ex",
              "line" => 33,
              "author" => "bob"
            }
          ],
          "failing_checks" => [
            %{"name" => "ci/test", "state" => "FAILURE", "link" => "https://x"}
          ]
        })

      issue = %Issue{id: "abc", identifier: "ABC-1", state: "review_pending"}
      rendered = Reviewer.prompt(issue, [])

      assert rendered =~ "session=ABC-1"
      assert rendered =~ "threads=2"
      assert rendered =~ "checks=1"
      assert rendered =~ "PRRT_a lib/a.ex:9 by alice: consider X"
      assert rendered =~ "PRRT_b lib/b.ex:33 by bob: what about Y"
      assert rendered =~ "ci/test FAILURE https://x"
    end

    test "treats missing snapshot as empty feedback", %{state_repo: state_repo} do
      _path = write_session_yaml!(state_repo, "abc", id: "abc", title: "T", status: "review_pending")

      issue = %Issue{id: "abc", identifier: "ABC-2", state: "review_pending"}
      rendered = Reviewer.prompt(issue, [])

      assert rendered =~ "session=ABC-2"
      assert rendered =~ "threads=0"
      assert rendered =~ "checks=0"
    end

    test "raises when REVIEW_FEEDBACK.md is missing", %{state_repo: _state_repo} do
      File.rm!(Path.join(Path.dirname(Workflow.workflow_file_path()), "REVIEW_FEEDBACK.md"))

      assert_raise RuntimeError, ~r/reviewer_prompt_missing/, fn ->
        Reviewer.prompt(%Issue{id: "abc"}, [])
      end
    end
  end
end
