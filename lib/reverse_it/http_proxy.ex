defmodule ReverseIt.HTTPProxy do
  @moduledoc """
  Handles HTTP request proxying using Finch for pooled requests and Mint for
  streaming request bodies.
  """

  require Logger
  alias ReverseIt.{Config, Headers}

  @doc """
  Proxies an HTTP request to the backend.
  """
  @spec proxy(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def proxy(conn, %Config{} = config) do
    with :ok <- validate_content_length(conn, config) do
      url = build_url(config, conn.request_path, conn.query_string)
      headers = Headers.request_headers(conn, config)

      case Plug.Conn.read_body(conn, first_body_read_opts(config)) do
        {:ok, body, conn} ->
          if within_request_body_limit?(byte_size(body), config) do
            request = Finch.build(conn.method, url, headers, body)
            stream_response_with_finch(conn, request, config)
          else
            send_error_response(conn, 413, "Payload Too Large")
          end

        {:more, first_chunk, conn} ->
          if within_request_body_limit?(byte_size(first_chunk), config) do
            Logger.debug("Request body exceeds buffer threshold, using streaming proxy")
            stream_request_with_mint(conn, url, headers, first_chunk, config)
          else
            send_error_response(conn, 413, "Payload Too Large")
          end

        {:error, reason} ->
          Logger.error("Failed to read request body: #{inspect(reason)}")
          send_error_response(conn, 400, "Bad Request")
      end
    else
      {:error, :request_body_too_large} ->
        send_error_response(conn, 413, "Payload Too Large")

      {:error, :invalid_content_length} ->
        send_error_response(conn, 400, "Bad Request")
    end
  end

  defp validate_content_length(_conn, %{max_request_body_size: :infinity}), do: :ok

  defp validate_content_length(conn, config) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [] ->
        :ok

      values ->
        values
        |> Enum.map(&Integer.parse/1)
        |> Enum.reduce_while(:ok, fn
          {length, ""}, :ok when length <= config.max_request_body_size ->
            {:cont, :ok}

          {length, ""}, :ok when length > config.max_request_body_size ->
            {:halt, {:error, :request_body_too_large}}

          _invalid, :ok ->
            {:halt, {:error, :invalid_content_length}}
        end)
    end
  end

  defp first_body_read_opts(config) do
    length =
      case config.max_request_body_size do
        :infinity -> config.request_body_buffer_size
        0 -> 1
        max -> min(config.request_body_buffer_size, max)
      end

    [
      length: length,
      read_length: min(config.request_body_chunk_size, length),
      read_timeout: config.request_body_read_timeout
    ]
  end

  defp within_request_body_limit?(_bytes, %{max_request_body_size: :infinity}), do: true
  defp within_request_body_limit?(bytes, config), do: bytes <= config.max_request_body_size

  defp stream_response_with_finch(conn, request, config) do
    acc = %{
      conn: conn,
      config: config,
      method: conn.method,
      status: nil,
      headers: [],
      sent?: false,
      response_bytes: 0,
      error: nil
    }

    opts = [
      pool_timeout: config.pool_timeout,
      receive_timeout: config.upstream_idle_timeout
    ]

    case Finch.stream_while(request, config.name, acc, &handle_finch_response/2, opts) do
      {:ok, %{sent?: false, error: nil} = acc} ->
        send_unsent_response(acc)

      {:ok, %{sent?: true, conn: conn}} ->
        conn

      {:ok, %{sent?: false, error: reason, conn: conn, config: config}} ->
        send_proxy_error(conn, config, reason)

      {:error, reason, %{sent?: false, conn: conn, config: config}} ->
        Logger.error("Failed to proxy request: #{inspect(reason)}")
        send_configured_bad_gateway(conn, config)

      {:error, reason, %{sent?: true, conn: conn}} ->
        Logger.error("Upstream stream failed after response started: #{inspect(reason)}")
        conn
    end
  end

  defp handle_finch_response({:status, status}, acc), do: {:cont, %{acc | status: status}}

  defp handle_finch_response({:headers, headers}, acc) do
    acc = %{acc | headers: acc.headers ++ headers}

    cond do
      response_content_length_exceeds?(acc.headers, acc.config) ->
        {:halt, %{acc | error: :response_body_too_large}}

      not send_body?(acc.method, acc.status) ->
        send_empty_response(acc)

      acc.config.max_response_body_size == :infinity ->
        send_chunked_headers(acc)

      true ->
        {:cont, acc}
    end
  end

  defp handle_finch_response({:data, data}, acc) do
    acc = maybe_count_response_bytes(acc, byte_size(data))

    cond do
      acc.error ->
        {:halt, acc}

      not send_body?(acc.method, acc.status) ->
        {:cont, acc}

      true ->
        with {:cont, acc} <- ensure_chunked_response_started(acc) do
          case Plug.Conn.chunk(acc.conn, data) do
            {:ok, conn} -> {:cont, %{acc | conn: conn}}
            {:error, reason} -> {:halt, %{acc | error: reason}}
          end
        end
    end
  end

  defp handle_finch_response({:trailers, _trailers}, acc), do: {:cont, acc}

  defp response_content_length_exceeds?(_headers, %{max_response_body_size: :infinity}), do: false

  defp response_content_length_exceeds?(headers, config) do
    Enum.any?(headers, fn
      {name, value} ->
        String.downcase(name) == "content-length" and
          match?({length, ""} when length > config.max_response_body_size, Integer.parse(value))
    end)
  end

  defp maybe_count_response_bytes(acc, bytes) do
    response_bytes = acc.response_bytes + bytes

    if acc.config.max_response_body_size != :infinity and
         response_bytes > acc.config.max_response_body_size do
      %{acc | response_bytes: response_bytes, error: :response_body_too_large}
    else
      %{acc | response_bytes: response_bytes}
    end
  end

  defp send_unsent_response(%{status: nil, conn: conn, config: config}) do
    Logger.error("Backend closed without a response status")
    send_configured_bad_gateway(conn, config)
  end

  defp send_unsent_response(acc) do
    result =
      if send_body?(acc.method, acc.status) do
        send_chunked_headers(acc)
      else
        send_empty_response(acc)
      end

    case result do
      {:cont, %{conn: conn}} ->
        conn

      {:halt, %{conn: conn, config: config, error: reason}} ->
        send_proxy_error(conn, config, reason)
    end
  end

  defp ensure_chunked_response_started(%{sent?: true} = acc), do: {:cont, acc}
  defp ensure_chunked_response_started(acc), do: send_chunked_headers(acc)

  defp send_chunked_headers(%{sent?: true} = acc), do: {:cont, acc}

  defp send_chunked_headers(%{status: status} = acc) when is_integer(status) do
    with {:ok, headers} <- Headers.response_headers(acc.headers, acc.config, mode: :chunked) do
      conn =
        acc.conn
        |> Headers.put_response_headers(headers)
        |> Plug.Conn.send_chunked(status)

      {:cont, %{acc | conn: conn, sent?: true}}
    else
      {:error, reason} -> {:halt, %{acc | error: reason}}
    end
  end

  defp send_chunked_headers(acc), do: {:halt, %{acc | error: :missing_response_status}}

  defp send_empty_response(%{sent?: true} = acc), do: {:cont, acc}

  defp send_empty_response(%{status: status} = acc) when is_integer(status) do
    mode = if acc.method == "HEAD", do: :identity, else: :chunked

    with {:ok, headers} <- Headers.response_headers(acc.headers, acc.config, mode: mode) do
      conn =
        acc.conn
        |> Headers.put_response_headers(headers)
        |> Plug.Conn.send_resp(status, "")

      {:cont, %{acc | conn: conn, sent?: true}}
    else
      {:error, reason} -> {:halt, %{acc | error: reason}}
    end
  end

  defp send_empty_response(acc), do: {:halt, %{acc | error: :missing_response_status}}

  defp send_body?("HEAD", _status), do: false
  defp send_body?(_method, status) when status in 100..199, do: false
  defp send_body?(_method, status) when status in [204, 304], do: false
  defp send_body?(_method, _status), do: true

  defp send_proxy_error(conn, _config, :response_body_too_large) do
    send_error_response(conn, 502, "Bad Gateway: Response too large")
  end

  defp send_proxy_error(conn, _config, :response_headers_too_large) do
    send_error_response(conn, 502, "Bad Gateway: Response headers too large")
  end

  defp send_proxy_error(conn, _config, :invalid_response_header) do
    send_error_response(conn, 502, "Bad Gateway: Invalid response header")
  end

  defp send_proxy_error(conn, config, reason) do
    Logger.error("Failed to proxy response: #{inspect(reason)}")
    send_configured_bad_gateway(conn, config)
  end

  defp build_url(config, request_path, query_string) do
    target_path = Config.build_target_path(config, request_path)

    scheme =
      case config.scheme do
        :https -> "https"
        :wss -> "https"
        _ -> "http"
      end

    url = "#{scheme}://#{config.host}:#{config.port}#{target_path}"

    if query_string && query_string != "" do
      url <> "?" <> query_string
    else
      url
    end
  end

  defp stream_request_with_mint(conn, url, headers, first_chunk, config) do
    uri = URI.parse(url)
    scheme = if config.scheme in [:https, :wss], do: :https, else: :http
    path = uri.path || "/"
    path = if uri.query, do: "#{path}?#{uri.query}", else: path

    connect_opts = [
      protocols: config.protocols,
      transport_opts: Config.transport_opts(config)
    ]

    case Mint.HTTP.connect(scheme, config.host, config.port, connect_opts) do
      {:ok, mint_conn} ->
        result = do_stream_request(conn, mint_conn, path, headers, first_chunk, config)
        Mint.HTTP.close(mint_conn)
        result

      {:error, reason} ->
        Logger.error("Failed to connect to backend for streaming: #{inspect(reason)}")
        send_configured_bad_gateway(conn, config)
    end
  end

  defp do_stream_request(conn, mint_conn, path, headers, first_chunk, config) do
    case Mint.HTTP.request(mint_conn, conn.method, path, headers, :stream) do
      {:ok, mint_conn, ref} ->
        with :ok <- ensure_request_body_limit(byte_size(first_chunk), config),
             {:ok, mint_conn} <- stream_mint_request_body(mint_conn, ref, first_chunk),
             {:ok, plug_conn, mint_conn} <-
               stream_request_body(conn, mint_conn, ref, config, byte_size(first_chunk)),
             {:ok, mint_conn} <- stream_mint_request_body(mint_conn, ref, :eof) do
          stream_response_with_mint(plug_conn, mint_conn, ref, config)
        else
          {:error, :request_body_too_large} ->
            send_error_response(conn, 413, "Payload Too Large")

          {:error, reason} ->
            Logger.error("Failed to stream request body: #{inspect(reason)}")
            send_configured_bad_gateway(conn, config)
        end

      {:error, _mint_conn, reason} ->
        Logger.error("Failed to start streaming request: #{inspect(reason)}")
        send_configured_bad_gateway(conn, config)
    end
  end

  defp stream_mint_request_body(mint_conn, ref, chunk) do
    case Mint.HTTP.stream_request_body(mint_conn, ref, chunk) do
      {:ok, mint_conn} -> {:ok, mint_conn}
      {:error, _mint_conn, reason} -> {:error, reason}
    end
  end

  defp stream_request_body(plug_conn, mint_conn, ref, config, bytes_seen) do
    opts = [
      length: config.request_body_chunk_size,
      read_length: config.request_body_chunk_size,
      read_timeout: config.request_body_read_timeout
    ]

    case Plug.Conn.read_body(plug_conn, opts) do
      {:more, chunk, plug_conn} ->
        bytes_seen = bytes_seen + byte_size(chunk)

        with :ok <- ensure_request_body_limit(bytes_seen, config),
             {:ok, mint_conn} <- stream_mint_request_body(mint_conn, ref, chunk) do
          stream_request_body(plug_conn, mint_conn, ref, config, bytes_seen)
        end

      {:ok, final_chunk, plug_conn} ->
        bytes_seen = bytes_seen + byte_size(final_chunk)

        with :ok <- ensure_request_body_limit(bytes_seen, config),
             {:ok, mint_conn} <- stream_mint_request_body(mint_conn, ref, final_chunk) do
          {:ok, plug_conn, mint_conn}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_request_body_limit(_bytes, %{max_request_body_size: :infinity}), do: :ok

  defp ensure_request_body_limit(bytes, config) do
    if bytes <= config.max_request_body_size do
      :ok
    else
      {:error, :request_body_too_large}
    end
  end

  defp stream_response_with_mint(plug_conn, mint_conn, ref, config) do
    case receive_response_headers(mint_conn, ref, config.response_header_timeout, nil, [], config) do
      {:ok, mint_conn, status, headers, remaining_responses} ->
        with false <- response_content_length_exceeds?(headers, config),
             {:ok, headers} <- Headers.response_headers(headers, config, mode: :chunked) do
          plug_conn =
            plug_conn
            |> Headers.put_response_headers(headers)
            |> Plug.Conn.send_chunked(status)

          acc = %{conn: plug_conn, bytes: 0, config: config, error: nil}

          case process_body_responses(acc, remaining_responses, ref) do
            {:continue, acc} -> receive_response_body(acc, mint_conn, ref, config)
            {:done, acc} -> acc.conn
            {:error, reason, acc} -> finish_mint_stream_error(reason, acc)
          end
        else
          true ->
            send_error_response(plug_conn, 502, "Bad Gateway: Response too large")

          {:error, reason} ->
            send_proxy_error(plug_conn, config, reason)
        end

      {:error, reason} ->
        Logger.error("Failed to receive response headers: #{inspect(reason)}")
        send_error_response(plug_conn, 504, "Gateway Timeout")
    end
  end

  defp receive_response_headers(mint_conn, ref, timeout, status, headers, config) do
    receive do
      message ->
        case Mint.HTTP.stream(mint_conn, message) do
          {:ok, mint_conn, responses} ->
            case process_header_responses(responses, ref, status, headers, config) do
              {:continue, status, headers} ->
                receive_response_headers(mint_conn, ref, timeout, status, headers, config)

              {:headers_complete, status, headers, remaining_responses} ->
                {:ok, mint_conn, status, headers, remaining_responses}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, _mint_conn, reason, _responses} ->
            {:error, reason}

          :unknown ->
            receive_response_headers(mint_conn, ref, timeout, status, headers, config)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp process_header_responses([], _ref, status, headers, _config) do
    {:continue, status, headers}
  end

  defp process_header_responses([response | rest], ref, status, headers, config) do
    case response do
      {:status, ^ref, status_code} ->
        process_header_responses(rest, ref, status_code, headers, config)

      {:headers, ^ref, new_headers} ->
        headers = headers ++ new_headers

        if header_block_within_limit?(headers, config) do
          if status != nil do
            {:headers_complete, status, headers, rest}
          else
            process_header_responses(rest, ref, status, headers, config)
          end
        else
          {:error, :response_headers_too_large}
        end

      {:data, ^ref, _data} when status != nil ->
        {:headers_complete, status, headers, [response | rest]}

      {:error, ^ref, reason} ->
        {:error, reason}

      _other ->
        process_header_responses(rest, ref, status, headers, config)
    end
  end

  defp header_block_within_limit?(headers, config) do
    Enum.reduce(headers, 0, fn {name, value}, total ->
      total + byte_size(name) + 2 + byte_size(value)
    end) <= config.max_response_header_bytes
  end

  defp receive_response_body(acc, mint_conn, ref, config) do
    receive do
      message ->
        case Mint.HTTP.stream(mint_conn, message) do
          {:ok, mint_conn, responses} ->
            case process_body_responses(acc, responses, ref) do
              {:continue, acc} -> receive_response_body(acc, mint_conn, ref, config)
              {:done, acc} -> acc.conn
              {:error, reason, acc} -> finish_mint_stream_error(reason, acc)
            end

          {:error, _mint_conn, reason, _responses} ->
            Logger.error("Mint stream error: #{inspect(reason)}")
            acc.conn

          :unknown ->
            receive_response_body(acc, mint_conn, ref, config)
        end
    after
      config.upstream_idle_timeout ->
        Logger.error("Timeout receiving response body")
        acc.conn
    end
  end

  defp process_body_responses(acc, [], _ref), do: {:continue, acc}

  defp process_body_responses(acc, [response | rest], ref) do
    case response do
      {:data, ^ref, data} ->
        acc = maybe_count_mint_response_bytes(acc, byte_size(data))

        cond do
          acc.error ->
            {:error, acc.error, acc}

          true ->
            case Plug.Conn.chunk(acc.conn, data) do
              {:ok, conn} -> process_body_responses(%{acc | conn: conn}, rest, ref)
              {:error, reason} -> {:error, reason, acc}
            end
        end

      {:done, ^ref} ->
        {:done, acc}

      {:error, ^ref, reason} ->
        {:error, reason, acc}

      _other ->
        process_body_responses(acc, rest, ref)
    end
  end

  defp maybe_count_mint_response_bytes(acc, bytes) do
    total = acc.bytes + bytes

    if acc.config.max_response_body_size != :infinity and
         total > acc.config.max_response_body_size do
      %{acc | bytes: total, error: :response_body_too_large}
    else
      %{acc | bytes: total}
    end
  end

  defp finish_mint_stream_error(:response_body_too_large, acc) do
    Logger.error("Backend response exceeded max_response_body_size")
    acc.conn
  end

  defp finish_mint_stream_error(reason, acc) do
    Logger.error("Error streaming response body: #{inspect(reason)}")
    acc.conn
  end

  defp send_configured_bad_gateway(conn, config) do
    {status, body} = config.error_response
    send_error_response(conn, status, body)
  end

  defp send_error_response(conn, status, message) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/plain")
    |> Plug.Conn.send_resp(status, message)
  end
end
