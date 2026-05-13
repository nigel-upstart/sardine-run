defmodule SardineRun.Worker.Sampler do
  @moduledoc """
  Probabilistic worker-kind selector used at dispatch time.

  `pick/2` returns `:claude` with the configured probability and `:codex`
  otherwise. The RNG is injectable so tests can drive deterministic
  selections; production callers use `&:rand.uniform/0` (the default).

  The probability is clamped to `[0.0, 1.0]`. Anything that cannot be coerced
  to a finite float in that range collapses to `0.0` (Codex-only), which is
  the safe default — Codex is the production-tested backend.
  """

  @typedoc "Probability of selecting Claude, expressed as a float in [0.0, 1.0]."
  @type probability :: float() | integer()

  @typedoc "Zero-arg function returning a uniform float in [0.0, 1.0)."
  @type rng_fn :: (-> float())

  @typedoc "Worker kind tag matching `SardineRun.Worker.kind/0` implementations."
  @type worker_kind :: :codex | :claude

  @doc """
  Returns `:claude` with `probability`, `:codex` otherwise.

  The optional `rng_fn` defaults to `&:rand.uniform/0`. Tests pass a
  deterministic generator to assert behavior at probability boundaries.

  Examples:

      iex> SardineRun.Worker.Sampler.pick(1.0, fn -> 0.5 end)
      :claude

      iex> SardineRun.Worker.Sampler.pick(0.0, fn -> 0.0 end)
      :codex
  """
  @spec pick(probability(), rng_fn()) :: worker_kind()
  def pick(probability, rng_fn \\ &:rand.uniform/0) when is_function(rng_fn, 0) do
    clamped = normalize_probability(probability)

    cond do
      clamped <= 0.0 ->
        :codex

      clamped >= 1.0 ->
        :claude

      true ->
        roll = rng_fn.()

        if is_float(roll) and roll < clamped do
          :claude
        else
          :codex
        end
    end
  end

  defp normalize_probability(value) when is_integer(value), do: normalize_probability(value * 1.0)

  defp normalize_probability(value) when is_float(value) do
    cond do
      value <= 0.0 -> 0.0
      value >= 1.0 -> 1.0
      true -> value
    end
  end

  defp normalize_probability(_value), do: 0.0
end
