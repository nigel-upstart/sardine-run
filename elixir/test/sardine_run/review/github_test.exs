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
