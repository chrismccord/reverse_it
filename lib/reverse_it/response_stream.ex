defmodule ReverseIt.ResponseStream do
  @moduledoc false

  require Logger
  alias ReverseIt.Headers

  def new(conn, config, response_handler \\ nil) do
    {handler, state} = response_handler || {nil, nil}

    %{
      conn: conn,
      config: config,
      method: conn.method,
      status: nil,
      headers_received?: false,
      headers: [],
      sent?: false,
      response_bytes: 0,
      output_bytes: 0,
      error: nil,
      handler: handler,
      handler_state: state,
      callbacks: %{},
      response_mode: :stream,
      buffer_limit: nil,
      chunks: []
    }
  end

  def event({:status, status}, acc), do: {:cont, %{acc | status: status}}

  # Mint emits chunked trailers as a second headers event. Like Finch's explicit
  # trailers event, these must not re-run the pre-commit callback or change mode.
  def event({:headers, _trailers}, %{headers_received?: true} = acc), do: {:cont, acc}

  def event({:headers, headers}, acc) do
    headers = acc.headers ++ headers

    case Headers.response_headers(headers, acc.config) do
      {:error, reason} ->
        halt(acc, reason)

      {:ok, _headers} when acc.status in 100..199 and acc.status != 101 ->
        {:cont, %{acc | status: nil, headers: []}}

      {:ok, headers} ->
        acc = %{acc | headers: headers, headers_received?: true}

        if send_body?(acc) and content_length_exceeds?(headers, acc.config.max_response_body_size) do
          halt(acc, :response_body_too_large)
        else
          prepare(acc)
        end
    end
  end

  def event({:data, data}, acc) do
    acc = %{acc | response_bytes: acc.response_bytes + byte_size(data)}

    cond do
      exceeds?(acc.response_bytes, acc.config.max_response_body_size) ->
        halt(acc, :response_body_too_large)

      not send_body?(acc) ->
        {:cont, acc}

      acc.response_mode == :buffer ->
        if acc.response_bytes > acc.buffer_limit do
          halt(acc, :response_buffer_too_large)
        else
          {:cont, %{acc | chunks: [data | acc.chunks]}}
        end

      true ->
        transform(acc, :handle_data, [data])
    end
  end

  def event({:trailers, _}, acc), do: {:cont, acc}

  def finish(%{error: reason} = acc) when not is_nil(reason), do: fail(acc, reason)
  def finish(%{status: nil} = acc), do: fail(acc, :missing_response_status)

  def finish(%{response_mode: :buffer} = acc) do
    body = acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    {:ok, headers} = Headers.response_headers(acc.headers, acc.config, mode: header_mode(acc))
    notify(acc, :buffered)

    {:buffered, %{status: acc.status, headers: headers, body: body}, acc.conn, acc.handler_state}
  end

  def finish(acc) do
    result = if send_body?(acc), do: transform(acc, :handle_end, []), else: {:cont, acc}

    case result do
      {:halt, acc} ->
        fail(acc, acc.error)

      {:cont, acc} ->
        acc = finish_response(acc)
        notify(acc, :ok)
        {:ok, acc.conn, acc.handler_state}
    end
  end

  def fail(acc, reason) do
    if acc.sent? do
      Logger.error("Failed to proxy HTTP response (after commitment): #{inspect(reason)}")
    end

    notify(acc, {:error, reason})

    if acc.sent? do
      exit({:upstream_stream_failed, reason})
    end

    {:error, reason, acc.conn, acc.handler_state}
  end

  defp prepare(%{handler: nil} = acc) do
    if send_body?(acc) and acc.config.max_response_body_size == :infinity do
      start(acc)
    else
      {:cont, acc}
    end
  end

  defp prepare(acc) do
    callbacks =
      Map.new([handle_data: 2, handle_end: 1], fn {callback, arity} ->
        {callback, function_exported?(acc.handler, callback, arity)}
      end)

    acc = %{acc | callbacks: callbacks}

    case acc.handler.handle_headers(acc.status, acc.headers, acc.handler_state) do
      {:stream, headers, state} when is_list(headers) ->
        prepare_stream(acc, headers, state, :output)

      {:stream, headers, state, []} when is_list(headers) ->
        prepare_stream(acc, headers, state, :output)

      {:stream, headers, state, commit: commitment}
      when is_list(headers) and commitment in [:headers, :output] ->
        prepare_stream(acc, headers, state, commitment)

      {:buffer, limit, state} when is_integer(limit) and limit >= 0 ->
        acc = %{acc | response_mode: :buffer, buffer_limit: limit, handler_state: state}

        if send_body?(acc) and content_length_exceeds?(acc.headers, limit) do
          halt(acc, :response_buffer_too_large)
        else
          {:cont, acc}
        end

      {:error, reason, state} ->
        halt(%{acc | handler_state: state}, reason)

      _invalid ->
        halt(acc, {:invalid_handler_return, :handle_headers})
    end
  end

  defp prepare_stream(acc, headers, state, commitment) do
    # A transforming stream must never retain an upstream byte count.
    mode = if send_body?(acc), do: :bodyless, else: header_mode(acc)
    acc = %{acc | handler_state: state}

    case Headers.response_headers(headers, acc.config, mode: mode) do
      {:ok, headers} ->
        acc = %{acc | headers: headers}
        acc = if commitment == :headers, do: finish_response(acc), else: acc
        {:cont, acc}

      {:error, reason} ->
        halt(acc, reason)
    end
  end

  defp transform(acc, callback, args) do
    result =
      if acc.callbacks[callback] do
        apply(acc.handler, callback, args ++ [acc.handler_state])
      else
        {:ok, List.first(args) || "", acc.handler_state}
      end

    case result do
      {:ok, data, state} -> emit(%{acc | handler_state: state}, data)
      {:error, reason, state} -> halt(%{acc | handler_state: state}, reason)
    end
  end

  defp emit(acc, data) do
    size = IO.iodata_length(data)
    acc = %{acc | output_bytes: acc.output_bytes + size}

    cond do
      exceeds?(acc.output_bytes, acc.config.max_response_body_size) ->
        halt(acc, :response_body_too_large)

      size == 0 ->
        {:cont, acc}

      true ->
        with {:cont, acc} <- start(acc) do
          case Plug.Conn.chunk(acc.conn, data) do
            {:ok, conn} -> {:cont, %{acc | conn: conn}}
            {:error, reason} -> halt(acc, {:downstream, reason})
          end
        end
    end
  end

  defp start(%{sent?: true} = acc), do: {:cont, acc}

  defp start(acc) do
    conn =
      acc.conn |> Headers.put_response_headers(acc.headers) |> Plug.Conn.send_chunked(acc.status)

    {:cont, %{acc | conn: conn, sent?: true}}
  end

  defp finish_response(%{sent?: true} = acc), do: acc

  defp finish_response(acc) do
    if send_body?(acc) do
      {:cont, acc} = start(acc)
      acc
    else
      {:ok, headers} = Headers.response_headers(acc.headers, acc.config, mode: header_mode(acc))

      conn =
        acc.conn
        |> Headers.put_response_headers(headers)
        |> Plug.Conn.send_resp(acc.status, "")

      %{acc | conn: conn, sent?: true}
    end
  end

  defp notify(%{handler: nil}, _), do: :ok

  defp notify(acc, outcome) do
    if function_exported?(acc.handler, :terminate, 2) do
      acc.handler.terminate(outcome, acc.handler_state)
    end
  end

  defp header_mode(%{method: "HEAD"}), do: :identity

  defp header_mode(acc), do: if(send_body?(acc), do: :identity, else: :bodyless)

  defp halt(acc, reason), do: {:halt, %{acc | error: reason}}

  defp send_body?(%{method: "HEAD"}), do: false
  defp send_body?(%{status: status}) when status in 100..199 or status in [204, 304], do: false
  defp send_body?(_), do: true

  defp exceeds?(_, :infinity), do: false
  defp exceeds?(size, limit), do: size > limit

  defp content_length_exceeds?(_, :infinity), do: false

  defp content_length_exceeds?(headers, limit) do
    Enum.any?(headers, fn {name, value} ->
      name == "content-length" and match?({size, ""} when size > limit, Integer.parse(value))
    end)
  end
end
