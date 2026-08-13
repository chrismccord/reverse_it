defmodule ReverseIt.MixProject do
  use Mix.Project

  @version "0.2.6"
  @source_url "https://github.com/chrismccord/reverse_it"

  def project do
    [
      app: :reverse_it,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      name: "ReverseIt",
      source_url: @source_url,
      homepage_url: @source_url,
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
      {:finch, "~> 0.23"},
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:websock, "~> 0.5"},
      {:websock_adapter, "~> 0.5"},
      {:castore, "~> 1.0"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:req, "~> 0.4", only: [:test]}
    ]
  end

  defp description do
    "A full-featured reverse proxy for Phoenix and Plug applications with HTTP and WebSocket support."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "GitHub" => @source_url
      }
    ]
  end
end
