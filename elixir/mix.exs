defmodule SardineRun.MixProject do
  use Mix.Project

  def project do
    [
      app: :sardine_run,
      version: "0.1.0",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      # Coverage enforcement is handled by `mix coverage.gate` (see
      # `lib/mix/tasks/coverage.gate.ex`) so that we can lock named modules at
      # 100% while letting newer/less-tested modules sit above a global floor.
      # `mix test --cover` keeps its summary table but no enforcement.
      test_coverage: [
        # The real gate is `mix coverage.gate` (lib/mix/tasks/coverage.gate.ex),
        # which locks named modules at 100% and applies a global floor. Disable
        # Mix's built-in threshold check so the summary table prints freely.
        summary: [threshold: 0],
        ignore_modules: [
          SardineRun.Config,
          SardineRun.SpecsCheck,
          SardineRun.CLI,
          SardineRun.HttpServer,
          SardineRunWeb.Endpoint,
          SardineRunWeb.ErrorHTML,
          SardineRunWeb.ErrorJSON,
          SardineRunWeb.Layouts,
          SardineRunWeb.Router,
          SardineRunWeb.Router.Helpers
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SardineRun.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: SardineRun.CLI,
      name: "sardine-run",
      path: "bin/sardine-run"
    ]
  end
end
