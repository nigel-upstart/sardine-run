defmodule SardineRun.OrchestratorPickWorkerTest do
  use SardineRun.TestSupport

  alias SardineRun.Orchestrator
  alias SardineRun.Tracker.Issue

  describe "pick_worker/2 reviewer branch" do
    test "review_pending sessions deterministically pick :reviewer with the configured backend (codex default)" do
      install_workflow!(claude_probability: 1.0, review_backend: "codex")

      issue = %Issue{id: "abc", identifier: "ABC-1", state: "review_pending"}

      assert {SardineRun.Codex.AppServer, :reviewer} =
               Orchestrator.pick_worker(orchestrator_state(), issue)
    end

    test "honors review.backend = claude" do
      install_workflow!(claude_probability: 0.0, review_backend: "claude")

      issue = %Issue{id: "abc", state: "review_pending"}

      assert {SardineRun.Claude.AppServer, :reviewer} =
               Orchestrator.pick_worker(orchestrator_state(), issue)
    end

    test "review_pending bypasses the sampler even when claude_probability is 1.0" do
      install_workflow!(claude_probability: 1.0, review_backend: "codex")

      issue = %Issue{id: "abc", state: "review_pending"}

      assert {SardineRun.Codex.AppServer, :reviewer} =
               Orchestrator.pick_worker(orchestrator_state(), issue)
    end

    test "non-review_pending sessions fall through to the sampler" do
      install_workflow!(claude_probability: 0.0, review_backend: "codex")

      issue = %Issue{id: "abc", state: "active"}

      assert {SardineRun.Codex.AppServer, :codex} =
               Orchestrator.pick_worker(orchestrator_state(), issue)
    end

    test "issue without :state field falls through to the sampler" do
      install_workflow!(claude_probability: 0.0)

      issue = %{id: "abc"}

      assert {SardineRun.Codex.AppServer, :codex} =
               Orchestrator.pick_worker(orchestrator_state(), issue)
    end
  end

  defp orchestrator_state, do: %SardineRun.Orchestrator.State{}

  defp install_workflow!(opts) do
    claude_probability = Keyword.get(opts, :claude_probability, 0.0)
    review_backend = Keyword.get(opts, :review_backend, "codex")

    content = """
    ---
    tracker:
      kind: memory
      active_states: [active, review_pending]
      terminal_states: [done, archived]
    agent:
      sampling:
        claude_probability: #{claude_probability}
    review:
      enabled: true
      backend: #{review_backend}
    codex:
      command: codex
    claude:
      command: claude
    ---
    prompt body
    """

    File.write!(Workflow.workflow_file_path(), content)

    if Process.whereis(SardineRun.WorkflowStore) do
      SardineRun.WorkflowStore.force_reload()
    end

    :ok
  end
end
