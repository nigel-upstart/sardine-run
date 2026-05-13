defmodule SardineRun.Review.GitHub do
  @moduledoc """
  Shell wrapper around the `gh` CLI for PR review interactions.

  Two surfaces, both shaped so the future `SardineRun.ReviewWatcher` (PR 3)
  can reuse them alongside the `sardine_run_session` dynamic-tool dispatch:

  - `reply_to_comment/4` — POST an inline reply via REST.
  - `resolve_thread/3` — `resolveReviewThread` GraphQL mutation.

  The shell runner is injectable through the `:runner` option so tests can
  stub it without putting a fake `gh` on PATH.
  """

  @type pr_ref :: %{owner: String.t(), repo: String.t(), number: integer()}
  @type runner :: ([String.t()] -> {String.t(), non_neg_integer()})

  @doc """
  Parses a GitHub PR URL like `https://github.com/owner/repo/pull/123` into
  the `pr_ref` shape expected by the other functions.
  """
  @spec parse_pr_url(String.t()) :: {:ok, pr_ref()} | {:error, :invalid_pr_url}
  def parse_pr_url(url) when is_binary(url) do
    case Regex.run(~r{\Ahttps?://github\.com/([^/]+)/([^/]+)/pull/(\d+)\b}, url) do
      [_, owner, repo, number] ->
        {:ok, %{owner: owner, repo: repo, number: String.to_integer(number)}}

      _ ->
        {:error, :invalid_pr_url}
    end
  end

  @doc """
  Posts an inline reply to an existing review comment via
  `gh api repos/{owner}/{repo}/pulls/{number}/comments`.
  """
  @spec reply_to_comment(pr_ref(), integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reply_to_comment(%{owner: owner, repo: repo, number: pr}, comment_id, body, opts \\ [])
      when is_integer(comment_id) and is_binary(body) do
    runner = Keyword.get(opts, :runner, &default_runner/1)

    args = [
      "api",
      "repos/#{owner}/#{repo}/pulls/#{pr}/comments",
      "-X",
      "POST",
      "-f",
      "body=#{body}",
      "-F",
      "in_reply_to=#{comment_id}"
    ]

    invoke(runner, args)
  end

  @doc """
  Marks a review thread as resolved via the GraphQL `resolveReviewThread`
  mutation. `thread_id` is the PR review-thread GraphQL node ID (e.g.
  `PRRT_kwDOKqpK0M5vt_nf`), not the REST comment ID.

  The `reason` argument is plumbed for caller bookkeeping (the prompt's
  "substantive reply" bar lives in the WORKFLOW.md prompt, not here) and is
  not transmitted to GitHub.
  """
  @spec resolve_thread(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_thread(thread_id, _reason, opts \\ []) when is_binary(thread_id) do
    runner = Keyword.get(opts, :runner, &default_runner/1)

    if Regex.match?(~r/\A[A-Za-z0-9_\-]+\z/, thread_id) do
      query =
        ~s|mutation { resolveReviewThread(input: {threadId: "#{thread_id}"}) { thread { id isResolved } } }|

      invoke(runner, ["api", "graphql", "-f", "query=#{query}"])
    else
      {:error, {:invalid_thread_id, thread_id}}
    end
  end

  defp invoke(runner, args) do
    case runner.(args) do
      {output, 0} -> {:ok, parse_json(output)}
      {output, status} -> {:error, {:gh_failed, status, String.trim(output)}}
    end
  end

  defp default_runner(args) do
    System.cmd("gh", args, stderr_to_stdout: true)
  end

  defp parse_json(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      _ -> %{"raw" => text}
    end
  end
end
