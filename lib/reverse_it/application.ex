defmodule ReverseIt.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Start test servers in dev/test mode
        test_servers()
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ReverseIt.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp test_servers do
    if Mix.env() in [:dev, :test] do
      [
        # Backend server on port 4001
        {Bandit, plug: ReverseIt.TestBackend, scheme: :http, port: 4001},
        # Proxy server on port 4000
        {Bandit, plug: ReverseIt.TestProxy, scheme: :http, port: 4000}
      ]
    else
      []
    end
  end
end
