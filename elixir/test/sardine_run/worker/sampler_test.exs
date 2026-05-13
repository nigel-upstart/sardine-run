defmodule SardineRun.Worker.SamplerTest do
  use ExUnit.Case, async: true

  alias SardineRun.Worker.Sampler

  describe "pick/2" do
    test "returns :codex when probability is 0.0 regardless of rng" do
      assert Sampler.pick(0.0, fn -> 0.0 end) == :codex
      assert Sampler.pick(0.0, fn -> 0.999_999 end) == :codex
    end

    test "returns :claude when probability is 1.0 regardless of rng" do
      assert Sampler.pick(1.0, fn -> 0.0 end) == :claude
      assert Sampler.pick(1.0, fn -> 0.999_999 end) == :claude
    end

    test "selects :claude when rng roll is strictly less than probability" do
      assert Sampler.pick(0.5, fn -> 0.4999 end) == :claude
    end

    test "selects :codex when rng roll equals probability (boundary)" do
      # `roll < probability` — equality falls to :codex.
      assert Sampler.pick(0.5, fn -> 0.5 end) == :codex
    end

    test "selects :codex when rng roll exceeds probability" do
      assert Sampler.pick(0.05, fn -> 0.06 end) == :codex
    end

    test "clamps probability above 1.0 to fully Claude" do
      assert Sampler.pick(2.0, fn -> 0.99 end) == :claude
    end

    test "clamps negative probability to fully Codex" do
      assert Sampler.pick(-0.5, fn -> 0.0 end) == :codex
    end

    test "coerces integer probabilities" do
      assert Sampler.pick(0, fn -> 0.0 end) == :codex
      assert Sampler.pick(1, fn -> 0.999 end) == :claude
    end

    test "falls back to :codex when probability is a non-number" do
      assert Sampler.pick(nil, fn -> 0.0 end) == :codex
      assert Sampler.pick("not a number", fn -> 0.0 end) == :codex
    end

    test "uses :rand.uniform/0 by default" do
      :rand.seed(:exsss, {1, 2, 3})
      # Just smoke-tests the default branch; deterministic value is not asserted
      # since we only need to confirm no crash.
      assert Sampler.pick(0.5) in [:claude, :codex]
    end
  end
end
