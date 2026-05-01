defmodule ElixirExec.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/kurtome/elixir_exec"

  def project do
    [
      app: :elixir_exec,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() === :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        doctor: :test,
        coverage: :test,
        dialyzer: :test,
        coveralls: :test,
        "coveralls.lcov": :test,
        "coveralls.json": :test,
        "coveralls.html": :test,
        "coveralls.detail": :test,
        "coveralls.post": :test
      ],
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_ignore_apps: [],
        plt_local_path: "dialyzer",
        plt_core_path: "dialyzer",
        list_unused_filters: true,
        ignore_warnings: ".dialyzer-ignore.exs",
        flags: [:unmatched_returns, :no_improper_lists]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirExec.Application, []}
    ]
  end

  defp deps do
    [
      {:erlexec, "~> 2.3"},
      {:nimble_options, "~> 1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:blitz_credo_checks, "~> 0.1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp description do
    "An idiomatic Elixir wrapper for the latest erlexec — execute and control OS processes from Elixir."
  end

  defp package do
    [
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "ElixirExec",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
