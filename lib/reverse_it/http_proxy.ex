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
        # Small body - use Finch with pooling (fast path)
        make_request(conn, url, headers, body, config)

      {:more, first_chunk, conn} ->
        # Large body exceeds max_body_size - fall back to Mint streaming
        Logger.info("Request body exceeds max_body_size (#{config.max_body_size}), using streaming proxy")
        stream_request_with_mint(conn, url, headers, first_chunk, config)

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

  # Streaming proxy implementation using raw Mint
  # Used when request body exceeds max_body_size

  defp stream_request_with_mint(conn, url, headers, first_chunk, config) do
    uri = URI.parse(url)
    scheme = if config.scheme in [:https, :wss], do: :https, else: :http
    path = uri.path || "/"
    path = if uri.query, do: "#{path}?#{uri.query}", else: path

    # Connect to backend with timeout
    connect_opts = [
      protocols: config.protocols,
      transport_opts: [timeout: config.connect_timeout || 5_000]
    ]

    case Mint.HTTP.connect(scheme, config.host, config.port, connect_opts) do
      {:ok, mint_conn} ->
        result = do_stream_request(conn, mint_conn, path, headers, first_chunk, config)
        # Always close the connection when done
        Mint.HTTP.close(mint_conn)
        result

      {:error, reason} ->
        Logger.error("Failed to connect to backend for streaming: #{inspect(reason)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(502, "Bad Gateway: Failed to connect")
    end
  end

  defp do_stream_request(conn, mint_conn, path, headers, first_chunk, config) do
    # Start the request with :stream to enable request body streaming
    case Mint.HTTP.request(mint_conn, conn.method, path, headers, :stream) do
      {:ok, mint_conn, ref} ->
        # Stream the first chunk we already read
        case Mint.HTTP.stream_request_body(mint_conn, ref, first_chunk) do
          {:ok, mint_conn} ->
            # Continue streaming the remaining body
            case stream_request_body(conn, mint_conn, ref, config.timeout) do
              {:ok, mint_conn} ->
                # Signal end of request body
                case Mint.HTTP.stream_request_body(mint_conn, ref, :eof) do
                  {:ok, mint_conn} ->
                    # Receive and stream response back to client
                    stream_response(conn, mint_conn, ref, config.timeout)

                  {:error, _mint_conn, reason} ->
                    Logger.error("Failed to finalize request body stream: #{inspect(reason)}")
                    send_error_response(conn, 502, "Bad Gateway: Failed to send request")
                end

              {:error, reason} ->
                Logger.error("Failed to stream request body: #{inspect(reason)}")
                send_error_response(conn, 502, "Bad Gateway: Failed to stream request body")
            end

          {:error, _mint_conn, reason} ->
            Logger.error("Failed to stream first chunk: #{inspect(reason)}")
            send_error_response(conn, 502, "Bad Gateway: Failed to stream request")
        end

      {:error, _mint_conn, reason} ->
        Logger.error("Failed to start streaming request: #{inspect(reason)}")
        send_error_response(conn, 502, "Bad Gateway: Failed to start request")
    end
  end

  defp stream_request_body(plug_conn, mint_conn, ref, timeout) do
    # Read chunks from the client and stream to backend
    stream_request_body_loop(plug_conn, mint_conn, ref, timeout, :os.system_time(:millisecond))
  end

  defp stream_request_body_loop(plug_conn, mint_conn, ref, timeout, start_time) do
    # Check timeout
    elapsed = :os.system_time(:millisecond) - start_time

    if elapsed > timeout do
      {:error, :timeout}
    else
      case Plug.Conn.read_body(plug_conn, length: 64_000) do
        {:more, chunk, plug_conn} ->
          case Mint.HTTP.stream_request_body(mint_conn, ref, chunk) do
            {:ok, mint_conn} ->
              # Continue reading more chunks
              stream_request_body_loop(plug_conn, mint_conn, ref, timeout, start_time)

            {:error, _mint_conn, reason} ->
              {:error, reason}
          end

        {:ok, final_chunk, _plug_conn} ->
          # Last chunk - stream it
          case Mint.HTTP.stream_request_body(mint_conn, ref, final_chunk) do
            {:ok, mint_conn} ->
              {:ok, mint_conn}

            {:error, _mint_conn, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp stream_response(plug_conn, mint_conn, ref, timeout) do
    # Receive response headers and stream body back to client
    case receive_response_headers(mint_conn, ref, timeout, nil, []) do
      {:ok, mint_conn, status, headers, remaining_responses} ->
        # Set response headers
        plug_conn = %{plug_conn | resp_headers: filter_response_headers(headers)}
        plug_conn = Plug.Conn.send_chunked(plug_conn, status)

        # Process any responses we got along with headers (like data)
        case process_body_responses(plug_conn, remaining_responses, ref) do
          {:continue, plug_conn} ->
            # Stream remaining response body
            receive_response_body(plug_conn, mint_conn, ref, timeout)

          {:done, plug_conn} ->
            # Response was complete
            plug_conn

          {:error, reason} ->
            Logger.error("Error processing initial body responses: #{inspect(reason)}")
            plug_conn
        end

      {:error, reason} ->
        Logger.error("Failed to receive response headers: #{inspect(reason)}")
        send_error_response(plug_conn, 502, "Bad Gateway: Failed to receive response")
    end
  end

  defp receive_response_headers(mint_conn, ref, timeout, status, headers) do
    receive do
      message ->
        case Mint.HTTP.stream(mint_conn, message) do
          {:ok, mint_conn, responses} ->
            case process_header_responses(responses, ref, status, headers) do
              {:continue, status, headers} ->
                receive_response_headers(mint_conn, ref, timeout, status, headers)

              {:headers_complete, status, headers, remaining_responses} ->
                {:ok, mint_conn, status, headers, remaining_responses}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, _mint_conn, reason, _responses} ->
            {:error, reason}

          :unknown ->
            receive_response_headers(mint_conn, ref, timeout, status, headers)
        end
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp process_header_responses([], _ref, status, headers) do
    {:continue, status, headers}
  end

  defp process_header_responses([response | rest], ref, status, headers) do
    case response do
      {:status, ^ref, status_code} ->
        process_header_responses(rest, ref, status_code, headers)

      {:headers, ^ref, new_headers} ->
        # Once we have headers and status, we're done with header phase
        # Return remaining responses to process as body
        if status != nil do
          {:headers_complete, status, headers ++ new_headers, rest}
        else
          process_header_responses(rest, ref, status, headers ++ new_headers)
        end

      {:data, ^ref, _data} ->
        # We got data, which means headers are complete
        # Return this response and rest for body processing
        {:headers_complete, status, headers, [response | rest]}

      {:error, ^ref, reason} ->
        {:error, reason}

      _other ->
        process_header_responses(rest, ref, status, headers)
    end
  end

  defp receive_response_body(plug_conn, mint_conn, ref, timeout) do
    receive do
      message ->
        case Mint.HTTP.stream(mint_conn, message) do
          {:ok, mint_conn, responses} ->
            case process_body_responses(plug_conn, responses, ref) do
              {:continue, plug_conn} ->
                receive_response_body(plug_conn, mint_conn, ref, timeout)

              {:done, plug_conn} ->
                plug_conn

              {:error, reason} ->
                Logger.error("Error streaming response body: #{inspect(reason)}")
                plug_conn
            end

          {:error, _mint_conn, reason, _responses} ->
            Logger.error("Mint stream error: #{inspect(reason)}")
            plug_conn

          :unknown ->
            receive_response_body(plug_conn, mint_conn, ref, timeout)
        end
    after
      timeout ->
        Logger.error("Timeout receiving response body")
        plug_conn
    end
  end

  defp process_body_responses(plug_conn, [], _ref) do
    {:continue, plug_conn}
  end

  defp process_body_responses(plug_conn, [response | rest], ref) do
    case response do
      {:data, ^ref, data} ->
        # Stream chunk to client
        case Plug.Conn.chunk(plug_conn, data) do
          {:ok, plug_conn} ->
            process_body_responses(plug_conn, rest, ref)

          {:error, reason} ->
            {:error, reason}
        end

      {:done, ^ref} ->
        # Response complete
        {:done, plug_conn}

      {:error, ^ref, reason} ->
        {:error, reason}

      _other ->
        process_body_responses(plug_conn, rest, ref)
    end
  end

  defp send_error_response(conn, status, message) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/plain")
    |> Plug.Conn.send_resp(status, message)
  end
end
