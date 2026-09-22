defmodule ReverseIt.ResponseStream do
  @moduledoc false
  alias ReverseIt.Headers

  def new(conn, config) do
    {handler, state} = config.response_handler || {nil, nil}

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
      mode: :stream,
      buffer_limit: nil,
      chunks: []
    }
  end

  def event({:status, status}, acc), do: {:cont, %{acc | status: status}}

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
      not send_body?(acc) ->
        {:cont, acc}

      exceeds?(acc.response_bytes, acc.config.max_response_body_size) ->
        halt(acc, :response_body_too_large)

      acc.mode == :buffer ->
        if acc.response_bytes > acc.buffer_limit,
          do: halt(acc, :response_buffer_too_large),
          else: {:cont, %{acc | chunks: [data | acc.chunks]}}

      true ->
        transform(acc, :handle_data, [data])
    end
  end

  def event({:trailers, _}, acc), do: {:cont, acc}

  defp prepare(%{handler: nil} = acc), do: maybe_start(acc)

  defp prepare(acc) do
    case acc.handler.handle_headers(acc.status, acc.headers, acc.handler_state) do
      {:stream, headers, state} ->
        # A transforming stream must never retain an upstream byte count.
        mode = if send_body?(acc), do: :bodyless, else: :identity

        case Headers.response_headers(headers, acc.config, mode: mode) do
          {:ok, headers} -> maybe_start(%{acc | headers: headers, handler_state: state})
          {:error, reason} -> halt(%{acc | handler_state: state}, reason)
        end

      {:buffer, limit, state} when is_integer(limit) and limit >= 0 ->
        acc = %{acc | mode: :buffer, buffer_limit: limit, handler_state: state}

        if send_body?(acc) and content_length_exceeds?(acc.headers, limit),
          do: halt(acc, :response_buffer_too_large),
          else: {:cont, acc}

      {:error, reason, state} ->
        halt(%{acc | handler_state: state}, reason)
    end
  end

  defp maybe_start(acc) do
    cond do
      not send_body?(acc) -> {:cont, acc}
      acc.config.max_response_body_size == :infinity -> start(acc)
      true -> {:cont, acc}
    end
  end

  defp transform(acc, callback, args) do
    result =
      if acc.handler && function_exported?(acc.handler, callback, length(args) + 1),
        do: apply(acc.handler, callback, args ++ [acc.handler_state]),
        else: {:ok, List.first(args) || "", acc.handler_state}

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

  def finish(%{error: reason} = acc) when not is_nil(reason), do: fail(acc, reason)
  def finish(%{status: nil} = acc), do: fail(acc, :missing_response_status)

  def finish(%{mode: :buffer} = acc) do
    body = acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    notify(acc, :buffered)

    {:buffered, %{status: acc.status, headers: acc.headers, body: body}, acc.conn,
     acc.handler_state}
  end

  def finish(acc) do
    result = if send_body?(acc), do: transform(acc, :handle_end, []), else: {:cont, acc}

    case result do
      {:halt, acc} ->
        fail(acc, acc.error)

      {:cont, acc} ->
        acc =
          if send_body?(acc) do
            {:cont, acc} = start(acc)
            acc
          else
            mode = if acc.method == "HEAD", do: :identity, else: :bodyless
            {:ok, headers} = Headers.response_headers(acc.headers, acc.config, mode: mode)

            conn =
              acc.conn
              |> Headers.put_response_headers(headers)
              |> Plug.Conn.send_resp(acc.status, "")

            %{acc | conn: conn, sent?: true}
          end

        notify(acc, :ok)
        {:ok, acc.conn, acc.handler_state}
    end
  end

  def fail(acc, reason) do
    notify(acc, {:error, reason})
    if acc.sent?, do: exit({:upstream_stream_failed, reason})
    {:error, reason, acc.conn, acc.handler_state}
  end

  defp notify(%{handler: nil}, _), do: :ok

  defp notify(acc, outcome) do
    if function_exported?(acc.handler, :terminate, 2),
      do: acc.handler.terminate(outcome, acc.handler_state)
  end

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
