defmodule SardineRun.Review.GitHubTest do
  use ExUnit.Case, async: true

  alias SardineRun.Review.GitHub

  describe "parse_pr_url/1" do
    test "extracts owner, repo, and number from a github.com PR URL" do
      assert {:ok, %{owner: "teamupstart", repo: "sardine-run", number: 42}} =
               GitHub.parse_pr_url("https://github.com/teamupstart/sardine-run/pull/42")
    end

    test "rejects non-PR URLs" do
      assert {:error, :invalid_pr_url} = GitHub.parse_pr_url("https://example.com/foo")
      assert {:error, :invalid_pr_url} = GitHub.parse_pr_url("https://github.com/owner/repo/issues/42")
    end
  end

  describe "reply_to_comment/4" do
    test "invokes gh api with the correct arg shape" do
      pr = %{owner: "o", repo: "r", number: 7}

      runner = fn args ->
        send(self(), {:gh_args, args})
        {~s|{"id": 999}|, 0}
      end

      assert {:ok, %{"id" => 999}} =
               GitHub.reply_to_comment(pr, 12_345, "addressed", runner: runner)

      assert_received {:gh_args, args}
      assert "api" in args
      assert Enum.member?(args, "repos/o/r/pulls/7/comments")
      assert Enum.any?(args, &(&1 == "body=addressed"))
      assert Enum.any?(args, &(&1 == "in_reply_to=12345"))
    end

    test "returns {:error, {:gh_failed, ...}} when gh exits non-zero" do
      pr = %{owner: "o", repo: "r", number: 7}
      runner = fn _ -> {"boom", 1} end

      assert {:error, {:gh_failed, 1, "boom"}} =
               GitHub.reply_to_comment(pr, 1, "...", runner: runner)
    end
  end

  describe "unresolved_threads/2" do
    test "returns only threads where isResolved=false and isCollapsed=false" do
      response =
        Jason.encode!(%{
          "data" => %{
            "repository" => %{
              "pullRequest" => %{
                "reviewThreads" => %{
                  "nodes" => [
                    %{
                      "id" => "PRRT_a",
                      "isResolved" => false,
                      "isCollapsed" => false,
                      "comments" => %{
                        "nodes" => [
                          %{
                            "databaseId" => 1,
                            "body" => "unresolved",
                            "path" => "lib/a.ex",
                            "line" => 10,
                            "author" => %{"login" => "alice"}
                          }
                        ]
                      }
                    },
                    %{
                      "id" => "PRRT_b",
                      "isResolved" => true,
                      "isCollapsed" => false,
                      "comments" => %{"nodes" => [%{"databaseId" => 2, "body" => "resolved"}]}
                    },
                    %{
                      "id" => "PRRT_c",
                      "isResolved" => false,
                      "isCollapsed" => true,
                      "comments" => %{"nodes" => [%{"databaseId" => 3, "body" => "collapsed"}]}
                    }
                  ]
                }
              }
            }
          }
        })

      runner = fn _args -> {response, 0} end

      assert {:ok, [thread]} =
               GitHub.unresolved_threads(%{owner: "o", repo: "r", number: 1}, runner: runner)

      assert thread["thread_id"] == "PRRT_a"
      assert thread["comment_id"] == 1
      assert thread["author"] == "alice"
    end

    test "returns [] when reviewThreads is missing or shaped unexpectedly" do
      runner = fn _ -> {Jason.encode!(%{"data" => %{}}), 0} end

      assert {:ok, []} =
               GitHub.unresolved_threads(%{owner: "o", repo: "r", number: 1}, runner: runner)
    end
  end

  describe "failing_checks/2" do
    test "filters to FAILURE / TIMED_OUT state" do
      response =
        Jason.encode!([
          %{"name" => "ci/test", "state" => "FAILURE", "link" => "http://x"},
          %{"name" => "ci/lint", "state" => "SUCCESS", "link" => "http://y"},
          %{"name" => "ci/slow", "state" => "TIMED_OUT", "link" => "http://z"},
          %{"name" => "ci/canc", "state" => "CANCELLED", "link" => "http://w"}
        ])

      runner = fn args ->
        # confirm we hit the right `gh pr checks` flags
        assert "pr" in args
        assert "checks" in args
        assert "--json" in args
        {response, 0}
      end

      assert {:ok, failing} =
               GitHub.failing_checks(%{owner: "o", repo: "r", number: 1}, runner: runner)

      names = Enum.map(failing, & &1["name"])
      assert "ci/test" in names
      assert "ci/slow" in names
      refute "ci/lint" in names
      refute "ci/canc" in names
    end

    test "returns [] when gh emits an empty array" do
      runner = fn _ -> {"[]", 0} end

      assert {:ok, []} =
               GitHub.failing_checks(%{owner: "o", repo: "r", number: 1}, runner: runner)
    end
  end

  describe "resolve_thread/3" do
    test "issues the resolveReviewThread GraphQL mutation" do
      runner = fn args ->
        send(self(), {:gh_args, args})
        {~s|{"data": {"resolveReviewThread": {"thread": {"isResolved": true}}}}|, 0}
      end

      assert {:ok, %{"data" => %{"resolveReviewThread" => %{"thread" => %{"isResolved" => true}}}}} =
               GitHub.resolve_thread("PRRT_abc123", "intentional pattern", runner: runner)

      assert_received {:gh_args, args}

      assert args == [
               "api",
               "graphql",
               "-f",
               ~s|query=mutation { resolveReviewThread(input: {threadId: "PRRT_abc123"}) { thread { id isResolved } } }|
             ]
    end

    test "rejects thread_id with characters outside [A-Za-z0-9_-]" do
      runner = fn _ -> {"unreachable", 0} end

      assert {:error, {:invalid_thread_id, ~s|" } } }|}} =
               GitHub.resolve_thread(~s|" } } }|, "reason", runner: runner)
    end
  end
end
