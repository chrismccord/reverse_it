defmodule ReverseIt.ConnectRetryTest do
  use ExUnit.Case, async: false

  @event [:finch, :connect, :stop]

  setup do
    {:ok, probe} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(probe)
    :gen_tcp.close(probe)
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      @event,
      fn _event, _m, meta, _ -> send(test, {:connect, Map.has_key?(meta, :error)}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    %{port: port}
  end

  defp proxy(name, port, opts \\ []) do
    start_supervised!({ReverseIt, name: name, pool_size: 1, connect_timeout: 500})

    ReverseIt.init(
      [backend: "http://127.0.0.1:#{port}", name: name, response_header_timeout: 2_000] ++ opts
    )
  end

  defp connects do
    receive do
      {:connect, failed?} -> [failed? | connects()]
    after
      0 -> []
    end
  end

  # Opens the backend once the proxy's first connect has failed.
  defp serve_after_refused(port, response) do
    test = self()

    id = {__MODULE__, :serve, make_ref()}

    :telemetry.attach(
      id,
      @event,
      fn _event, _m, meta, _ ->
        if Map.has_key?(meta, :error) do
          :telemetry.detach(id)

          {:ok, listener} =
            :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

          pid =
            spawn(fn ->
              {:ok, socket} = :gen_tcp.accept(listener)
              send(test, {:backend_request, read_request(socket, "")})
              :ok = :gen_tcp.send(socket, response)
              Process.sleep(100)
              :gen_tcp.close(socket)
              :gen_tcp.close(listener)
            end)

          :gen_tcp.controlling_process(listener, pid)
        end
      end,
      nil
    )
  end

  # Reads one request: headers, plus a Content-Length or chunked body.
  defp read_request(socket, acc) do
    complete? =
      case String.split(acc, "\r\n\r\n", parts: 2) do
        [head, body] ->
          cond do
            head =~ ~r/transfer-encoding: chunked/i ->
              String.ends_with?(body, "0\r\n\r\n")

            m = Regex.run(~r/content-length: (\d+)/i, head) ->
              byte_size(body) >= String.to_integer(List.last(m))

            true ->
              true
          end

        _ ->
          false
      end

    if complete? do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      read_request(socket, acc <> data)
    end
  end

  test "a request whose connection fails to open goes once more, for any method", %{port: port} do
    config = proxy(__MODULE__.RetryPut, port)
    serve_after_refused(port, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")

    conn = Plug.Test.conn("PUT", "/object", "body") |> ReverseIt.call(config)

    assert conn.status == 200
    assert conn.resp_body == "ok"
    assert_received {:backend_request, "PUT /object" <> _}
    assert connects() == [true, false]
  end

  test "a streamed upload whose connection fails to open is sent in full on the retry", %{
    port: port
  } do
    config = proxy(__MODULE__.RetryStream, port, request_body_buffer_size: 16)
    serve_after_refused(port, "HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n")

    body = :binary.copy("x", 64)
    conn = Plug.Test.conn("PUT", "/object", body) |> ReverseIt.call(config)

    assert conn.status == 201
    assert_received {:backend_request, request}
    [_head, chunked] = String.split(request, "\r\n\r\n", parts: 2)
    assert chunked |> String.graphemes() |> Enum.count(&(&1 == "x")) == byte_size(body)
    assert connects() == [true, false]
  end

  test "it retries once, then fails", %{port: port} do
    config = proxy(__MODULE__.GiveUp, port)

    conn = Plug.Test.conn("PUT", "/object", "body") |> ReverseIt.call(config)

    assert conn.status == 502
    assert connects() == [true, true]
  end

  test "connect_retries: 0 turns it off", %{port: port} do
    config = proxy(__MODULE__.Off, port, connect_retries: 0)

    conn = Plug.Test.conn("PUT", "/object", "body") |> ReverseIt.call(config)

    assert conn.status == 502
    assert connects() == [true]
  end

  test "a request that reached the backend is not retried when the response times out" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    test = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
      send(test, :backend_request)
      Process.sleep(2_000)
      :gen_tcp.close(socket)
    end)

    config =
      proxy(__MODULE__.NoReadRetry, port,
        response_header_timeout: 200,
        upstream_idle_timeout: 200
      )

    conn = Plug.Test.conn("PUT", "/object", "body") |> ReverseIt.call(config)

    assert conn.status in [502, 504]
    assert_received :backend_request
    refute_received :backend_request
    assert connects() == [false]
    :gen_tcp.close(listener)
  end
end
