defmodule ReverseIt.MixProject do
  use Mix.Project

  def project do
    [
      app: :reverse_it,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ReverseIt.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.16"},
      {:finch, "~> 0.19"},
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:websock, "~> 0.5"},
      {:websock_adapter, "~> 0.5"},
      {:castore, "~> 1.0"},
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:req, "~> 0.4", only: [:test]}
    ]
  end
end
