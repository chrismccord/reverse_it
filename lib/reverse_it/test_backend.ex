defmodule ReverseIt.TestBackend do
  @moduledoc """
  Test backend server with HTTP and WebSocket endpoints.
  Used for testing the reverse proxy functionality.
  """

  use Plug.Router

  require Logger

  plug(:match)
  plug(:dispatch)

  # Simple GET endpoint
  get "/hello" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "Hello from backend!")
  end

  # JSON endpoint
  get "/api/status" do
    response = Jason.encode!(%{status: "ok", server: "backend", timestamp: DateTime.utc_now()})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, response)
  end

  # Echo POST endpoint
  post "/echo" do
    {:ok, body, conn} = read_body(conn)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{echo: body}))
  end

  # Headers inspection endpoint
  get "/headers" do
    headers = Map.new(conn.req_headers)
    response = Jason.encode!(%{headers: headers})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, response)
  end

  # WebSocket endpoint
  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(ReverseIt.TestBackend.WebSocketHandler, [], [])
  end

  # Catch all
  match _ do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
  end
end

defmodule ReverseIt.TestBackend.WebSocketHandler do
  @moduledoc """
  Simple WebSocket echo handler for testing.
  """

  require Logger

  @behaviour WebSock

  @impl WebSock
  def init(_opts) do
    Logger.debug("Backend WebSocket connection established")
    {:ok, %{}}
  end

  @impl WebSock
  def handle_in({message, opcode: :text}, state) do
    Logger.debug("Backend received text: #{message}")
    # Echo back with a prefix
    response = "Backend echo: #{message}"
    {:reply, :ok, {:text, response}, state}
  end

  def handle_in({message, opcode: :binary}, state) do
    Logger.debug("Backend received binary: #{byte_size(message)} bytes")
    # Echo back binary
    {:reply, :ok, {:binary, message}, state}
  end

  @impl WebSock
  def handle_control({_data, opcode: :ping}, state) do
    {:ok, state}
  end

  def handle_control({_data, opcode: :pong}, state) do
    {:ok, state}
  end

  @impl WebSock
  def handle_info(_message, state) do
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, _state) do
    Logger.debug("Backend WebSocket connection closed: #{inspect(reason)}")
    :ok
  end
end
