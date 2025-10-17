defmodule ReverseIt.TestProxy do
  @moduledoc """
  Test proxy server that forwards requests to the backend.
  Uses a custom plug to dynamically configure ReverseIt with runtime port.
  """

  use Plug.Router

  require Logger

  plug(:match)
  plug(:proxy)
  plug(:dispatch)

  # Dynamic proxy plug that gets backend port at runtime
  defp proxy(conn, _opts) do
    backend_port = Application.get_env(:reverse_it, :test_backend_port)

    ReverseIt.call(
      conn,
      ReverseIt.init(
        name: ReverseIt.TestFinch,
        backend: "http://localhost:#{backend_port}"
      )
    )
  end

  # This should never be reached as ReverseIt halts the connection
  match _ do
    send_resp(conn, 500, "Proxy failed")
  end
end
