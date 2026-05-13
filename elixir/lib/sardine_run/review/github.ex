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

  @doc """
  Lists unresolved review threads on a PR.

  Returns a list of maps shaped like:

      %{
        "thread_id" => "PRRT_…",         # GraphQL node ID (for resolve_thread)
        "comment_id" => 12345,           # REST databaseId of the first comment
        "path" => "lib/foo.ex",
        "line" => 42,
        "author" => "alice",
        "body" => "consider extracting …"
      }

  Threads marked `isResolved: true` and pure-bot / outdated threads
  (`isCollapsed: true`) are filtered out before returning.
  """
  @spec unresolved_threads(pr_ref(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def unresolved_threads(%{owner: owner, repo: repo, number: number}, opts \\ []) do
    runner = Keyword.get(opts, :runner, &default_runner/1)

    query = """
    query { repository(owner: "#{owner}", name: "#{repo}") { pullRequest(number: #{number}) {\
     reviewThreads(first: 100) { nodes { id isResolved isCollapsed\
     comments(first: 1) { nodes { databaseId body path line author { login } } } } } } } }
    """

    case invoke(runner, ["api", "graphql", "-f", "query=#{query}"]) do
      {:ok, response} -> {:ok, extract_unresolved_threads(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists failing checks on a PR. Returns entries shaped like
  `%{"name" => "ci/test", "state" => "FAILURE", "link" => "…"}` — the
  fields are `name`, `state`, and `link`, matching `gh pr checks --json`.

  Includes checks whose state is `FAILURE` or `TIMED_OUT`; ignores
  cancelled, skipped, neutral, and in-progress runs so we only nudge the
  reviewer when there's something to actually fix.
  """
  @spec failing_checks(pr_ref(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def failing_checks(%{owner: owner, repo: repo, number: number}, opts \\ []) do
    runner = Keyword.get(opts, :runner, &default_runner/1)

    args = [
      "pr",
      "checks",
      "#{number}",
      "--repo",
      "#{owner}/#{repo}",
      "--json",
      "name,state,link"
    ]

    case invoke(runner, args) do
      {:ok, checks} when is_list(checks) -> {:ok, Enum.filter(checks, &failing?/1)}
      {:ok, _} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_unresolved_threads(%{"data" => %{"repository" => %{"pullRequest" => %{"reviewThreads" => %{"nodes" => threads}}}}}) when is_list(threads) do
    threads
    |> Enum.reject(&hidden_thread?/1)
    |> Enum.flat_map(&extract_thread_summary/1)
  end

  defp extract_unresolved_threads(_response), do: []

  defp hidden_thread?(thread) do
    Map.get(thread, "isResolved", false) or Map.get(thread, "isCollapsed", false)
  end

  defp extract_thread_summary(%{"id" => thread_id, "comments" => %{"nodes" => [first | _]}}) do
    [
      %{
        "thread_id" => thread_id,
        "comment_id" => Map.get(first, "databaseId"),
        "body" => Map.get(first, "body"),
        "path" => Map.get(first, "path"),
        "line" => Map.get(first, "line"),
        "author" => get_in(first, ["author", "login"])
      }
    ]
  end

  defp extract_thread_summary(_thread), do: []

  defp failing?(%{"state" => state}) when is_binary(state),
    do: String.upcase(state) in ["FAILURE", "TIMED_OUT", "FAIL", "FAILING"]

  defp failing?(_check), do: false

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
