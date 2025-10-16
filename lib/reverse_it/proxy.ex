defmodule ReverseIt.Proxy do
  @moduledoc """
  Main Plug module for the reverse proxy.

  This plug can be inserted into any Plug or Phoenix pipeline to proxy
  both HTTP and WebSocket connections to a backend server.

  ## Usage

      # In a Phoenix router
      scope "/api" do
        forward "/", ReverseIt.Proxy,
          backend: "http://localhost:4000",
          strip_path: "/api"
      end

      # In a Plug pipeline
      plug ReverseIt.Proxy,
        backend: "ws://localhost:4000/socket"

  ## Options

    * `:backend` - Backend URL (required). Can be http://, https://, ws://, or wss://
    * `:strip_path` - Path prefix to strip from incoming requests before proxying
    * `:timeout` - Request timeout in milliseconds (default: 30_000)
    * `:protocols` - List of supported HTTP protocols (default: [:http1, :http2])

  ## Features

    * Full HTTP/1.1 and HTTP/2 support
    * WebSocket proxying with bidirectional frame forwarding
    * Automatic protocol detection (HTTP vs WebSocket)
    * Proper header forwarding and filtering
    * X-Forwarded-* header injection
    * Streaming request and response bodies

  """

  @behaviour Plug

  require Logger
  alias ReverseIt.{Config, HTTPProxy, WebSocketProxy}

  @impl Plug
  def init(opts) do
    case Config.parse(opts) do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise ArgumentError, "Invalid ReverseIt.Proxy configuration: #{reason}"
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
        # Log at debug level in test environment (known limitation)
        Logger.debug("Failed to upgrade WebSocket connection: #{inspect(error)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(502, "Bad Gateway: WebSocket upgrade failed")
    end
  end
end
