defmodule SardineRun.ReviewWatcher do
  @moduledoc """
  Periodically polls GitHub for unresolved review feedback on PRs linked to
  sessions sitting in the `review` status, and flips those sessions to
  `review_pending` so the orchestrator dispatches the `:reviewer` 🐡 worker.

  ## Tick cadence

  Each tick fires `review.poll_interval_ms` after the previous tick PLUS a
  uniform random jitter in `[0, review.poll_jitter_ms]` so multiple
  sardine-run instances (or many sessions inside one instance) don't
  hammer the GitHub API at exactly the same wall-clock moment.

  ## What happens per tick

  1. Ask the configured tracker for issues whose state is `review`.
  2. For each, look up the first `kind: pr` link in `links.yaml`. Skip
     sessions without one (we can't process a review without a PR ref).
  3. Call `Review.GitHub.unresolved_threads/2` and — when `review.check_ci`
     is true — `Review.GitHub.failing_checks/2`.
  4. If either has any results, write a snapshot to
     `sessions/<id>/pending_feedback.yaml` via
     `SessionWriter.write_pending_feedback/2` and flip the session's status
     from `review` to `review_pending` via
     `SessionWriter.update_status/3`.

  ## Testability

  All three external dependencies are injectable via `start_link` options:

  - `:tracker` — `{:ok, [Issue.t()]}` source (defaults to
    `SardineRun.Tracker.fetch_issues_by_states/1`).
  - `:gh_runner` — passed through as `:runner` to every
    `Review.GitHub` call.
  - `:clock` — `fn -> integer() end` returning monotonic time. Tests can
    skip the timer entirely and invoke `tick_now/1` instead.

  Tests should call `tick_now/1` synchronously rather than racing the
  scheduled tick.
  """

  use GenServer
  require Logger

  alias SardineRun.Config
  alias SardineRun.Review.GitHub
  alias SardineRun.Tracker
  alias SardineRun.Tracker.Issue
  alias SardineRun.TrafficControl.SessionWriter

  @default_name __MODULE__

  @type option :: {:name, GenServer.name()} | {:tracker, function()} | {:gh_runner, function()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs one watcher tick synchronously and returns a summary map listing:

  - `:flipped` — session IDs that were transitioned to `review_pending`.
  - `:clean` — session IDs polled with no new feedback.
  - `:skipped_no_pr` — session IDs skipped because no `link_kind: pr`
    link was recorded.
  - `:errored` — session IDs whose poll failed (state-repo error, malformed
    PR URL, etc.). Useful for operators to detect persistent gh / repo
    failures; counts non-zero here mean the loop is silently dropping work.

  Intended for tests and ad-hoc operator invocations from `iex -S mix`.
  """
  @spec tick_now(GenServer.server()) :: %{
          flipped: [String.t()],
          clean: [String.t()],
          skipped_no_pr: [String.t()],
          errored: [String.t()]
        }
  def tick_now(server \\ @default_name) do
    GenServer.call(server, :tick_now, 30_000)
  end

  @impl true
  def init(opts) do
    state = %{
      tracker: Keyword.get(opts, :tracker, &default_tracker/1),
      gh_runner: Keyword.get(opts, :gh_runner),
      timer_ref: nil
    }

    {:ok, schedule_next_tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = do_tick(state)
    {:noreply, schedule_next_tick(%{state | timer_ref: nil})}
  end

  @impl true
  def handle_call(:tick_now, _from, state) do
    summary = do_tick(state)
    {:reply, summary, state}
  end

  defp schedule_next_tick(state) do
    settings = Config.settings!().review
    interval = settings.poll_interval_ms + jitter(settings.poll_jitter_ms)
    timer_ref = Process.send_after(self(), :tick, interval)
    %{state | timer_ref: timer_ref}
  end

  defp jitter(0), do: 0
  defp jitter(max) when is_integer(max) and max > 0, do: :rand.uniform(max + 1) - 1

  defp do_tick(state) do
    review_state = "review"

    case state.tracker.([review_state]) do
      {:ok, issues} ->
        process_issues(issues, state)

      {:error, reason} ->
        Logger.warning("review_watcher: tracker fetch failed (#{inspect(reason)}); skipping tick")
        empty_summary()
    end
  end

  defp process_issues(issues, state) do
    Enum.reduce(issues, empty_summary(), fn issue, summary ->
      classify(process_issue(issue, state), issue, summary)
    end)
  end

  defp classify({:flipped, _}, %Issue{id: id}, summary), do: %{summary | flipped: [id | summary.flipped]}
  defp classify(:clean, %Issue{id: id}, summary), do: %{summary | clean: [id | summary.clean]}
  defp classify(:skipped_no_pr, %Issue{id: id}, summary), do: %{summary | skipped_no_pr: [id | summary.skipped_no_pr]}
  defp classify(:error, %Issue{id: id}, summary), do: %{summary | errored: [id | summary.errored]}
  defp classify(_other, _issue, summary), do: summary

  defp process_issue(%Issue{id: session_id}, state) when is_binary(session_id) do
    case SessionWriter.find_pr_url(session_id) do
      {:ok, url} ->
        with_pr_ref(session_id, url, state)

      {:error, :no_pr_link} ->
        :skipped_no_pr

      {:error, reason} ->
        Logger.warning("review_watcher: find_pr_url failed for #{session_id}: #{inspect(reason)}")
        :error
    end
  end

  defp process_issue(_issue, _state), do: :error

  defp with_pr_ref(session_id, url, state) do
    case GitHub.parse_pr_url(url) do
      {:ok, pr_ref} ->
        gather_and_flip(session_id, pr_ref, state)

      {:error, reason} ->
        Logger.warning("review_watcher: unparseable PR url for #{session_id}: #{inspect(reason)}")
        :error
    end
  end

  defp gather_and_flip(session_id, pr_ref, state) do
    threads = fetch_threads(pr_ref, state)
    checks = fetch_failing_checks(pr_ref, state)

    if threads == [] and checks == [] do
      :clean
    else
      apply_pending_feedback(session_id, threads, checks)
    end
  end

  defp fetch_threads(pr_ref, state) do
    case GitHub.unresolved_threads(pr_ref, gh_opts(state)) do
      {:ok, threads} ->
        threads

      {:error, reason} ->
        Logger.warning("review_watcher: unresolved_threads gh call failed: #{inspect(reason)}")
        []
    end
  end

  defp fetch_failing_checks(pr_ref, state) do
    if Config.settings!().review.check_ci do
      case GitHub.failing_checks(pr_ref, gh_opts(state)) do
        {:ok, checks} ->
          checks

        {:error, reason} ->
          Logger.warning("review_watcher: failing_checks gh call failed: #{inspect(reason)}")
          []
      end
    else
      []
    end
  end

  defp apply_pending_feedback(session_id, threads, checks) do
    feedback = %{
      "threads" => threads,
      "failing_checks" => checks,
      "snapshot_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- SessionWriter.write_pending_feedback(session_id, feedback),
         :ok <- SessionWriter.update_status(session_id, "review_pending", nil) do
      Logger.info("🐡 review_watcher: flipped session #{session_id} to review_pending (#{length(threads)} thread(s), #{length(checks)} failing check(s))")

      {:flipped, feedback}
    else
      {:error, reason} ->
        Logger.warning("review_watcher: failed to apply pending feedback for #{session_id}: #{inspect(reason)}")
        :error
    end
  end

  defp gh_opts(%{gh_runner: nil}), do: []
  defp gh_opts(%{gh_runner: runner}) when is_function(runner, 1), do: [runner: runner]

  defp default_tracker(states), do: Tracker.fetch_issues_by_states(states)

  defp empty_summary, do: %{flipped: [], clean: [], skipped_no_pr: [], errored: []}
end
