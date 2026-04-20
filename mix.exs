defmodule Lacuna.MixProject do
  use Mix.Project

  def project do
    [
      app: :lacuna,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {Lacuna.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:ex_gram, "~> 0.65"},
      {:tesla, "~> 1.14"},
      {:hackney, "~> 1.20"},
      {:toml, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:dotenvy, "~> 1.1"},
      {:bypass, "~> 2.1", only: :test},
      {:mox, "~> 1.2", only: :test}
    ]
  end

  defp releases do
    [
      lacuna: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  defp aliases do
    [
      "lacuna.run": ["run --no-halt"]
    ]
  end
end
