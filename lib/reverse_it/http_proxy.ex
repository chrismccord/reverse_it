defmodule ReverseIt.HTTPProxy do
  @moduledoc """
  Handles HTTP request proxying using Mint HTTP client.
  Supports HTTP/1.1 and HTTP/2 with streaming responses.
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
  Proxies an HTTP request to the backend and streams the response back to the client.
  """
  @spec proxy(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def proxy(conn, %Config{} = config) do
    # Build target path
    target_path = Config.build_target_path(config, conn.request_path)

    # Add query string if present
    target_path =
      if conn.query_string && conn.query_string != "" do
        target_path <> "?" <> conn.query_string
      else
        target_path
      end

    # Prepare headers
    headers = prepare_headers(conn, config)

    # Read request body if present
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

    # Connect to backend
    scheme = Config.http_scheme(config)

    case Mint.HTTP.connect(scheme, config.host, config.port,
           protocols: config.protocols,
           transport_opts: [timeout: config.timeout]
         ) do
      {:ok, mint_conn} ->
        perform_request(conn, mint_conn, config, conn.method, target_path, headers, body)

      {:error, reason} ->
        Logger.error("Failed to connect to backend: #{inspect(reason)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(502, "Bad Gateway: Unable to connect to backend")
    end
  end

  # Private functions

  defp perform_request(conn, mint_conn, config, method, path, headers, body) do
    # Make request to backend
    case Mint.HTTP.request(mint_conn, method, path, headers, body) do
      {:ok, mint_conn, request_ref} ->
        # Stream response back to client
        stream_response(conn, mint_conn, request_ref, config.timeout)

      {:error, mint_conn, reason} ->
        Mint.HTTP.close(mint_conn)
        Logger.error("Failed to send request to backend: #{inspect(reason)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(502, "Bad Gateway: Request failed")
    end
  end

  defp stream_response(conn, mint_conn, request_ref, timeout) do
    # Collect all response parts
    case receive_response(mint_conn, request_ref, timeout, [], nil, []) do
      {:ok, status, headers, body_chunks} ->
        Mint.HTTP.close(mint_conn)

        # Send response to client
        conn = %{conn | resp_headers: filter_response_headers(headers)}

        # If we have body chunks, send them
        if body_chunks != [] do
          body = IO.iodata_to_binary(body_chunks)
          Plug.Conn.send_resp(conn, status, body)
        else
          Plug.Conn.send_resp(conn, status, "")
        end

      {:error, reason} ->
        Mint.HTTP.close(mint_conn)
        Logger.error("Failed to receive response from backend: #{inspect(reason)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(502, "Bad Gateway: Response failed")
    end
  end

  defp receive_response(mint_conn, request_ref, timeout, acc_headers, status, body_chunks) do
    receive do
      message ->
        case Mint.HTTP.stream(mint_conn, message) do
          {:ok, mint_conn, responses} ->
            case process_responses(responses, request_ref, acc_headers, status, body_chunks) do
              {:done, status, headers, body_chunks} ->
                {:ok, status, headers, body_chunks}

              {:continue, acc_headers, status, body_chunks} ->
                receive_response(mint_conn, request_ref, timeout, acc_headers, status, body_chunks)

              {:error, reason} ->
                {:error, reason}
            end

          {:error, _mint_conn, reason, _responses} ->
            {:error, reason}

          :unknown ->
            # Not a Mint message, ignore
            receive_response(mint_conn, request_ref, timeout, acc_headers, status, body_chunks)
        end
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp process_responses([], _request_ref, acc_headers, status, body_chunks) do
    {:continue, acc_headers, status, body_chunks}
  end

  defp process_responses([response | rest], request_ref, acc_headers, status, body_chunks) do
    case response do
      {:status, ^request_ref, status_code} ->
        process_responses(rest, request_ref, acc_headers, status_code, body_chunks)

      {:headers, ^request_ref, headers} ->
        process_responses(rest, request_ref, acc_headers ++ headers, status, body_chunks)

      {:data, ^request_ref, data} ->
        process_responses(rest, request_ref, acc_headers, status, body_chunks ++ [data])

      {:done, ^request_ref} ->
        {:done, status, acc_headers, body_chunks}

      {:error, ^request_ref, reason} ->
        {:error, reason}

      _other ->
        # Ignore other messages
        process_responses(rest, request_ref, acc_headers, status, body_chunks)
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
