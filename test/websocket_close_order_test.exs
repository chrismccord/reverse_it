defmodule ReverseIt.WebSocketCloseOrderTest do
  use ExUnit.Case, async: true

  alias ReverseIt.WebSocketProxy

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)
         {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)
         [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, request)
         accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

         :ok =
           :gen_tcp.send(socket, [
             "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n",
             "Sec-WebSocket-Accept: ",
             Base.encode64(accept),
             "\r\n\r\n"
           ])

         {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
       end}
    )

    config = ReverseIt.init(backend: "http://127.0.0.1:#{port}", name: ReverseIt.TestFinch)
    client = %{headers: [], remote_ip: "127.0.0.1", scheme: "http", host: "localhost"}
    {:ok, state, _headers} = ReverseIt.WebSocketHandshake.open(config, client, "/", "")
    on_exit(fn -> Mint.HTTP.close(state.conn) end)
    %{state: state}
  end

  test "data before close is delivered in order with the backend close code and reason", %{
    state: state
  } do
    data = <<0x81, 3, "one", 0x82, 3, "two", 0x88, 6, 1001::16, "away">>

    assert {:stop, :normal, {1001, "away"}, [{:text, "one"}, {:binary, "two"}], _} =
             deliver(data, state)
  end

  test "close without a payload preserves preceding data and uses a valid wire close code", %{
    state: state
  } do
    assert {:stop, :normal, {1000, ""}, [{:text, "one"}], _} =
             deliver(<<0x81, 3, "one", 0x88, 0>>, state)
  end

  test "frames after close are not forwarded", %{state: state} do
    assert {:stop, :normal, {1000, ""}, _} =
             deliver(<<0x88, 2, 1000::16, 0x81, 4, "late">>, state)
  end

  test "ordinary data and control frames keep their original order", %{state: state} do
    assert {:push, [{:text, "one"}, {:ping, "?"}, {:pong, "!"}, {:binary, "two"}], _} =
             deliver(<<0x81, 3, "one", 0x89, 1, "?", 0x8A, 1, "!", 0x82, 3, "two">>, state)
  end

  defp deliver(data, state) do
    WebSocketProxy.handle_info({:tcp, Mint.HTTP.get_socket(state.conn), data}, state)
  end
end
