defmodule ReverseIt.HTTPProxy do
  @moduledoc """
  Handles HTTP request proxying using Finch HTTP client.
  Supports HTTP/1.1 and HTTP/2 with streaming responses, connection pooling,
  and automatic HTTP/2 multiplexing.
  """

  require Logger
  alias ReverseIt.Config

  # Hop-by-hop headers that should not be forwarded
  @hop_by_hop_headers [
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade"
  ]

  @doc """
  Proxies an HTTP request to the backend using Finch connection pool.
  """
  @spec proxy(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def proxy(conn, %Config{} = config) do
    # Build target URL
    url = build_url(config, conn.request_path, conn.query_string)

    # Prepare headers
    headers = prepare_headers(conn, config)

    # Read request body if present with configured max size
    body_opts =
      case config.max_body_size do
        :infinity -> []
        max_size -> [length: max_size]
      end

    case Plug.Conn.read_body(conn, body_opts) do
      {:ok, body, conn} ->
        make_request(conn, url, headers, body, config)

      {:more, _partial, conn} ->
        # Body exceeds max_body_size
        Logger.warning("Request body exceeds max_body_size: #{config.max_body_size}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(413, "Request Entity Too Large")

      {:error, reason} ->
        Logger.error("Failed to read request body: #{inspect(reason)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(400, "Bad Request")
    end
  end

  defp make_request(conn, url, headers, body, config) do
    # Build Finch request
    request = Finch.build(conn.method, url, headers, body)

    # Make request using the configured Finch pool
    case Finch.request(request, config.name, receive_timeout: config.timeout) do
      {:ok, response} ->
        # Send response to client
        conn = %{conn | resp_headers: filter_response_headers(response.headers)}
        Plug.Conn.send_resp(conn, response.status, response.body)

      {:error, reason} ->
        Logger.error("Failed to proxy request: #{inspect(reason)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(502, "Bad Gateway: Request failed")
    end
  end

  # Private functions

  defp build_url(config, request_path, query_string) do
    # Build target path
    target_path = Config.build_target_path(config, request_path)

    # Build scheme
    scheme =
      case config.scheme do
        :https -> "https"
        :wss -> "https"
        _ -> "http"
      end

    # Build base URL
    url = "#{scheme}://#{config.host}:#{config.port}#{target_path}"

    # Add query string if present
    if query_string && query_string != "" do
      url <> "?" <> query_string
    else
      url
    end
  end

  defp prepare_headers(conn, config) do
    conn.req_headers
    |> filter_hop_by_hop_headers()
    |> add_forwarded_headers(conn)
    |> replace_host_header(config)
    |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
  end

  defp filter_hop_by_hop_headers(headers) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(name) in @hop_by_hop_headers
    end)
  end

  defp add_forwarded_headers(headers, conn) do
    # Add X-Forwarded-For
    forwarded_for =
      case List.keyfind(headers, "x-forwarded-for", 0) do
        {_, existing} ->
          existing <> ", " <> to_string(:inet.ntoa(conn.remote_ip))

        nil ->
          to_string(:inet.ntoa(conn.remote_ip))
      end

    headers = List.keystore(headers, "x-forwarded-for", 0, {"x-forwarded-for", forwarded_for})

    # Add X-Forwarded-Proto
    proto = if conn.scheme == :https, do: "https", else: "http"
    headers = List.keystore(headers, "x-forwarded-proto", 0, {"x-forwarded-proto", proto})

    # Add X-Forwarded-Host
    case Plug.Conn.get_req_header(conn, "host") do
      [host | _] ->
        List.keystore(headers, "x-forwarded-host", 0, {"x-forwarded-host", host})

      [] ->
        headers
    end
  end

  defp replace_host_header(headers, config) do
    # Remove existing host header and add backend host
    headers = List.keydelete(headers, "host", 0)
    host = if config.port in [80, 443], do: config.host, else: "#{config.host}:#{config.port}"
    [{"host", host} | headers]
  end

  defp filter_response_headers(headers) do
    headers
    |> Enum.reject(fn {name, _value} ->
      String.downcase(name) in @hop_by_hop_headers
    end)
  end
end
