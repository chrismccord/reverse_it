defmodule ReverseIt.TestProxy do
  @moduledoc """
  Test proxy server that forwards requests to the backend.
  """

  use Plug.Router

  require Logger

  plug(:match)

  # Proxy everything through ReverseIt.Proxy
  plug(ReverseIt.Proxy, backend: "http://localhost:4001")

  plug(:dispatch)

  # This should never be reached as ReverseIt.Proxy halts the connection
  match _ do
    send_resp(conn, 500, "Proxy failed")
  end
end
