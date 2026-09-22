defmodule ReverseIt.HTTPProxy do
  @moduledoc """
  Handles HTTP request proxying using Finch for pooled requests and Mint for
  streaming request bodies.
  """

  require Logger
  alias ReverseIt.{Config, Headers, ResponseStream, Upstream}

  @doc """
  Proxies an HTTP request to the backend.
  """
  @spec proxy(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def proxy(conn, %Config{} = config) do
    case request(conn, config) do
      {:ok, conn, _state} ->
        conn

      {:buffered, response, conn, _state} ->
        conn
        |> Headers.put_response_headers(response.headers)
        |> Plug.Conn.send_resp(response.status, response.body)

      {:error, reason, conn, _state} ->
        send_proxy_error(conn, config, reason)
    end
  end

  @doc false
  def request(conn, %Config{} = config) do
    with :ok <- validate_content_length(conn, config) do
      url = build_url(config, conn.request_path, conn.query_string)
      headers = Headers.request_headers(conn, config)

      headers =
        if is_binary(config.request_body),
          do: Enum.reject(headers, fn {name, _} -> name == "content-length" end),
          else: headers

      case read_request_body(conn, config) do
        {:ok, body, conn} ->
          if within_request_body_limit?(byte_size(body), config) do
            proxy_buffered_request(conn, url, headers, body, config)
          else
            request_error(conn, config, :request_body_too_large)
          end

        {:more, first_chunk, conn} ->
          if within_request_body_limit?(byte_size(first_chunk), config) do
            Logger.debug("Request body exceeds buffer threshold, using streaming proxy")

            case config.upstream_connection do
              :pooled -> stream_request_with_finch(conn, url, headers, first_chunk, config)
              :one_shot -> stream_request_with_mint(conn, url, headers, first_chunk, config)
            end
          else
            request_error(conn, config, :request_body_too_large)
          end

        {:error, reason} ->
          Logger.error("Failed to read request body: #{inspect(reason)}")
          request_error(conn, config, {:request_body_read_failed, reason})
      end
    else
      {:error, :request_body_too_large} ->
        request_error(conn, config, :request_body_too_large)

      {:error, :invalid_content_length} ->
        request_error(conn, config, :invalid_content_length)
    end
  end

  defp read_request_body(conn, %{request_body: body}) when is_binary(body), do: {:ok, body, conn}

  defp read_request_body(conn, config),
    do: Plug.Conn.read_body(conn, first_body_read_opts(config))

  defp request_error(conn, config, reason),
    do: ResponseStream.fail(ResponseStream.new(conn, config), reason)

  defp validate_content_length(_conn, %{request_body: body}) when is_binary(body), do: :ok
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

  defp proxy_buffered_request(conn, url, headers, body, %{upstream_connection: :pooled} = config) do
    request = Finch.build(conn.method, url, headers, body)
    stream_response_with_finch(conn, request, config)
  end

  defp proxy_buffered_request(
         conn,
         url,
         headers,
         body,
         %{upstream_connection: :one_shot} = config
       ) do
    request_with_mint(conn, url, headers, body, config)
  end

  defp stream_response_with_finch(conn, request, config) do
    stream_response_with_finch(conn, request, config, config.response_header_retries)
  end

  defp stream_response_with_finch(conn, request, config, retries_left) do
    acc = response_acc(conn, config)
    do_stream_response_with_finch(request, acc, retries_left)
  end

  defp response_acc(conn, config), do: ResponseStream.new(conn, config)

  defp do_stream_response_with_finch(request, acc, retries_left) do
    config = acc.config
    opts = [pool_timeout: config.pool_timeout, receive_timeout: config.upstream_idle_timeout]

    case Finch.stream_while(request, config.name, acc, &ResponseStream.event/2, opts) do
      {:ok, acc} ->
        ResponseStream.finish(acc)

      {:error, reason, acc} ->
        if is_nil(config.response_handler) and not acc.sent? and
             retry_response_headers?(acc.method, reason, retries_left) do
          stream_response_with_finch(acc.conn, request, config, retries_left - 1)
        else
          ResponseStream.fail(acc, acc.error || reason)
        end
    end
  end

  defp send_proxy_error(conn, _config, :invalid_content_length),
    do: send_error_response(conn, 400, "Bad Request")

  defp send_proxy_error(conn, _config, {:response_headers, _reason}),
    do: send_error_response(conn, 504, "Gateway Timeout")

  defp send_proxy_error(conn, _config, :response_buffer_too_large),
    do: send_error_response(conn, 502, "Bad Gateway: Response buffer too large")

  defp send_proxy_error(conn, _config, :response_body_too_large) do
    send_error_response(conn, 502, "Bad Gateway: Response too large")
  end

  defp send_proxy_error(conn, _config, :response_headers_too_large) do
    send_error_response(conn, 502, "Bad Gateway: Response headers too large")
  end

  defp send_proxy_error(conn, _config, :invalid_response_header) do
    send_error_response(conn, 502, "Bad Gateway: Invalid response header")
  end

  defp send_proxy_error(conn, _config, :request_body_too_large) do
    send_error_response(conn, 413, "Payload Too Large")
  end

  defp send_proxy_error(conn, _config, {:request_body_read_failed, _reason}) do
    send_error_response(conn, 400, "Bad Request")
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

    %URI{
      scheme: scheme,
      host: config.host,
      port: config.port,
      path: target_path,
      query: if(query_string in [nil, ""], do: nil, else: query_string)
    }
    |> URI.to_string()
  end

  defp stream_request_with_finch(conn, url, headers, first_chunk, config) do
    acc =
      conn
      |> response_acc(config)
      |> Map.merge(%{
        request_body_chunk: first_chunk,
        request_body_done?: false,
        request_bytes: byte_size(first_chunk)
      })

    request = Finch.build(conn.method, url, headers, {:stream, &next_request_body/1})
    do_stream_response_with_finch(request, acc, 0)
  end

  defp next_request_body(%{request_body_chunk: chunk} = acc) when is_binary(chunk) do
    {:data, chunk, %{acc | request_body_chunk: nil}}
  end

  defp next_request_body(%{request_body_done?: true} = acc), do: {:done, acc}

  defp next_request_body(acc) do
    opts = [
      length: acc.config.request_body_chunk_size,
      read_length: acc.config.request_body_chunk_size,
      read_timeout: acc.config.request_body_read_timeout
    ]

    case Plug.Conn.read_body(acc.conn, opts) do
      {:more, chunk, conn} ->
        continue_request_body(acc, conn, chunk, false)

      {:ok, chunk, conn} ->
        continue_request_body(acc, conn, chunk, true)

      {:error, reason} ->
        {:halt, %{acc | error: {:request_body_read_failed, reason}}}
    end
  end

  defp continue_request_body(acc, conn, chunk, done?) do
    request_bytes = acc.request_bytes + byte_size(chunk)
    acc = %{acc | conn: conn, request_body_done?: done?, request_bytes: request_bytes}

    case ensure_request_body_limit(request_bytes, acc.config) do
      :ok when chunk == "" and done? -> {:done, acc}
      :ok -> {:data, chunk, acc}
      {:error, :request_body_too_large} -> {:halt, %{acc | error: :request_body_too_large}}
    end
  end

  defp stream_request_with_mint(conn, url, headers, first_chunk, config) do
    uri = URI.parse(url)
    path = uri.path || "/"
    path = if uri.query, do: "#{path}?#{uri.query}", else: path

    case Upstream.connect(config, mode: :passive) do
      {:ok, mint_conn} ->
        try do
          do_stream_request(conn, mint_conn, path, headers, first_chunk, config)
        after
          Mint.HTTP.close(mint_conn)
        end

      {:error, reason} ->
        Logger.error("Failed to connect to backend for streaming: #{inspect(reason)}")
        request_error(conn, config, reason)
    end
  end

  defp request_with_mint(conn, url, headers, body, config) do
    uri = URI.parse(url)
    path = uri.path || "/"
    path = if uri.query, do: "#{path}?#{uri.query}", else: path

    case Upstream.connect(config, mode: :passive) do
      {:ok, mint_conn} ->
        try do
          case Mint.HTTP.request(mint_conn, conn.method, path, headers, body) do
            {:ok, mint_conn, ref} ->
              stream_response_with_mint(conn, mint_conn, ref, config)

            {:error, _mint_conn, reason} ->
              Logger.error("Failed to send one-shot request: #{inspect(reason)}")
              request_error(conn, config, reason)
          end
        after
          Mint.HTTP.close(mint_conn)
        end

      {:error, reason} ->
        Logger.error("Failed to connect one-shot upstream: #{inspect(reason)}")
        request_error(conn, config, reason)
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
            request_error(conn, config, :request_body_too_large)

          {:error, reason} ->
            Logger.error("Failed to stream request body: #{inspect(reason)}")
            request_error(conn, config, reason)
        end

      {:error, _mint_conn, reason} ->
        Logger.error("Failed to start streaming request: #{inspect(reason)}")
        request_error(conn, config, reason)
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

  defp stream_response_with_mint(conn, mint_conn, ref, config) do
    receive_response(response_acc(conn, config), mint_conn, ref)
  end

  defp receive_response(acc, mint_conn, ref) do
    timeout =
      if not acc.headers_received?,
        do: acc.config.response_header_timeout,
        else: acc.config.upstream_idle_timeout

    case Mint.HTTP.recv(mint_conn, 0, timeout) do
      {:ok, mint_conn, responses} ->
        case process_responses(acc, responses, ref) do
          {:cont, acc} -> receive_response(acc, mint_conn, ref)
          {:done, acc} -> ResponseStream.finish(acc)
          {:halt, acc} -> ResponseStream.fail(acc, acc.error)
        end

      {:error, _mint_conn, reason, responses} ->
        case process_responses(acc, responses, ref) do
          {:done, acc} -> ResponseStream.finish(acc)
          {_, acc} -> ResponseStream.fail(acc, acc.error || mint_receive_error(acc, reason))
        end
    end
  end

  defp process_responses(acc, [], _ref), do: {:cont, acc}
  defp process_responses(acc, [{:done, ref} | _], ref), do: {:done, acc}

  defp process_responses(acc, [{:error, ref, reason} | _], ref),
    do: {:halt, %{acc | error: mint_receive_error(acc, reason)}}

  defp process_responses(acc, [{kind, ref, value} | rest], ref)
       when kind in [:status, :headers, :data, :trailers] do
    case ResponseStream.event({kind, value}, acc) do
      {:cont, acc} -> process_responses(acc, rest, ref)
      {:halt, acc} -> {:halt, acc}
    end
  end

  defp process_responses(acc, [_ | rest], ref), do: process_responses(acc, rest, ref)

  # Keep the existing Plug response for direct upstream failures while waiting
  # for headers. request/2 also exposes the phase to application error handlers.
  defp mint_receive_error(%{headers_received?: false}, reason),
    do: {:response_headers, reason}

  defp mint_receive_error(_acc, reason), do: reason

  defp retry_response_headers?(method, %Mint.TransportError{reason: reason}, retries_left)
       when method in ["GET", "HEAD"] and retries_left > 0 and
              reason in [:closed, :econnreset],
       do: true

  defp retry_response_headers?(method, %Finch.TransportError{reason: reason}, retries_left)
       when method in ["GET", "HEAD"] and retries_left > 0 and
              reason in [:closed, :econnreset],
       do: true

  defp retry_response_headers?(method, reason, retries_left)
       when method in ["GET", "HEAD"] and retries_left > 0 and
              reason in [:closed, :econnreset],
       do: true

  defp retry_response_headers?(_method, _reason, _retries_left), do: false

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
