defmodule ReverseIt do
  @moduledoc """
  A full-featured HTTP/1.1, HTTP/2, and WebSocket reverse proxy for Elixir.

  Built using Finch (HTTP) and Mint (WebSockets), ReverseIt is designed to work seamlessly within
  Phoenix/Plug pipelines as a standard Plug module.

  ## Features

  - **Full HTTP Support**: HTTP/1.1 and HTTP/2 proxying with streaming request/response bodies
  - **Connection Pooling**: Uses Finch for automatic connection pooling and reuse across requests
  - **HTTP/2 Multiplexing**: Automatically leverages HTTP/2 multiplexing when available (up to 50 connections per backend)
  - **WebSocket Proxying**: Bidirectional WebSocket frame forwarding with full protocol support
  - **Plug Integration**: Works as a standard Plug module in any Phoenix or Plug application
  - **Header Management**: Automatic X-Forwarded-* header injection and hop-by-hop header filtering
  - **Request Body Limits**: Configurable request body size limits (default: 10MB)
  - **Path Manipulation**: Strip path prefixes and add backend path prefixes
  - **Protocol Detection**: Automatic detection and routing for HTTP vs WebSocket upgrades

  ## Setup

  First, add ReverseIt to your application's supervision tree with a connection pool:

      defmodule MyApp.Application do
        def start(_type, _args) do
          children = [
            # Start ReverseIt with a connection pool
            {ReverseIt, name: MyApp.ReverseProxy, pool_size: 100},
            # ... other children
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Usage

  ### In a Phoenix Router

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router

        # Regular Phoenix routes
        scope "/", MyAppWeb do
          get "/", PageController, :index
        end

        # Proxy API requests to backend service
        scope "/api" do
          forward "/", ReverseIt,
            name: MyApp.ReverseProxy,
            backend: "http://backend-api:4000",
            strip_path: "/api"
        end

        # Proxy WebSocket connections
        scope "/socket" do
          forward "/", ReverseIt,
            name: MyApp.ReverseProxy,
            backend: "ws://backend-ws:4000"
        end
      end

  ### As a Plug

      defmodule MyApp.ProxyPlug do
        use Plug.Router

        plug :match
        plug :dispatch

        forward "/", ReverseIt,
          name: MyApp.ReverseProxy,
          backend: "http://localhost:4001",
          timeout: 60_000,
          protocols: [:http1, :http2]
      end

  ## Configuration Options

  ### Supervisor Options (when starting ReverseIt)

    * `:name` (required) - Name for the Finch connection pool
    * `:pool_size` - Max connections per backend (default: 50)
    * `:pool_count` - Number of connection pools (default: 1)
    * `:pool_timeout` - Connection timeout in ms (default: 30_000)

  ### Plug Options (when using as a Plug)

    * `:name` (required) - Name of the Finch pool to use
    * `:backend` (required) - Backend URL (http://, https://, ws://, or wss://)
    * `:strip_path` - Path prefix to strip from incoming requests before proxying
    * `:timeout` - Request timeout in milliseconds (default: 30,000)
    * `:max_body_size` - Maximum request body size in bytes (default: 10,485,760 / 10MB, `:infinity` for unlimited)
    * `:protocols` - List of supported HTTP protocols (default: [:http1, :http2])

  ## Connection Pooling

  ReverseIt uses Finch for HTTP requests, which provides automatic connection pooling:

  - **Pool Size**: 50 connections per backend by default
  - **Reuse**: Connections are automatically reused across requests
  - **HTTP/2 Multiplexing**: Multiple requests can share a single HTTP/2 connection
  - **Performance**: Eliminates TCP/TLS handshake overhead for subsequent requests

  You configure the pool when adding ReverseIt to your supervisor tree.

  ## Examples

  ### Basic HTTP Proxying

      # Proxy all requests to a backend server
      forward "/", ReverseIt,
        name: MyApp.ReverseProxy,
        backend: "http://localhost:4001"

  ### Path Stripping

      # Strip /api prefix before forwarding
      # Request to /api/users becomes /users at backend
      forward "/api", ReverseIt,
        name: MyApp.ReverseProxy,
        backend: "http://api-server:4000",
        strip_path: "/api"

  ### WebSocket Proxying

      # Proxy WebSocket connections
      forward "/ws", ReverseIt,
        name: MyApp.ReverseProxy,
        backend: "ws://websocket-server:4000"

  ### Custom Timeouts and Protocols

      # Configure timeout and HTTP protocols
      forward "/", ReverseIt,
        name: MyApp.ReverseProxy,
        backend: "https://backend:443",
        timeout: 60_000,
        protocols: [:http1, :http2]
  """

  @behaviour Plug

  require Logger
  alias ReverseIt.{Config, HTTPProxy, WebSocketProxy}

  @doc """
  Child spec for starting ReverseIt with a Finch connection pool.

  Add this to your application's supervision tree:

      children = [
        {ReverseIt, name: MyApp.ReverseProxy, pool_size: 100}
      ]

  ## Options

    * `:name` (required) - Name for the Finch pool
    * `:pool_size` - Max connections per backend (default: 50)
    * `:pool_count` - Number of connection pools (default: 1)
    * `:pool_timeout` - Connection timeout in ms (default: 30_000)
  """
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, 50)
    pool_count = Keyword.get(opts, :pool_count, 1)
    pool_timeout = Keyword.get(opts, :pool_timeout, 30_000)

    %{
      id: name,
      start:
        {Finch, :start_link,
         [
           [
             name: name,
             pools: %{
               default: [
                 size: pool_size,
                 count: pool_count,
                 conn_opts: [
                   transport_opts: [timeout: pool_timeout]
                 ]
               ]
             }
           ]
         ]}
    }
  end

  @impl Plug
  def init(opts) do
    case Config.parse(opts) do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise ArgumentError, "Invalid ReverseIt configuration: #{reason}"
    end
  end

  @impl Plug
  def call(conn, config) do
    conn =
      if websocket_upgrade?(conn) do
        # Handle WebSocket upgrade
        handle_websocket(conn, config)
      else
        # Handle regular HTTP request
        HTTPProxy.proxy(conn, config)
      end

    # Ensure the connection is halted after proxying
    Plug.Conn.halt(conn)
  end

  # Private functions

  defp websocket_upgrade?(conn) do
    # Check for WebSocket upgrade headers
    connection_header =
      conn
      |> Plug.Conn.get_req_header("connection")
      |> Enum.map(&String.downcase/1)
      |> Enum.any?(&String.contains?(&1, "upgrade"))

    upgrade_header =
      conn
      |> Plug.Conn.get_req_header("upgrade")
      |> Enum.map(&String.downcase/1)
      |> Enum.member?("websocket")

    connection_header && upgrade_header
  end

  defp handle_websocket(conn, config) do
    # Prepare options for WebSocket proxy
    opts = [
      config: config,
      client_headers: conn.req_headers,
      path: conn.request_path,
      query_string: conn.query_string
    ]

    # Upgrade connection using WebSockAdapter
    # This will call WebSocketProxy.init/1 and handle the WebSocket lifecycle
    try do
      WebSockAdapter.upgrade(conn, WebSocketProxy, opts, [])
    rescue
      error ->
        Logger.debug("Failed to upgrade WebSocket connection: #{inspect(error)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(502, "Bad Gateway: WebSocket upgrade failed")
    end
  end
end
