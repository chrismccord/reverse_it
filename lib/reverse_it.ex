defmodule ReverseIt do
  @moduledoc ~s"""
  A hardened HTTP/1.1, optional HTTP/2, and WebSocket reverse proxy for Elixir.

  Built using Finch (HTTP) and Mint (WebSockets), ReverseIt is designed to work seamlessly within
  Phoenix/Plug pipelines as a standard Plug module.

  ## Features

  - **Full HTTP Support**: HTTP/1.1 proxying by default, optional HTTP/2 upstreams, and streaming request/response bodies
  - **Connection Pooling**: Uses Finch for automatic connection pooling and reuse across requests
  - **One-Shot Upstreams**: Fresh HTTP/1.1 connections over TCP or Unix-domain sockets
  - **HTTP/2 Support**: Opt-in upstream HTTP/2 support with `protocols: [:http1, :http2]`
  - **WebSocket Proxying**: Bidirectional WebSocket frame forwarding with full protocol support
  - **Plug Integration**: Works as a standard Plug module in any Phoenix or Plug application
  - **Header Management**: Automatic X-Forwarded-* header injection and hop-by-hop header filtering
  - **DoS Protection**: Configurable request body, header, timeout, response, and WebSocket limits
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
          upstream_idle_timeout: 60_000,
          protocols: [:http1, :http2]
      end

  ### One-Shot Unix-Socket Upstreams

      ReverseIt.call(
        conn,
        ReverseIt.init(
          name: MyApp.ReverseProxy,
          backend: "http://provider-tunnel",
          unix_socket: "/run/my_app/provider-tunnel.sock",
          upstream_connection: :one_shot,
          protocols: [:http1]
        )
      )

  `:unix_socket` selects the transport address while the backend host remains
  the HTTP authority. Unix-socket upstreams support local, unencrypted HTTP/1.1
  and WebSocket traffic. They always use a fresh connection and never enter the
  Finch pool.

  ## Configuration Options

  ### Supervisor Options (when starting ReverseIt)

    * `:name` (required) - Name for the Finch connection pool
    * `:pool_size` - Max connections per backend (default: 50)
    * `:pool_count` - Number of connection pools (default: 1)
    * `:connect_timeout` - Backend connection timeout in ms (default: 5_000)
    * `:conn_max_idle_time` - Idle timeout for pooled backend HTTP/1 connections (default: 90_000)
    * `:protocols` - Upstream protocols for pooled Finch requests (default: [:http1])

  ### Plug Options (when using as a Plug)

    * `:name` (required) - Name of the Finch pool to use
    * `:backend` (required) - Backend URL (http://, https://, ws://, or wss://)
    * `:unix_socket` - Connect through this Unix-domain socket instead of the backend host/port
    * `:upstream_connection` - `:pooled` or `:one_shot` (default: `:pooled`)
    * `:strip_path` - Path prefix to strip from incoming requests before proxying
    * `:connect_timeout` - Backend connection timeout in milliseconds (default: 5_000)
    * `:pool_timeout` - Finch pool checkout timeout in milliseconds (default: 5_000)
    * `:response_header_timeout` - Time to wait for backend response headers in streaming paths (default: 30_000)
    * `:upstream_idle_timeout` - Rolling idle timeout while receiving backend data (default: 55_000)
    * `:request_body_read_timeout` - Rolling timeout while reading client request bodies (default: 55_000)
    * `:max_request_body_size` - Maximum request body size in bytes (default: 100MB, `:infinity` for unlimited)
    * `:request_body_buffer_size` - Bytes buffered before switching to request streaming (default: 1MB)
    * `:max_response_body_size` - Maximum response body size in bytes (default: :infinity)
    * `:max_request_target_bytes` - Maximum request path/query bytes (default: 8KB)
    * `:max_request_header_line_bytes` - Maximum single request header bytes (default: 8KB)
    * `:max_request_header_bytes` - Maximum total request header bytes (default: 64KB)
    * `:max_request_headers` - Maximum request header count (default: 100)
    * `:max_response_header_bytes` - Maximum backend response header bytes (default: 64KB)
    * `:forwarded_headers` - `:append`, `:replace`, or `false` for X-Forwarded-* behavior (default: :append)
    * `:protocols` - List of supported upstream protocols (default: [:http1])
    * `:max_websocket_frame_size` - Maximum WebSocket frame/message size (default: 16MB)

  ## Connection Pooling

  ReverseIt uses Finch for HTTP requests, which provides automatic connection pooling:

  - **Pool Size**: 50 connections per backend by default
  - **Reuse**: Connections are automatically reused across requests
  - **HTTP/2 Support**: Upstream HTTP/2 can be enabled with `protocols: [:http1, :http2]`
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

      # Configure timeouts and HTTP protocols
      forward "/", ReverseIt,
        name: MyApp.ReverseProxy,
        backend: "https://backend:443",
        upstream_idle_timeout: 60_000,
        protocols: [:http1, :http2]

  ### Customizing Requests and Responses

  You can wrap ReverseIt in your own Plug to modify request/response headers,
  add authentication, logging, etc. Use `Plug.Conn.register_before_send/2` to
  modify responses before they're sent to the client.

      defmodule MyApp.APIProxy do
        @behaviour Plug


        def init(opts), do: opts

        def call(conn, _opts) do
          # Modify request before proxying
          conn
          |> Plug.Conn.put_req_header("x-api-key", "...")
          # Register callback to modify response after backend responds
          |> Plug.Conn.register_before_send(fn conn ->
            conn
            |> Plug.Conn.put_resp_header("x-proxy-by", "MyApp")
            |> Plug.Conn.put_resp_header("x-proxy-version", "1.0")
            |> log_request()
          end)
          # Proxy to backend
          |> ReverseIt.call(
            ReverseIt.init(
              name: MyApp.ReverseProxy,
              backend: "http://backend-api:4000",
              strip_path: "/api"
            )
          )
        end

        defp log_request(conn) do
          Logger.info("Proxied \#{conn.method} \#{conn.request_path} → \#{conn.status}")
          conn
        end
      end

      # In your router:
      scope "/api" do
        forward "/", MyApp.APIProxy
      end
  """

  @behaviour Plug

  require Logger
  alias ReverseIt.{Config, Headers, HTTPProxy, WebSocketProxy}

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
    * `:connect_timeout` - Backend connection timeout in ms (default: 5_000)
    * `:conn_max_idle_time` - Idle timeout for pooled backend HTTP/1 connections (default: 90_000)
    * `:protocols` - Upstream protocols for pooled Finch requests (default: [:http1])
  """
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, 50)
    pool_count = Keyword.get(opts, :pool_count, 1)
    connect_timeout = Keyword.get(opts, :connect_timeout, 5_000)
    conn_max_idle_time = Keyword.get(opts, :conn_max_idle_time, 90_000)
    protocols = Keyword.get(opts, :protocols, [:http1])
    verify_tls = Keyword.get(opts, :verify_tls, true)

    transport_opts =
      [timeout: connect_timeout]
      |> maybe_disable_tls_verification(verify_tls)

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
                 protocols: protocols,
                 conn_max_idle_time: conn_max_idle_time,
                 conn_opts: [
                   transport_opts: transport_opts
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
      case Headers.validate_client_request(conn, config) do
        :ok ->
          if websocket_upgrade?(conn) do
            # Handle WebSocket upgrade
            handle_websocket(conn, config)
          else
            # Handle regular HTTP request
            HTTPProxy.proxy(conn, config)
          end

        {:error, reason} ->
          send_client_request_error(conn, reason)
      end

    # Ensure the connection is halted after proxying
    Plug.Conn.halt(conn)
  end

  # Private functions

  defp websocket_upgrade?(conn) do
    # Check for WebSocket upgrade headers
    connection_header? =
      conn
      |> Plug.Conn.get_req_header("connection")
      |> Enum.flat_map(&Plug.Conn.Utils.list/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.any?(&(&1 == "upgrade"))

    upgrade_header? =
      conn
      |> Plug.Conn.get_req_header("upgrade")
      |> Enum.map(&String.downcase/1)
      |> Enum.member?("websocket")

    connection_header? && upgrade_header?
  end

  defp handle_websocket(conn, config) do
    client = %{
      headers: conn.req_headers,
      remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      scheme: Atom.to_string(conn.scheme),
      host: forwarded_host(conn)
    }

    # Prepare options for WebSocket proxy
    opts = [
      config: config,
      client: client,
      path: conn.request_path,
      query_string: conn.query_string
    ]

    connection_opts =
      [
        timeout: config.websocket_idle_timeout,
        compress: config.websocket_compress,
        max_frame_size: config.max_websocket_frame_size,
        validate_utf8: config.websocket_validate_utf8,
        validate_text_frames: config.websocket_validate_utf8
      ]
      |> maybe_put_opt(:fullsweep_after, config.websocket_fullsweep_after)
      |> maybe_put_opt(:max_heap_size, config.websocket_max_heap_size)

    # Upgrade connection using WebSockAdapter
    # This will call WebSocketProxy.init/1 and handle the WebSocket lifecycle
    try do
      WebSockAdapter.upgrade(conn, WebSocketProxy, opts, connection_opts)
    rescue
      error in WebSockAdapter.UpgradeError ->
        Logger.debug("Invalid WebSocket upgrade request: #{Exception.message(error)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(400, "Bad Request: invalid WebSocket upgrade")

      error ->
        Logger.debug("Failed to upgrade WebSocket connection: #{inspect(error)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(502, "Bad Gateway: WebSocket upgrade failed")
    end
  end

  defp send_client_request_error(conn, :request_target_too_large) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/plain")
    |> Plug.Conn.send_resp(414, "URI Too Long")
  end

  defp send_client_request_error(conn, reason)
       when reason in [
              :too_many_request_headers,
              :request_headers_too_large,
              :request_header_line_too_large
            ] do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/plain")
    |> Plug.Conn.send_resp(431, "Request Header Fields Too Large")
  end

  defp maybe_disable_tls_verification(transport_opts, false),
    do: Keyword.put(transport_opts, :verify, :verify_none)

  defp maybe_disable_tls_verification(transport_opts, _verify_tls), do: transport_opts

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp forwarded_host(conn) do
    case Plug.Conn.get_req_header(conn, "host") do
      [host | _] -> host
      [] -> nil
    end
  end
end
